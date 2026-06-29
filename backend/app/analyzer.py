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


def _nearest_circle(
    candidates: np.ndarray, px: float, py: float
) -> Optional[tuple[float, float, float]]:
    """Pick the candidate circle whose center is closest to ``(px, py)``."""
    best = None
    best_dist = float("inf")
    for c in candidates:
        dist = (float(c[0]) - px) ** 2 + (float(c[1]) - py) ** 2
        if dist < best_dist:
            best_dist = dist
            best = (float(c[0]), float(c[1]), float(c[2]))
    return best


def _detect_laser_dots(frame: np.ndarray) -> list[tuple[float, float]]:
    """Find the mount's red laser dots, returned as ``[top, bottom]`` by y.

    The dots are the only saturated-red, near-white-hot points in the scene, so a
    simple red-dominance threshold separates them from the neutral carpet, the
    white ball, and the dark putter. Returns 0, 1, or 2 points.
    """
    b, g, r = cv2.split(frame.astype(np.int16))
    redness = r - np.maximum(g, b)
    mask = ((redness > 60) & (r > 170)).astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))

    h, w = frame.shape[:2]
    max_area = h * w * 0.02
    num, _labels, stats, centroids = cv2.connectedComponentsWithStats(mask, 8)

    blobs: list[tuple[int, float, float]] = []
    for i in range(1, num):  # skip background label 0
        area = int(stats[i, cv2.CC_STAT_AREA])
        if area < 6 or area > max_area:
            continue
        cx, cy = centroids[i]
        blobs.append((area, float(cx), float(cy)))

    blobs.sort(reverse=True)  # largest blobs first
    pts = [(cx, cy) for _area, cx, cy in blobs[:2]]
    pts.sort(key=lambda p: p[1])  # top (smaller y) first
    return pts


