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

// One putt found inside a multi-putt session video: the analysis fields plus
// where it sits in the source clip.
export interface SessionPutt extends AnalysisResult {
  index: number;
  start_frame: number;
  end_frame: number;
  start_s: number;
  end_s: number;
}

export interface SessionCalibration {
  gate_center_x: number;
  gate_line_y: number;
  aim_top: [number, number] | null;
  ball_radius_px: number | null;
  mm_per_px: number;
  calibration_frame: number;
  scale_source: "ball_radius" | "gate_width_override";
}

// Response of POST /analyze-session: the backend segments the video by motion
// and returns only the segments that produced a real putt.
export interface SessionResult {
  fps: number;
  frame_count: number;
  duration_s: number;
  calibration: SessionCalibration;
  segments_detected: number;
  putts: SessionPutt[];
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

// Backend base URL. Same-origin `/api` by default: in production Firebase
// Hosting rewrites /api/** to Cloud Run (no CORS); in dev the Vite server
// proxies /api to the local backend (see vite.config.ts). Overridable via
// VITE_API_BASE (see .env.production).
export const API_BASE = import.meta.env.VITE_API_BASE ?? "/api";

// Estimate a clip's frame rate by briefly (muted) playing it and measuring the
// gap between presented frames via requestVideoFrameCallback — more reliable
// than what the backend can read from some containers. Pauses and rewinds the
// video before resolving; resolves null when the API is unavailable or the
// measurement fails.
export function measureVideoFps(
  video: HTMLVideoElement,
): Promise<number | null> {
  return new Promise((resolve) => {
    if (!("requestVideoFrameCallback" in video)) {
      resolve(null);
      return;
    }
    const deltas: number[] = [];
    let lastMediaTime: number | null = null;
    const finish = () => {
      const positive = deltas.filter((d) => d > 0).sort((a, b) => a - b);
      const median = positive.length
        ? positive[Math.floor(positive.length / 2)]
        : 0;
      video.pause();
      const onSeeked = () => {
        video.removeEventListener("seeked", onSeeked);
        resolve(median > 0 ? snapFps(1 / median) : null);
      };
      video.addEventListener("seeked", onSeeked);
      video.currentTime = 0;
    };
    const onFrame: VideoFrameRequestCallback = (_now, metadata) => {
      if (lastMediaTime !== null)
        deltas.push(metadata.mediaTime - lastMediaTime);
      lastMediaTime = metadata.mediaTime;
      if (deltas.length >= 15) {
        finish();
      } else {
        video.requestVideoFrameCallback(onFrame);
      }
    };
    const prevMuted = video.muted;
    video.muted = true;
    video
      .play()
      .then(() => {
        video.requestVideoFrameCallback(onFrame);
      })
      .catch(() => {
        video.muted = prevMuted;
        resolve(null);
      });
  });
}
