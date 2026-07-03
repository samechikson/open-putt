import { useEffect, useState } from "react";
import {
  fetchSession,
  fetchPutts,
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
  const [putts, setPutts] = useState<PuttRow[] | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([fetchSession(sessionId), fetchPutts(sessionId)])
      .then(([s, p]) => {
        if (cancelled) return;
        setSession(s);
        setPutts(p);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : "Failed to load session");
        setSession(null);
        setPutts(null);
      });
    return () => {
      cancelled = true;
    };
  }, [sessionId]);

  const rows = putts ?? [];
  const offsets = rows
    .map((p) => p.offset_mm)
    .filter((o): o is number => o != null);
  const speeds = rows
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

      {putts === undefined && (
        <div className="flex items-center gap-2 text-sm text-[#888]">
          <span className="w-3.5 h-3.5 border-2 border-[#22c55e] border-t-transparent rounded-full animate-spin" />
          Loading…
        </div>
      )}

      {(session === null || putts === null) && (
        <div className="bg-[#1a1a1a] border border-[#3a2020] rounded-xl p-5 text-sm text-[#f87171]">
          {error ?? "Failed to load session."}
        </div>
      )}

      {putts && (
        <>
          <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 mb-6">
            <h3 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-3">
              Session Averages · {rows.length} putt{rows.length === 1 ? "" : "s"}
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

          {rows.length > 0 && (
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
                  {rows.map((p) => (
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
