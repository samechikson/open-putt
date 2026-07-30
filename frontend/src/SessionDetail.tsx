import { useEffect, useRef, useState } from "react";
import {
  fetchSession,
  fetchPutts,
  fetchSessionVideoUrl,
  fetchPuttFrameUrl,
  fetchPuttVideoUrl,
  deleteSession,
  reanalyzeSession,
  updateSession,
  subscribeToSession,
  breakTypeLabel,
  BREAK_TYPES,
  type SessionRow,
  type PuttRow,
} from "./sessions";
import { fetchPutters, type PutterRow } from "./putters";
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
  const [putters, setPutters] = useState<PutterRow[]>([]);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  // Bumped after a re-analysis so the load-and-subscribe effect re-runs: the
  // original subscription stops polling once a session is terminal, so a fresh
  // one is needed to watch the re-run through to done/error.
  const [reloadKey, setReloadKey] = useState(0);
  const videoRef = useRef<HTMLVideoElement>(null);
  // When playing a single putt, pause once its segment ends.
  const puttEndRef = useRef<number | null>(null);

  // The putt whose gate-crossing still is shown in the side panel, and the
  // fetched still itself (an object URL we must revoke when it changes).
  const [selectedPutt, setSelectedPutt] = useState<PuttRow | null>(null);
  const [frameUrl, setFrameUrl] = useState<string | null>(null);
  const [frameLoading, setFrameLoading] = useState(false);
  const [frameError, setFrameError] = useState<string | null>(null);
  const frameUrlRef = useRef<string | null>(null);
  // Per-putt review clip (hardware-gate putts). A signed URL played directly, so
  // no object URL to revoke — unlike the crossing still.
  const [puttVideoUrl, setPuttVideoUrl] = useState<string | null>(null);
  const [puttVideoLoading, setPuttVideoLoading] = useState(false);
  // Bumped on every selection so a slow in-flight fetch for a previous putt
  // can't overwrite the current one.
  const frameReqRef = useRef(0);

  const setFrame = (url: string | null) => {
    if (frameUrlRef.current) URL.revokeObjectURL(frameUrlRef.current);
    frameUrlRef.current = url;
    setFrameUrl(url);
  };

  // Select a putt and load its gate-crossing still. Legacy putts (no stored
  // crossing frame) get no still — just the selection, no fetch, no error.
  const selectPutt = (p: PuttRow) => {
    setSelectedPutt(p);
    const req = ++frameReqRef.current;
    setFrame(null);
    setFrameError(null);
    setPuttVideoUrl(null);

    // Hardware-gate putts carry their own review clip; prefer it over a still.
    if (p.video_path != null) {
      setFrameLoading(false);
      setPuttVideoLoading(true);
      fetchPuttVideoUrl(sessionId, p.putt_index)
        .then((url) => {
          if (req !== frameReqRef.current) return; // superseded
          setPuttVideoUrl(url);
          setPuttVideoLoading(false);
        })
        .catch(() => {
          if (req !== frameReqRef.current) return;
          setPuttVideoLoading(false);
        });
      return;
    }

    setPuttVideoLoading(false);
    if (p.crossing_frame == null) {
      setFrameLoading(false);
      return;
    }
    setFrameLoading(true);
    fetchPuttFrameUrl(sessionId, p.putt_index)
      .then((url) => {
        if (req !== frameReqRef.current) {
          URL.revokeObjectURL(url); // superseded by a later selection
          return;
        }
        setFrame(url);
        setFrameLoading(false);
      })
      .catch((e: unknown) => {
        if (req !== frameReqRef.current) return;
        setFrameError(e instanceof Error ? e.message : "Could not load frame");
        setFrameLoading(false);
      });
  };

  // Release the last object URL on unmount.
  useEffect(
    () => () => {
      if (frameUrlRef.current) URL.revokeObjectURL(frameUrlRef.current);
    },
    [],
  );

  // Jump the player to a putt and play just its segment.
  const playPutt = (p: PuttRow) => {
    const video = videoRef.current;
    if (!video || p.start_s == null) return;
    puttEndRef.current = p.end_s ?? null;
    video.currentTime = p.start_s;
    void video.play();
  };

  // Clicking a putt row: show its crossing still and jump the video to it.
  const handlePuttClick = (p: PuttRow) => {
    selectPutt(p);
    playPutt(p);
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
  }, [sessionId, reloadKey]);

  // The user's putters, for tagging this session (and resolving its putter name).
  useEffect(() => {
    let cancelled = false;
    fetchPutters()
      .then((rows) => {
        if (!cancelled) setPutters(rows);
      })
      .catch(() => {
        /* putter tagging is optional; the rest of the view still works */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const activePutter = putters.find((p) => p.is_active) ?? null;
  const sessionPutter =
    putters.find((p) => p.id === session?.putter_id) ?? null;

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

  // The hardware gate stores the three per-sensor offsets behind each putt's
  // average; video-pipeline putts have none. Only show the column when present.
  const hasSensors = putts.some((p) => p.sensor_offsets_mm != null);

  const fmt = (n: number | null, digits = 1) =>
    n == null ? "—" : n.toFixed(digits);

  // Metadata editor: distance (feet), break type, and putter. `editing` holds
  // the draft values, or null when not editing.
  const [editing, setEditing] = useState<{
    length: string;
    breakType: string;
    putterId: string;
  } | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const startEditing = () => {
    setSaveError(null);
    setEditing({
      length: session?.length_feet == null ? "" : String(session.length_feet),
      breakType: session?.break_type ?? "",
      // Default to the session's putter, or the active putter when un-tagged.
      putterId: session?.putter_id ?? activePutter?.id ?? "",
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
        putter_id: editing.putterId === "" ? null : editing.putterId,
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

  const [reanalyzing, setReanalyzing] = useState(false);
  const handleReanalyze = async () => {
    // A 'done' session has results this will replace; confirm before discarding.
    if (
      status === "done" &&
      !window.confirm(
        "Re-analyze this session? Its current putts will be replaced by the new results.",
      )
    )
      return;
    setReanalyzing(true);
    setLoadError(null);
    try {
      await reanalyzeSession(sessionId);
      // Reflect the reset immediately, then re-subscribe to watch it complete.
      setPutts([]);
      setSelectedPutt(null);
      setFrame(null);
      setFrameError(null);
      setSession((prev) =>
        prev ? { ...prev, status: "queued", error: null } : prev,
      );
      setReloadKey((k) => k + 1);
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : "Could not start re-analysis");
    } finally {
      setReanalyzing(false);
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
          {session && session.video_path && !pending && (
            <button
              type="button"
              onClick={handleReanalyze}
              disabled={reanalyzing}
              className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] disabled:opacity-50 rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
            >
              {reanalyzing ? "Starting…" : "Re-analyze"}
            </button>
          )}
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
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
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
              <div>
                <div className="text-white font-semibold truncate">
                  {sessionPutter?.name ?? "—"}
                </div>
                <p className="text-sm text-[#aaa]">putter</p>
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
                <label className="flex flex-col gap-1">
                  <span className="text-sm text-[#aaa]">Putter</span>
                  <select
                    value={editing.putterId}
                    onChange={(e) =>
                      setEditing((d) =>
                        d ? { ...d, putterId: e.target.value } : d,
                      )
                    }
                    className="bg-[#222] border border-[#333] focus:border-[#22c55e] rounded-lg text-sm text-white px-3 py-2 cursor-pointer focus:outline-none"
                  >
                    <option value="">—</option>
                    {putters.map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.name}
                        {p.is_active ? " (active)" : ""}
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
            <div className="flex flex-col lg:flex-row gap-6">
              <div className="flex-1 min-w-0 bg-[#1a1a1a] border border-[#333] rounded-xl overflow-x-auto">
                <table className="w-full text-sm min-w-[20rem]">
                  <thead>
                    <tr className="text-left text-xs uppercase tracking-widest text-[#888] border-b border-[#333]">
                      <th className="px-4 py-3 font-semibold">#</th>
                      <th className="px-4 py-3 font-semibold">Offset</th>
                      <th className="px-4 py-3 font-semibold">Direction</th>
                      <th className="px-4 py-3 font-semibold">Speed</th>
                      {hasSensors && (
                        <th
                          className="px-4 py-3 font-semibold"
                          title="Per-sensor offset (golfer's view; + = right)"
                        >
                          Sensors (mm)
                        </th>
                      )}
                    </tr>
                  </thead>
                  <tbody>
                    {putts.map((p) => {
                      const selected = p.putt_index === selectedPutt?.putt_index;
                      return (
                        <tr
                          key={p.putt_index}
                          onClick={() => handlePuttClick(p)}
                          className={`border-b border-[#262626] last:border-0 cursor-pointer hover:bg-[#222] ${
                            selected ? "bg-[#222]" : ""
                          }`}
                        >
                          <td className="px-4 py-3 text-[#aaa]">
                            {(videoUrl || p.video_path) && (
                              <span className="text-[#22c55e] mr-1">▶</span>
                            )}
                            {p.putt_index + 1}
                          </td>
                          <td className="px-4 py-3 text-white">
                            {p.offset_mm == null
                              ? "—"
                              : `${Math.abs(p.offset_mm).toFixed(1)} mm`}
                          </td>
                          <td className="px-4 py-3 text-[#aaa] capitalize">
                            {/* Report the golfer's left/right, not the raw
                                image-space `direction` (clips are filmed face-on,
                                which mirrors it). Matches the session bias above. */}
                            {p.offset_mm == null ? "—" : golferSide(p.offset_mm)}
                          </td>
                          <td className="px-4 py-3 text-[#aaa]">
                            {p.speed_mps == null
                              ? "—"
                              : `${p.speed_mps.toFixed(2)} m/s`}
                          </td>
                          {hasSensors && (
                            <td className="px-4 py-3 text-[#888] font-mono text-xs whitespace-nowrap">
                              {p.sensor_offsets_mm == null
                                ? "—"
                                : p.sensor_offsets_mm
                                    .map((v) => {
                                      if (v == null) return "—";
                                      // Golfer's view: undo the face-on mirror, as
                                      // the Offset/Direction columns do.
                                      const g = -v;
                                      const sign = g > 0 ? "+" : g < 0 ? "−" : "";
                                      return sign + Math.abs(g).toFixed(1);
                                    })
                                    .join(" / ")}
                            </td>
                          )}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>

              <div className="lg:w-80 shrink-0 bg-[#1a1a1a] border border-[#333] rounded-xl p-4">
                <h3 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-3">
                  {selectedPutt && (puttVideoUrl || puttVideoLoading)
                    ? "Review clip"
                    : "Crossing frame"}
                </h3>
                {selectedPutt == null ? (
                  <p className="text-sm text-[#666]">
                    Select a putt to see its footage.
                  </p>
                ) : puttVideoLoading || frameLoading ? (
                  <div className="flex items-center gap-2 text-sm text-[#888]">
                    <span className="w-3.5 h-3.5 border-2 border-[#22c55e] border-t-transparent rounded-full animate-spin" />
                    Loading…
                  </div>
                ) : puttVideoUrl ? (
                  <div>
                    <video
                      src={puttVideoUrl}
                      controls
                      playsInline
                      className="w-full rounded-lg bg-black"
                    />
                    <p className="text-xs text-[#666] mt-2">
                      Putt {selectedPutt.putt_index + 1} · last 2s before the gate
                    </p>
                  </div>
                ) : frameUrl ? (
                  <div>
                    <img
                      src={frameUrl}
                      alt={`Putt ${selectedPutt.putt_index + 1} crossing the gate`}
                      className="w-full rounded-lg bg-black"
                    />
                    <p className="text-xs text-[#666] mt-2">
                      Putt {selectedPutt.putt_index + 1} · at the gate line
                    </p>
                  </div>
                ) : frameError ? (
                  <p className="text-sm text-[#f87171]">{frameError}</p>
                ) : (
                  // Putt with no stored footage (legacy still or no clip yet).
                  <p className="text-sm text-[#666]">
                    No footage for this putt.
                  </p>
                )}
              </div>
            </div>
          )}
        </>
      )}
    </>
  );
}
