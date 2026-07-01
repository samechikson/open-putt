import { useState, useCallback } from "react";
import "./App.css";
import VideoCard from "./VideoCard";
import type { AnalysisResult } from "./analysis";

const MAX_VIDEOS = 5;

interface VideoItem {
  id: string;
  file: File;
}

function mean(nums: number[]): number | null {
  if (nums.length === 0) return null;
  return nums.reduce((a, b) => a + b, 0) / nums.length;
}

function App() {
  const [videos, setVideos] = useState<VideoItem[]>([]);
  const [results, setResults] = useState<Record<string, AnalysisResult | null>>(
    {},
  );
  const [overflowNote, setOverflowNote] = useState(false);

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files ?? []);
    setOverflowNote(files.length > MAX_VIDEOS);
    const items: VideoItem[] = files.slice(0, MAX_VIDEOS).map((file, i) => ({
      id: `${Date.now()}-${i}-${file.name}`,
      file,
    }));
    setVideos(items);
    setResults({});
    // Allow re-selecting the same files to re-trigger.
    e.target.value = "";
  };

  const handleResult = useCallback(
    (id: string, result: AnalysisResult | null) => {
      setResults((prev) => ({ ...prev, [id]: result }));
    },
    [],
  );

  // Aggregate over videos that produced a usable offset.
  const valid = videos
    .map((v) => results[v.id])
    .filter((r): r is AnalysisResult => !!r && r.offset_mm !== null);
  const offsets = valid.map((r) => r.offset_mm as number);
  const speeds = valid
    .map((r) => r.speed_mps)
    .filter((s): s is number => s != null);

  const avgAbsOffset = mean(offsets.map(Math.abs));
  const bias = mean(offsets); // signed: positive = right, negative = left
  const avgSpeed = mean(speeds);

  const biasDir = bias == null ? "" : bias > 0 ? "right" : bias < 0 ? "left" : "center";
  const analyzedCount = valid.length;

  const fmt = (n: number | null, digits = 1) =>
    n == null ? "—" : n.toFixed(digits);

  return (
    <div className="min-h-screen bg-[#0d0d0d] text-[#d0d0d0] px-4 py-8">
      <div className="max-w-6xl mx-auto">
        <h1 className="text-3xl font-bold text-white mb-1">
          Putting Gate Dashboard
        </h1>
        <p className="text-sm text-[#888] mb-6">
          Upload up to {MAX_VIDEOS} putts — analysis runs automatically
        </p>

        {/* Upload */}
        <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 mb-6">
          <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-3">
            Upload Videos
          </h2>
          <input
            type="file"
            accept="video/*"
            multiple
            onChange={handleFileChange}
            className="block w-full bg-[#111] border border-[#444] rounded-md text-sm text-[#fff] px-3 py-2 file:mr-3 file:py-1 file:px-3 file:rounded file:border-0 file:bg-[#333] file:text-white file:cursor-pointer"
          />
          {overflowNote && (
            <p className="text-xs text-[#f0b429] mt-2">
              Only the first {MAX_VIDEOS} videos are analyzed.
            </p>
          )}
          {videos.length > 0 && (
            <p className="text-xs text-[#888] mt-2">
              {videos.length} video{videos.length > 1 ? "s" : ""} loaded
            </p>
          )}
        </div>

        {/* Summary */}
        {videos.length > 0 && (
          <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 mb-6">
            <div className="flex items-center justify-between mb-3">
              <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa]">
                Session Averages
              </h2>
              <span className="text-xs text-[#888]">
                {analyzedCount} of {videos.length} analyzed
              </span>
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
              <div>
                <div className="offset-value">{fmt(avgAbsOffset)} mm</div>
                <p className="text-sm text-[#aaa] -mt-1">avg offset (accuracy)</p>
              </div>
              <div>
                <div className="offset-value">
                  {bias == null ? "—" : `${Math.abs(bias).toFixed(1)} mm`}
                </div>
                <p className="text-sm text-[#aaa] -mt-1">
                  {bias == null
                    ? "directional bias"
                    : biasDir === "center"
                      ? "no directional bias"
                      : `bias ${biasDir}`}
                </p>
              </div>
              <div>
                <div className="offset-value">{fmt(avgSpeed, 2)} m/s</div>
                <p className="text-sm text-[#aaa] -mt-1">avg speed at gate</p>
              </div>
            </div>
          </div>
        )}

        {/* Per-video cards */}
        {videos.length > 0 && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            {videos.map((v, i) => (
              <VideoCard
                key={v.id}
                id={v.id}
                index={i}
                file={v.file}
                onResult={handleResult}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

export default App;
