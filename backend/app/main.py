from fastapi import FastAPI, File, UploadFile, Form, HTTPException
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import logging
import tempfile
import os
import uuid
import asyncio
from typing import Optional
from .analyzer import CalibrationError, analyze_putt, analyze_session, detect_ball_in_frame
from .db import persist_session, create_pending_session, set_session_status

# Cap concurrent background analyses so a small instance isn't overwhelmed;
# extra jobs wait their turn in 'queued'. Tune with MAX_CONCURRENT_JOBS.
_JOB_SEMAPHORE = asyncio.Semaphore(int(os.environ.get("MAX_CONCURRENT_JOBS", "1")))

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


async def _run_session_job(
    session_id: str,
    tmp_path: str,
    metadata: dict,
    gate_width_px: int,
    gate_width_mm: float,
    fps: float,
) -> None:
    """Background worker: analyze the clip and drive the session row through
    processing → done/error. Never raises; failures are recorded on the row."""
    try:
        async with _JOB_SEMAPHORE:  # bound concurrent heavy analyses
            await run_in_threadpool(set_session_status, session_id, "processing")
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
                await run_in_threadpool(set_session_status, session_id, "error", str(exc))
                return

            if "error" in result:
                await run_in_threadpool(set_session_status, session_id, "error", result["error"])
                return
            if not result.get("putts"):
                await run_in_threadpool(
                    set_session_status, session_id, "error", _no_putts_message(result)
                )
                return

            # persist_session upserts the full row (status 'done') and its putts.
            await run_in_threadpool(persist_session, session_id, metadata, result)
    except Exception:  # noqa: BLE001 — a job failure must not crash the worker
        logger.exception("Session job %s failed", session_id)
        try:
            await run_in_threadpool(
                set_session_status, session_id, "error", "Analysis failed unexpectedly."
            )
        except Exception:  # noqa: BLE001
            logger.exception("Could not mark session %s as failed", session_id)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


@app.post("/analyze-session", status_code=202)
async def analyze_session_endpoint(
    video: UploadFile = File(...),
    gate_width_px: int = Form(default=0),
    gate_width_mm: float = Form(default=0.0),
    fps: float = Form(default=0.0),
    # Optional iOS Recording metadata; used to tag/identify the session.
    recording_id: Optional[str] = Form(default=None),
    captured_at: Optional[str] = Form(default=None),
    duration: Optional[float] = Form(default=None),
    length_feet: Optional[int] = Form(default=None),
    break_type: Optional[str] = Form(default=None),
    user_id: Optional[str] = Form(default=None),
):
    """Queue analysis of a multi-putt video and return immediately.

    Analysis is decode-bound and can run for minutes, so instead of holding the
    request open we create the session row as 'queued', kick off a background
    job, and return its id. Clients watch the row (via Supabase Realtime) for the
    transition to 'done' (results + putts persisted) or 'error' (message on the
    row). Calibration is automatic; pass both gate_width fields to override the
    mm-per-px scale.
    """
    if not video.content_type.startswith("video/"):
        raise HTTPException(status_code=400, detail="File must be a video")

    tmp_path = await _save_upload_to_temp(video)
    session_id = recording_id or str(uuid.uuid4())
    metadata = {
        "user_id": user_id,
        "file_name": video.filename,
        "captured_at": captured_at,
        "ios_duration_s": duration,
        "length_feet": length_feet,
        "break_type": break_type,
    }

    # Create the row before returning so the client can immediately subscribe.
    try:
        await run_in_threadpool(create_pending_session, session_id, metadata)
    except Exception:  # noqa: BLE001
        os.unlink(tmp_path)
        logger.exception("Failed to create pending session %s", session_id)
        raise HTTPException(status_code=503, detail="Could not queue analysis. Try again.")

    # Fire-and-forget: runs independently of this request's lifecycle.
    asyncio.create_task(
        _run_session_job(session_id, tmp_path, metadata, gate_width_px, gate_width_mm, fps)
    )

    return JSONResponse(
        {"session_id": session_id, "status": "queued"}, status_code=202
    )


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
