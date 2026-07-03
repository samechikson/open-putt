import { useState, useCallback } from "react";
import "./App.css";
import VideoCard from "./VideoCard";
import SessionCard from "./SessionCard";
import {
  biasWord,
  golferSide,
  type AnalysisResult,
  type SessionResult,
} from "./analysis";
import { useAuth } from "./AuthContext";

const MAX_VIDEOS = 5;

interface VideoItem {
  id: string;
  file: File;
}

function mean(nums: number[]): number | null {
  if (nums.length === 0) return null;
  return nums.reduce((a, b) => a + b, 0) / nums.length;
}

// Sample standard deviation — the spread of values around their mean. Needs at
// least two values; a single putt has no dispersion to speak of.
function stdev(nums: number[]): number | null {
  if (nums.length < 2) return null;
  const m = nums.reduce((a, b) => a + b, 0) / nums.length;
  const variance =
    nums.reduce((a, b) => a + (b - m) ** 2, 0) / (nums.length - 1);
  return Math.sqrt(variance);
}

function App() {
  const { user, signOut } = useAuth();
  const [videos, setVideos] = useState<VideoItem[]>([]);
  const [results, setResults] = useState<Record<string, AnalysisResult | null>>(
    {},
  );
  const [busy, setBusy] = useState<Record<string, boolean>>({});
  const [overflowNote, setOverflowNote] = useState(false);
  // Session mode: one video holding several putts, split up by the backend.
  // The two upload paths are alternatives, so picking one clears the other.
  const [session, setSession] = useState<{ id: string; file: File } | null>(
    null,
  );
  // undefined = pipeline not finished yet, null = it failed (like `results`).
  const [sessionResult, setSessionResult] = useState<
    SessionResult | null | undefined
  >(undefined);
  const [sessionBusy, setSessionBusy] = useState(false);

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
    setSession(null);
    setSessionResult(undefined);
    setSessionBusy(false);
    // Allow re-selecting the same files to re-trigger.
    e.target.value = "";
  };

  const handleSessionFileChange = (
    e: React.ChangeEvent<HTMLInputElement>,
  ) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setSession({ id: `${Date.now()}-${file.name}`, file });
    setSessionResult(undefined);
    setSessionBusy(false);
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

  const handleSessionResult = useCallback((result: SessionResult | null) => {
    setSessionResult(result);
  }, []);

  const handleSessionBusy = useCallback((b: boolean) => {
    setSessionBusy(b);
  }, []);

  const handleReset = useCallback(() => {
    setVideos([]);
    setResults({});
    setBusy({});
    setOverflowNote(false);
    setSession(null);
    setSessionResult(undefined);
    setSessionBusy(false);
  }, []);

  // Aggregate over putts that produced a usable offset — the per-video results
  // in single-putt mode, or the putts split out of the session video.
  const candidates: (AnalysisResult | null | undefined)[] = session
    ? (sessionResult?.putts ?? [])
    : videos.map((v) => results[v.id]);
  const valid = candidates.filter(
    (r): r is AnalysisResult => !!r && r.offset_mm !== null,
  );
  const offsets = valid.map((r) => r.offset_mm as number);
  const speeds = valid
    .map((r) => r.speed_mps)
    .filter((s): s is number => s != null);

  const avgAbsOffset = mean(offsets.map(Math.abs));
  const bias = mean(offsets); // raw image-space mean; golferSide flips it face-on
  // Spread of gate speeds across putts — how consistent the player's pace is.
  const speedDispersion = stdev(speeds);

  const biasSide = bias == null ? "center" : golferSide(bias);
  const biasLabel = biasWord(biasSide); // "push" (right) / "pull" (left)
  // Per-putt tallies: right of target = push, left = pull.
  const sides = offsets.map(golferSide);
  const pushes = sides.filter((s) => s === "right").length;
  const pulls = sides.filter((s) => s === "left").length;
  const analyzedCount = valid.length;
  // A video is still processing while its card reports busy, or before it has
  // reported any terminal result (undefined = pipeline not finished yet).
  const anyProcessing = session
    ? sessionBusy || sessionResult === undefined
    : videos.some((v) => busy[v.id] || results[v.id] === undefined);
  const haveUploads = videos.length > 0 || session !== null;

  const fmt = (n: number | null, digits = 1) =>
    n == null ? "—" : n.toFixed(digits);

  return (
    <div className="min-h-screen bg-[#0d0d0d] text-[#d0d0d0] px-4 py-8">
      <div className="max-w-6xl mx-auto">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
          <div>
            <h1 className="text-3xl font-bold text-white mb-1">
              Putting Gate Dashboard
            </h1>
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
                Upload New
              </button>
            )}
            {user && (
              <div className="flex items-center gap-3">
                <span className="text-xs text-[#888] hidden sm:inline">
                  {user.email}
                </span>
                <button
                  type="button"
                  onClick={signOut}
                  className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
                >
                  Sign out
                </button>
              </div>
            )}
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
              One video with several putts — split up automatically
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

        {/* Summary */}
        {haveUploads && (
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
                {session
                  ? `${analyzedCount} putt${analyzedCount === 1 ? "" : "s"} found`
                  : `${analyzedCount} of ${videos.length} analyzed`}
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
                onBusyChange={handleBusy}
              />
            ))}
          </div>
        )}

        {/* Session card */}
        {session && (
          <SessionCard
            key={session.id}
            file={session.file}
            onResult={handleSessionResult}
            onBusyChange={handleSessionBusy}
          />
        )}
      </div>
    </div>
  );
}

export default App;
