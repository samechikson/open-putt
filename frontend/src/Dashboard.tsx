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
  type SessionStatus,
} from "./sessions";
import { fetchPutters } from "./putters";
import { biasWord, golferSide } from "./analysis";
import { mean } from "./stats";
import ContributionGraph from "./ContributionGraph";

// How many recent completed sessions the home-page summary considers.
type SessionWindow = number | "all";
const WINDOW_OPTIONS: SessionWindow[] = [5, 10, 20, "all"];

interface DashboardProps {
  onNewSession: () => void;
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

const STATUS_STYLE: Record<SessionStatus, string> = {
  queued: "bg-[#3a3320] text-[#f0b429]",
  processing: "bg-[#3a3320] text-[#f0b429]",
  done: "bg-[#1e3320] text-[#22c55e]",
  error: "bg-[#3a2020] text-[#f87171]",
};

function StatusBadge({ status }: { status: SessionStatus }) {
  const label =
    status === "processing"
      ? "Processing"
      : status.charAt(0).toUpperCase() + status.slice(1);
  return (
    <span
      className={`px-2 py-0.5 rounded text-[10px] font-semibold uppercase tracking-wide ${STATUS_STYLE[status]}`}
    >
      {label}
    </span>
  );
}

export default function Dashboard({
  onNewSession,
  onOpenSession,
}: DashboardProps) {
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

  // The most recent completed sessions in the selected window, honouring the
  // putt-type filters (rows arrive newest-first from fetchSessions).
  const windowSessionIds = useMemo(() => {
    if (!filteredSessions) return [];
    const done = filteredSessions.filter((s) => s.status === "done");
    return (sessionWindow === "all" ? done : done.slice(0, sessionWindow)).map(
      (s) => s.id,
    );
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
  const hasDoneSessions = windowSessionIds.length > 0;

  return (
    <>
      {sessions && sessions.length > 0 && (
        <div className="flex flex-wrap items-center gap-2 mb-6">
          <span className="text-xs font-semibold uppercase tracking-widest text-[#888] mr-1">
            Filter
          </span>
          <select
            value={lengthFilter === "all" ? "all" : String(lengthFilter)}
            onChange={(e) =>
              setLengthFilter(
                e.target.value === "all" ? "all" : Number(e.target.value),
              )
            }
            className="bg-[#222] border border-[#333] hover:border-[#444] rounded-lg text-sm text-white px-3 py-1.5 cursor-pointer focus:outline-none focus:border-[#22c55e]"
          >
            <option value="all">All lengths</option>
            {lengthBuckets.map((b) => (
              <option key={b} value={b}>
                {lengthBucketLabel(b)}
              </option>
            ))}
          </select>
          <select
            value={breakFilter}
            onChange={(e) =>
              setBreakFilter(e.target.value as BreakDirection | "all")
            }
            className="bg-[#222] border border-[#333] hover:border-[#444] rounded-lg text-sm text-white px-3 py-1.5 cursor-pointer focus:outline-none focus:border-[#22c55e]"
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
              className="px-3 py-1.5 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-[#aaa] font-medium transition-all cursor-pointer"
            >
              Clear
            </button>
          )}
        </div>
      )}

      {sessions && sessions.length > 0 && (
        <div className="flex flex-col lg:flex-row gap-6 mb-6">
          <ContributionGraph
            sessions={filteredSessions ?? sessions}
            className="lg:w-1/3 lg:shrink-0 min-w-0"
          />

          {hasDoneSessions && (
            <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 lg:flex-1 min-w-0">
              <div className="flex items-center justify-between gap-4 mb-3">
                <h3 className="text-xs font-semibold uppercase tracking-widest text-[#aaa]">
                  Recent Form
                </h3>
                <select
                  value={sessionWindow === "all" ? "all" : String(sessionWindow)}
                  onChange={(e) =>
                    setSessionWindow(
                      e.target.value === "all" ? "all" : Number(e.target.value),
                    )
                  }
                  className="bg-[#222] border border-[#333] hover:border-[#444] rounded-lg text-sm text-white px-3 py-1.5 cursor-pointer focus:outline-none focus:border-[#22c55e]"
                >
                  {WINDOW_OPTIONS.map((opt) => (
                    <option key={opt} value={opt === "all" ? "all" : opt}>
                      {opt === "all" ? "All sessions" : `Last ${opt} sessions`}
                    </option>
                  ))}
                </select>
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <div className="offset-value">
                    {offsets == null
                      ? "…"
                      : bias == null
                        ? "—"
                        : `${Math.abs(bias).toFixed(1)} mm`}
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
                    {offsets == null ? "…" : totalPutts}
                  </div>
                  <p className="text-sm text-[#aaa] -mt-1">total putts</p>
                </div>
              </div>
            </div>
          )}
        </div>
      )}

      <div className="flex items-center justify-between gap-4 mb-6">
        <h2 className="text-xl font-bold text-white">Your Sessions</h2>
        <button
          type="button"
          onClick={onNewSession}
          className="px-4 py-2 bg-[#22c55e] hover:bg-[#16a34a] rounded-lg text-sm text-black font-semibold transition-all cursor-pointer"
        >
          + New Session
        </button>
      </div>

      {sessions === undefined && (
        <div className="flex items-center gap-2 text-sm text-[#888]">
          <span className="w-3.5 h-3.5 border-2 border-[#22c55e] border-t-transparent rounded-full animate-spin" />
          Loading sessions…
        </div>
      )}

      {sessions === null && (
        <div className="bg-[#1a1a1a] border border-[#3a2020] rounded-xl p-5 text-sm text-[#f87171]">
          {error ?? "Failed to load sessions."}
        </div>
      )}

      {sessions && sessions.length === 0 && (
        <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-8 text-center">
          <p className="text-[#aaa] mb-4">
            No sessions yet. Upload a putting video to get started.
          </p>
          <button
            type="button"
            onClick={onNewSession}
            className="px-4 py-2 bg-[#22c55e] hover:bg-[#16a34a] rounded-lg text-sm text-black font-semibold transition-all cursor-pointer"
          >
            + New Session
          </button>
        </div>
      )}

      {sessions &&
        sessions.length > 0 &&
        filteredSessions &&
        filteredSessions.length === 0 && (
          <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-8 text-center">
            <p className="text-[#aaa]">
              No sessions match the selected putt type.
            </p>
          </div>
        )}

      {sessions && sessions.length > 0 && filteredSessions && filteredSessions.length > 0 && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
          {filteredSessions.map((s) => (
            <button
              key={s.id}
              type="button"
              onClick={() => onOpenSession(s.id)}
              className="text-left bg-[#1a1a1a] border border-[#333] hover:bg-[#222] hover:border-[#444] rounded-xl p-4 transition-all cursor-pointer flex items-center justify-between gap-4"
            >
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <span className="text-white font-medium truncate">
                    {s.file_name ?? "Session"}
                  </span>
                  {s.status !== "done" && <StatusBadge status={s.status} />}
                </div>
                <div className="text-xs text-[#888] mt-0.5">
                  {formatDate(s.captured_at ?? s.created_at)}
                  {s.length_feet != null && ` · ${s.length_feet} ft`}
                  {s.break_type && ` · ${breakTypeLabel(s.break_type)}`}
                  {s.putter_id &&
                    putterNames.has(s.putter_id) &&
                    ` · ${putterNames.get(s.putter_id)}`}
                </div>
              </div>
              <div className="text-right shrink-0">
                {s.status === "done" ? (
                  <>
                    <div className="text-white font-semibold">
                      {s.putt_count} putt{s.putt_count === 1 ? "" : "s"}
                    </div>
                    {s.duration_s != null && (
                      <div className="text-xs text-[#888]">
                        {s.duration_s.toFixed(1)}s
                      </div>
                    )}
                  </>
                ) : (
                  <span className="text-[#666] text-lg">›</span>
                )}
              </div>
            </button>
          ))}
        </div>
      )}
    </>
  );
}
