import { useState, useCallback } from "react";
import VideoCard from "./VideoCard";
import SessionUploader from "./SessionUploader";
import {
  biasWord,
  golferSide,
  type AnalysisResult,
} from "./analysis";
import { mean, stdev } from "./stats";

const MAX_VIDEOS = 5;

interface VideoItem {
  id: string;
  file: File;
}

interface AnalyzeViewProps {
  onBack: () => void;
  // Called once a Full Session upload is queued, with its new session id, so
  // the app can navigate to the session's page to watch it process.
  onSessionCreated: (sessionId: string) => void;
}

// Upload flow. Individual Putts are analyzed in-browser and shown inline (short
// clips, not persisted). A Full Session is queued for background analysis on the
// server and the app navigates to its session page.
export default function AnalyzeView({
  onBack,
  onSessionCreated,
}: AnalyzeViewProps) {
  const [videos, setVideos] = useState<VideoItem[]>([]);
  const [results, setResults] = useState<Record<string, AnalysisResult | null>>(
    {},
  );
  const [busy, setBusy] = useState<Record<string, boolean>>({});
  const [overflowNote, setOverflowNote] = useState(false);
  // The two upload paths are alternatives, so picking one clears the other.
  const [sessionFile, setSessionFile] = useState<File | null>(null);

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files ?? []);
    setOverflowNote(files.length > MAX_VIDEOS);
    const items: VideoItem[] = files.slice(0, MAX_VIDEOS).map((file, i) => ({
      id: `${Date.now()}-${i}-${file.name}`,
      file,
    }));
    setVideos(items);
    setResults({});
    setBusy({});
    setSessionFile(null);
    // Allow re-selecting the same files to re-trigger.
    e.target.value = "";
  };

  const handleSessionFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setSessionFile(file);
    setVideos([]);
    setResults({});
    setBusy({});
    setOverflowNote(false);
    e.target.value = "";
  };

  const handleResult = useCallback(
    (id: string, result: AnalysisResult | null) => {
      setResults((prev) => ({ ...prev, [id]: result }));
    },
    [],
  );

  const handleBusy = useCallback((id: string, b: boolean) => {
    setBusy((prev) => (prev[id] === b ? prev : { ...prev, [id]: b }));
  }, []);

  const handleReset = useCallback(() => {
    setVideos([]);
    setResults({});
    setBusy({});
    setOverflowNote(false);
    setSessionFile(null);
  }, []);

  // Aggregate over individual-putt results that produced a usable offset.
  const valid = videos
    .map((v) => results[v.id])
    .filter((r): r is AnalysisResult => !!r && r.offset_mm !== null);
  const offsets = valid.map((r) => r.offset_mm as number);
  const speeds = valid
    .map((r) => r.speed_mps)
    .filter((s): s is number => s != null);

  const avgAbsOffset = mean(offsets.map(Math.abs));
  const bias = mean(offsets); // raw image-space mean; golferSide flips it face-on
  const speedDispersion = stdev(speeds);

  const biasSide = bias == null ? "center" : golferSide(bias);
  const biasLabel = biasWord(biasSide); // "push" (right) / "pull" (left)
  const sides = offsets.map(golferSide);
  const pushes = sides.filter((s) => s === "right").length;
  const pulls = sides.filter((s) => s === "left").length;
  const analyzedCount = valid.length;
  const anyProcessing = videos.some(
    (v) => busy[v.id] || results[v.id] === undefined,
  );
  const haveUploads = videos.length > 0 || sessionFile !== null;

  const fmt = (n: number | null, digits = 1) =>
    n == null ? "—" : n.toFixed(digits);

  return (
    <>
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <div>
          <h2 className="text-xl font-bold text-white mb-1">New Session</h2>
          <p className="text-sm text-[#888]">
            Upload one clip per putt, or a single video of the whole session —
            analysis runs automatically
          </p>
        </div>
        <div className="flex items-center gap-3">
          {haveUploads && (
            <button
              type="button"
              onClick={handleReset}
              className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
            >
              Clear
            </button>
          )}
          <button
            type="button"
            onClick={onBack}
            className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
          >
            ← Sessions
          </button>
        </div>
      </div>

      {/* Upload: one clip per putt (left) or one multi-putt video (right) */}
      {!haveUploads && (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
          <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5">
            <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-1">
              Individual Putts
            </h2>
            <p className="text-xs text-[#888] mb-3">
              One video per putt, up to {MAX_VIDEOS}
            </p>
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
          </div>
          <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5">
            <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-1">
              Full Session
            </h2>
            <p className="text-xs text-[#888] mb-3">
              One video with several putts — analyzed in the background
            </p>
            <input
              type="file"
              accept="video/*"
              onChange={handleSessionFileChange}
              className="block w-full bg-[#111] border border-[#444] rounded-md text-sm text-[#fff] px-3 py-2 file:mr-3 file:py-1 file:px-3 file:rounded file:border-0 file:bg-[#333] file:text-white file:cursor-pointer"
            />
          </div>
        </div>
      )}

      {/* Full Session: queue for background analysis, then navigate to it. */}
      {sessionFile && (
        <SessionUploader
          file={sessionFile}
          onCreated={onSessionCreated}
          onCancel={handleReset}
        />
      )}

      {/* Individual Putts: summary + per-video cards (synchronous). */}
      {videos.length > 0 && (
        <>
          <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 mb-6">
            <div className="flex items-center justify-between mb-3">
              <h2 className="text-xs font-semibold uppercase tracking-widest text-[#aaa]">
                Session Averages
              </h2>
              <span className="text-xs text-[#888] flex items-center gap-2">
                {anyProcessing && (
                  <span className="w-3.5 h-3.5 border-2 border-[#22c55e] border-t-transparent rounded-full animate-spin" />
                )}
                {anyProcessing ? "Analyzing… " : ""}
                {`${analyzedCount} of ${videos.length} analyzed`}
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
                    : biasSide === "center"
                      ? "no directional bias"
                      : `${biasLabel} bias`}
                </p>
              </div>
              <div>
                <div className="offset-value">
                  {speedDispersion == null ? "—" : `± ${speedDispersion.toFixed(2)}`} m/s
                </div>
                <p className="text-sm text-[#aaa] -mt-1">
                  speed dispersion (consistency)
                </p>
              </div>
            </div>
            <div className="flex gap-6 mt-4 pt-4 border-t border-[#333] text-sm">
              <span className="text-[#aaa]">
                Pushes <span className="text-white font-semibold">{pushes}</span>
              </span>
              <span className="text-[#aaa]">
                Pulls <span className="text-white font-semibold">{pulls}</span>
              </span>
            </div>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            {videos.map((v, i) => (
              <VideoCard
                key={v.id}
                id={v.id}
                index={i}
                file={v.file}
                onResult={handleResult}
                onBusyChange={handleBusy}
              />
            ))}
          </div>
        </>
      )}
    </>
  );
}
