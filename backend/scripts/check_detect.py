"""Visual tuning harness for the white-ball detector.

Drop the captured putting-green frames into ``backend/tests/fixtures/`` (any
``.jpg`` / ``.jpeg`` / ``.png``), then run::

    .venv/bin/python scripts/check_detect.py [output_dir]

For each fixture it runs ``detect_ball_in_frame`` and writes an annotated copy
(detected circle + center) plus the white mask alongside it, so you can confirm
the circle lands on the ball and tune the HSV / circularity / solidity constants
in ``app.analyzer._white_mask`` / ``_white_ball_candidates``.
"""

import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.analyzer import _white_mask, detect_ball_in_frame  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "tests" / "fixtures"
EXTS = {".jpg", ".jpeg", ".png"}


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else FIXTURES / "_annotated"
    out_dir.mkdir(parents=True, exist_ok=True)

    frames = sorted(p for p in FIXTURES.iterdir() if p.suffix.lower() in EXTS) \
        if FIXTURES.exists() else []
    if not frames:
        print(f"No fixtures found in {FIXTURES}. Add frame images there first.")
        return 1

    for path in frames:
        data = path.read_bytes()
        res = detect_ball_in_frame(data, center_x=None, search_half_width=None)
        frame = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
        annotated = frame.copy()
        status = "MISS"
        if res["x"] is not None:
            x, y, r = res["x"], res["y"], res["r"]
            cv2.circle(annotated, (x, y), r, (0, 0, 255), 3)
            cv2.circle(annotated, (x, y), 3, (0, 0, 255), -1)
            status = f"x={x} y={y} r={r}"
        print(f"{path.name:30s} -> {status}")

        cv2.imwrite(str(out_dir / f"{path.stem}_annotated.jpg"), annotated)
        cv2.imwrite(str(out_dir / f"{path.stem}_mask.jpg"), _white_mask(frame))

    print(f"\nAnnotated images written to {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
