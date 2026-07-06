import { useMemo } from "react";
import type { SessionRow } from "./sessions";

interface ContributionGraphProps {
  sessions: SessionRow[];
  className?: string;
}

const BOX = 11; // px, side of a day cell
const GAP = 3; // px, between cells
const LABEL_W = 28; // px, left day-of-week label column

// Sunday-first day labels; only Mon/Wed/Fri are shown (like GitHub).
const DAY_LABELS = ["", "Mon", "", "Wed", "", "Fri", ""];
const MONTH_NAMES = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

// Local YYYY-MM-DD key for a date (matches how the day cells are keyed).
function dateKey(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

// Green intensity by session count for the day (grey when none), echoing the
// GitHub contribution palette.
function cellColor(count: number): string {
  if (count <= 0) return "#2a2a2a";
  if (count === 1) return "#0e4429";
  if (count === 2) return "#006d32";
  if (count === 3) return "#26a641";
  return "#39d353";
}

interface Day {
  key: string;
  date: Date;
  count: number;
}

export default function ContributionGraph({
  sessions,
  className = "",
}: ContributionGraphProps) {
  const { weeks, total } = useMemo(() => {
    // How many sessions fall on each local day.
    const counts = new Map<string, number>();
    for (const s of sessions) {
      const d = new Date(s.captured_at ?? s.created_at);
      if (Number.isNaN(d.getTime())) continue;
      const key = dateKey(d);
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }

    // Span the last 3 months, ending today, starting on a Sunday so columns are
    // whole weeks.
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const start = new Date(today);
    start.setMonth(start.getMonth() - 3);
    start.setDate(start.getDate() - start.getDay());

    const cols: Day[][] = [];
    let total = 0;
    const cursor = new Date(start);
    while (cursor <= today) {
      const week: Day[] = [];
      for (let i = 0; i < 7 && cursor <= today; i++) {
        const key = dateKey(cursor);
        const count = counts.get(key) ?? 0;
        total += count;
        week.push({ key, date: new Date(cursor), count });
        cursor.setDate(cursor.getDate() + 1);
      }
      cols.push(week);
    }
    return { weeks: cols, total };
  }, [sessions]);

  // A month label sits above the first week whose Sunday falls in a new month.
  const monthLabel = (i: number): string => {
    const month = weeks[i][0].date.getMonth();
    if (i === 0) return "";
    return weeks[i - 1][0].date.getMonth() === month ? "" : MONTH_NAMES[month];
  };

  return (
    <div className={`bg-[#1a1a1a] border border-[#333] rounded-xl p-5 ${className}`}>
      <h3 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-3">
        {total} session{total === 1 ? "" : "s"} in the last 3 months
      </h3>

      <div className="overflow-x-auto">
        <div className="inline-block">
          {/* Month labels */}
          <div
            className="flex"
            style={{ marginLeft: LABEL_W + GAP, gap: GAP }}
          >
            {weeks.map((_, i) => (
              <div
                key={i}
                className="text-[10px] text-[#888] whitespace-nowrap leading-none"
                style={{ width: BOX }}
              >
                {monthLabel(i)}
              </div>
            ))}
          </div>

          {/* Day-of-week labels + week columns */}
          <div className="flex mt-1" style={{ gap: GAP }}>
            <div
              className="flex flex-col"
              style={{ gap: GAP, width: LABEL_W }}
            >
              {DAY_LABELS.map((label, r) => (
                <div
                  key={r}
                  className="text-[10px] text-[#888] leading-none flex items-center"
                  style={{ height: BOX }}
                >
                  {label}
                </div>
              ))}
            </div>

            {weeks.map((week, i) => (
              <div key={i} className="flex flex-col" style={{ gap: GAP }}>
                {week.map((day) => (
                  <div
                    key={day.key}
                    title={`${day.count} session${
                      day.count === 1 ? "" : "s"
                    } on ${day.date.toLocaleDateString(undefined, {
                      month: "short",
                      day: "numeric",
                      year: "numeric",
                    })}`}
                    className="rounded-sm"
                    style={{
                      width: BOX,
                      height: BOX,
                      background: cellColor(day.count),
                    }}
                  />
                ))}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
