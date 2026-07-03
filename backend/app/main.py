from fastapi import FastAPI, File, UploadFile, Form, HTTPException
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import logging
import tempfile
import os
import uuid
from typing import Optional
from .analyzer import CalibrationError, analyze_putt, analyze_session, detect_ball_in_frame
from .db import persist_session

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


@app.post("/analyze-session")
async def analyze_session_endpoint(
    video: UploadFile = File(...),
    gate_width_px: int = Form(default=0),
    gate_width_mm: float = Form(default=0.0),
    fps: float = Form(default=0.0),
    # Optional iOS Recording metadata; when present the session is persisted.
    recording_id: Optional[str] = Form(default=None),
    captured_at: Optional[str] = Form(default=None),
    duration: Optional[float] = Form(default=None),
    length_feet: Optional[int] = Form(default=None),
    break_type: Optional[str] = Form(default=None),
    user_id: Optional[str] = Form(default=None),
):
    """Analyze a video containing multiple putts.

    Calibration is derived from the laser dots and the resting ball on a quiet
    frame; pass both gate_width fields to override the mm-per-px scale. When the
    optional iOS metadata fields are supplied, the session and its putts are
    persisted to Supabase and the session id is echoed back.
    """
    if not video.content_type.startswith("video/"):
        raise HTTPException(status_code=400, detail="File must be a video")

    tmp_path = await _save_upload_to_temp(video)

    try:
        # Offload the blocking, decode-bound analysis to a thread so the event
        # loop stays free to answer health checks and other requests.
        result = await run_in_threadpool(
            analyze_session,
            video_path=tmp_path,
            gate_width_px=gate_width_px or None,
            gate_width_mm=gate_width_mm or None,
            fps=fps or None,
        )
    except CalibrationError as exc:
        # `exc` is already a plain-language, actionable message.
        raise HTTPException(status_code=422, detail=str(exc))
    finally:
        os.unlink(tmp_path)

    if "error" in result:
        raise HTTPException(status_code=400, detail=result["error"])

    # Calibration succeeded but no motion segment was a real putt — tell the
    # user rather than returning an empty, silently-successful result.
    if not result.get("putts"):
        segments = result.get("segments_detected", 0)
        if segments:
            detail = (
                f"Found {segments} movement"
                f"{'s' if segments != 1 else ''} in the video but none looked "
                "like a putt rolling through the gate. Make sure the ball rolls "
                "cleanly through both lasers."
            )
        else:
            detail = (
                "No putts were detected in the video. Record the ball rolling "
                "through the gate, and keep the camera steady."
            )
        raise HTTPException(status_code=422, detail=detail)

    # Persist after a successful analysis. A DB failure must not break the
    # response, so log and continue.
    session_id = recording_id or str(uuid.uuid4())
    try:
        # persist_session makes blocking Supabase HTTP calls; keep them off the
        # event loop too.
        persisted = await run_in_threadpool(
            persist_session,
            session_id=session_id,
            metadata={
                "user_id": user_id,
                "file_name": video.filename,
                "captured_at": captured_at,
                "ios_duration_s": duration,
                "length_feet": length_feet,
                "break_type": break_type,
            },
            result=result,
        )
        if persisted is not None:
            result["session_id"] = persisted
    except Exception:  # noqa: BLE001 — persistence is best-effort
        logger.exception("Failed to persist session %s", session_id)

    return JSONResponse(result)


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