def _hough_detect(
    gray: np.ndarray,
    min_r: int,
    max_r: int,
    param2: int = 25,
    roi: Optional[tuple[int, int, int, int]] = None,  # (x1, y1, x2, y2)
    near: Optional[tuple[float, float]] = None,
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

    # When an anchor is given (e.g. a laser dot marking the ball), pick the
    # closest circle; otherwise fall back to the brightest one.
    if near is not None:
        return _nearest_circle(candidates, near[0], near[1])
    return _brightest_circle(gray, candidates)


def _make_roi(
    w: int, h: int, center_x: int, half_width: int, top_fraction: float = 1 / 3
) -> tuple[int, int, int, int]:
    x1 = max(0, center_x - half_width)
    x2 = min(w, center_x + half_width)
    y1 = int(h * top_fraction)
    y2 = h
    return (x1, y1, x2, y2)


def _crossing_x(
    positions: list[tuple[float, float]], gate_line_y: int
) -> Optional[tuple[float, float]]:
    """Interpolate the ball's (x, y) at the moment it crosses the gate line.

    Scans consecutive tracked points for a sign change in ``y - gate_line_y``
    and linearly interpolates x at exactly ``y == gate_line_y``. Direction
    agnostic (works whether the ball travels toward larger or smaller y);
    returns the first crossing, or None if the track never straddles the line.
    """
    for (x0, y0), (x1, y1) in zip(positions, positions[1:]):
        d0 = y0 - gate_line_y
        d1 = y1 - gate_line_y
        if d0 == 0:
            return (x0, y0)
        if d0 * d1 < 0:  # straddles the gate line
            t = d0 / (d0 - d1)
            return (x0 + t * (x1 - x0), float(gate_line_y))
    return None


def detect_ball_in_frame(
    image_bytes: bytes,
    center_x: Optional[int] = None,
    search_half_width: Optional[int] = None,
) -> dict:
    buf = np.frombuffer(image_bytes, dtype=np.uint8)
    frame = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    empty = {"x": None, "y": None, "r": None, "lasers": None,
             "gate_center_x": None, "gate_line_y": None}
    if frame is None:
        return empty

    h, w = frame.shape[:2]
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

    min_r = max(10, w // 50)
    max_r = max(min_r + 20, w // 12)

    # Locate the mount's fixed laser dots: top = ball rest, bottom = target.
    lasers = _detect_laser_dots(frame)
    top = lasers[0] if len(lasers) >= 1 else None
    bottom = lasers[1] if len(lasers) >= 2 else None

    best = None
    if top is not None:
        # Anchor the ball search to a tight box around the top laser, picking the
        # circle nearest the dot. The ball center sits just above the laser, so
        # extend the box mostly upward.
        tx, ty = top
        tight = (
            max(0, int(tx - 4 * max_r)), max(0, int(ty - 5 * max_r)),
            min(w, int(tx + 4 * max_r)), min(h, int(ty + max_r)),
        )
        best = _hough_detect(gray, min_r, max_r, param2=20, roi=tight, near=(tx, ty))

    if best is None:
        # Fall back to the frame-center band ROI, then a relaxed full-frame pass.
        roi = None
        if center_x is not None and search_half_width:
            roi = _make_roi(w, h, center_x, search_half_width, top_fraction=0)
        best = _hough_detect(gray, min_r, max_r, param2=25, roi=roi)
        if best is None and roi is not None:
            best = _hough_detect(gray, min_r, max_r, param2=20)

    laser_payload = {
        "top": [round(top[0], 1), round(top[1], 1)] if top is not None else None,
        "bottom": [round(bottom[0], 1), round(bottom[1], 1)] if bottom is not None else None,
    }
    # Gate + target are anchored on the bottom dot (the target); the aim line is
    # drawn through both dots on the frontend.
    gate_center_x = round(bottom[0]) if bottom is not None else None
    gate_line_y = round(bottom[1]) if bottom is not None else None

    result: dict = {
        "lasers": laser_payload if lasers else None,
        "gate_center_x": gate_center_x,
        "gate_line_y": gate_line_y,
    }
    if best is None:
        result.update({"x": None, "y": None, "r": None})
    else:
        result.update({"x": int(best[0]), "y": int(best[1]), "r": int(best[2])})
    return result


def analyze_putt(
    video_path: str,
    gate_center_x: int,
    gate_line_y: int,
    gate_width_px: int,
    gate_width_mm: float,
    ball_radius_hint: Optional[int] = None,
    ball_x_hint: Optional[int] = None,
    ball_y_hint: Optional[int] = None,
) -> dict:
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        return {"error": "Could not open video"}
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)

    mm_per_px = gate_width_mm / gate_width_px
    positions: list[tuple[float, float]] = []
    hough_circles: list[tuple[float, float, float]] = []

    if ball_radius_hint and ball_radius_hint > 0:
        min_r = max(5, ball_radius_hint - 10)
        max_r = ball_radius_hint + 10
    else:
        min_r = None  # computed per-frame once dimensions are known
        max_r = None

    roi: Optional[tuple[int, int, int, int]] = None
    tracker: Optional[cv2.Tracker] = None
    ball_r: int = ball_radius_hint if (ball_radius_hint and ball_radius_hint > 0) else 15
    last_y: Optional[float] = None

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        h, w = frame.shape[:2]
        if roi is None:
            roi = _make_roi(w, h, gate_center_x, gate_width_px)
        if min_r is None:
            min_r = max(10, w // 50)
            max_r = max(min_r + 20, w // 12)

        detected_pos: Optional[tuple[float, float]] = None

        # On the very first frame, if no ball hint was supplied, derive one from
        # the top laser dot (the ball rests at it) so the tracker seeds on the
        # real ball rather than whatever the full-frame Hough fallback finds.
        if frame_idx == 0 and ball_x_hint is None and ball_y_hint is None:
            lasers = _detect_laser_dots(frame)
            if lasers:
                tx, ty = lasers[0]
                gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                seed_roi = (
                    max(0, int(tx - 4 * max_r)), max(0, int(ty - 5 * max_r)),
                    min(w, int(tx + 4 * max_r)), min(h, int(ty + max_r)),
                )
                seed = _hough_detect(gray, min_r, max_r, param2=20, roi=seed_roi)
                if seed is not None:
                    ball_x_hint = int(seed[0])
                    ball_y_hint = int(seed[1])
                    ball_r = max(5, int(seed[2]))

        # On the very first frame, seed the tracker from the known initial position
        if frame_idx == 0 and tracker is None and ball_x_hint is not None and ball_y_hint is not None:
            r = ball_r
            bx = max(0, ball_x_hint - r)
            by = max(0, ball_y_hint - r)
            bw = min(2 * r, w - bx)
            bh = min(2 * r, h - by)
            tracker = cv2.TrackerCSRT_create()
            tracker.init(frame, (bx, by, bw, bh))
            last_y = float(ball_y_hint)

        if tracker is not None:
            ok, bbox = tracker.update(frame)
            if ok:
                cx = bbox[0] + bbox[2] / 2.0
                cy = bbox[1] + bbox[3] / 2.0
                if last_y is None or cy >= last_y - ball_r:
                    detected_pos = (cx, cy)
                else:
                    tracker = None  # drifted upward — reset

        # Periodic Hough correction: re-anchor the tracker every 10 frames to
        # counteract drift caused by the ball rotating as it rolls
        if detected_pos is not None and frame_idx % 10 == 0:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            px, py = detected_pos
            margin = ball_r * 3
            corr_roi = (
                max(0, int(px - margin)), max(0, int(py - margin)),
                min(w, int(px + margin)), min(h, int(py + margin)),
            )
            fix = _hough_detect(gray, min_r, max_r, param2=20, roi=corr_roi)
            if fix is not None:
                hx, hy, hr = fix
                hough_circles.append((hx, hy, hr))
                if ((hx - px) ** 2 + (hy - py) ** 2) ** 0.5 < ball_r * 2:
                    ball_r = max(5, int(hr))
                    bx = max(0, int(hx - ball_r))
                    by = max(0, int(hy - ball_r))
                    bw = min(2 * ball_r, w - bx)
                    bh = min(2 * ball_r, h - by)
                    tracker = cv2.TrackerCSRT_create()
                    tracker.init(frame, (bx, by, bw, bh))
                    detected_pos = (hx, hy)

        if detected_pos is None and frame_idx % 5 == 0:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            best = _hough_detect(gray, min_r, max_r, param2=15, roi=roi)
            if best is None:
                best = _hough_detect(gray, min_r, max_r, param2=15)
            if best is not None:
                hx, hy, hr = best
                hough_circles.append((hx, hy, hr))
                if last_y is None or hy >= last_y - ball_r:
                    ball_r = max(5, int(hr))
                    bx = max(0, int(hx - hr))
                    by = max(0, int(hy - hr))
                    bw = min(int(2 * hr), w - bx)
                    bh = min(int(2 * hr), h - by)
                    tracker = cv2.TrackerCSRT_create()
                    tracker.init(frame, (bx, by, bw, bh))
                    detected_pos = (hx, hy)

        if detected_pos is not None:
            x, y = detected_pos
            positions.append((x, y))
            last_y = y

        frame_idx += 1

    cap.release()

    serialized = [[round(x, 1), round(y, 1)] for x, y in positions]
    serialized_hough = [
        [round(x, 1), round(y, 1), round(r, 1)] for x, y, r in hough_circles
    ]

    if not positions:
        return {
            "offset_px": None,
            "offset_mm": None,
            "direction": None,
            "track_count": 0,
            "positions": serialized,
            "hough_circles": serialized_hough,
            "crossing_pos": None,
            "message": "Ball not detected — check calibration values",
        }

    message: Optional[str] = None
    crossing_pos = _crossing_x(positions, gate_line_y)
    if crossing_pos is None:
        # Track never straddled the gate line; estimate from the nearest point.
        crossing_pos = min(positions, key=lambda p: abs(p[1] - gate_line_y))
        message = "Ball did not cleanly cross gate line — offset is a best-effort estimate"

    offset_px = crossing_pos[0] - gate_center_x
    offset_mm = offset_px * mm_per_px
    direction = "right" if offset_px > 0 else ("left" if offset_px < 0 else "center")

    result = {
        "offset_px": round(offset_px, 1),
        "offset_mm": round(offset_mm, 2),
        "direction": direction,
        "track_count": len(positions),
        "positions": serialized,
        "hough_circles": serialized_hough,
        "crossing_pos": [round(crossing_pos[0], 1), round(crossing_pos[1], 1)],
    }
    if message is not None:
        result["message"] = message
    return result
