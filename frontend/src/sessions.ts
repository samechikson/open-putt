import { apiFetch, apiJson, detailFromResponse } from "./api";

// A session, as returned by the backend (which scopes every query to the
// signed-in user, so the client never has to filter by user). Sessions are
// gate-only: a hardware-gate session is created on its first relayed putt and
// keeps gaining putts as the player putts. Mirrors db.py's _SESSION_FIELDS.
export interface SessionRow {
  id: string;
  created_at: string;
  length_feet: number | null;
  break_type: string | null;
  putt_count: number;
  putter_id: string | null;
}

// The `putt_break` enum values with human labels, in menu order. Used for the
// session metadata editor and for rendering a break type anywhere in the UI.
export const BREAK_TYPES: { value: string; label: string }[] = [
  { value: "straight", label: "Straight" },
  { value: "leftToRight", label: "Left to right" },
  { value: "rightToLeft", label: "Right to left" },
  { value: "uphillStraight", label: "Uphill · straight" },
  { value: "uphillLeftToRight", label: "Uphill · left to right" },
  { value: "uphillRightToLeft", label: "Uphill · right to left" },
  { value: "downhillStraight", label: "Downhill · straight" },
  { value: "downhillLeftToRight", label: "Downhill · left to right" },
  { value: "downhillRightToLeft", label: "Downhill · right to left" },
];

const BREAK_LABELS = new Map(BREAK_TYPES.map((b) => [b.value, b.label]));

// Human label for a stored break_type (falls back to the raw value).
export function breakTypeLabel(value: string | null | undefined): string | null {
  if (!value) return null;
  return BREAK_LABELS.get(value) ?? value;
}

// The left/right slope of a putt, collapsing the uphill/downhill break_type
// variants down to just their break direction (used for filtering). Straight
// putts (no break) map to "straight"; a missing break_type has no direction.
export type BreakDirection = "leftToRight" | "rightToLeft" | "straight";

export function breakDirection(
  value: string | null | undefined,
): BreakDirection | null {
  if (!value) return null;
  const v = value.toLowerCase();
  if (v.includes("lefttoright")) return "leftToRight";
  if (v.includes("righttoleft")) return "rightToLeft";
  return "straight";
}

// Human labels for the break-direction filter, in menu order.
export const BREAK_DIRECTIONS: { value: BreakDirection; label: string }[] = [
  { value: "leftToRight", label: "Left to right" },
  { value: "rightToLeft", label: "Right to left" },
  { value: "straight", label: "Straight" },
];

// Putt lengths are filtered in three-foot buckets.
export const LENGTH_BUCKET_FEET = 3;

// The 0-based length bucket for a putt, in three-foot increments (1–3 ft → 0,
// 4–6 ft → 1, …). Missing or non-positive lengths have no bucket.
export function lengthBucket(feet: number | null | undefined): number | null {
  if (feet == null || feet <= 0) return null;
  return Math.floor((feet - 1) / LENGTH_BUCKET_FEET);
}

// Human label for a length bucket index (e.g. "4–6 ft").
export function lengthBucketLabel(bucket: number): string {
  const lo = bucket * LENGTH_BUCKET_FEET + 1;
  const hi = (bucket + 1) * LENGTH_BUCKET_FEET;
  return `${lo}–${hi} ft`;
}

// Update a session's editable metadata (distance, break type, putter) via the
// backend. Pass null to clear a field.
export async function updateSession(
  sessionId: string,
  metadata: {
    length_feet: number | null;
    break_type: string | null;
    putter_id: string | null;
  },
): Promise<void> {
  const res = await apiFetch(`/sessions/${sessionId}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(metadata),
  });
  if (!res.ok) {
    throw new Error(await detailFromResponse(res, "Could not update session"));
  }
}

// Delete a session and its putts via the backend.
export async function deleteSession(sessionId: string): Promise<void> {
  const res = await apiFetch(`/sessions/${sessionId}`, { method: "DELETE" });
  if (!res.ok) {
    throw new Error(await detailFromResponse(res, "Could not delete session"));
  }
}

// Delete a single putt from a session (by its putt_index). The backend keeps
// the session's putt_count in sync; remaining putts keep their indices.
export async function deletePutt(
  sessionId: string,
  puttIndex: number,
): Promise<void> {
  const res = await apiFetch(`/sessions/${sessionId}/putts/${puttIndex}`, {
    method: "DELETE",
  });
  if (!res.ok) {
    throw new Error(await detailFromResponse(res, "Could not delete putt"));
  }
}

export async function fetchSessions(): Promise<SessionRow[]> {
  return apiJson<SessionRow[]>("/sessions", {}, "Could not load sessions");
}

export async function fetchSession(id: string): Promise<SessionRow | null> {
  const res = await apiFetch(`/sessions/${id}`);
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(await detailFromResponse(res, "Could not load session"));
  return (await res.json()) as SessionRow;
}

// One putt as returned by the backend. Mirrors db.py's _PUTT_FIELDS.
export interface PuttRow {
  putt_index: number;
  offset_mm: number | null;
  direction: string | null;
  speed_mps: number | null;
  // Per-sensor offsets from the hardware gate (device mounting order; null per
  // sensor that didn't see the ball).
  sensor_offsets_mm: (number | null)[] | null;
}

export async function fetchPutts(sessionId: string): Promise<PuttRow[]> {
  return apiJson<PuttRow[]>(
    `/sessions/${sessionId}/putts`,
    {},
    "Could not load putts",
  );
}

// Pull every putt's offset_mm across several sessions in one request, for the
// home-page analytics summary. Nulls (putts with no measured offset) are dropped
// server-side.
export async function fetchOffsetsForSessions(
  sessionIds: string[],
): Promise<number[]> {
  if (sessionIds.length === 0) return [];
  const { offsets } = await apiJson<{ offsets: number[] }>(
    "/putts/offsets",
    { method: "POST", body: JSON.stringify({ session_ids: sessionIds }) },
    "Could not load analytics",
  );
  return offsets;
}
