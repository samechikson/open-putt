from fastapi import (
    FastAPI, File, UploadFile, Form, HTTPException, Header, Request, Depends,
)
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, FileResponse, Response
import logging
import tempfile
import os
import uuid
import hmac
import asyncio
import cv2
from typing import Optional
from .analyzer import (
    CalibrationError,
    analyze_putt,
    analyze_session,
    detect_ball_in_frame,
    check_calibration_frame,
    _read_frame_at,
)
from . import db
from .db import (
    persist_session,
    create_pending_session,
    begin_reanalysis,
    set_session_status,
    get_session_video_path,
    get_putt_crossing_frame,
    delete_session,
    update_session_metadata,
    list_sessions,
    get_session,
    list_putts,
    offsets_for_sessions,
    list_putters,
    create_putter,
    update_putter,
    delete_putter,
    set_active_putter,
)
from .auth import require_user
from . import cloud

logger = logging.getLogger(__name__)

# Read uploads off the wire in 1 MiB chunks so a large clip is never held whole
# in memory — critical for the 200 MB+ session videos.
_UPLOAD_CHUNK = 1 << 20

# The `putt_break` enum values (mirror of supabase/migrations/0001_sessions.sql).
# Used to validate the break_type on a session metadata edit.
_BREAK_TYPES = frozenset(
    {
        "straight",
        "leftToRight",
        "rightToLeft",
        "uphillStraight",
        "uphillLeftToRight",
        "uphillRightToLeft",
        "downhillStraight",
        "downhillLeftToRight",
        "downhillRightToLeft",
    }
)


async def _save_upload_to_temp(upload: UploadFile) -> str:
    """Stream an uploaded file to a temp file on disk, returning its path.

    Streaming (vs. ``await upload.read()``) keeps memory bounded to one chunk
    regardless of clip size.
    """
    suffix = os.path.splitext(upload.filename or "video.mp4")[1] or ".mp4"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        while chunk := await upload.read(_UPLOAD_CHUNK):
            tmp.write(chunk)
        return tmp.name

app = FastAPI(title="Putting Gate Analyzer")

