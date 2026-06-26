import { useState, useRef, useEffect, useCallback } from "react";
import "./App.css";

interface CalibrationValues {
  gateCenterX: number;
  gateLineY: number;
  gateWidthPx: number;
  gateWidthMm: number;
}

interface AnalysisResult {
  offset_px: number | null;
  offset_mm: number | null;
  direction: string | null;
  pass_fail: string | null;
  track_count: number;
  positions: [number, number][];
  crossing_pos: [number, number] | null;
  message?: string;
}

const DEFAULT_CAL: CalibrationValues = {
  gateCenterX: 320,
  gateLineY: 400,
  gateWidthPx: 200,
  gateWidthMm: 100,
};

function App() {
  const [file, setFile] = useState<File | null>(null);
  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  const [videoDims, setVideoDims] = useState<{ w: number; h: number } | null>(
    null,
  );
  const [ballCircle, setBallCircle] = useState<{
    x: number;
    y: number;
    r: number;
  } | null>(null);
  const [detectStatus, setDetectStatus] = useState<
    "idle" | "detecting" | "found" | "not-found"
  >("idle");
  const [ballPath, setBallPath] = useState<[number, number][]>([]);
  const [crossingPos, setCrossingPos] = useState<[number, number] | null>(null);
  const [cal, setCal] = useState<CalibrationValues>(DEFAULT_CAL);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<AnalysisResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);

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

    ctx.strokeStyle = "rgba(0, 230, 100, 0.9)";
    ctx.lineWidth = 2;
    ctx.setLineDash([]);
    ctx.beginPath();
    ctx.moveTo(cx, 0);
    ctx.lineTo(cx, canvas.height);
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
    ctx.fillText("center", cx + 6, 18);
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
  }, [cal, videoDims, ballCircle, ballPath, crossingPos]);

  useEffect(() => {
    drawCalibration();
  }, [drawCalibration]);

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
      fd.append("gate_width_px", String(Math.round(w * 0.2)));
      try {
        const res = await fetch("http://localhost:8000/detect-ball", {
          method: "POST",
          body: fd,
        });
        if (!res.ok) {
          setDetectStatus("not-found");
          return;
        }
        const data = await res.json();
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

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0] ?? null;
    setFile(f);
    setResult(null);
    setBallCircle(null);
    setDetectStatus("idle");
    setBallPath([]);
    setCrossingPos(null);
    if (videoUrl) URL.revokeObjectURL(videoUrl);
    setVideoUrl(f ? URL.createObjectURL(f) : null);
    setVideoDims(null);
  };

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

  const handleVideoData = () => {
    const video = videoRef.current;
    if (!video || !video.videoWidth) return;
    detectBallInFirstFrame(video, video.videoWidth, video.videoHeight);
  };

  useEffect(() => {
    const observer = new ResizeObserver(() => {
      syncCanvasSize();
      drawCalibration();
    });
    if (videoRef.current) observer.observe(videoRef.current);
    return () => observer.disconnect();
  }, [syncCanvasSize, drawCalibration]);

  const updateCal = (key: keyof CalibrationValues, val: string) => {
    setCal((prev) => ({ ...prev, [key]: Number(val) }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!file) return;
    setLoading(true);
    setError(null);
    setResult(null);
    const fd = new FormData();
    fd.append("video", file);
    fd.append("gate_center_x", String(cal.gateCenterX));
    fd.append("gate_line_y", String(cal.gateLineY));
    fd.append("gate_width_px", String(cal.gateWidthPx));
    fd.append("gate_width_mm", String(cal.gateWidthMm));
    if (ballCircle) {
      fd.append("ball_radius_hint", String(ballCircle.r));
      fd.append("ball_x_hint", String(Math.round(ballCircle.x)));
      fd.append("ball_y_hint", String(Math.round(ballCircle.y)));
    }
    try {
      const res = await fetch("http://localhost:8000/analyze", {
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
      setCrossingPos(data.crossing_pos ?? null);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Unknown error");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-[#0d0d0d] text-[#d0d0d0] px-4 py-8">
      <div className="max-w-6xl mx-auto">
        <h1 className="text-3xl font-bold text-white mb-1">
          Putting Gate Analyzer
        </h1>
        <p className="text-sm text-[#888] mb-6">
          Upload a video — get your offset measurement
        </p>

        <form onSubmit={handleSubmit}>
          {/* Two-column layout on md+ screens */}
          <div className="flex flex-col md:flex-row gap-6">
            {/* LEFT: Video */}
            <div className="md:w-1/2 flex flex-col gap-4">
              {/* Upload */}
              <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5">
                <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-3">
                  1. Upload Video
                </h2>
                <input
                  ref={fileRef}
                  type="file"
                  accept="video/*"
                  onChange={handleFileChange}
                  required
                  className="block w-full bg-[#111] border border-[#444] rounded-md text-sm text-[#fff] px-3 py-2 file:mr-3 file:py-1 file:px-3 file:rounded file:border-0 file:bg-[#333] file:text-white file:cursor-pointer"
                />
                {file && (
                  <p className="text-xs text-[#888] mt-2">{file.name}</p>
                )}
              </div>

              {/* Video preview */}
              {videoUrl && (
                <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5">
                  <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-3">
                    Preview
                  </h2>
                  <div className="relative w-full">
                    <video
                      ref={videoRef}
                      src={videoUrl}
                      className="w-full block rounded-md bg-black"
                      controls
                      onLoadedMetadata={handleVideoMetadata}
                      onLoadedData={handleVideoData}
                    />
                    <canvas ref={canvasRef} className="cal-canvas" />
                  </div>
                  <p className={`detect-status ${detectStatus}`}>
                    {detectStatus === "detecting" && "Detecting ball…"}
                    {detectStatus === "found" && "Ball detected"}
                    {detectStatus === "not-found" &&
                      "Ball not found — adjust HoughCircles params or check lighting"}
                  </p>
                </div>
              )}
            </div>

            {/* RIGHT: Controls */}
            <div className="md:w-1/2 flex flex-col gap-4">
              {/* Calibration */}
              <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5">
                <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-1">
                  2. Calibration
                </h2>
                <p className="text-xs text-[#888] mb-4">
                  Adjust these values so the lines in the preview align with
                  your physical gate. Measure once per camera position.
                </p>
                <div className="grid grid-cols-2 gap-3">
                  {(
                    [
                      ["gateCenterX", "Gate center X (px)"],
                      ["gateLineY", "Gate reference line Y (px)"],
                      ["gateWidthPx", "Gate width (px)"],
                      ["gateWidthMm", "Gate width (mm)"],
                    ] as [keyof CalibrationValues, string][]
                  ).map(([key, label]) => (
                    <label
                      key={key}
                      className="flex flex-col gap-1 text-sm text-[#ccc]"
                    >
                      {label}
                      <input
                        type="number"
                        value={cal[key]}
                        onChange={(e) => updateCal(key, e.target.value)}
                        className="bg-[#111] border border-[#444] rounded-md text-white px-2.5 py-2 text-sm w-full box-border"
                      />
                    </label>
                  ))}
                </div>
              </div>

              {/* Submit */}
              <button
                type="submit"
                disabled={!file || loading}
                className="w-full py-3.5 bg-[#22c55e] text-black text-base font-bold rounded-lg cursor-pointer transition-colors hover:bg-[#16a34a] disabled:bg-[#333] disabled:text-[#666] disabled:cursor-not-allowed"
              >
                {loading ? "Analyzing…" : "Analyze Putt"}
              </button>

              {/* Error */}
              {error && (
                <div className="bg-[#3a0a0a] border border-[#7f1d1d] text-[#fca5a5] rounded-lg px-4 py-3 text-sm">
                  {error}
                </div>
              )}

              {/* Result */}
              {result && (
                <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5">
                  <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-2">
                    Result
                  </h2>
                  {result.message && (
                    <p className="text-xs text-[#888] mb-2">{result.message}</p>
                  )}
                  {result.pass_fail && (
                    <div className={`verdict ${result.pass_fail}`}>
                      {result.pass_fail.toUpperCase()}
                    </div>
                  )}
                  {result.offset_mm !== null && (
                    <p className="text-sm mt-1">
                      Offset:{" "}
                      <strong>
                        {result.offset_mm > 0 ? "+" : ""}
                        {result.offset_mm} mm
                      </strong>{" "}
                      ({result.direction})
                    </p>
                  )}
                  <p className="text-xs text-[#888] mt-2">
                    Frames with ball detected: {result.track_count}
                  </p>
                </div>
              )}
            </div>
          </div>
        </form>
      </div>
    </div>
  );
}

export default App;
