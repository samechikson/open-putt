import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  fetchSession,
  fetchPutts,
  fetchSessionVideoUrl,
  fetchPuttFrameUrl,
  deleteSession,
  deletePutt,
  reanalyzeSession,
  updateSession,
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

// How often a live session is polled for new putts / status, and how long after
// creation a session still counts as live.
const POLL_MS = 20_000;
const RECENT_MS = 10 * 60_000;

// Whether a session is worth polling. A hardware-gate session is 'done' from its
// first putt but keeps gaining putts as the player putts, so recency (not status)
// is what marks it live; a video analysis is also live while it's still running.
// Stale sessions are fetched once and left alone.
function isSessionLive(session: SessionRow | null | undefined): boolean {
  if (!session) return false;
  if (session.status === "queued" || session.status === "processing") return true;
  return Date.now() - new Date(session.created_at).getTime() < RECENT_MS;
}

export default function SessionDetail({
  sessionId,
  onBack,
}: SessionDetailProps) {
  const queryClient = useQueryClient();

  // The session, polled every 20s while it's live (new gate putts land, or a
  // video analysis finishes) and fetched once otherwise. `refetchInterval` is a
  // function so it re-evaluates against the latest data and stops on its own.
  const sessionQuery = useQuery({
    queryKey: ["session", sessionId],
    queryFn: () => fetchSession(sessionId),
    refetchInterval: (query) =>
      isSessionLive(query.state.data) ? POLL_MS : false,
  });
  const session = sessionQuery.data; // SessionRow | null | undefined

  // The session's putts, polled on the same cadence so new ones appear on their
  // own during a live session; a stale session just fetches them once.
  const puttsQuery = useQuery({
    queryKey: ["putts", sessionId],
    queryFn: () => fetchPutts(sessionId),
    refetchInterval: isSessionLive(session) ? POLL_MS : false,
  });
  const putts = puttsQuery.data ?? [];

  const puttersQuery = useQuery({
    queryKey: ["putters"],
    queryFn: fetchPutters,
  });
  const putters: PutterRow[] = puttersQuery.data ?? [];

  // Signed playback URL for a session with a retained video (short-lived, so let
  // it go stale slowly). Gate sessions have no video, so this stays disabled.
  const videoQuery = useQuery({
    queryKey: ["sessionVideo", sessionId],
    queryFn: () => fetchSessionVideoUrl(sessionId),
    enabled: !!session?.video_path,
    staleTime: RECENT_MS,
  });
  const videoUrl = videoQuery.data ?? null;

  // Error from a re-analyze / delete action (session load errors render below).
  const [actionError, setActionError] = useState<string | null>(null);
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

  // The putt_index currently being deleted (disables its row's button), and any
  // error from the last delete attempt.
  const [deletingPutt, setDeletingPutt] = useState<number | null>(null);
  const [puttError, setPuttError] = useState<string | null>(null);

  // Delete a single putt (e.g. a mishit or a false gate trip). Drops it from the
  // table on success and clears the crossing still if it was the selected putt.
  const handleDeletePutt = async (p: PuttRow) => {
    if (
      !window.confirm(`Delete putt ${p.putt_index + 1}? This can't be undone.`)
    )
      return;
    setDeletingPutt(p.putt_index);
    setPuttError(null);
    try {
      await deletePutt(sessionId, p.putt_index);
      queryClient.setQueryData<PuttRow[]>(["putts", sessionId], (prev) =>
        (prev ?? []).filter((x) => x.putt_index !== p.putt_index),
      );
      if (selectedPutt?.putt_index === p.putt_index) {
        setSelectedPutt(null);
        setFrame(null);
        setFrameError(null);
      }
    } catch (e) {
      setPuttError(e instanceof Error ? e.message : "Could not delete putt");
    } finally {
      setDeletingPutt(null);
    }
  };

  const handleTimeUpdate = () => {
    const video = videoRef.current;
    if (!video || puttEndRef.current == null) return;
    if (video.currentTime >= puttEndRef.current) {
      video.pause();
      puttEndRef.current = null;
    }
  };

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
      queryClient.setQueryData<SessionRow | null>(["session", sessionId], (prev) =>
        prev ? { ...prev, ...metadata } : prev,
      );
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
    setActionError(null);
    try {
      await reanalyzeSession(sessionId);
      // Reflect the reset immediately: clearing putts and flipping to 'queued'
      // makes isSessionLive() true, so both queries resume polling until done.
      queryClient.setQueryData<PuttRow[]>(["putts", sessionId], []);
      setSelectedPutt(null);
      setFrame(null);
      setFrameError(null);
      queryClient.setQueryData<SessionRow | null>(["session", sessionId], (prev) =>
        prev ? { ...prev, status: "queued", error: null } : prev,
      );
      void queryClient.invalidateQueries({ queryKey: ["session", sessionId] });
    } catch (e) {
      setActionError(
        e instanceof Error ? e.message : "Could not start re-analysis",
      );
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
    setActionError(null);
    try {
      await deleteSession(sessionId);
      onBack();
    } catch (e) {
      setDeleting(false);
      setActionError(
        e instanceof Error ? e.message : "Could not delete session",
      );
    }
  };

  const errorCardStyle = {
    fontSize: 14,
    color: "var(--color-accent-800)",
  } as const;

  return (
    <>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 16,
          marginBottom: 24,
          flexWrap: "wrap",
        }}
      >
        <div
          style={{
            fontFamily: "var(--font-heading)",
            fontSize: 24,
            minWidth: 0,
            overflow: "hidden",
            textOverflow: "ellipsis",
          }}
        >
          {session?.file_name ?? "Session"}
        </div>
        <div style={{ display: "flex", gap: 10, flexShrink: 0 }}>
          {session && session.video_path && !pending && (
            <button
              type="button"
              onClick={handleReanalyze}
              disabled={reanalyzing}
              className="btn btn-secondary"
            >
              {reanalyzing ? "Starting…" : "Re-analyze"}
            </button>
          )}
          {session && (
            <button
              type="button"
              onClick={handleDelete}
              disabled={deleting}
              className="btn btn-secondary"
              style={{ color: "var(--color-accent-800)" }}
            >
              {deleting ? "Deleting…" : "Delete"}
            </button>
          )}
          <button type="button" onClick={onBack} className="btn btn-secondary">
            ← Sessions
          </button>
        </div>
      </div>

      {actionError && (
        <div
          className="card elev-sm"
          style={{ ...errorCardStyle, marginBottom: 24 }}
        >
          {actionError}
        </div>
      )}

      {sessionQuery.isPending && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            fontSize: 14,
            color: "var(--color-neutral-600)",
          }}
        >
          <span className="spinner" />
          Loading…
        </div>
      )}

      {(sessionQuery.isError || session === null) && (
        <div className="card elev-sm" style={errorCardStyle}>
          {sessionQuery.error instanceof Error
            ? sessionQuery.error.message
            : session === null
              ? "Session not found."
              : "Failed to load session."}
        </div>
      )}

      {session && (
        <div className="card elev-sm" style={{ marginBottom: 24 }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              marginBottom: 14,
            }}
          >
            <span className="kicker">Putt Details</span>
            {editing == null && (
              <button
                type="button"
                onClick={startEditing}
                className="btn btn-ghost"
                style={{ padding: "6px 14px", fontSize: 13 }}
              >
                Edit
              </button>
            )}
          </div>

          {editing == null ? (
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(3, 1fr)",
                gap: 20,
              }}
            >
              <div>
                <div style={{ fontWeight: 600 }}>
                  {session.length_feet == null
                    ? "—"
                    : `${session.length_feet} ft`}
                </div>
                <div style={{ fontSize: 13, color: "var(--color-neutral-600)" }}>
                  distance
                </div>
              </div>
              <div>
                <div style={{ fontWeight: 600 }}>
                  {breakTypeLabel(session.break_type) ?? "—"}
                </div>
                <div style={{ fontSize: 13, color: "var(--color-neutral-600)" }}>
                  putt type
                </div>
              </div>
              <div>
                <div
                  style={{
                    fontWeight: 600,
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  }}
                >
                  {sessionPutter?.name ?? "—"}
                </div>
                <div style={{ fontSize: 13, color: "var(--color-neutral-600)" }}>
                  putter
                </div>
              </div>
            </div>
          ) : (
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))",
                  gap: 16,
                }}
              >
                <div className="field">
                  <label>Distance (feet)</label>
                  <input
                    className="input"
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
                  />
                </div>
                <div className="field">
                  <label>Putt type</label>
                  <select
                    className="input"
                    value={editing.breakType}
                    onChange={(e) =>
                      setEditing((d) =>
                        d ? { ...d, breakType: e.target.value } : d,
                      )
                    }
                  >
                    <option value="">—</option>
                    {BREAK_TYPES.map((b) => (
                      <option key={b.value} value={b.value}>
                        {b.label}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="field">
                  <label>Putter</label>
                  <select
                    className="input"
                    value={editing.putterId}
                    onChange={(e) =>
                      setEditing((d) =>
                        d ? { ...d, putterId: e.target.value } : d,
                      )
                    }
                  >
                    <option value="">—</option>
                    {putters.map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.name}
                        {p.is_active ? " (active)" : ""}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
              {saveError && (
                <p style={{ margin: 0, ...errorCardStyle }}>{saveError}</p>
              )}
              <div style={{ display: "flex", gap: 10 }}>
                <button
                  type="button"
                  onClick={handleSaveMetadata}
                  disabled={saving}
                  className="btn btn-primary"
                >
                  {saving ? "Saving…" : "Save"}
                </button>
                <button
                  type="button"
                  onClick={() => setEditing(null)}
                  disabled={saving}
                  className="btn btn-ghost"
                >
                  Cancel
                </button>
              </div>
            </div>
          )}
        </div>
      )}

      {pending && (
        <div className="card elev-sm" style={{ padding: 56, textAlign: "center" }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 10,
              color: "var(--color-neutral-700)",
              fontSize: 15,
            }}
          >
            <span className="spinner" style={{ width: 18, height: 18 }} />
            {status === "queued"
              ? "Queued for analysis…"
              : "Analyzing your putts…"}
          </div>
          <div
            style={{
              fontSize: 13,
              color: "var(--color-neutral-500)",
              marginTop: 8,
            }}
          >
            This can take a few minutes for a long clip. You can leave this page;
            it'll keep processing.
          </div>
        </div>
      )}

      {status === "error" && (
        <>
          <div
            className="card elev-sm"
            style={{ ...errorCardStyle, marginBottom: 24 }}
          >
            {session?.error ?? "Analysis failed."}
          </div>
          {videoUrl && (
            <div className="card elev-sm">
              <video
                src={videoUrl}
                controls
                playsInline
                className="w-full"
                style={{
                  maxHeight: "28rem",
                  borderRadius: "var(--radius-md)",
                  background: "#000",
                }}
              />
              <p
                style={{
                  fontSize: 12,
                  color: "var(--color-neutral-600)",
                  margin: "8px 4px 0",
                }}
              >
                Your recording, kept so you can review what happened.
              </p>
            </div>
          )}
        </>
      )}

      {(status === "done" || putts.length > 0) && (
        <>
          {videoUrl && (
            <div className="card elev-sm" style={{ marginBottom: 24, padding: 12 }}>
              <video
                ref={videoRef}
                src={videoUrl}
                controls
                playsInline
                onTimeUpdate={handleTimeUpdate}
                className="w-full"
                style={{
                  maxHeight: "28rem",
                  borderRadius: "var(--radius-md)",
                  background: "#000",
                }}
              />
              <p
                style={{
                  fontSize: 12,
                  color: "var(--color-neutral-600)",
                  margin: "8px 4px 0",
                }}
              >
                Tap a putt below to jump to it.
              </p>
            </div>
          )}

          <div className="card elev-sm" style={{ marginBottom: 24 }}>
            <h3 className="kicker" style={{ marginBottom: 16 }}>
              Session Averages · {putts.length} putt
              {putts.length === 1 ? "" : "s"}
            </h3>
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
                      : `${biasWord(biasSide)} bias`}
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
          </div>

          {putts.length > 0 && (
            <div
              style={{
                display: "flex",
                gap: 24,
                alignItems: "flex-start",
                flexWrap: "wrap",
              }}
            >
              <div
                className="card elev-sm"
                style={{
                  flex: "1 1 700px",
                  padding: 0,
                  overflow: "hidden",
                  minWidth: 0,
                }}
              >
                <div style={{ overflowX: "auto" }}>
                  <table className="table" style={{ minWidth: "20rem" }}>
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Offset</th>
                        <th>Direction</th>
                        <th>Speed</th>
                        {hasSensors && (
                          <th title="Per-sensor offset (golfer's view; + = right)">
                            Sensors (mm)
                          </th>
                        )}
                        <th>
                          <span className="sr-only">Actions</span>
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {putts.map((p) => {
                        const selected =
                          p.putt_index === selectedPutt?.putt_index;
                        return (
                          <tr
                            key={p.putt_index}
                            onClick={() => handlePuttClick(p)}
                            style={{
                              cursor: "pointer",
                              background: selected
                                ? "color-mix(in srgb, var(--color-accent) 12%, transparent)"
                                : undefined,
                            }}
                          >
                            <td>
                              {videoUrl && (
                                <span
                                  style={{
                                    color: "var(--color-accent)",
                                    marginRight: 4,
                                  }}
                                >
                                  ▶
                                </span>
                              )}
                              {p.putt_index + 1}
                            </td>
                            <td>
                              {p.offset_mm == null
                                ? "—"
                                : `${Math.abs(p.offset_mm).toFixed(1)} mm`}
                            </td>
                            <td style={{ color: "var(--color-neutral-700)" }}>
                              {/* Report the golfer's left/right, not the raw
                                  image-space `direction` (clips are filmed
                                  face-on, which mirrors it). Matches the session
                                  bias above. */}
                              {p.offset_mm == null
                                ? "—"
                                : golferSide(p.offset_mm)}
                            </td>
                            <td style={{ color: "var(--color-neutral-700)" }}>
                              {p.speed_mps == null
                                ? "—"
                                : `${p.speed_mps.toFixed(2)} m/s`}
                            </td>
                            {hasSensors && (
                              <td
                                style={{
                                  fontFamily: "ui-monospace, monospace",
                                  fontSize: 12,
                                  whiteSpace: "nowrap",
                                  color: "var(--color-neutral-600)",
                                }}
                              >
                                {p.sensor_offsets_mm == null
                                  ? "—"
                                  : p.sensor_offsets_mm
                                      .map((v) => {
                                        if (v == null) return "—";
                                        // Golfer's view: undo the face-on
                                        // mirror, as Offset/Direction do.
                                        const g = -v;
                                        const sign =
                                          g > 0 ? "+" : g < 0 ? "−" : "";
                                        return sign + Math.abs(g).toFixed(1);
                                      })
                                      .join(" / ")}
                              </td>
                            )}
                            <td style={{ textAlign: "right" }}>
                              <button
                                type="button"
                                onClick={(e) => {
                                  // Don't let the row's select/play click fire.
                                  e.stopPropagation();
                                  void handleDeletePutt(p);
                                }}
                                disabled={deletingPutt === p.putt_index}
                                title="Delete this putt"
                                className="nav-link"
                                style={{
                                  color: "var(--color-accent-700)",
                                  fontSize: 13,
                                }}
                              >
                                {deletingPutt === p.putt_index
                                  ? "Deleting…"
                                  : "Delete"}
                              </button>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
                {puttError && (
                  <p
                    style={{
                      ...errorCardStyle,
                      padding: "9px 13px",
                      borderTop: "1px solid var(--color-divider)",
                      margin: 0,
                    }}
                  >
                    {puttError}
                  </p>
                )}
              </div>

              <div className="card elev-sm" style={{ flex: "1 1 300px" }}>
                <div className="kicker" style={{ marginBottom: 14 }}>
                  Crossing frame
                </div>
                {selectedPutt == null ? (
                  <p style={{ margin: 0, fontSize: 14, color: "var(--color-neutral-600)" }}>
                    Select a putt to see where it crossed the gate.
                  </p>
                ) : frameLoading ? (
                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 8,
                      fontSize: 14,
                      color: "var(--color-neutral-600)",
                    }}
                  >
                    <span className="spinner" />
                    Loading frame…
                  </div>
                ) : frameUrl ? (
                  <div>
                    <img
                      src={frameUrl}
                      alt={`Putt ${selectedPutt.putt_index + 1} crossing the gate`}
                      className="w-full"
                      style={{ borderRadius: "var(--radius-md)", background: "#000" }}
                    />
                    <p
                      style={{
                        fontSize: 12,
                        color: "var(--color-neutral-600)",
                        marginTop: 10,
                      }}
                    >
                      Putt {selectedPutt.putt_index + 1} · at the gate line
                    </p>
                  </div>
                ) : frameError ? (
                  <p style={{ margin: 0, ...errorCardStyle }}>{frameError}</p>
                ) : (
                  // Legacy putt with no stored crossing frame: show nothing.
                  <p style={{ margin: 0, fontSize: 14, color: "var(--color-neutral-600)" }}>
                    Select a putt to see where it crossed the gate.
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