# Allowed browser origins. Defaults cover local dev; set CORS_ALLOW_ORIGINS to a
# comma-separated list (e.g. the deployed frontend URL) in production.
_default_origins = "http://localhost:5173,http://localhost:3000"
allow_origins = [
    o.strip()
    for o in os.environ.get("CORS_ALLOW_ORIGINS", _default_origins).split(",")
    if o.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=allow_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/analyze")
async def analyze(
    video: UploadFile = File(...),
    uid: str = Depends(require_user),
    gate_center_x: int = Form(...),
    gate_line_y: int = Form(...),
    gate_width_px: int = Form(...),
    gate_width_mm: float = Form(default=100.0),
    ball_radius_hint: int = Form(default=0),
    ball_x_hint: int = Form(default=0),
    ball_y_hint: int = Form(default=0),
    aim_top_x: int = Form(default=0),
    aim_top_y: int = Form(default=0),
    fps: float = Form(default=0.0),
):
    if not video.content_type.startswith("video/"):
        raise HTTPException(status_code=400, detail="File must be a video")

    tmp_path = await _save_upload_to_temp(video)

    try:
        # Offload the blocking, decode-bound analysis to a thread so the event
        # loop stays free to answer health checks and other requests.
        result = await run_in_threadpool(
            analyze_putt,
            video_path=tmp_path,
            gate_center_x=gate_center_x,
            gate_line_y=gate_line_y,
            gate_width_px=gate_width_px,
            gate_width_mm=gate_width_mm,
            ball_radius_hint=ball_radius_hint or None,
            ball_x_hint=ball_x_hint or None,
            ball_y_hint=ball_y_hint or None,
            aim_top_x=aim_top_x or None,
            aim_top_y=aim_top_y or None,
            fps=fps or None,
        )
    finally:
        os.unlink(tmp_path)

    return JSONResponse(result)


def _no_putts_message(result: dict) -> str:
    """Actionable message when calibration worked but no segment was a real putt."""
    segments = result.get("segments_detected", 0)
    if segments:
        return (
            f"Found {segments} movement{'s' if segments != 1 else ''} in the "
            "video but none looked like a putt rolling through the gate. Make "
            "sure the ball rolls cleanly through both lasers."
        )
    return (
        "No putts were detected in the video. Record the ball rolling through "
        "the gate, and keep the camera steady."
    )


@app.post("/uploads", status_code=201)
async def create_upload(request: Request, uid: str = Depends(require_user)):
    """Give the client a URL to PUT its video to directly — a signed Cloud
    Storage URL, or this backend's /local-storage endpoint in local mode. Either
    way the video bypasses the request body of the analysis call.

    Body: `{filename?, recording_id?}`. Returns `{session_id, object_name,
    upload_url}`. The client PUTs the bytes to `upload_url`, then calls
    `/analyze-session` with `session_id` + `object_name`.
    """
    if not cloud.storage_ready():
        raise HTTPException(status_code=503, detail="Analysis backend is not configured.")

    body = await request.json()
    session_id = body.get("recording_id") or str(uuid.uuid4())
    object_name = cloud.object_name_for(session_id, body.get("filename"))
    try:
        upload_url = await run_in_threadpool(cloud.upload_url_for, object_name)
    except Exception:  # noqa: BLE001
        logger.exception("Failed to make upload URL for %s", object_name)
        raise HTTPException(status_code=503, detail="Could not start upload. Try again.")

    return JSONResponse(
        {"session_id": session_id, "object_name": object_name, "upload_url": upload_url},
        status_code=201,
    )


@app.post("/analyze-session", status_code=202)
async def analyze_session_endpoint(
    request: Request, uid: str = Depends(require_user)
):
    """Queue analysis of a video already uploaded to storage.

    Body: `{session_id, object_name, gate_width_px?, gate_width_mm?, fps?}` plus
    optional metadata (`file_name, captured_at, duration, length_feet,
    break_type, putter_id`). The owner is the authenticated user (`uid`), not a
    body field; `putter_id` is only applied if the user owns that putter.
    Creates the session row as 'queued' and starts the analysis in the background
    (a Cloud Task, or in-process in local mode). Clients poll the session for
    'done'/'error'. Returns immediately with 202.
    """
    if not cloud.storage_ready():
        raise HTTPException(status_code=503, detail="Analysis backend is not configured.")

    body = await request.json()
    session_id = body.get("session_id")
    object_name = body.get("object_name")
    if not session_id or not object_name:
        raise HTTPException(status_code=400, detail="session_id and object_name are required")
    # Only our own upload namespace is addressable.
    if not object_name.startswith("uploads/"):
        raise HTTPException(status_code=400, detail="Invalid object_name")
    if not await run_in_threadpool(cloud.object_exists, object_name):
        raise HTTPException(status_code=400, detail="Uploaded file not found. Upload it first.")

    putter_id = body.get("putter_id")
    if putter_id is not None:
        try:
            putter_id = str(uuid.UUID(str(putter_id)))
        except (ValueError, TypeError, AttributeError):
            raise HTTPException(status_code=400, detail="putter_id must be a UUID.")

    metadata = {
        "user_id": uid,
        "file_name": body.get("file_name"),
        "captured_at": body.get("captured_at"),
        "ios_duration_s": body.get("duration"),
        "length_feet": body.get("length_feet"),
        "break_type": body.get("break_type"),
        "putter_id": putter_id,
    }
    gate_width_px = int(body.get("gate_width_px") or 0)
    gate_width_mm = float(body.get("gate_width_mm") or 0.0)
    fps = float(body.get("fps") or 0.0)

    # Create the row before returning so the client can immediately subscribe.
    try:
        await run_in_threadpool(create_pending_session, session_id, metadata)
    except Exception:  # noqa: BLE001
        await run_in_threadpool(cloud.delete_object, object_name)
        logger.exception("Failed to create pending session %s", session_id)
        raise HTTPException(status_code=503, detail="Could not queue analysis. Try again.")

    # Start the background analysis. Local mode runs it in-process (the dev server
    # stays alive); prod hands it to Cloud Tasks so a fresh request owns the CPU.
    if cloud.is_local():
        asyncio.create_task(
            _run_local_job(session_id, object_name, metadata, gate_width_px, gate_width_mm, fps)
        )
    else:
        try:
            await run_in_threadpool(
                cloud.enqueue_process_task,
                {
                    "session_id": session_id,
                    "object_name": object_name,
                    "gate_width_px": gate_width_px,
                    "gate_width_mm": gate_width_mm,
                    "fps": fps,
                    "metadata": metadata,
                },
            )
        except Exception:  # noqa: BLE001
            # The row already exists, so retain the clip (rather than lose it) and
            # record the failure on the row before returning.
            await _record_error(session_id, object_name, "Could not start analysis.")
            logger.exception("Failed to enqueue task for session %s", session_id)
            raise HTTPException(status_code=503, detail="Could not queue analysis. Try again.")

    return JSONResponse(
        {"session_id": session_id, "status": "queued"}, status_code=202
    )


@app.post("/sessions/{session_id}/reanalyze", status_code=202)
async def reanalyze_session_endpoint(
    session_id: str, uid: str = Depends(require_user)
):
    """Re-run analysis on a session's already-retained video, on demand.

    Reprocesses the same clip (e.g. after an analyzer improvement) without a
    re-upload: resets the row to 'queued', clears its prior putts, and runs the
    same pipeline against the retained `sessions/` object — which is left in
    place, since it's the only copy. Returns 202; clients poll the session for
    'done'/'error' exactly as they do after the initial upload.
    """
    if not cloud.storage_ready():
        raise HTTPException(status_code=503, detail="Analysis backend is not configured.")

    # Resets the row to 'queued' + clears putts, and returns the retained video
    # path, fps, and metadata to re-run with. None ⇒ not found / not owned / no
    # retained video to re-analyze.
    info = await run_in_threadpool(begin_reanalysis, uid, session_id)
    if info is None:
        raise HTTPException(
            status_code=404,
            detail="Session not found, or it has no saved video to re-analyze.",
        )

    object_name = info["video_path"]
    metadata = info["metadata"]
    fps = float(info.get("fps") or 0.0)

    if not await run_in_threadpool(cloud.object_exists, object_name):
        message = "The saved video is no longer available to re-analyze."
        await _record_error(session_id, object_name, message, already_retained=True)
        raise HTTPException(status_code=409, detail=message)

    if cloud.is_local():
        asyncio.create_task(
            _run_local_job(
                session_id, object_name, metadata, 0, 0.0, fps, already_retained=True
            )
        )
    else:
        try:
            await run_in_threadpool(
                cloud.enqueue_process_task,
                {
                    "session_id": session_id,
                    "object_name": object_name,
                    "gate_width_px": 0,
                    "gate_width_mm": 0.0,
                    "fps": fps,
                    "metadata": metadata,
                    "already_retained": True,
                },
            )
        except Exception:  # noqa: BLE001
            await _record_error(
                session_id, object_name, "Could not start analysis.", already_retained=True
            )
            logger.exception("Failed to enqueue reanalysis for session %s", session_id)
            raise HTTPException(status_code=503, detail="Could not queue analysis. Try again.")

    return JSONResponse(
        {"session_id": session_id, "status": "queued"}, status_code=202
    )


async def _retain_video(object_name: str) -> str:
    """Copy the transient `uploads/` clip to the retained `sessions/` prefix
    (kept for playback/review) and return the retained object path. The caller
    drops the `uploads/` copy once the outcome is terminal."""
    retained = cloud.retained_object_name(object_name)
    await run_in_threadpool(cloud.copy_object, object_name, retained)
    return retained


async def _record_error(
    session_id: str,
    object_name: str,
    message: str,
    already_retained: bool = False,
) -> None:
    """Terminal failure: retain the video for review, record the message and the
    retained video path on the row, then drop the transient upload.

    Every recorded clip is kept in `sessions/` regardless of the analysis
    outcome, so no putt a player captured is ever lost to a calibration miss,
    a no-putt clip, or an unexpected failure.

    On a re-analysis the video is already in `sessions/` (``already_retained``);
    it's both the source and the retained copy, so we neither re-copy nor delete
    it — that would destroy the only clip.
    """
    if already_retained:
        retained = object_name
    else:
        retained = await _retain_video(object_name)
    await run_in_threadpool(set_session_status, session_id, "error", message, retained)
    if not already_retained:
        await run_in_threadpool(cloud.delete_object, object_name)


async def _process_session(
    session_id: str,
    object_name: str,
    metadata: dict,
    gate_width_px: int,
    gate_width_mm: float,
    fps: float,
    already_retained: bool = False,
) -> None:
    """Analyze one queued session and drive its row to done/error.

    Domain failures (calibration / no putts / bad video) are recorded on the row
    and return normally. Unexpected/infra errors propagate so the caller can
    decide whether to retry.

    ``already_retained`` marks a re-analysis whose source is the retained
    `sessions/` clip rather than a fresh `uploads/` object: the video stays where
    it is (no copy, no delete of the source) so the only clip is preserved.
    """
    tmp_path: Optional[str] = None
    try:
        await run_in_threadpool(set_session_status, session_id, "processing")
        tmp_path = await run_in_threadpool(cloud.download_to_temp, object_name)

        try:
            result = await run_in_threadpool(
                analyze_session,
                video_path=tmp_path,
                gate_width_px=gate_width_px or None,
                gate_width_mm=gate_width_mm or None,
                fps=fps or None,
            )
        except CalibrationError as exc:
            await _record_error(session_id, object_name, str(exc), already_retained)
            return

        if "error" in result:
            await _record_error(session_id, object_name, result["error"], already_retained)
            return
        if not result.get("putts"):
            await _record_error(
                session_id, object_name, _no_putts_message(result), already_retained
            )
            return

        # Retain the video for playback: copy it to the 90-day `sessions/` prefix
        # and record the path, then drop the transient `uploads/` copy. On a
        # re-analysis the clip is already retained, so keep it in place.
        retained = object_name if already_retained else await _retain_video(object_name)
        await run_in_threadpool(
            persist_session, session_id, {**metadata, "video_path": retained}, result
        )
        if not already_retained:
            await run_in_threadpool(cloud.delete_object, object_name)
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


async def _run_local_job(
    session_id: str, object_name: str, metadata: dict,
    gate_width_px: int, gate_width_mm: float, fps: float,
    already_retained: bool = False,
) -> None:
    """In-process worker for local mode; records an error on unexpected failure."""
    try:
        await _process_session(
            session_id, object_name, metadata,
            gate_width_px, gate_width_mm, fps, already_retained,
        )
    except Exception:  # noqa: BLE001
        logger.exception("Local job %s failed", session_id)
        try:
            await _record_error(
                session_id, object_name, "Analysis failed unexpectedly.", already_retained
            )
        except Exception:  # noqa: BLE001
            logger.exception("Could not mark session %s as failed", session_id)


@app.post("/process")
async def process_session(
    request: Request,
    x_tasks_token: Optional[str] = Header(default=None),
):
    """Cloud Tasks target: analyze one queued session. CPU is allocated for the
    full duration of this request, so long clips are safe here.

    Returns 200 for terminal outcomes (done or a domain error — both recorded on
    the row) so Cloud Tasks stops; returns 500 on an unexpected/infra error so
    Cloud Tasks retries, giving up (and recording the error) after MAX_RETRIES.
    """
    expected = cloud.TASKS_INTERNAL_TOKEN
    if not expected or not x_tasks_token or not hmac.compare_digest(x_tasks_token, expected):
        raise HTTPException(status_code=403, detail="Forbidden")

    payload = await request.json()
    session_id = payload["session_id"]
    object_name = payload["object_name"]
    already_retained = bool(payload.get("already_retained"))
    retry_count = int(request.headers.get("X-CloudTasks-TaskRetryCount", "0"))

    try:
        await _process_session(
            session_id,
            object_name,
            payload.get("metadata") or {},
            int(payload.get("gate_width_px") or 0),
            float(payload.get("gate_width_mm") or 0.0),
            float(payload.get("fps") or 0.0),
            already_retained,
        )
        return JSONResponse({"status": "processed"})
    except Exception:  # noqa: BLE001 — unexpected/infra error
        max_retries = int(os.environ.get("TASKS_MAX_RETRIES", "3"))
        logger.exception(
            "Processing session %s failed (attempt %s/%s)", session_id, retry_count, max_retries
        )
        if retry_count >= max_retries:
            # Out of retries: record the failure and stop (200 → no more retries).
            try:
                await _record_error(
                    session_id, object_name, "Analysis failed unexpectedly.", already_retained
                )
            except Exception:  # noqa: BLE001
                logger.exception("Cleanup after failure of %s failed", session_id)
            return JSONResponse({"status": "error"})
        # Let Cloud Tasks retry with backoff; keep the object for the retry.
        raise HTTPException(status_code=500, detail="Processing failed; will retry")


# MARK: Local storage (LOCAL_MODE only) — stands in for Cloud Storage on a laptop.


@app.put("/local-storage/{object_path:path}")
async def local_storage_put(object_path: str, request: Request):
    if not cloud.is_local():
        raise HTTPException(status_code=404, detail="Not found")
    try:
        dest = cloud.local_path(object_path)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid path")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with open(dest, "wb") as f:
        async for chunk in request.stream():
            f.write(chunk)
    return JSONResponse({"status": "ok"})


@app.get("/local-storage/{object_path:path}")
async def local_storage_get(object_path: str):
    if not cloud.is_local():
        raise HTTPException(status_code=404, detail="Not found")
    try:
        path = cloud.local_path(object_path)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid path")
    if not path.exists():
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(path)


@app.post("/detect-ball")
async def detect_ball(
    frame: UploadFile = File(...),
    uid: str = Depends(require_user),
    center_x: int = Form(None),
    search_half_width: int = Form(None),
):
    data = await frame.read()
    result = await run_in_threadpool(
        detect_ball_in_frame,
        data, center_x=center_x, search_half_width=search_half_width
    )
    return JSONResponse(result)


@app.post("/calibration-check")
async def calibration_check(
    frame: UploadFile = File(...), uid: str = Depends(require_user)
):
    """Pre-flight for the iOS "Capture test": given one live frame, report
    whether the laser gate and the resting ball are both visible, so the player
    can fix the scene before recording a putt they can't analyze."""
    data = await frame.read()
    result = await run_in_threadpool(check_calibration_frame, data)
    return JSONResponse(result)


# MARK: Session reads (ownership-scoped by the authenticated user)


@app.get("/sessions")
async def sessions_list(uid: str = Depends(require_user)):
    """All of the signed-in user's sessions, newest first."""
    return await run_in_threadpool(list_sessions, uid)


@app.get("/sessions/{session_id}")
async def session_get(session_id: str, uid: str = Depends(require_user)):
    """One session, if it belongs to the signed-in user (polled for status)."""
    row = await run_in_threadpool(get_session, uid, session_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Session not found.")
    return row


@app.get("/sessions/{session_id}/putts")
async def session_putts(session_id: str, uid: str = Depends(require_user)):
    """A session's putts, if the session belongs to the signed-in user."""
    return await run_in_threadpool(list_putts, uid, session_id)


@app.post("/putts/offsets")
async def putts_offsets(request: Request, uid: str = Depends(require_user)):
    """offset_mm for every putt across the given owned sessions (dashboard
    summary). Body: `{session_ids: [...]}`. POST (not GET) so a large id list
    isn't constrained by URL length."""
    body = await request.json()
    session_ids = body.get("session_ids") or []
    if not isinstance(session_ids, list):
        raise HTTPException(status_code=400, detail="session_ids must be a list.")
    offsets = await run_in_threadpool(offsets_for_sessions, uid, session_ids)
    return {"offsets": offsets}


@app.get("/sessions/{session_id}/video")
async def session_video_url(session_id: str, uid: str = Depends(require_user)):
    """Return a short-lived signed URL to stream the user's session video."""
    if not cloud.storage_ready():
        raise HTTPException(status_code=503, detail="Video storage is not configured.")
    video_path = await run_in_threadpool(get_session_video_path, uid, session_id)
    if not video_path:
        raise HTTPException(status_code=404, detail="No video for this session.")
    url = await run_in_threadpool(cloud.download_url_for, video_path)
    return JSONResponse({"url": url})


@app.get("/sessions/{session_id}/putts/{putt_index}/frame")
async def putt_crossing_frame(
    session_id: str, putt_index: int, uid: str = Depends(require_user)
):
    """Serve a JPEG still of the frame where the putt crossed the gate (the
    bottom laser line). 404 when the session has no video, or when the putt has
    no stored crossing frame (legacy putts analyzed before this was recorded).

    Note: seeking is keyframe-granular on iPhone .mov, so the still may land a
    few frames off — fine for a "at the gate" image."""
    if not cloud.storage_ready():
        raise HTTPException(status_code=503, detail="Video storage is not configured.")
    video_path = await run_in_threadpool(get_session_video_path, uid, session_id)
    if not video_path:
        raise HTTPException(status_code=404, detail="No video for this session.")
    frame_idx = await run_in_threadpool(
        get_putt_crossing_frame, uid, session_id, putt_index
    )
    if frame_idx is None:
        raise HTTPException(status_code=404, detail="No crossing frame for this putt.")

    def _render() -> Optional[bytes]:
        tmp_path = cloud.download_to_temp(video_path)
        try:
            frame = _read_frame_at(tmp_path, frame_idx)
            if frame is None:
                return None
            ok, buf = cv2.imencode(".jpg", frame)
            return buf.tobytes() if ok else None
        finally:
            os.unlink(tmp_path)

    jpeg = await run_in_threadpool(_render)
    if jpeg is None:
        raise HTTPException(status_code=404, detail="Could not read the crossing frame.")
    return Response(content=jpeg, media_type="image/jpeg")


@app.delete("/sessions/{session_id}")
async def delete_session_endpoint(session_id: str, uid: str = Depends(require_user)):
    """Delete the user's session: its putts, the row, and the retained video.
    Idempotent — deleting a missing/other-owner session is a no-op."""
    video_path = await run_in_threadpool(get_session_video_path, uid, session_id)
    if video_path:
        await run_in_threadpool(cloud.delete_object, video_path)
    await run_in_threadpool(delete_session, uid, session_id)
    return JSONResponse({"status": "deleted"})


@app.patch("/sessions/{session_id}")
async def update_session_endpoint(
    session_id: str, request: Request, uid: str = Depends(require_user)
):
    """Update the user's session metadata: putt distance, break type, putter.

    Body: `{length_feet?, break_type?, putter_id?}`. Any may be null to clear it.
    """
    body = await request.json()

    length_feet = body.get("length_feet")
    if length_feet is not None:
        try:
            length_feet = int(length_feet)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="length_feet must be an integer.")
        if length_feet < 0:
            raise HTTPException(status_code=400, detail="length_feet must be non-negative.")

    break_type = body.get("break_type")
    if break_type is not None and break_type not in _BREAK_TYPES:
        raise HTTPException(status_code=400, detail="Unknown break_type.")

    putter_id = body.get("putter_id")
    if putter_id is not None:
        try:
            putter_id = str(uuid.UUID(str(putter_id)))
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="putter_id must be a UUID.")

    ok = await run_in_threadpool(
        update_session_metadata, uid, session_id, length_feet, break_type, putter_id
    )
    if not ok:
        raise HTTPException(status_code=404, detail="Session not found.")
    return JSONResponse({"status": "updated"})


