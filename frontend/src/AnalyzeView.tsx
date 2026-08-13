import { useState, useCallback } from "react";
import VideoCard from "./VideoCard";
import SessionUploader from "./SessionUploader";
import { biasWord, golferSide, type AnalysisResult } from "./analysis";
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

// The dashed drop-zone shared by the two upload paths. It's a label wrapping a
// hidden file input, so clicking anywhere in the zone opens the picker.
function DropZone({
  prompt,
  multiple,
  onChange,
}: {
  prompt: string;
  multiple?: boolean;
  onChange: (e: React.ChangeEvent<HTMLInputElement>) => void;
}) {
  return (
    <label
      style={{
        border: "2px dashed var(--color-neutral-400)",
        borderRadius: "var(--radius-lg)",
        padding: 28,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 10,
        textAlign: "center",
        cursor: "pointer",
      }}
    >
      <svg
        width="28"
        height="28"
        viewBox="0 0 24 24"
        fill="none"
        stroke="var(--color-accent-600)"
        strokeWidth="2.75"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M12 3v12" />
        <path d="m7 8 5-5 5 5" />
        <path d="M5 21h14" />
      </svg>
      <div style={{ fontSize: 13, color: "var(--color-neutral-700)" }}>
        {prompt}
      </div>
      <span
        className="btn btn-secondary"
        style={{ padding: "8px 16px", fontSize: 13 }}
      >
        Browse files
      </span>
      <input
        type="file"
        accept="video/*"
        multiple={multiple}
        onChange={onChange}
        style={{
          position: "absolute",
          width: 1,
          height: 1,
          padding: 0,
          margin: -1,
          overflow: "hidden",
          clip: "rect(0 0 0 0)",
          border: 0,
        }}
      />
    </label>
  );
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
    if (files.length === 0) return;
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
      <div
        style={{
          display: "flex",
          alignItems: "flex-start",
          justifyContent: "space-between",
          gap: 16,
          marginBottom: 24,
          flexWrap: "wrap",
        }}
      >
        <div>
          <div
            style={{
              fontFamily: "var(--font-heading)",
              fontSize: 24,
              marginBottom: 4,
            }}
          >
            New Session
          </div>
          <div style={{ fontSize: 14, color: "var(--color-neutral-700)" }}>
            Upload one clip per putt, or a single video of the whole session —
            analysis runs automatically
          </div>
        </div>
        <div style={{ display: "flex", gap: 10, flexShrink: 0 }}>
          {haveUploads && (
            <button type="button" onClick={handleReset} className="btn btn-ghost">
              Clear
            </button>
          )}
          <button type="button" onClick={onBack} className="btn btn-secondary">
            ← Sessions
          </button>
        </div>
      </div>

      {/* Upload: one clip per putt (left) or one multi-putt video (right) */}
      {!haveUploads && (
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))",
            gap: 20,
            marginBottom: 28,
          }}
        >
          <div className="card elev-sm">
            <div className="kicker" style={{ marginBottom: 4 }}>
              Individual Putts
            </div>
            <div
              style={{
                fontSize: 13,
                color: "var(--color-neutral-600)",
                marginBottom: 16,
              }}
            >
              One video per putt, up to {MAX_VIDEOS}
            </div>
            <DropZone
              prompt="Drag clips here, or"
              multiple
              onChange={handleFileChange}
            />
            {overflowNote && (
              <p
                style={{
                  fontSize: 12,
                  color: "var(--color-accent-800)",
                  marginTop: 8,
                }}
              >
                Only the first {MAX_VIDEOS} videos are analyzed.
              </p>
            )}
          </div>
          <div className="card elev-sm">
            <div className="kicker" style={{ marginBottom: 4 }}>
              Full Session
            </div>
            <div
              style={{
                fontSize: 13,
                color: "var(--color-neutral-600)",
                marginBottom: 16,
              }}
            >
              One video with several putts — analyzed in the background
            </div>
            <DropZone
              prompt="Drag a video here, or"
              onChange={handleSessionFileChange}
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
          <div className="card elev-sm" style={{ marginBottom: 24 }}>
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                marginBottom: 16,
              }}
            >
              <span className="kicker">Session Averages</span>
              <span
                style={{
                  fontSize: 12,
                  color: "var(--color-neutral-600)",
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                }}
              >
                {anyProcessing && <span className="spinner" />}
                {anyProcessing ? "Analyzing… " : ""}
                {`${analyzedCount} of ${videos.length} analyzed`}
              </span>
            </div>
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(3, 1fr)",
                gap: 20,
              }}
            >
              <div>
                <div className="stat" style={{ fontSize: 28 }}>
                  {fmt(avgAbsOffset)} mm
                </div>
                <div className="stat-sub">avg offset (accuracy)</div>
              </div>
              <div>
                <div className="stat" style={{ fontSize: 28 }}>
                  {bias == null ? "—" : `${Math.abs(bias).toFixed(1)} mm`}
                </div>
                <div className="stat-sub">
                  {bias == null
                    ? "directional bias"
                    : biasSide === "center"
                      ? "no directional bias"
                      : `${biasLabel} bias`}
                </div>
              </div>
              <div>
                <div className="stat" style={{ fontSize: 28 }}>
                  {speedDispersion == null
                    ? "—"
                    : `± ${speedDispersion.toFixed(2)}`}{" "}
                  m/s
                </div>
                <div className="stat-sub">speed dispersion (consistency)</div>
              </div>
            </div>
            <div
              style={{
                display: "flex",
                gap: 24,
                marginTop: 16,
                paddingTop: 16,
                borderTop: "1px solid var(--color-divider)",
                fontSize: 14,
              }}
            >
              <span style={{ color: "var(--color-neutral-700)" }}>
                Pushes{" "}
                <span style={{ fontWeight: 700, color: "var(--color-text)" }}>
                  {pushes}
                </span>
              </span>
              <span style={{ color: "var(--color-neutral-700)" }}>
                Pulls{" "}
                <span style={{ fontWeight: 700, color: "var(--color-text)" }}>
                  {pulls}
                </span>
              </span>
            </div>
          </div>

          <div
            style={{
              display: "grid",
              gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))",
              gap: 20,
            }}
          >
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
