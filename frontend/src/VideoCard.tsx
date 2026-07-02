import { useState, useRef, useEffect, useCallback } from "react";
import {
  API_BASE,
  DEFAULT_CAL,
  golferSide,
  measureVideoFps,
  type AnalysisResult,
  type CalibrationValues,
} from "./analysis";

interface VideoCardProps {
  id: string;
  file: File;
  index: number;
  onResult: (id: string, result: AnalysisResult | null) => void;
  onBusyChange: (id: string, busy: boolean) => void;
}

function VideoCard({ id, file, index, onResult, onBusyChange }: VideoCardProps) {
  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  const [videoDims, setVideoDims] = useState<{ w: number; h: number } | null>(
    null,
  );
  const [ballCircle, setBallCircle] = useState<{
    x: number;
    y: number;
    r: number;
  } | null>(null);
  const [laserPoints, setLaserPoints] = useState<{
    top: [number, number] | null;
    bottom: [number, number] | null;
  } | null>(null);
  const [detectStatus, setDetectStatus] = useState<
    "idle" | "detecting" | "found" | "not-found"
  >("idle");
  const [ballPath, setBallPath] = useState<[number, number][]>([]);
  const [houghCircles, setHoughCircles] = useState<
    [number, number, number][]
  >([]);
  const [crossingPos, setCrossingPos] = useState<[number, number] | null>(null);
  const [cal, setCal] = useState<CalibrationValues>(DEFAULT_CAL);
  const [loading, setLoading] = useState(false);
  const [processing, setProcessing] = useState(false); // detect + fps + analyze
  const [result, setResult] = useState<AnalysisResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fps, setFps] = useState(30);

  // "Busy" whenever the backend pipeline (detect/fps/analyze) is in flight, so
  // the card and the dashboard summary can show a loading indicator.
  const busy = processing || loading;

  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const didInitVideo = useRef(false);
  const didAutoAnalyze = useRef(false);
  // Latest calibration/fps/laser values for the auto-analysis kickoff, which
  // runs from a ref-guarded async flow rather than reactively.
  const calRef = useRef(cal);
  const fpsRef = useRef(fps);
  const laserRef = useRef(laserPoints);
  const ballRef = useRef(ballCircle);
  useEffect(() => {
    calRef.current = cal;
  }, [cal]);
  useEffect(() => {
    fpsRef.current = fps;
  }, [fps]);
  useEffect(() => {
    laserRef.current = laserPoints;
  }, [laserPoints]);
  useEffect(() => {
    ballRef.current = ballCircle;
  }, [ballCircle]);
  useEffect(() => {
    onBusyChange(id, busy);
  }, [busy, id, onBusyChange]);

  // Create/revoke the object URL for the file.
  useEffect(() => {
    const url = URL.createObjectURL(file);
    setVideoUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [file]);

  const drawCalibration = useCallback(() => {
    const canvas = canvasRef.current;
    const video = videoRef.current;
    if (!canvas || !video || !videoDims) return;

    const scaleX = canvas.width / videoDims.w;
    const scaleY = canvas.height / videoDims.h;

    const cx = cal.gateCenterX * scaleX;
    const ly = cal.gateLineY * scaleY;
    const halfGate = (cal.gateWidthPx / 2) * scaleX;

    const ctx = canvas.getContext("2d")!;
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    ctx.strokeStyle = "rgba(255, 220, 0, 0.85)";
    ctx.lineWidth = 2;
    ctx.setLineDash([8, 4]);
    ctx.beginPath();
    ctx.moveTo(0, ly);
    ctx.lineTo(canvas.width, ly);
    ctx.stroke();

    // Aim line: draw through both laser dots (extended to the frame edges) so it
    // follows the real putt line; fall back to a vertical line at cx otherwise.
    const top = laserPoints?.top;
    const bottom = laserPoints?.bottom;
    const tilted = top && bottom && top[1] !== bottom[1];
    const xAt = (y: number) => {
      const [tx, ty] = top!;
      const [bx, by] = bottom!;
      return (tx + ((y / scaleY - ty) * (bx - tx)) / (by - ty)) * scaleX;
    };
    ctx.strokeStyle = "rgba(0, 230, 100, 0.9)";
    ctx.lineWidth = 2;
    ctx.setLineDash([]);
    ctx.beginPath();
    if (tilted) {
      ctx.moveTo(xAt(0), 0);
      ctx.lineTo(xAt(canvas.height), canvas.height);
    } else {
      ctx.moveTo(cx, 0);
      ctx.lineTo(cx, canvas.height);
    }
    ctx.stroke();

    ctx.strokeStyle = "rgba(0, 180, 255, 0.85)";
    ctx.lineWidth = 2;
    ctx.setLineDash([]);
    ctx.beginPath();
    ctx.moveTo(cx - halfGate, ly - 14);
    ctx.lineTo(cx - halfGate, ly + 14);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(cx + halfGate, ly - 14);
    ctx.lineTo(cx + halfGate, ly + 14);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(cx - halfGate, ly);
    ctx.lineTo(cx + halfGate, ly);
    ctx.stroke();

    ctx.font = "bold 13px system-ui, sans-serif";
    ctx.fillStyle = "rgba(0, 230, 100, 0.95)";
    ctx.fillText("center", (tilted ? xAt(18) : cx) + 6, 18);
    ctx.fillStyle = "rgba(255, 220, 0, 0.95)";
    ctx.fillText("gate line", 6, ly - 6);

    if (ballPath.length > 1) {
      const n = ballPath.length;
      ctx.strokeStyle = "rgba(255, 20, 20, 1)";
      ctx.lineWidth = 3;
      ctx.setLineDash([]);
      ctx.beginPath();
      const [x0, y0] = ballPath[0];
      ctx.moveTo(x0 * scaleX, y0 * scaleY);
      for (let i = 1; i < n; i++) {
        const [x1, y1] = ballPath[i];
        ctx.lineTo(x1 * scaleX, y1 * scaleY);
      }
      ctx.stroke();
      for (let i = 0; i < n; i++) {
        const [x, y] = ballPath[i];
        ctx.fillStyle = "rgba(255, 20, 20, 0.85)";
        ctx.beginPath();
        ctx.arc(x * scaleX, y * scaleY, 4, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    if (crossingPos) {
      const [bx, by] = [crossingPos[0] * scaleX, crossingPos[1] * scaleY];
      ctx.strokeStyle = "rgba(255, 80, 50, 1)";
      ctx.lineWidth = 3;
      ctx.setLineDash([]);
      ctx.beginPath();
      ctx.arc(bx, by, 14, 0, Math.PI * 2);
      ctx.stroke();
      ctx.fillStyle = "rgba(255, 80, 50, 0.9)";
      ctx.beginPath();
      ctx.arc(bx, by, 5, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = "rgba(255, 160, 50, 0.8)";
      ctx.lineWidth = 2;
      ctx.setLineDash([4, 3]);
      ctx.beginPath();
      ctx.moveTo(cx, by);
      ctx.lineTo(bx, by);
      ctx.stroke();
      ctx.setLineDash([]);
    }

    if (ballCircle && ballPath.length === 0) {
      const bx = ballCircle.x * scaleX;
      const by = ballCircle.y * scaleY;
      const br = ballCircle.r * Math.max(scaleX, scaleY);
      ctx.strokeStyle = "rgba(255, 80, 80, 0.9)";
      ctx.lineWidth = 2.5;
      ctx.setLineDash([]);
      ctx.beginPath();
      ctx.arc(bx, by, br, 0, Math.PI * 2);
      ctx.stroke();
      ctx.fillStyle = "rgba(255, 80, 80, 0.9)";
      ctx.beginPath();
      ctx.arc(bx, by, 3, 0, Math.PI * 2);
      ctx.fill();
    }

    // Laser dots from the mount — magenta crosses confirming auto-calibration.
    if (laserPoints) {
      ctx.strokeStyle = "rgba(255, 0, 200, 0.95)";
      ctx.lineWidth = 2;
      ctx.setLineDash([]);
      const arm = 8;
      for (const pt of [laserPoints.top, laserPoints.bottom]) {
        if (!pt) continue;
        const lx = pt[0] * scaleX;
        const lyp = pt[1] * scaleY;
        ctx.beginPath();
        ctx.moveTo(lx - arm, lyp);
        ctx.lineTo(lx + arm, lyp);
        ctx.moveTo(lx, lyp - arm);
        ctx.lineTo(lx, lyp + arm);
        ctx.stroke();
      }
    }

    if (houghCircles.length) {
      ctx.strokeStyle = "rgba(80, 180, 255, 0.9)";
      ctx.lineWidth = 2;
      ctx.setLineDash([]);
      const rScale = Math.max(scaleX, scaleY);
      for (const [hx, hy, hr] of houghCircles) {
        ctx.beginPath();
        ctx.arc(hx * scaleX, hy * scaleY, hr * rScale, 0, Math.PI * 2);
        ctx.stroke();
      }
    }
  }, [cal, videoDims, ballCircle, ballPath, houghCircles, crossingPos, laserPoints]);

  useEffect(() => {
    drawCalibration();
  }, [drawCalibration]);

  const syncCanvasSize = useCallback(() => {
    const video = videoRef.current;
    const canvas = canvasRef.current;
    if (!video || !canvas) return;
    const rect = video.getBoundingClientRect();
    if (canvas.width !== rect.width || canvas.height !== rect.height) {
      canvas.width = rect.width;
      canvas.height = rect.height;
    }
  }, []);

  useEffect(() => {
    const observer = new ResizeObserver(() => {
      syncCanvasSize();
      drawCalibration();
    });
    if (videoRef.current) observer.observe(videoRef.current);
    return () => observer.disconnect();
  }, [syncCanvasSize, drawCalibration]);

  // Run the analysis for this video with the current calibration/fps.
  const runAnalysis = useCallback(async () => {
    setLoading(true);
    setError(null);
    const c = calRef.current;
    const fd = new FormData();
    fd.append("video", file);
    fd.append("gate_center_x", String(c.gateCenterX));
    fd.append("gate_line_y", String(c.gateLineY));
    fd.append("gate_width_px", String(c.gateWidthPx));
    fd.append("gate_width_mm", String(c.gateWidthMm));
    const ball = ballRef.current;
    if (ball) {
      fd.append("ball_radius_hint", String(ball.r));
      fd.append("ball_x_hint", String(Math.round(ball.x)));
      fd.append("ball_y_hint", String(Math.round(ball.y)));
    }
    // The top laser dot anchors the aim line (ball → target) so the offset is
    // measured perpendicular to the real putt line rather than vertically.
    const lasers = laserRef.current;
    if (lasers?.top) {
      fd.append("aim_top_x", String(Math.round(lasers.top[0])));
      fd.append("aim_top_y", String(Math.round(lasers.top[1])));
    }
    // The measured frame rate lets the backend turn the per-frame ball
    // displacement into a real speed (m/s) at the gate.
    fd.append("fps", String(fpsRef.current));
    try {
      const res = await fetch(`${API_BASE}/analyze`, {
        method: "POST",
        body: fd,
      });
      if (!res.ok) {
        const data = await res.json();
        throw new Error(data.detail || "Server error");
      }
      const data: AnalysisResult = await res.json();
      setResult(data);
      setBallPath(data.positions ?? []);
      setHoughCircles(data.hough_circles ?? []);
      setCrossingPos(data.crossing_pos ?? null);
      onResult(id, data);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Unknown error");
      onResult(id, null);
    } finally {
      setLoading(false);
    }
  }, [file, id, onResult]);

  const detectBallInFirstFrame = useCallback(
    async (video: HTMLVideoElement, w: number, h: number) => {
      setDetectStatus("detecting");
      await new Promise<void>((resolve) => {
        const onSeeked = () => {
          video.removeEventListener("seeked", onSeeked);
          resolve();
        };
        video.addEventListener("seeked", onSeeked);
        video.currentTime = 0;
      });
      const offscreen = document.createElement("canvas");
      offscreen.width = w;
      offscreen.height = h;
      offscreen.getContext("2d")!.drawImage(video, 0, 0, w, h);
      const blob = await new Promise<Blob | null>((res) =>
        offscreen.toBlob(res, "image/jpeg", 0.92),
      );
      if (!blob) {
        setDetectStatus("not-found");
        return;
      }
      const fd = new FormData();
      fd.append("frame", blob, "frame.jpg");
      fd.append("center_x", String(Math.round(w / 2)));
      fd.append("search_half_width", String(Math.round(w * 0.2)));
      try {
        const res = await fetch(`${API_BASE}/detect-ball`, {
          method: "POST",
          body: fd,
        });
        if (!res.ok) {
          setDetectStatus("not-found");
          return;
        }
        const data = await res.json();
        if (data.lasers) {
          setLaserPoints(data.lasers);
        }
        // Auto-calibrate from the fixed laser dots: top → center x, bottom → target line.
        if (data.gate_center_x != null || data.gate_line_y != null) {
          setCal((prev) => ({
            ...prev,
            ...(data.gate_center_x != null
              ? { gateCenterX: data.gate_center_x }
              : {}),
            ...(data.gate_line_y != null
              ? { gateLineY: data.gate_line_y }
              : {}),
          }));
        }
        if (data.x !== null) {
          setBallCircle({ x: data.x, y: data.y, r: data.r });
          setDetectStatus("found");
        } else {
          setDetectStatus("not-found");
        }
      } catch {
        setDetectStatus("not-found");
      }
    },
    [],
  );

  const handleVideoMetadata = () => {
    const video = videoRef.current;
    if (!video) return;
    const w = video.videoWidth;
    const h = video.videoHeight;
    setVideoDims({ w, h });
    setCal((prev) => ({
      ...prev,
      gateCenterX: Math.round(w / 2),
      gateLineY: Math.round(h - 20),
    }));
    syncCanvasSize();
  };

  // Falls back to the current fps if the measurement fails.
  const measureFps = useCallback(async (video: HTMLVideoElement) => {
    const measured = await measureVideoFps(video);
    if (measured != null) setFps(measured);
  }, []);

  // On load: detect the ball + lasers, measure fps, then auto-run the analysis
  // once. All guarded by refs so it fires a single time per file.
  const handleVideoData = async () => {
    const video = videoRef.current;
    if (!video || !video.videoWidth) return;
    if (didInitVideo.current) return;
    didInitVideo.current = true;
    setProcessing(true);
    try {
      await detectBallInFirstFrame(video, video.videoWidth, video.videoHeight);
      await measureFps(video);
      if (!didAutoAnalyze.current) {
        didAutoAnalyze.current = true;
        await runAnalysis();
      }
    } finally {
      setProcessing(false);
    }
  };

  const updateCal = (key: keyof CalibrationValues, val: string) => {
    setCal((prev) => ({ ...prev, [key]: Number(val) }));
  };

  return (
    <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-4 flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-white truncate" title={file.name}>
          Putt {index + 1}
        </h3>
        <span className="text-[11px] text-[#666] truncate max-w-[50%]" title={file.name}>
          {file.name}
        </span>
      </div>

      <div className="relative w-full">
        <video
          ref={videoRef}
          src={videoUrl ?? undefined}
          className="w-full block rounded-md bg-black"
          playsInline
          controls
          onLoadedMetadata={handleVideoMetadata}
          onLoadedData={handleVideoData}
        />
        <canvas ref={canvasRef} className="cal-canvas" />
        {busy && (
          <div className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-2 bg-black/50 rounded-md">
            <span className="w-8 h-8 border-[3px] border-[#22c55e] border-t-transparent rounded-full animate-spin" />
            <span className="text-xs text-[#ddd]">
              {loading ? "Analyzing…" : "Detecting ball…"}
            </span>
          </div>
        )}
      </div>

      <p className={`detect-status ${detectStatus}`}>
        {detectStatus === "detecting" && "Detecting ball…"}
        {detectStatus === "found" && "Ball detected"}
        {detectStatus === "not-found" &&
          "Ball not found — adjust calibration or check lighting"}
      </p>

      {/* Individual result */}
      {result && (
        <div className="border-t border-[#333] pt-3">
          {result.offset_mm !== null ? (
            <div className="flex items-end gap-6">
              <div>
                <div className="offset-value !text-[1.75rem] !my-0">
                  {Math.abs(result.offset_mm)} mm
                </div>
                <p className="text-xs text-[#aaa]">
                  {golferSide(result.offset_mm) === "center"
                    ? "on center"
                    : golferSide(result.offset_mm)}
                </p>
              </div>
              {result.speed_mps != null && (
                <div>
                  <div className="offset-value !text-[1.75rem] !my-0">
                    {result.speed_mps} m/s
                  </div>
                  <p className="text-xs text-[#aaa]">at gate</p>
                </div>
              )}
            </div>
          ) : (
            <p className="text-sm text-[#888]">No offset measured</p>
          )}
          {result.message && (
            <p className="text-[11px] text-[#777] mt-1">{result.message}</p>
          )}
        </div>
      )}

      {error && (
        <div className="bg-[#3a0a0a] border border-[#7f1d1d] text-[#fca5a5] rounded-lg px-3 py-2 text-xs">
          {error}
        </div>
      )}

      {/* Calibration (collapsible) */}
      <details className="text-sm text-[#ccc]">
        <summary className="cursor-pointer text-xs text-[#888] select-none">
          Calibration
        </summary>
        <div className="grid grid-cols-2 gap-2 mt-2">
          {(
            [
              ["gateCenterX", "Center X (px)"],
              ["gateLineY", "Gate line Y (px)"],
              ["gateWidthPx", "Gate width (px)"],
              ["gateWidthMm", "Gate width (mm)"],
            ] as [keyof CalibrationValues, string][]
          ).map(([key, label]) => (
            <label key={key} className="flex flex-col gap-1 text-xs text-[#ccc]">
              {label}
              <input
                type="number"
                value={cal[key]}
                onChange={(e) => updateCal(key, e.target.value)}
                className="bg-[#111] border border-[#444] rounded-md text-white px-2 py-1.5 text-sm w-full box-border"
              />
            </label>
          ))}
        </div>
        <button
          type="button"
          onClick={() => runAnalysis()}
          disabled={loading}
          className="mt-2 px-3 py-1.5 bg-[#222] border border-[#444] rounded-md text-sm text-white cursor-pointer hover:bg-[#2c2c2c] disabled:opacity-50"
        >
          {loading ? "Analyzing…" : "Re-analyze"}
        </button>
      </details>
    </div>
  );
}

export default VideoCard;
