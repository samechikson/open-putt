"""Validation harness for multi-putt session segmentation and analysis.

Runs the full ``analyze_session`` pipeline over a session clip and prints the
auto-calibration, every motion segment with its verdict (kept putt vs. dropped
with the rejection detail), and the per-putt measurements. Use it to tune the
``app.segmenter`` thresholds against real recordings. Run::

    .venv/bin/python scripts/check_segments.py [clip]

Defaults to ``tests/fixtures/long-video-5-putts.MOV`` — a real session with 5
putts, a practice stroke without a ball, and the recording-start bustle, so it
exercises both the keep and drop paths. Exit code is non-zero when that known
fixture stops yielding exactly its expected putts.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.analyzer import CalibrationError, analyze_session  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "tests" / "fixtures"
DEFAULT_CLIP = FIXTURES / "long-video-5-putts.MOV"
EXPECTED_PUTTS = {DEFAULT_CLIP.name: 5}


def main() -> int:
    clip = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CLIP
    if not clip.exists():
        print(f"Clip not found: {clip}")
        return 1

    try:
        res = analyze_session(str(clip), include_dropped=True)
    except CalibrationError as exc:
        print(f"CALIBRATION FAILED: {exc}")
        return 1
    if "error" in res:
        print(f"ERROR: {res['error']}")
        return 1

    cal = res["calibration"]
    print(
        f"{clip.name}: {res['duration_s']}s @ {res['fps']}fps, "
        f"{res['frame_count']} frames"
    )
    print(
        f"calibration (frame {cal['calibration_frame']}): "
        f"gate=({cal['gate_center_x']}, {cal['gate_line_y']}) "
        f"aim_top={cal['aim_top']} ball_r={cal['ball_radius_px']}px "
        f"mm/px={cal['mm_per_px']} ({cal['scale_source']})"
    )
    print(f"\n{res['segments_detected']} motion segments:")
    for p in res["putts"]:
        print(
            f"  PUTT  {p['start_s']:7.2f}-{p['end_s']:7.2f}s  "
            f"offset={p['offset_mm']:+7.2f}mm {p['direction']:6s} "
            f"speed={p['speed_mps']:.2f}m/s track={p['track_count']}"
        )
    for d in res["dropped"]:
        print(
            f"  drop  {d['start_s']:7.2f}-{d['end_s']:7.2f}s  "
            f"track={d['track_count']} crossed={d['crossed_gate']} "
            f"speed={d['speed_mps']}  {d['message'] or ''}"
        )

    expected = EXPECTED_PUTTS.get(clip.name)
    if expected is not None and len(res["putts"]) != expected:
        print(f"\nFAIL: expected {expected} putts, got {len(res['putts'])}")
        return 1
    print(f"\n{len(res['putts'])} putts detected.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
