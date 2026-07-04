from fastapi import FastAPI, File, UploadFile, Form, HTTPException, Header, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import logging
import tempfile
import os
import uuid
import hmac
from typing import Optional
from .analyzer import CalibrationError, analyze_putt, analyze_session, detect_ball_in_frame
from .db import (
    persist_session,
    create_pending_session,
    set_session_status,
    get_session_video_path,
)
from . import cloud

logger = logging.getLogger(__name__)

# Read uploads off the wire in 1 MiB chunks so a large clip is never held whole
# in memory — critical for the 200 MB+ session videos.
_UPLOAD_CHUNK = 1 << 20


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
    """Mint a short-lived signed URL for the client to PUT its video straight to
    Cloud Storage, bypassing Cloud Run's 32 MiB request-body limit.

    Body: `{filename?, recording_id?}`. Returns `{session_id, object_name,
    upload_url}`. The client PUTs the bytes to `upload_url`, then calls
    `/analyze-session` with `session_id` + `object_name`.
    """
    if not cloud.tasks_enabled():
        raise HTTPException(status_code=503, detail="Analysis backend is not configured.")

    body = await request.json()
    session_id = body.get("recording_id") or str(uuid.uuid4())
    object_name = cloud.object_name_for(session_id, body.get("filename"))
    try:
        upload_url = await run_in_threadpool(cloud.generate_upload_url, object_name)
    except Exception:  # noqa: BLE001
        logger.exception("Failed to sign upload URL for %s", object_name)
        raise HTTPException(status_code=503, detail="Could not start upload. Try again.")

    return JSONResponse(
        {"session_id": session_id, "object_name": object_name, "upload_url": upload_url},
        status_code=201,
    )


@app.post("/analyze-session", status_code=202)
async def analyze_session_endpoint(request: Request):
    """Queue analysis of a video already uploaded to Cloud Storage.

    Body: `{session_id, object_name, gate_width_px?, gate_width_mm?, fps?}` plus
    optional metadata (`user_id, file_name, captured_at, duration, length_feet,
    break_type`). Creates the session row as 'queued' and enqueues a Cloud Task
    that analyzes the clip in a separate `/process` request. Clients watch the row
    via Supabase Realtime for 'done'/'error'. Returns immediately with 202.
    """
    if not cloud.tasks_enabled():
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

    # Create the row before returning so the client can immediately subscribe.
    try:
        await run_in_threadpool(create_pending_session, session_id, metadata)
    except Exception:  # noqa: BLE001
        await run_in_threadpool(cloud.delete_gcs_object, object_name)
        logger.exception("Failed to create pending session %s", session_id)
        raise HTTPException(status_code=503, detail="Could not queue analysis. Try again.")

    # Enqueue the background analysis. If this fails, mark the row so the client
    # doesn't wait forever.
    try:
        await run_in_threadpool(
            cloud.enqueue_process_task,
            {
                "session_id": session_id,
                "object_name": object_name,
                "gate_width_px": int(body.get("gate_width_px") or 0),
                "gate_width_mm": float(body.get("gate_width_mm") or 0.0),
                "fps": float(body.get("fps") or 0.0),
                "metadata": metadata,
            },
        )
    except Exception:  # noqa: BLE001
        await run_in_threadpool(set_session_status, session_id, "error", "Could not start analysis.")
        await run_in_threadpool(cloud.delete_gcs_object, object_name)
        logger.exception("Failed to enqueue task for session %s", session_id)
        raise HTTPException(status_code=503, detail="Could not queue analysis. Try again.")

    return JSONResponse(
        {"session_id": session_id, "status": "queued"}, status_code=202
    )


async def _record_error(session_id: str, object_name: str, message: str) -> None:
    """Terminal failure: record the message on the row and drop the upload."""
    await run_in_threadpool(set_session_status, session_id, "error", message)
    await run_in_threadpool(cloud.delete_gcs_object, object_name)


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
    metadata = payload.get("metadata") or {}
    gate_width_px = int(payload.get("gate_width_px") or 0)
    gate_width_mm = float(payload.get("gate_width_mm") or 0.0)
    fps = float(payload.get("fps") or 0.0)
    retry_count = int(request.headers.get("X-CloudTasks-TaskRetryCount", "0"))

    tmp_path: Optional[str] = None
    try:
        await run_in_threadpool(set_session_status, session_id, "processing")
        tmp_path = await run_in_threadpool(cloud.download_gcs_to_temp, object_name)

        try:
            result = await run_in_threadpool(
                analyze_session,
                video_path=tmp_path,
                gate_width_px=gate_width_px or None,
                gate_width_mm=gate_width_mm or None,
                fps=fps or None,
            )
        except CalibrationError as exc:
            # `exc` is already a plain-language, actionable message.
            await _record_error(session_id, object_name, str(exc))
            return JSONResponse({"status": "error"})

        if "error" in result:
            await _record_error(session_id, object_name, result["error"])
            return JSONResponse({"status": "error"})
        if not result.get("putts"):
            await _record_error(session_id, object_name, _no_putts_message(result))
            return JSONResponse({"status": "error"})

        # Retain the video for playback: copy it to the 90-day `sessions/` prefix
        # and record the path, then drop the transient `uploads/` copy.
        retained = cloud.retained_object_name(object_name)
        await run_in_threadpool(cloud.copy_gcs_object, object_name, retained)
        metadata = {**metadata, "video_path": retained}
        await run_in_threadpool(persist_session, session_id, metadata, result)
        await run_in_threadpool(cloud.delete_gcs_object, object_name)
        return JSONResponse({"status": "done"})

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
        # Let Cloud Tasks retry with backoff; keep the GCS object for the retry.
        raise HTTPException(status_code=500, detail="Processing failed; will retry")
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


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


@app.get("/sessions/{session_id}/video")
async def session_video_url(session_id: str):
    """Return a short-lived signed URL to stream a session's retained video.

    The session id is an unguessable UUID and the URL expires quickly; there's
    no ownership check (the row itself is RLS-protected in Supabase).
    """
    if not cloud.tasks_enabled():
        raise HTTPException(status_code=503, detail="Video storage is not configured.")
    video_path = await run_in_threadpool(get_session_video_path, session_id)
    if not video_path:
        raise HTTPException(status_code=404, detail="No video for this session.")
    url = await run_in_threadpool(cloud.generate_download_url, video_path)
    return JSONResponse({"url": url})
