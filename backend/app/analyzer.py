import cv2
import numpy as np
from typing import Optional


def _brightest_circle(
    gray: np.ndarray, candidates: np.ndarray
) -> Optional[tuple[float, float, float]]:
    best = None
    best_brightness = -1.0
    for c in candidates:
        cx, cy, cr = int(c[0]), int(c[1]), int(c[2])
        mask = np.zeros(gray.shape, dtype=np.uint8)
        cv2.circle(mask, (cx, cy), cr, 255, -1)
        mean_val = float(cv2.mean(gray, mask=mask)[0])
        if mean_val > best_brightness:
            best_brightness = mean_val
            best = (float(c[0]), float(c[1]), float(c[2]))
    return best


def _hough_detect(
    gray: np.ndarray,
    min_r: int,
    max_r: int,
    param2: int = 25,
    roi: Optional[tuple[int, int, int, int]] = None,  # (x1, y1, x2, y2)
) -> Optional[tuple[float, float, float]]:
    blurred = cv2.GaussianBlur(gray, (5, 5), 1)
    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1,
        minDist=50,
        param1=50,
        param2=param2,
        minRadius=min_r,
        maxRadius=max_r,
    )
    if circles is None:
        return None

    candidates = circles[0]  # shape (N, 3): x, y, r

    if roi is not None:
        x1, y1, x2, y2 = roi
        candidates = np.array([
            c for c in candidates if x1 <= c[0] <= x2 and y1 <= c[1] <= y2
        ])
        if len(candidates) == 0:
            return None

    return _brightest_circle(gray, candidates)


def _make_roi(
    w: int, h: int, center_x: int, half_width: int, top_fraction: float = 1 / 3
) -> tuple[int, int, int, int]:
    x1 = max(0, center_x - half_width)
    x2 = min(w, center_x + half_width)
    y1 = int(h * top_fraction)
    y2 = h
    return (x1, y1, x2, y2)


def detect_ball_in_frame(
    image_bytes: bytes,
    center_x: Optional[int] = None,
    search_half_width: Optional[int] = None,
) -> dict:
    buf = np.frombuffer(image_bytes, dtype=np.uint8)
    frame = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if frame is None:
        return {"x": None, "y": None, "r": None}

    h, w = frame.shape[:2]
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

    min_r = max(10, w // 50)
    max_r = max(min_r + 20, w // 12)

    roi = None
    if center_x is not None and search_half_width:
        roi = _make_roi(w, h, center_x, search_half_width, top_fraction=0)

    best = _hough_detect(gray, min_r, max_r, param2=25, roi=roi)
    if best is None and roi is not None:
        best = _hough_detect(gray, min_r, max_r, param2=20)
    if best is None:
        return {"x": None, "y": None, "r": None}
    return {"x": int(best[0]), "y": int(best[1]), "r": int(best[2])}


def analyze_putt(
    video_path: str,
    gate_center_x: int,
    gate_line_y: int,
    gate_width_px: int,
    gate_width_mm: float,
    ball_radius_hint: Optional[int] = None,
) -> dict:
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        return {"error": "Could not open video"}
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)

    mm_per_px = gate_width_mm / gate_width_px
    positions: list[tuple[float, float]] = []
    crossing_pos: Optional[tuple[float, float]] = None

    if ball_radius_hint and ball_radius_hint > 0:
        min_r = max(5, ball_radius_hint - 10)
        max_r = ball_radius_hint + 10
    else:
        min_r = None  # computed per-frame once dimensions are known
        max_r = None

    roi: Optional[tuple[int, int, int, int]] = None

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if frame_idx % 10 != 0:
            frame_idx += 1
            continue

        h, w = frame.shape[:2]
        if roi is None:
            roi = _make_roi(w, h, gate_center_x, gate_width_px)
        if min_r is None:
            min_r = max(10, w // 50)
            max_r = max(min_r + 20, w // 12)

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        best = _hough_detect(gray, min_r, max_r, param2=15, roi=roi)
        if best:
            x, y = best[0], best[1]
            positions.append((x, y))
            if crossing_pos is None and abs(y - gate_line_y) < 8:
                crossing_pos = (x, y)

        frame_idx += 1

    cap.release()

    serialized = [[round(x, 1), round(y, 1)] for x, y in positions]

    if crossing_pos is None:
        if positions:
            crossing_pos = min(positions, key=lambda p: abs(p[1] - gate_line_y))
        return {
            "offset_px": None,
            "offset_mm": None,
            "direction": None,
            "pass_fail": None,
            "track_count": len(positions),
            "positions": serialized,
            "crossing_pos": None,
            "message": "Ball did not clearly cross gate line — check calibration values",
        }

    offset_px = crossing_pos[0] - gate_center_x
    offset_mm = offset_px * mm_per_px
    direction = "right" if offset_px > 0 else ("left" if offset_px < 0 else "center")
    pass_fail = "pass" if abs(offset_mm) <= 2.0 else "fail"

    return {
        "offset_px": round(offset_px, 1),
        "offset_mm": round(offset_mm, 2),
        "direction": direction,
        "pass_fail": pass_fail,
        "track_count": len(positions),
        "positions": serialized,
        "crossing_pos": [round(crossing_pos[0], 1), round(crossing_pos[1], 1)],
    }
