"""Offline regression/tuning harness for the iOS motion detector.

Replays real putt clips (``backend/tests/fixtures/*.mov``) through the shared
motion metric in ``app.segmenter`` — the Python port of
``ios/PuttingGate/Capture/MotionDetector.swift`` — and confirms each clip trips
the trigger while idle frames do not. Run::

    .venv/bin/python scripts/check_motion.py

``app.segmenter`` must stay in sync with the Swift detector: a 32x24
point-sampled luma grid over the center-60% ROI, scored by the *maximum*
per-cell absolute frame difference.

This is what proved the original ``mean``-based metric could not detect a golf
ball (it peaked ~0.03, below the 0.04 threshold) and that the ``max`` metric
separates putt peaks (~0.6-0.9) from idle noise (<0.06) with wide margin.
"""

import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.segmenter import TRIGGER as THRESHOLD, motion_levels  # noqa: E402

BASELINE_MAX = 0.06         # idle noise must stay below this

FIXTURES = Path(__file__).resolve().parents[1] / "tests" / "fixtures"


def _levels(path: Path) -> np.ndarray:
    """Per-frame max-cell luma diff for a clip (empty if unreadable)."""
    cap = cv2.VideoCapture(str(path))
    levels = motion_levels(cap)
    cap.release()
    return levels


def main() -> int:
    clips = sorted(
        p for p in FIXTURES.iterdir()
        if p.suffix.lower() == ".mov"
    ) if FIXTURES.exists() else []
    if not clips:
        print(f"No .mov fixtures found in {FIXTURES}.")
        return 1

    failures = 0
    for path in clips:
        levels = _levels(path)
        if levels.size == 0:
            print(f"{path.name:16s} -> UNREADABLE")
            failures += 1
            continue
        peak = float(levels.max())
        baseline = float(np.median(levels))
        triggers = int((levels > THRESHOLD).sum())
        ok = triggers > 0 and baseline < BASELINE_MAX
        failures += not ok
        print(
            f"{path.name:16s} peak={peak:.3f} baseline={baseline:.3f} "
            f"frames>thr({THRESHOLD})={triggers:3d}  {'OK' if ok else 'FAIL'}"
        )

    print(f"\n{len(clips) - failures}/{len(clips)} clips detected a putt.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
