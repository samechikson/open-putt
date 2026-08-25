import { useEffect, useMemo, useState } from "react";
import {
  fetchSessions,
  fetchOffsetsForSessions,
  breakTypeLabel,
  breakDirection,
  lengthBucket,
  lengthBucketLabel,
  BREAK_DIRECTIONS,
  type BreakDirection,
  type SessionRow,
} from "./sessions";
import { fetchPutters } from "./putters";
import { biasWord, golferSide } from "./analysis";
import { mean } from "./stats";
import ContributionGraph from "./ContributionGraph";

// How many recent sessions the home-page summary considers.
type SessionWindow = number | "all";
const WINDOW_OPTIONS: SessionWindow[] = [5, 10, 20, "all"];

interface DashboardProps {
  onOpenSession: (id: string) => void;
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export default function Dashboard({ onOpenSession }: DashboardProps) {
  // undefined = loading, null = error, array = loaded
  const [sessions, setSessions] = useState<SessionRow[] | null | undefined>(
    undefined,
  );
  const [error, setError] = useState<string | null>(null);
  // Map of putter id → name, to label session cards with their putter.
  const [putterNames, setPutterNames] = useState<Map<string, string>>(
    new Map(),
  );
  const [sessionWindow, setSessionWindow] = useState<SessionWindow>(5);
  // null = loading, array = loaded offsets across the selected sessions.
  const [offsets, setOffsets] = useState<number[] | null>(null);
  // Session-list filters by putt type: length bucket (3-ft increments) and
  // break slope direction. "all" = no filter on that dimension.
  const [lengthFilter, setLengthFilter] = useState<number | "all">("all");
  const [breakFilter, setBreakFilter] = useState<BreakDirection | "all">("all");

  useEffect(() => {
    let cancelled = false;
    fetchSessions()
      .then((rows) => {
        if (!cancelled) setSessions(rows);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : "Failed to load sessions");
        setSessions(null);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    fetchPutters()
      .then((rows) => {
        if (!cancelled)
          setPutterNames(new Map(rows.map((p) => [p.id, p.name])));
      })
      .catch(() => {
        // Putter labels are cosmetic; leave cards un-labelled on failure.
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // The length buckets present across the loaded sessions, so the length filter
  // only offers ranges that actually have sessions.
  const lengthBuckets = useMemo(() => {
    if (!sessions) return [];
    const present = new Set<number>();
    for (const s of sessions) {
      const b = lengthBucket(s.length_feet);
      if (b != null) present.add(b);
    }
    return [...present].sort((a, b) => a - b);
  }, [sessions]);

  // Sessions after applying the putt-type filters. Drives both the session list
  // and the aggregate metrics below, so the whole page reflects the filter.
  const filteredSessions = useMemo(() => {
    if (!sessions) return sessions;
    return sessions.filter((s) => {
      if (lengthFilter !== "all" && lengthBucket(s.length_feet) !== lengthFilter)
        return false;
      if (breakFilter !== "all" && breakDirection(s.break_type) !== breakFilter)
        return false;
      return true;
    });
  }, [sessions, lengthFilter, breakFilter]);

  const filtersActive = lengthFilter !== "all" || breakFilter !== "all";

  // The most recent sessions in the selected window, honouring the putt-type
  // filters (rows arrive newest-first from fetchSessions).
  const windowSessionIds = useMemo(() => {
    if (!filteredSessions) return [];
    return (
      sessionWindow === "all"
        ? filteredSessions
        : filteredSessions.slice(0, sessionWindow)
    ).map((s) => s.id);
  }, [filteredSessions, sessionWindow]);

  const idsKey = windowSessionIds.join(",");
  useEffect(() => {
    let cancelled = false;
    setOffsets(null);
    fetchOffsetsForSessions(windowSessionIds)
      .then((rows) => {
        if (!cancelled) setOffsets(rows);
      })
      .catch(() => {
        // Summary is secondary; leave it loading rather than breaking the list.
      });
    return () => {
      cancelled = true;
    };
  }, [idsKey]);

  const bias = offsets ? mean(offsets) : null;
  const biasSide = bias == null ? "center" : golferSide(bias);
  const totalPutts = offsets?.length ?? 0;
  const hasWindowSessions = windowSessionIds.length > 0;

  const selectStyle = { width: "auto", padding: "8px 14px" } as const;

  return (
    <>
      {sessions && sessions.length > 0 && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 10,
            marginBottom: 24,
            flexWrap: "wrap",
          }}
        >
          <span className="kicker" style={{ marginRight: 2 }}>
            Filter
          </span>
          <select
            className="input"
            style={selectStyle}
            value={lengthFilter === "all" ? "all" : String(lengthFilter)}
            onChange={(e) =>
              setLengthFilter(
                e.target.value === "all" ? "all" : Number(e.target.value),
              )
            }
          >
            <option value="all">All lengths</option>
            {lengthBuckets.map((b) => (
              <option key={b} value={b}>
                {lengthBucketLabel(b)}
              </option>
            ))}
          </select>
          <select
            className="input"
            style={selectStyle}
            value={breakFilter}
            onChange={(e) =>
              setBreakFilter(e.target.value as BreakDirection | "all")
            }
          >
            <option value="all">All breaks</option>
            {BREAK_DIRECTIONS.map((d) => (
              <option key={d.value} value={d.value}>
                {d.label}
              </option>
            ))}
          </select>
          {filtersActive && (
            <button
              type="button"
              onClick={() => {
                setLengthFilter("all");
                setBreakFilter("all");
              }}
              className="btn btn-ghost"
              style={{ padding: "8px 16px", fontSize: 13 }}
            >
              Clear
            </button>
          )}
        </div>
      )}

      {sessions && sessions.length > 0 && (
        <div
          style={{
            display: "flex",
            gap: 24,
            marginBottom: 28,
            flexWrap: "wrap",
            alignItems: "stretch",
          }}
        >
          <ContributionGraph
            sessions={filteredSessions ?? sessions}
            style={{ flex: "1 1 440px", minWidth: 0 }}
          />

          {hasWindowSessions && (
            <div
              className="card elev-sm"
              style={{ flex: "1 1 360px", minWidth: 0 }}
            >
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "space-between",
                  marginBottom: 16,
                }}
              >
                <span className="kicker">Recent Form</span>
                <select
                  className="input"
                  style={{ width: "auto", fontSize: 13, padding: "6px 12px" }}
                  value={sessionWindow === "all" ? "all" : String(sessionWindow)}
                  onChange={(e) =>
                    setSessionWindow(
                      e.target.value === "all" ? "all" : Number(e.target.value),
                    )
                  }
                >
                  {WINDOW_OPTIONS.map((opt) => (
                    <option key={opt} value={opt === "all" ? "all" : opt}>
                      {opt === "all" ? "All sessions" : `Last ${opt} sessions`}
                    </option>
                  ))}
                </select>
              </div>
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "1fr 1fr",
                  gap: 20,
                }}
              >
                <div>
                  <div className="stat">
                    {offsets == null
                      ? "…"
                      : bias == null
                        ? "—"
                        : `${Math.abs(bias).toFixed(1)} mm`}
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
                  <div className="stat">
                    {offsets == null ? "…" : totalPutts}
                  </div>
                  <div className="stat-sub">total putts</div>
                </div>
              </div>
            </div>
          )}
        </div>
      )}

      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 16,
          marginBottom: 18,
        }}
      >
        <div style={{ fontFamily: "var(--font-heading)", fontSize: 24 }}>
          Your Sessions
        </div>
      </div>

      {sessions === undefined && (
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
          Loading sessions…
        </div>
      )}

      {sessions === null && (
        <div
          className="card elev-sm"
          style={{ fontSize: 14, color: "var(--color-accent-800)" }}
        >
          {error ?? "Failed to load sessions."}
        </div>
      )}

      {sessions && sessions.length === 0 && (
        <div className="card elev-sm" style={{ padding: 32, textAlign: "center" }}>
          <p style={{ margin: 0, color: "var(--color-neutral-700)" }}>
            No sessions yet. Roll a few putts through the gate — they'll show up
            here as you play.
          </p>
        </div>
      )}

      {sessions &&
        sessions.length > 0 &&
        filteredSessions &&
        filteredSessions.length === 0 && (
          <div
            className="card elev-sm"
            style={{ padding: 32, textAlign: "center" }}
          >
            <p style={{ margin: 0, color: "var(--color-neutral-700)" }}>
              No sessions match the selected putt type.
            </p>
          </div>
        )}

      {sessions &&
        sessions.length > 0 &&
        filteredSessions &&
        filteredSessions.length > 0 && (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3.5">
            {filteredSessions.map((s) => (
              <button
                key={s.id}
                type="button"
                onClick={() => onOpenSession(s.id)}
                className="card elev-sm"
                style={{
                  textAlign: "left",
                  cursor: "pointer",
                  flexDirection: "row",
                  alignItems: "center",
                  justifyContent: "space-between",
                  gap: 14,
                }}
              >
                <div style={{ minWidth: 0 }}>
                  <div
                    style={{
                      fontWeight: 600,
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {formatDate(s.created_at)}
                  </div>
                  <div
                    style={{
                      fontSize: 12,
                      color: "var(--color-neutral-600)",
                      marginTop: 2,
                    }}
                  >
                    {s.length_feet != null && `${s.length_feet} ft`}
                    {s.break_type &&
                      `${s.length_feet != null ? " · " : ""}${breakTypeLabel(s.break_type)}`}
                    {s.putter_id &&
                      putterNames.has(s.putter_id) &&
                      ` · ${putterNames.get(s.putter_id)}`}
                  </div>
                </div>
                <div style={{ textAlign: "right", flexShrink: 0 }}>
                  <div style={{ fontWeight: 600 }}>
                    {s.putt_count} putt{s.putt_count === 1 ? "" : "s"}
                  </div>
                </div>
              </button>
            ))}
          </div>
        )}
    </>
  );
}
