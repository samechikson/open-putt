import { useState, useRef, useEffect, useCallback } from "react";
import {
  API_BASE,
  golferSide,
  measureVideoFps,
  type SessionResult,
} from "./analysis";

interface SessionCardProps {
  file: File;
  onResult: (result: SessionResult | null) => void;
  onBusyChange: (busy: boolean) => void;
}

// One multi-putt video: the backend segments it by motion, auto-calibrates from
// the laser dots, and returns a result per putt. Clicking a putt row seeks the
// player to that putt and highlights its track on the overlay.
function SessionCard({ file, onResult, onBusyChange }: SessionCardProps) {
  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  const [videoDims, setVideoDims] = useState<{ w: number; h: number } | null>(
    null,
  );
  const [result, setResult] = useState<SessionResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [selected, setSelected] = useState<number | null>(null);

  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const didAnalyze = useRef(false);

  useEffect(() => {
    onBusyChange(loading);
  }, [loading, onBusyChange]);

  useEffect(() => {
    const url = URL.createObjectURL(file);
    setVideoUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [file]);

  const runAnalysis = useCallback(
    async (fps: number | null) => {
      setLoading(true);
      setError(null);
      const fd = new FormData();
      fd.append("video", file);
      if (fps) fd.append("fps", String(fps));
      try {
        const res = await fetch(`${API_BASE}/analyze-session`, {
          method: "POST",
          body: fd,
        });
        if (!res.ok) {
          const data = await res.json();
          throw new Error(data.detail || "Server error");
        }
        const data: SessionResult = await res.json();
        setResult(data);
        setSelected(data.putts.length ? 0 : null);
        onResult(data);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : "Unknown error");
        onResult(null);
      } finally {
        setLoading(false);
      }
    },
    [file, onResult],
  );

  // On load: measure the real frame rate, then send the whole clip off for
  // segmentation + analysis. Ref-guarded so it fires once per file.
  const handleVideoData = async () => {
    const video = videoRef.current;
    if (!video || !video.videoWidth || didAnalyze.current) return;
    didAnalyze.current = true;
    const fps = await measureVideoFps(video);
    await runAnalysis(fps);
  };

  const handleVideoMetadata = () => {
    const video = videoRef.current;
    if (!video) return;
    setVideoDims({ w: video.videoWidth, h: video.videoHeight });
    syncCanvasSize();
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

  // Overlay: gate line + aim line from the backend's auto-calibration, and the
  // selected putt's track + crossing point.
  const drawOverlay = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas || !videoDims) return;
    const ctx = canvas.getContext("2d")!;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (!result) return;

    const scaleX = canvas.width / videoDims.w;
    const scaleY = canvas.height / videoDims.h;
    const { gate_center_x, gate_line_y, aim_top } = result.calibration;
    const cx = gate_center_x * scaleX;
    const ly = gate_line_y * scaleY;

    ctx.strokeStyle = "rgba(255, 220, 0, 0.85)";
    ctx.lineWidth = 2;
    ctx.setLineDash([8, 4]);
    ctx.beginPath();
    ctx.moveTo(0, ly);
    ctx.lineTo(canvas.width, ly);
    ctx.stroke();

    // Aim line through the ball-rest dot and the gate anchor, extended to the
    // frame edges; vertical through the gate when the top dot is missing.
    ctx.strokeStyle = "rgba(0, 230, 100, 0.9)";
    ctx.setLineDash([]);
    ctx.beginPath();
    if (aim_top && aim_top[1] !== gate_line_y) {
      const xAt = (y: number) =>
        (aim_top[0] +
          ((y / scaleY - aim_top[1]) * (gate_center_x - aim_top[0])) /
            (gate_line_y - aim_top[1])) *
        scaleX;
      ctx.moveTo(xAt(0), 0);
      ctx.lineTo(xAt(canvas.height), canvas.height);
    } else {
      ctx.moveTo(cx, 0);
      ctx.lineTo(cx, canvas.height);
    }
    ctx.stroke();

    ctx.font = "bold 13px system-ui, sans-serif";
    ctx.fillStyle = "rgba(255, 220, 0, 0.95)";
    ctx.fillText("gate line", 6, ly - 6);

    const putt = selected != null ? result.putts[selected] : undefined;
    if (putt && putt.positions.length > 1) {
      ctx.strokeStyle = "rgba(255, 20, 20, 1)";
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.moveTo(putt.positions[0][0] * scaleX, putt.positions[0][1] * scaleY);
      for (const [x, y] of putt.positions.slice(1)) {
        ctx.lineTo(x * scaleX, y * scaleY);
      }
      ctx.stroke();
    }
    if (putt?.crossing_pos) {
      const [bx, by] = [
        putt.crossing_pos[0] * scaleX,
        putt.crossing_pos[1] * scaleY,
      ];
      ctx.strokeStyle = "rgba(255, 80, 50, 1)";
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.arc(bx, by, 14, 0, Math.PI * 2);
      ctx.stroke();
    }
  }, [result, selected, videoDims]);

  useEffect(() => {
    drawOverlay();
  }, [drawOverlay]);

  useEffect(() => {
    const observer = new ResizeObserver(() => {
      syncCanvasSize();
      drawOverlay();
    });
    if (videoRef.current) observer.observe(videoRef.current);
    return () => observer.disconnect();
  }, [syncCanvasSize, drawOverlay]);

  const seekToPutt = (index: number) => {
    setSelected(index);
    const video = videoRef.current;
    const putt = result?.putts[index];
    if (video && putt) video.currentTime = putt.start_s;
  };

  const droppedCount = result
    ? result.segments_detected - result.putts.length
    : 0;

  return (
    <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-4 flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-white truncate" title={file.name}>
          Session Video
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
        {loading && (
          <div className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-2 bg-black/50 rounded-md">
            <span className="w-8 h-8 border-[3px] border-[#22c55e] border-t-transparent rounded-full animate-spin" />
            <span className="text-xs text-[#ddd]">
              Splitting into putts… this can take a minute
            </span>
          </div>
        )}
      </div>

      {error && (
        <div className="bg-[#3a0a0a] border border-[#7f1d1d] text-[#fca5a5] rounded-lg px-3 py-2 text-xs">
          {error}
        </div>
      )}

      {result && result.putts.length === 0 && (
        <p className="text-sm text-[#888]">
          No putts found in this video — make sure the ball starts on the
          ball-rest laser dot and rolls through the gate.
        </p>
      )}

      {result && result.putts.length > 0 && (
        <div className="border-t border-[#333] pt-3">
          <p className="text-xs text-[#888] mb-2">
            {result.putts.length} putt{result.putts.length > 1 ? "s" : ""} found
            {droppedCount > 0 &&
              ` (${droppedCount} other motion segment${droppedCount > 1 ? "s" : ""} skipped)`}
            {" — "}click a putt to jump to it
          </p>
          <div className="flex flex-col gap-1">
            {result.putts.map((putt, i) => {
              const side =
                putt.offset_mm == null ? "center" : golferSide(putt.offset_mm);
              return (
                <button
                  key={putt.index}
                  type="button"
                  onClick={() => seekToPutt(i)}
                  className={`flex items-baseline gap-4 text-left px-3 py-2 rounded-md border text-sm cursor-pointer ${
                    selected === i
                      ? "bg-[#232323] border-[#555]"
                      : "bg-[#111] border-[#333] hover:bg-[#1e1e1e]"
                  }`}
                >
                  <span className="text-white font-semibold whitespace-nowrap">
                    Putt {i + 1}
                  </span>
                  <span className="text-[11px] text-[#666] whitespace-nowrap">
                    {putt.start_s.toFixed(1)}–{putt.end_s.toFixed(1)}s
                  </span>
                  <span className="text-[#ddd] whitespace-nowrap">
                    {putt.offset_mm == null
                      ? "—"
                      : `${Math.abs(putt.offset_mm).toFixed(1)} mm ${
                          side === "center" ? "on center" : side
                        }`}
                  </span>
                  {putt.speed_mps != null && (
                    <span className="text-[#aaa] whitespace-nowrap">
                      {putt.speed_mps} m/s
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

export default SessionCard;
