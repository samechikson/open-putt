// Shared types and helpers for putt analysis, used by the dashboard (App) and
// the per-video cards (VideoCard).

export const COMMON_FPS = [24, 25, 30, 48, 50, 60, 90, 120, 144, 240];

// Snap a measured frame rate to the nearest common value when it's within ~8%,
// otherwise just round it.
export function snapFps(measured: number): number {
  const nearest = COMMON_FPS.reduce((prev, cur) =>
    Math.abs(cur - measured) < Math.abs(prev - measured) ? cur : prev,
  );
  return Math.abs(nearest - measured) / nearest <= 0.08
    ? nearest
    : Math.max(1, Math.round(measured));
}

export interface CalibrationValues {
  gateCenterX: number;
  gateLineY: number;
  gateWidthPx: number;
  gateWidthMm: number;
}

export interface AnalysisResult {
  offset_px: number | null;
  offset_mm: number | null;
  direction: string | null;
  track_count: number;
  positions: [number, number][];
  hough_circles?: [number, number, number][]; // [x, y, r] in source-video px
  crossing_pos: [number, number] | null;
  speed_mps?: number | null; // ball speed at the gate crossing
  message?: string;
}

export type Side = "left" | "right" | "center";

// Clips are filmed face-on, which mirrors the image horizontally, so the raw
// offset sign from the backend (positive = image-right) is the opposite of the
// golfer's left/right. Flip it to report the golfer's perspective.
export function golferSide(offsetMm: number): Side {
  const v = -offsetMm; // undo the face-on mirror
  return v > 0 ? "right" : v < 0 ? "left" : "center";
}

// A putt that finishes right of the target is a "push"; left of it, a "pull".
export function biasWord(side: Side): string {
  return side === "right" ? "push" : side === "left" ? "pull" : "none";
}

export const DEFAULT_CAL: CalibrationValues = {
  gateCenterX: 320,
  gateLineY: 400,
  gateWidthPx: 200,
  gateWidthMm: 100,
};

export const API_BASE = "http://localhost:8000";
