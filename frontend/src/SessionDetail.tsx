import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  fetchSession,
  fetchPutts,
  deleteSession,
  deletePutt,
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

// How often a live session is polled for new putts, and how long after creation
// a session still counts as live. A hardware-gate session keeps gaining putts as
// the player putts, so recency is what marks it live; stale sessions are fetched
// once and left alone.
const POLL_MS = 20_000;
const RECENT_MS = 10 * 60_000;

function isSessionLive(session: SessionRow | null | undefined): boolean {
  if (!session) return false;
  return Date.now() - new Date(session.created_at).getTime() < RECENT_MS;
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export default function SessionDetail({
  sessionId,
  onBack,
}: SessionDetailProps) {
  const queryClient = useQueryClient();

  // The session, polled every 20s while it's live (new gate putts land) and
  // fetched once otherwise. `refetchInterval` is a function so it re-evaluates
  // against the latest data and stops on its own.
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

  // Error from a delete action (session load errors render below).
  const [actionError, setActionError] = useState<string | null>(null);

  // The putt_index currently being deleted (disables its row's button), and any
  // error from the last delete attempt.
  const [deletingPutt, setDeletingPutt] = useState<number | null>(null);
  const [puttError, setPuttError] = useState<string | null>(null);

  // Delete a single putt (e.g. a mishit or a false gate trip). Drops it from the
  // table on success.
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
    } catch (e) {
      setPuttError(e instanceof Error ? e.message : "Could not delete putt");
    } finally {
      setDeletingPutt(null);
    }
  };

  const activePutter = putters.find((p) => p.is_active) ?? null;
  const sessionPutter =
    putters.find((p) => p.id === session?.putter_id) ?? null;

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

  // The hardware gate stores the per-sensor offsets behind each putt's average.
  // Only show the column when present.
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

  const [deleting, setDeleting] = useState(false);
  const handleDelete = async () => {
    if (
      !window.confirm("Delete this session and its putts? This can't be undone.")
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
          {session ? formatDate(session.created_at) : "Session"}
        </div>
        <div style={{ display: "flex", gap: 10, flexShrink: 0 }}>
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

      {session && (
        <>
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
              className="card elev-sm"
              style={{ padding: 0, overflow: "hidden" }}
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
                    {putts.map((p) => (
                      <tr key={p.putt_index}>
                        <td>{p.putt_index + 1}</td>
                        <td>
                          {p.offset_mm == null
                            ? "—"
                            : `${Math.abs(p.offset_mm).toFixed(1)} mm`}
                        </td>
                        <td style={{ color: "var(--color-neutral-700)" }}>
                          {p.offset_mm == null ? "—" : golferSide(p.offset_mm)}
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
                                    // Golfer's view: recover the sign, as
                                    // Offset/Direction do.
                                    const g = -v;
                                    const sign = g > 0 ? "+" : g < 0 ? "−" : "";
                                    return sign + Math.abs(g).toFixed(1);
                                  })
                                  .join(" / ")}
                          </td>
                        )}
                        <td style={{ textAlign: "right" }}>
                          <button
                            type="button"
                            onClick={() => void handleDeletePutt(p)}
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
                    ))}
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
          )}
        </>
      )}
    </>
  );
}
