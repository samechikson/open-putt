"""Motion-based segmentation of a multi-putt session video.

The motion metric is the Python port of the iOS detector in
``ios/PuttingGate/Capture/MotionDetector.swift``: a 32x24 point-sampled luma
grid over the center-60% ROI, scored by the *maximum* per-cell absolute frame
difference. Putt strikes peak ~0.6-0.9 on this metric while idle noise stays
below ~0.06, so a 0.25 trigger separates them with wide margin (validated on
the clips in ``tests/fixtures`` by ``scripts/check_motion.py``, which imports
this module and must be kept passing whenever the metric changes).
"""

from typing import Optional

import cv2
import numpy as np

COLS, ROWS = 32, 24
ROI = (0.2, 0.2, 0.6, 0.6)  # x, y, w, h normalized -- matches AppSettings default
TRIGGER = 0.25              # matches AppSettings.motionThreshold default
RELEASE = 0.10              # hysteresis floor: activity persists above this
QUIET = 0.08                # scene-at-rest level for quiet-frame selection

PRE_ROLL_S = 0.4    # segment starts this long before the trigger (ball at rest)
POST_ROLL_S = 0.3   # segment keeps rolling this long after motion subsides
QUIET_GAP_S = 0.7   # continuous quiet needed to close a segment
MIN_ACTIVE_S = 0.15  # shorter activity bursts are noise, not putts
MAX_ACTIVE_S = 10.0  # cap runaway activity (person milling around)
MIN_QUIET_RUN_S = 0.3  # minimum quiet run usable as a calibration frame
MAX_SEGMENTS = 100


def _sample_coords(w: int, h: int) -> tuple[np.ndarray, np.ndarray]:
    rx, ry = int(ROI[0] * w), int(ROI[1] * h)
    rw, rh = max(1, int(ROI[2] * w)), max(1, int(ROI[3] * h))
    xs = np.clip(rx + (np.arange(COLS) * rw) // COLS, 0, w - 1)
    ys = np.clip(ry + (np.arange(ROWS) * rh) // ROWS, 0, h - 1)
    return xs, ys


def motion_levels(cap: cv2.VideoCapture) -> np.ndarray:
    """Per-frame max-cell luma diff for an open capture (empty if unreadable).

    ``levels[i]`` is the difference between frames ``i`` and ``i + 1``, so a
    readable video yields ``frame_count - 1`` entries. The caller owns the
    capture's open/release lifecycle.
    """
    prev, xs, ys, out = None, None, None, []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if xs is None:
            xs, ys = _sample_coords(frame.shape[1], frame.shape[0])
        sub = frame[np.ix_(ys, xs)].astype(np.float32)  # BGR
        grid = (0.114 * sub[:, :, 0] + 0.587 * sub[:, :, 1] + 0.299 * sub[:, :, 2]) / 255.0
        if prev is not None:
            out.append(float(np.abs(grid - prev).max()))
        prev = grid
    return np.array(out)


def segment_motion(levels: np.ndarray, fps: float) -> list[tuple[int, int]]:
    """Split a motion-level trace into putt-candidate frame windows.

    Returns ``[(start_frame, end_frame_exclusive)]`` in source-frame indices,
    non-overlapping and in order. A window opens ``PRE_ROLL_S`` before the
    trigger so the tracker can cold-start on the resting ball, and closes
    ``POST_ROLL_S`` after activity stays under ``RELEASE`` for ``QUIET_GAP_S``.
    The trigger requires two consecutive active frames, so single-frame spikes
    (e.g. hard cuts in a concatenated test clip) do not open a window.
    """
    n = len(levels)
    if n == 0 or fps <= 0:
        return []
    pre = round(PRE_ROLL_S * fps)
    post = round(POST_ROLL_S * fps)
    quiet_gap = max(1, round(QUIET_GAP_S * fps))
    min_active = max(2, round(MIN_ACTIVE_S * fps))
    max_active = max(min_active, round(MAX_ACTIVE_S * fps))

    # Active spans as (trigger, last_active) level indices.
    spans: list[tuple[int, int]] = []
    i = 0
    while i < n and len(spans) < MAX_SEGMENTS:
        if levels[i] > TRIGGER and i + 1 < n and levels[i + 1] > RELEASE:
            trigger, last_active = i, i + 1
            j = i + 2
            while j < n and j - last_active <= quiet_gap:
                if levels[j] > RELEASE:
                    last_active = j
                j += 1
            end_active = min(last_active, trigger + max_active)
            if end_active - trigger + 1 >= min_active:
                spans.append((trigger, end_active))
            i = last_active + 1  # consume the whole activity blob
        else:
            i += 1

    # Convert to padded frame windows. levels[k] spans frames (k, k + 1).
    frame_count = n + 1
    segments: list[tuple[int, int]] = []
    for k, (trigger, last_active) in enumerate(spans):
        start = max(0, trigger - pre)
        if segments:
            start = max(start, segments[-1][1])
        end = min(frame_count, last_active + 2 + post)
        if k + 1 < len(spans):
            end = min(end, spans[k + 1][0])
        if end > start:
            segments.append((start, end))
    return segments


def quiet_frames(
    levels: np.ndarray,
    fps: float,
    segments: list[tuple[int, int]],
    max_candidates: int = 3,
) -> list[int]:
    """Frame indices usable for calibration, best first.

    Prefers midpoints of long quiet runs before the first segment (ball placed
    at address, person stepped away), then long quiet runs anywhere. Always
    returns at least ``[0]`` so callers have a frame to try.
    """
    min_run = max(1, round(MIN_QUIET_RUN_S * fps)) if fps > 0 else 1

    runs: list[tuple[int, int]] = []  # (length, start) of quiet stretches
    start: Optional[int] = None
    for i, level in enumerate(levels):
        if level < QUIET:
            if start is None:
                start = i
        elif start is not None:
            runs.append((i - start, start))
            start = None
    if start is not None:
        runs.append((len(levels) - start, start))

    first_start = segments[0][0] if segments else len(levels)
    eligible = [r for r in runs if r[0] >= min_run]
    before = sorted((r for r in eligible if r[1] + r[0] <= first_start), reverse=True)
    anywhere = sorted((r for r in eligible if r not in before), reverse=True)

    candidates = [length // 2 + run_start for length, run_start in before + anywhere]
    return (candidates or [0])[:max_candidates]
