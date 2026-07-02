from fastapi import FastAPI, File, UploadFile, Form, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import tempfile
import os
from .analyzer import CalibrationError, analyze_putt, analyze_session, detect_ball_in_frame

app = FastAPI(title="Putting Gate Analyzer")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://localhost:3000"],
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

    suffix = os.path.splitext(video.filename or "video.mp4")[1] or ".mp4"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(await video.read())
        tmp_path = tmp.name

    try:
        result = analyze_putt(
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
):
    """Analyze a video containing multiple putts.

    Calibration is derived from the laser dots and the resting ball on a quiet
    frame; pass both gate_width fields to override the mm-per-px scale.
    """
    if not video.content_type.startswith("video/"):
        raise HTTPException(status_code=400, detail="File must be a video")

    suffix = os.path.splitext(video.filename or "video.mp4")[1] or ".mp4"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(await video.read())
        tmp_path = tmp.name

    try:
        result = analyze_session(
            video_path=tmp_path,
            gate_width_px=gate_width_px or None,
            gate_width_mm=gate_width_mm or None,
            fps=fps or None,
        )
    except CalibrationError as exc:
        raise HTTPException(
            status_code=422, detail=f"Auto-calibration failed: {exc}"
        )
    finally:
        os.unlink(tmp_path)

    if "error" in result:
        raise HTTPException(status_code=400, detail=result["error"])
    return JSONResponse(result)


@app.post("/detect-ball")
async def detect_ball(
    frame: UploadFile = File(...),
    center_x: int = Form(None),
    search_half_width: int = Form(None),
):
    data = await frame.read()
    result = detect_ball_in_frame(
        data, center_x=center_x, search_half_width=search_half_width
    )
    return JSONResponse(result)
