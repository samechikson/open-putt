from fastapi import FastAPI, File, UploadFile, Form, HTTPException, Header, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, FileResponse
import logging
import tempfile
import os
import uuid
import hmac
import asyncio
from typing import Optional
from .analyzer import (
    CalibrationError,
    analyze_putt,
    analyze_session,
    detect_ball_in_frame,
    check_calibration_frame,
)
from .db import (
    persist_session,
    create_pending_session,
    set_session_status,
    get_session_video_path,
    delete_session,
    update_session_metadata,
)
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
async def create_upload(request: Request):
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
async def analyze_session_endpoint(request: Request):
    """Queue analysis of a video already uploaded to storage.

    Body: `{session_id, object_name, gate_width_px?, gate_width_mm?, fps?}` plus
    optional metadata (`user_id, file_name, captured_at, duration, length_feet,
    break_type`). Creates the session row as 'queued' and starts the analysis in
    the background (a Cloud Task, or in-process in local mode). Clients watch the
    row via Supabase Realtime for 'done'/'error'. Returns immediately with 202.
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

    metadata = {
        "user_id": body.get("user_id"),
        "file_name": body.get("file_name"),
        "captured_at": body.get("captured_at"),
        "ios_duration_s": body.get("duration"),
        "length_feet": body.get("length_feet"),
        "break_type": body.get("break_type"),
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
            await run_in_threadpool(set_session_status, session_id, "error", "Could not start analysis.")
            await run_in_threadpool(cloud.delete_object, object_name)
            logger.exception("Failed to enqueue task for session %s", session_id)
            raise HTTPException(status_code=503, detail="Could not queue analysis. Try again.")

    return JSONResponse(
        {"session_id": session_id, "status": "queued"}, status_code=202
    )


async def _record_error(session_id: str, object_name: str, message: str) -> None:
    """Terminal failure: record the message on the row and drop the upload."""
    await run_in_threadpool(set_session_status, session_id, "error", message)
    await run_in_threadpool(cloud.delete_object, object_name)


async def _process_session(
    session_id: str,
    object_name: str,
    metadata: dict,
    gate_width_px: int,
    gate_width_mm: float,
    fps: float,
) -> None:
    """Analyze one queued session and drive its row to done/error.

    Domain failures (calibration / no putts / bad video) are recorded on the row
    and return normally. Unexpected/infra errors propagate so the caller can
    decide whether to retry.
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
            await _record_error(session_id, object_name, str(exc))
            return

        if "error" in result:
            await _record_error(session_id, object_name, result["error"])
            return
        if not result.get("putts"):
            await _record_error(session_id, object_name, _no_putts_message(result))
            return

        # Retain the video for playback: copy it to the 90-day `sessions/` prefix
        # and record the path, then drop the transient `uploads/` copy.
        retained = cloud.retained_object_name(object_name)
        await run_in_threadpool(cloud.copy_object, object_name, retained)
        await run_in_threadpool(
            persist_session, session_id, {**metadata, "video_path": retained}, result
        )
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
) -> None:
    """In-process worker for local mode; records an error on unexpected failure."""
    try:
        await _process_session(session_id, object_name, metadata, gate_width_px, gate_width_mm, fps)
    except Exception:  # noqa: BLE001
        logger.exception("Local job %s failed", session_id)
        try:
            await _record_error(session_id, object_name, "Analysis failed unexpectedly.")
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
    retry_count = int(request.headers.get("X-CloudTasks-TaskRetryCount", "0"))

    try:
        await _process_session(
            session_id,
            object_name,
            payload.get("metadata") or {},
            int(payload.get("gate_width_px") or 0),
            float(payload.get("gate_width_mm") or 0.0),
            float(payload.get("fps") or 0.0),
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
                await _record_error(session_id, object_name, "Analysis failed unexpectedly.")
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
async def calibration_check(frame: UploadFile = File(...)):
    """Pre-flight for the iOS "Capture test": given one live frame, report
    whether the laser gate and the resting ball are both visible, so the player
    can fix the scene before recording a putt they can't analyze."""
    data = await frame.read()
    result = await run_in_threadpool(check_calibration_frame, data)
    return JSONResponse(result)


@app.get("/sessions/{session_id}/video")
async def session_video_url(session_id: str):
    """Return a short-lived signed URL to stream a session's retained video.

    The session id is an unguessable UUID and the URL expires quickly; there's
    no ownership check (the row itself is RLS-protected in Supabase).
    """
    if not cloud.storage_ready():
        raise HTTPException(status_code=503, detail="Video storage is not configured.")
    video_path = await run_in_threadpool(get_session_video_path, session_id)
    if not video_path:
        raise HTTPException(status_code=404, detail="No video for this session.")
    url = await run_in_threadpool(cloud.download_url_for, video_path)
    return JSONResponse({"url": url})


@app.delete("/sessions/{session_id}")
async def delete_session_endpoint(session_id: str):
    """Delete a session: its putts, the row, and the retained video. Idempotent.

    No ownership check (consistent with the video endpoint): session ids are
    unguessable UUIDs and the rows are RLS-protected in Supabase.
    """
    video_path = await run_in_threadpool(get_session_video_path, session_id)
    if video_path:
        await run_in_threadpool(cloud.delete_object, video_path)
    await run_in_threadpool(delete_session, session_id)
    return JSONResponse({"status": "deleted"})


@app.patch("/sessions/{session_id}")
async def update_session_endpoint(session_id: str, request: Request):
    """Update a session's editable metadata: putt distance and break type.

    Body: `{length_feet?, break_type?}`. Either may be null to clear it. No
    ownership check (consistent with the other session endpoints): ids are
    unguessable UUIDs and the rows are RLS-protected in Supabase.
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

    await run_in_threadpool(
        update_session_metadata, session_id, length_feet, break_type
    )
    return JSONResponse({"status": "updated"})
