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


def _white_mask(frame: np.ndarray) -> np.ndarray:
    """Binary mask of bright, low-saturation (white) regions — i.e. the golf ball.

    A putting green is strongly saturated green, so thresholding on low saturation
    and high value isolates the white ball without relying on edges (which the
    grass texture overwhelms). Morphological open/close removes grass speckle and
    fuses the ball's dimples / logo text into one solid blob.
    """
    hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]
    mask = ((s < 70) & (v > 150)).astype(np.uint8) * 255
    kernel = np.ones((5, 5), np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    return mask


# A white-ball candidate: center x, y, enclosing radius, area, circularity.
Candidate = tuple[float, float, float, float, float]


def _white_ball_candidates(
    frame: np.ndarray, min_r: int, max_r: int
) -> list[Candidate]:
    """All white blobs that *contain* a ball-sized disc, via distance transform.

    Colour cannot tell a matte-white ball from a polished metal putter shaft
    (both are low-saturation and bright), and at address the shaft fuses to the
    ball in the mask — so a contour-shape test (circularity/solidity) rejects the
    fused blob and loses the ball. Instead, for each connected white component we
    take the peak of its distance transform: the centre of the largest inscribed
    circle, with the peak value as its radius. A thin shaft contributes only tiny
    distances, so this locks onto the round ball and ignores attachments. The
    remaining ball-vs-hosel ambiguity is resolved by the caller spatially
    (aim-line corridor) and temporally (velocity-predicted tracking).
    """
    mask = _white_mask(frame)
    num, labels, stats, _centroids = cv2.connectedComponentsWithStats(mask, 8)

    candidates: list[Candidate] = []
    for i in range(1, num):  # skip background label 0
        area = int(stats[i, cv2.CC_STAT_AREA])
        if area < min_r * min_r:  # too small to hold a ball; cheap pre-filter
            continue
        comp = (labels == i).astype(np.uint8)
        dist = cv2.distanceTransform(comp, cv2.DIST_L2, 5)
        _minv, max_dist, _minl, max_loc = cv2.minMaxLoc(dist)
        r = float(max_dist)  # radius of the largest inscribed circle
        if r < min_r or r > max_r:
            continue
        candidates.append((float(max_loc[0]), float(max_loc[1]), r, float(area), 1.0))
    return candidates


def _pick_seed(
    candidates: list[Candidate],
    w: int,
    h: int,
    center_x: Optional[int] = None,
    half_width: Optional[int] = None,
) -> Optional[tuple[float, float, float]]:
    """Cold-start pick of the ball at address.

    Prefers the largest, roundest disc inside the aim-line corridor, breaking
    ties toward lower blobs — at address the ball sits in front of (below) the
    putter head and hosel, so the leading white disc is the ball, not the metal
    behind it.
    """
    if not candidates:
        return None
    bx = float(center_x) if center_x is not None else w / 2.0
    hw = float(half_width) if half_width else w / 2.0
    pool = [c for c in candidates if abs(c[0] - bx) <= hw] or candidates

    def score(c: Candidate) -> float:
        x, y, _r, area, circ = c
        x_pref = 1.0 - min(1.0, abs(x - bx) / (w / 2.0))
        y_pref = y / h  # favour lower (leading) blobs
        return area * circ * (0.5 + 0.5 * x_pref) * (0.4 + 0.6 * y_pref)

    best = max(pool, key=score)
    return (best[0], best[1], best[2])


def _make_roi(
    w: int, h: int, center_x: int, half_width: int, top_fraction: float = 1 / 3
) -> tuple[int, int, int, int]:
    x1 = max(0, center_x - half_width)
    x2 = min(w, center_x + half_width)
    y1 = int(h * top_fraction)
    y2 = h
    return (x1, y1, x2, y2)


def _aim_crossing(
    positions: list[tuple[float, float]],
    ax: float, ay: float, bx: float, by: float,
) -> Optional[tuple[float, float, tuple[float, float]]]:
    """Offset of the ball from the aim line A→B as it reaches the target B.

    The aim line runs from the ball-rest dot ``A`` to the target dot ``B``. The
    "gate" is the line through ``B`` perpendicular to that aim line (not a
    horizontal line), so a tilted mount is handled correctly. Scans the track for
    where it crosses that gate — i.e. where progress along the aim direction
    reaches ``B`` — and returns ``(offset_px, crossing_point)`` where
    ``offset_px`` is the signed perpendicular distance (positive = right of the
    aim line, looking from A toward B). Returns None if the track never reaches
    the gate.
    """
    ux, uy = bx - ax, by - ay
    length = (ux * ux + uy * uy) ** 0.5
    if length == 0:
        return None
    ux, uy = ux / length, uy / length  # aim direction (unit)
    nx, ny = uy, -ux  # right-hand perpendicular (== +x when the aim is vertical)

    def progress(p: tuple[float, float]) -> float:  # signed distance to B along u
        return (p[0] - bx) * ux + (p[1] - by) * uy

    def offset(cx: float, cy: float) -> float:  # signed perpendicular distance
        return (cx - bx) * nx + (cy - by) * ny

    for (x0, y0), (x1, y1) in zip(positions, positions[1:]):
        s0, s1 = progress((x0, y0)), progress((x1, y1))
        if s0 == 0:
            return (offset(x0, y0), (x0, y0))
        if s0 < 0 <= s1:  # crosses the gate (reaches the target's distance)
            t = s0 / (s0 - s1)
            cx, cy = x0 + t * (x1 - x0), y0 + t * (y1 - y0)
            return (offset(cx, cy), (cx, cy))
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

    # Wide range: the ball is smallest at rest (far) and grows as it rolls toward
    # the camera, so allow up to ~w/5. Hough is now only a fallback.
    min_r = max(8, w // 60)
    max_r = max(min_r + 20, w // 5)

    # Locate the mount's fixed laser dots (sorted top-to-bottom by y). The
    # bottom-most dot is the target on the green and anchors the gate; it is the
    # large, reliable dot. The upper ball-rest dot is small and often missing, so
    # only treat a dot as the ball reference when a second, higher dot is present.
    lasers = _detect_laser_dots(frame)
    bottom = lasers[-1] if lasers else None
    top = lasers[0] if len(lasers) >= 2 else None

    # Primary: segment the white ball by colour (robust against grass texture and
    # independent of the laser dots, which wash out outdoors). Restrict to the
    # aim-line corridor and prefer the leading disc so the metallic shaft / hosel
    # behind the ball is not picked instead.
    best = _pick_seed(
        _white_ball_candidates(frame, min_r, max_r),
        w, h, center_x=center_x, half_width=search_half_width,
    )

    if best is None:
        # Fall back to the old edge-based search (handles low-contrast / indoor
        # scenes): frame-center band ROI, then a relaxed full-frame pass.
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
    aim_top_x: Optional[int] = None,
    aim_top_y: Optional[int] = None,
) -> dict:
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        return {"error": "Could not open video"}
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)

    mm_per_px = gate_width_mm / gate_width_px
    positions: list[tuple[float, float]] = []
    # Per-frame detected circles, surfaced for the frontend's debug overlay.
    detected_circles: list[tuple[float, float, float]] = []

    min_r: Optional[int] = None  # computed per-frame once dimensions are known
    max_r: Optional[int] = None
    ball_r: float = float(ball_radius_hint) if (ball_radius_hint and ball_radius_hint > 0) else 15.0
    last_x: Optional[float] = float(ball_x_hint) if ball_x_hint is not None else None
    last_y: Optional[float] = float(ball_y_hint) if ball_y_hint is not None else None
    vx: float = 0.0  # ball velocity from the previous step, for prediction
    vy: float = 0.0

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        h, w = frame.shape[:2]
        if min_r is None:
            # The ball grows as it rolls toward the camera; allow a wide range.
            min_r = max(8, w // 60)
            max_r = max(min_r + 20, w // 5)

        candidates = _white_ball_candidates(frame, min_r, max_r)

        # Keep only blobs inside the corridor around the aim line. The ball stays
        # near gate_center_x (its offset is what we measure); the putter shaft
        # enters from the side, so the corridor rejects most of it.
        corridor_hw = max(gate_width_px, 5.0 * ball_r)
        in_corridor = [c for c in candidates if abs(c[0] - gate_center_x) <= corridor_hw]
        pool = in_corridor or candidates

        # On the first frame without a supplied hint, seed on the leading disc.
        if frame_idx == 0 and last_x is None:
            seed = _pick_seed(pool, w, h, center_x=gate_center_x)
            if seed is not None:
                last_x, last_y, ball_r = seed[0], seed[1], max(5.0, seed[2])

        detected_pos: Optional[tuple[float, float]] = None
        if last_x is not None and last_y is not None:
            # Predict where the ball should be from its velocity, then choose the
            # blob best matching the prediction. Without prediction the slow/still
            # putter near the last position outranks a ball that has just been
            # struck and leapt forward; with it, the moving ball wins.
            px, py = last_x + vx, last_y + vy
            reach = max(3.0 * ball_r, (vx * vx + vy * vy) ** 0.5 + 2.0 * ball_r)
            valid = [
                c for c in pool
                if c[1] >= last_y - ball_r                      # never moves backward
                and 0.5 * ball_r <= c[2] <= 2.0 * ball_r        # radius continuity
                and ((c[0] - last_x) ** 2 + (c[1] - last_y) ** 2) ** 0.5 <= reach
            ]
            if valid:
                best = min(valid, key=lambda c: (c[0] - px) ** 2 + (c[1] - py) ** 2)
                detected_pos = (best[0], best[1])
                ball_r = 0.6 * ball_r + 0.4 * best[2]  # smooth the growing radius
                detected_circles.append((best[0], best[1], best[2]))

        if detected_pos is not None:
            x, y = detected_pos
            if last_x is not None:
                vx, vy = x - last_x, y - last_y
            positions.append((x, y))
            last_x, last_y = x, y

        frame_idx += 1

    cap.release()

    serialized = [[round(x, 1), round(y, 1)] for x, y in positions]
    serialized_hough = [
        [round(x, 1), round(y, 1), round(r, 1)] for x, y, r in detected_circles
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

    # Aim line: from the ball-rest dot (top laser, ≈ ball address) to the target
    # dot (gate). Offset is measured perpendicular to this line so a tilted mount
    # is handled correctly. Fall back to the ball address, then straight-down, so
    # a missing top dot degrades to the old vertical measurement.
    if aim_top_x is not None and aim_top_y is not None:
        ax, ay = float(aim_top_x), float(aim_top_y)
    elif ball_x_hint is not None and ball_y_hint is not None:
        ax, ay = float(ball_x_hint), float(ball_y_hint)
    else:
        ax, ay = float(gate_center_x), float(gate_line_y) - 100.0

    message: Optional[str] = None
    crossing = _aim_crossing(positions, ax, ay, float(gate_center_x), float(gate_line_y))
    if crossing is not None:
        offset_px, crossing_pos = crossing
    else:
        # Track never reached the gate; estimate from the furthest-along point.
        ux, uy = gate_center_x - ax, gate_line_y - ay
        norm = (ux * ux + uy * uy) ** 0.5 or 1.0
        ux, uy = ux / norm, uy / norm
        crossing_pos = max(positions, key=lambda p: (p[0] - ax) * ux + (p[1] - ay) * uy)
        offset_px = (crossing_pos[0] - gate_center_x) * uy - (crossing_pos[1] - gate_line_y) * ux
        message = "Ball did not cleanly cross gate line — offset is a best-effort estimate"

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