# MARK: Putters (owned by the authenticated user; formerly written client-side)


def _putter_fields(body: dict, *, require_name: bool) -> dict:
    """Validate/coerce a putter payload. `name` is required on create."""
    fields: dict = {}
    if "name" in body or require_name:
        name = (body.get("name") or "").strip()
        if require_name and not name:
            raise HTTPException(status_code=400, detail="name is required.")
        if "name" in body:
            fields["name"] = name
    for k in ("brand", "model", "grip"):
        if k in body:
            v = body.get(k)
            fields[k] = v.strip() if isinstance(v, str) else v
    for k in ("length_in", "lie_deg"):
        if k in body:
            v = body.get(k)
            if v is None or v == "":
                fields[k] = None
            else:
                try:
                    fields[k] = float(v)
                except (TypeError, ValueError):
                    raise HTTPException(status_code=400, detail=f"{k} must be a number.")
    return fields


@app.get("/putters")
async def putters_list(uid: str = Depends(require_user)):
    """The user's putters, active first then newest."""
    return await run_in_threadpool(list_putters, uid)


@app.post("/putters", status_code=201)
async def putters_create(request: Request, uid: str = Depends(require_user)):
    """Create a putter owned by the user."""
    fields = _putter_fields(await request.json(), require_name=True)
    row = await run_in_threadpool(create_putter, uid, fields)
    if row is None:
        raise HTTPException(status_code=503, detail="Persistence is not configured.")
    return row  # status 201 from the decorator; FastAPI encodes UUID/datetime


