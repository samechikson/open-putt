import { useEffect, useState } from "react";
import {
  fetchSessions,
  type SessionRow,
  type SessionStatus,
} from "./sessions";

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

  return (
    <>
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

      {sessions && sessions.length > 0 && (
        <div className="flex flex-col gap-3">
          {sessions.map((s) => (
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
                  {s.break_type && ` · ${s.break_type}`}
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
