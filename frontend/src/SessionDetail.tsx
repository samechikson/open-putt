import { useEffect, useRef, useState } from "react";
import {
  fetchSession,
  fetchPutts,
  fetchSessionVideoUrl,
  deleteSession,
  updateSession,
  subscribeToSession,
  breakTypeLabel,
  BREAK_TYPES,
  type SessionRow,
  type PuttRow,
} from "./sessions";
import { biasWord, golferSide } from "./analysis";
import { mean, stdev } from "./stats";

interface SessionDetailProps {
  sessionId: string;
  onBack: () => void;
}

export default function SessionDetail({
  sessionId,
  onBack,
}: SessionDetailProps) {
  const [session, setSession] = useState<SessionRow | null | undefined>(
    undefined,
  );
  const [putts, setPutts] = useState<PuttRow[]>([]);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  // When playing a single putt, pause once its segment ends.
  const puttEndRef = useRef<number | null>(null);

  // Jump the player to a putt and play just its segment.
  const playPutt = (p: PuttRow) => {
    const video = videoRef.current;
    if (!video || p.start_s == null) return;
    puttEndRef.current = p.end_s ?? null;
    video.currentTime = p.start_s;
    void video.play();
  };

  const handleTimeUpdate = () => {
    const video = videoRef.current;
    if (!video || puttEndRef.current == null) return;
    if (video.currentTime >= puttEndRef.current) {
      video.pause();
      puttEndRef.current = null;
    }
  };

  useEffect(() => {
    let cancelled = false;

    // When a session reaches 'done', pull its putts in.
    const loadPutts = () => {
      fetchPutts(sessionId)
        .then((rows) => {
          if (!cancelled) setPutts(rows);
        })
        .catch(() => {
          /* putts are secondary; the status drives the UI */
        });
    };

    // Any session with a retained video (done, or errored after retention):
    // fetch a signed playback URL so the clip can be reviewed.
    const loadVideo = (row: SessionRow) => {
      if (!row.video_path) return;
      fetchSessionVideoUrl(sessionId)
        .then((url) => {
          if (!cancelled) setVideoUrl(url);
        })
        .catch(() => {
          /* playback is optional; stats still render */
        });
    };

    fetchSession(sessionId)
      .then((row) => {
        if (cancelled || !row) {
          if (!cancelled) setSession(row);
          return;
        }
        setSession(row);
        if (row.status === "done") {
          loadPutts();
        }
        loadVideo(row);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setLoadError(e instanceof Error ? e.message : "Failed to load session");
        setSession(null);
      });

    // Watch for background-analysis transitions (queued/processing → done/error).
    const unsubscribe = subscribeToSession(sessionId, (row) => {
      if (cancelled) return;
      setSession(row);
      if (row.status === "done") {
        loadPutts();
      }
      loadVideo(row);
    });

    return () => {
      cancelled = true;
      unsubscribe();
    };
  }, [sessionId]);

  const status = session?.status;
  const pending = status === "queued" || status === "processing";

  const offsets = putts
    .map((p) => p.offset_mm)
    .filter((o): o is number => o != null);
  const speeds = putts
    .map((p) => p.speed_mps)
    .filter((s): s is number => s != null);
  const avgAbsOffset = mean(offsets.map(Math.abs));
  const bias = mean(offsets);
  const speedDispersion = stdev(speeds);
  const biasSide = bias == null ? "center" : golferSide(bias);

  const fmt = (n: number | null, digits = 1) =>
    n == null ? "—" : n.toFixed(digits);

  // Metadata editor: distance (feet) and break type. `editing` holds the draft
  // values, or null when not editing.
  const [editing, setEditing] = useState<{
    length: string;
    breakType: string;
  } | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const startEditing = () => {
    setSaveError(null);
    setEditing({
      length: session?.length_feet == null ? "" : String(session.length_feet),
      breakType: session?.break_type ?? "",
    });
  };

  const handleSaveMetadata = async () => {
    if (!editing) return;
    const trimmed = editing.length.trim();
    const length = trimmed === "" ? null : Number(trimmed);
    if (length != null && (!Number.isFinite(length) || length < 0)) {
      setSaveError("Distance must be a non-negative number.");
      return;
    }
    setSaving(true);
    setSaveError(null);
    try {
      const metadata = {
        length_feet: length == null ? null : Math.round(length),
        break_type: editing.breakType === "" ? null : editing.breakType,
      };
      await updateSession(sessionId, metadata);
      setSession((prev) => (prev ? { ...prev, ...metadata } : prev));
      setEditing(null);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : "Could not update session");
    } finally {
      setSaving(false);
    }
  };

  const [deleting, setDeleting] = useState(false);
  const handleDelete = async () => {
    if (
      !window.confirm(
        "Delete this session, its putts and video? This can't be undone.",
      )
    )
      return;
    setDeleting(true);
    try {
      await deleteSession(sessionId);
      onBack();
    } catch (e) {
      setDeleting(false);
      setLoadError(e instanceof Error ? e.message : "Could not delete session");
    }
  };

  return (
    <>
      <div className="flex items-center justify-between gap-4 mb-6">
        <h2 className="text-xl font-bold text-white truncate">
          {session?.file_name ?? "Session"}
        </h2>
        <div className="flex items-center gap-2 shrink-0">
          {session && (
            <button
              type="button"
              onClick={handleDelete}
              disabled={deleting}
              className="px-4 py-2 bg-[#2a1a1a] border border-[#4a2a2a] hover:bg-[#3a2020] disabled:opacity-50 rounded-lg text-sm text-[#f87171] font-medium transition-all cursor-pointer"
            >
              {deleting ? "Deleting…" : "Delete"}
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

      {session === undefined && (
        <div className="flex items-center gap-2 text-sm text-[#888]">
          <span className="w-3.5 h-3.5 border-2 border-[#22c55e] border-t-transparent rounded-full animate-spin" />
          Loading…
        </div>
      )}

      {session === null && (
        <div className="bg-[#1a1a1a] border border-[#3a2020] rounded-xl p-5 text-sm text-[#f87171]">
          {loadError ?? "Failed to load session."}
        </div>
      )}

      {session && (
        <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 mb-6">
          <div className="flex items-center justify-between gap-4 mb-3">
            <h3 className="text-xs font-semibold uppercase tracking-widest text-[#aaa]">
              Putt Details
            </h3>
            {editing == null && (
              <button
                type="button"
                onClick={startEditing}
                className="px-3 py-1.5 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-xs text-white font-medium transition-all cursor-pointer"
              >
                Edit
              </button>
            )}
          </div>

          {editing == null ? (
            <div className="grid grid-cols-2 gap-4">
              <div>
                <div className="text-white font-semibold">
                  {session.length_feet == null
                    ? "—"
                    : `${session.length_feet} ft`}
                </div>
                <p className="text-sm text-[#aaa]">distance</p>
              </div>
              <div>
                <div className="text-white font-semibold">
                  {breakTypeLabel(session.break_type) ?? "—"}
                </div>
                <p className="text-sm text-[#aaa]">putt type</p>
              </div>
            </div>
          ) : (
            <div className="flex flex-col gap-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <label className="flex flex-col gap-1">
                  <span className="text-sm text-[#aaa]">Distance (feet)</span>
                  <input
                    type="number"
                    min={0}
                    inputMode="numeric"
                    value={editing.length}
                    onChange={(e) =>
                      setEditing((d) =>
                        d ? { ...d, length: e.target.value } : d,
                      )
                    }
                    placeholder="—"
                    className="bg-[#222] border border-[#333] focus:border-[#22c55e] rounded-lg text-sm text-white px-3 py-2 focus:outline-none"
                  />
                </label>
                <label className="flex flex-col gap-1">
                  <span className="text-sm text-[#aaa]">Putt type</span>
                  <select
                    value={editing.breakType}
                    onChange={(e) =>
                      setEditing((d) =>
                        d ? { ...d, breakType: e.target.value } : d,
                      )
                    }
                    className="bg-[#222] border border-[#333] focus:border-[#22c55e] rounded-lg text-sm text-white px-3 py-2 cursor-pointer focus:outline-none"
                  >
                    <option value="">—</option>
                    {BREAK_TYPES.map((b) => (
                      <option key={b.value} value={b.value}>
                        {b.label}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
              {saveError && (
                <p className="text-sm text-[#f87171]">{saveError}</p>
              )}
              <div className="flex items-center gap-2">
                <button
                  type="button"
                  onClick={handleSaveMetadata}
                  disabled={saving}
                  className="px-4 py-2 bg-[#22c55e] hover:bg-[#16a34a] disabled:opacity-50 rounded-lg text-sm text-black font-semibold transition-all cursor-pointer"
                >
                  {saving ? "Saving…" : "Save"}
                </button>
                <button
                  type="button"
                  onClick={() => setEditing(null)}
                  disabled={saving}
                  className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] disabled:opacity-50 rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
                >
                  Cancel
                </button>
              </div>
            </div>
          )}
        </div>
      )}

      {pending && (
        <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-8 text-center">
          <div className="flex items-center justify-center gap-2 text-[#aaa]">
            <span className="w-4 h-4 border-2 border-[#22c55e] border-t-transparent rounded-full animate-spin" />
            {status === "queued"
              ? "Queued for analysis…"
              : "Analyzing your putts…"}
          </div>
          <p className="text-xs text-[#666] mt-2">
            This can take a few minutes for a long clip. You can leave this page;
            it'll keep processing.
          </p>
        </div>
      )}

      {status === "error" && (
        <>
          <div className="bg-[#1a1a1a] border border-[#3a2020] rounded-xl p-5 text-sm text-[#f87171] mb-6">
            {session?.error ?? "Analysis failed."}
          </div>
          {videoUrl && (
            <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-3">
              <video
                src={videoUrl}
                controls
                playsInline
                className="w-full max-h-[28rem] rounded-lg bg-black"
              />
              <p className="text-xs text-[#666] mt-2 px-1">
                Your recording, kept so you can review what happened.
              </p>
            </div>
          )}
        </>
      )}

      {status === "done" && (
        <>
          {videoUrl && (
            <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-3 mb-6">
              <video
                ref={videoRef}
                src={videoUrl}
                controls
                playsInline
                onTimeUpdate={handleTimeUpdate}
                className="w-full max-h-[28rem] rounded-lg bg-black"
              />
              <p className="text-xs text-[#666] mt-2 px-1">
                Tap a putt below to jump to it.
              </p>
            </div>
          )}

          <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 mb-6">
            <h3 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-3">
              Session Averages · {putts.length} putt
              {putts.length === 1 ? "" : "s"}
            </h3>
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
                      : `${biasWord(biasSide)} bias`}
                </p>
              </div>
              <div>
                <div className="offset-value">
                  {speedDispersion == null
                    ? "—"
                    : `± ${speedDispersion.toFixed(2)}`}{" "}
                  m/s
                </div>
                <p className="text-sm text-[#aaa] -mt-1">
                  speed dispersion (consistency)
                </p>
              </div>
            </div>
          </div>

          {putts.length > 0 && (
            <div className="bg-[#1a1a1a] border border-[#333] rounded-xl overflow-x-auto">
              <table className="w-full text-sm min-w-[20rem]">
                <thead>
                  <tr className="text-left text-xs uppercase tracking-widest text-[#888] border-b border-[#333]">
                    <th className="px-4 py-3 font-semibold">#</th>
                    <th className="px-4 py-3 font-semibold">Offset</th>
                    <th className="px-4 py-3 font-semibold">Direction</th>
                    <th className="px-4 py-3 font-semibold">Speed</th>
                  </tr>
                </thead>
                <tbody>
                  {putts.map((p) => (
                    <tr
                      key={p.putt_index}
                      onClick={videoUrl ? () => playPutt(p) : undefined}
                      className={`border-b border-[#262626] last:border-0 ${
                        videoUrl ? "cursor-pointer hover:bg-[#222]" : ""
                      }`}
                    >
                      <td className="px-4 py-3 text-[#aaa]">
                        {videoUrl && <span className="text-[#22c55e] mr-1">▶</span>}
                        {p.putt_index + 1}
                      </td>
                      <td className="px-4 py-3 text-white">
                        {p.offset_mm == null
                          ? "—"
                          : `${Math.abs(p.offset_mm).toFixed(1)} mm`}
                      </td>
                      <td className="px-4 py-3 text-[#aaa] capitalize">
                        {p.direction ?? "—"}
                      </td>
                      <td className="px-4 py-3 text-[#aaa]">
                        {p.speed_mps == null
                          ? "—"
                          : `${p.speed_mps.toFixed(2)} m/s`}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </>
  );
}
