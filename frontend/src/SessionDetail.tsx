import { useEffect, useState } from "react";
import {
  fetchSession,
  fetchPutts,
  subscribeToSession,
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

    fetchSession(sessionId)
      .then((row) => {
        if (cancelled) return;
        setSession(row);
        if (row?.status === "done") loadPutts();
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
      if (row.status === "done") loadPutts();
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

  return (
    <>
      <div className="flex items-center justify-between gap-4 mb-6">
        <h2 className="text-xl font-bold text-white truncate">
          {session?.file_name ?? "Session"}
        </h2>
        <button
          type="button"
          onClick={onBack}
          className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-white font-medium transition-all cursor-pointer shrink-0"
        >
          ← Sessions
        </button>
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
        <div className="bg-[#1a1a1a] border border-[#3a2020] rounded-xl p-5 text-sm text-[#f87171]">
          {session?.error ?? "Analysis failed."}
        </div>
      )}

      {status === "done" && (
        <>
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
            <div className="bg-[#1a1a1a] border border-[#333] rounded-xl overflow-hidden">
              <table className="w-full text-sm">
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
                      className="border-b border-[#262626] last:border-0"
                    >
                      <td className="px-4 py-3 text-[#aaa]">
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