@app.patch("/putters/{putter_id}")
async def putters_update(
    putter_id: str, request: Request, uid: str = Depends(require_user)
):
    """Update the user's putter."""
    fields = _putter_fields(await request.json(), require_name=False)
    row = await run_in_threadpool(update_putter, uid, putter_id, fields)
    if row is None:
        raise HTTPException(status_code=404, detail="Putter not found.")
    return row


@app.delete("/putters/{putter_id}")
async def putters_delete(putter_id: str, uid: str = Depends(require_user)):
    """Delete the user's putter (its sessions are un-tagged)."""
    ok = await run_in_threadpool(delete_putter, uid, putter_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Putter not found.")
    return JSONResponse({"status": "deleted"})


@app.post("/putters/{putter_id}/activate")
async def putters_activate(putter_id: str, uid: str = Depends(require_user)):
    """Make this the user's active (default) putter."""
    ok = await run_in_threadpool(set_active_putter, uid, putter_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Putter not found.")
    return JSONResponse({"status": "activated"})


# The public API is served under /api so the app can sit behind a same-origin
# proxy: Firebase Hosting rewrites `/api/**` to this Cloud Run service, so the
# web frontend never makes a cross-origin API call. Every caller targets the
# same prefix — the frontend (VITE_API_BASE=/api), the iOS app
# (AppSettings.backendBaseURL + /api), and the Cloud Tasks callback
# (PROCESS_URL=.../api/process). The routes above stay defined at the root; this
# outer app is a thin mount. uvicorn serves `application` (see Dockerfile /
# start.sh).
application = FastAPI(title="Putting Gate Analyzer (proxy root)")
application.mount("/api", app)


@application.on_event("shutdown")
def _close_db_pool() -> None:
    # Mounted sub-apps don't receive lifespan events from the parent, so close
    # the DB connection pool here on the served app's shutdown.
    db.close()
