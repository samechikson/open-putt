import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  updateDoc,
  where,
  writeBatch,
  type DocumentData,
} from "firebase/firestore";
import { db, currentUid } from "./firebaseClient";

// A session, stored in `sessions/{sessionId}` and scoped to the signed-in user
// by its `user_id` field (enforced in firestore.rules). Sessions are gate-only:
// created by the backend on the session's first relayed putt, then read/edited
// here. `sessionId` is the iOS session UUID.
export interface SessionRow {
  id: string;
  created_at: string;
  length_feet: number | null;
  break_type: string | null;
  putt_count: number;
  putter_id: string | null;
}

// One putt, stored in `putts/{sessionId_index}` (a top-level collection).
export interface PuttRow {
  putt_index: number;
  offset_mm: number | null;
  direction: string | null;
  speed_mps: number | null;
  // Per-sensor offsets from the hardware gate (device mounting order; null per
  // sensor that didn't see the ball).
  sensor_offsets_mm: (number | null)[] | null;
}

// Render a Firestore Timestamp (or a raw string) as an ISO-8601 string, so
// SessionRow.created_at stays a string the UI can pass to `new Date(...)`.
function toIso(value: unknown): string {
  if (value && typeof (value as { toDate?: unknown }).toDate === "function") {
    return (value as { toDate: () => Date }).toDate().toISOString();
  }
  if (typeof value === "string") return value;
  return new Date(0).toISOString();
}

function toSessionRow(id: string, data: DocumentData): SessionRow {
  return {
    id,
    created_at: toIso(data.created_at),
    length_feet: data.length_feet ?? null,
    break_type: data.break_type ?? null,
    putt_count: data.putt_count ?? 0,
    putter_id: data.putter_id ?? null,
  };
}

function toPuttRow(data: DocumentData): PuttRow {
  return {
    putt_index: data.putt_index,
    offset_mm: data.offset_mm ?? null,
    direction: data.direction ?? null,
    speed_mps: data.speed_mps ?? null,
    sensor_offsets_mm: data.sensor_offsets_mm ?? null,
  };
}

const puttDocId = (sessionId: string, puttIndex: number) =>
  `${sessionId}_${puttIndex}`;

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

// All of the user's sessions, newest first. Single equality filter (user_id) +
// client-side sort keeps this index-free.
export async function fetchSessions(): Promise<SessionRow[]> {
  const uid = await currentUid();
  const snap = await getDocs(
    query(collection(db, "sessions"), where("user_id", "==", uid)),
  );
  const rows = snap.docs.map((d) => toSessionRow(d.id, d.data()));
  rows.sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
  return rows;
}

export async function fetchSession(id: string): Promise<SessionRow | null> {
  const uid = await currentUid();
  const snap = await getDoc(doc(db, "sessions", id));
  if (!snap.exists() || snap.data().user_id !== uid) return null;
  return toSessionRow(snap.id, snap.data());
}

// A session's putts, ordered by putt_index. Scoped by user_id (which also
// satisfies the security rule for the query).
export async function fetchPutts(sessionId: string): Promise<PuttRow[]> {
  const uid = await currentUid();
  const snap = await getDocs(
    query(
      collection(db, "putts"),
      where("user_id", "==", uid),
      where("session_id", "==", sessionId),
    ),
  );
  const rows = snap.docs.map((d) => toPuttRow(d.data()));
  rows.sort((a, b) => a.putt_index - b.putt_index);
  return rows;
}

// Every putt's offset_mm across the given sessions, for the dashboard summary.
// One user-scoped query, filtered to the requested sessions client-side.
export async function fetchOffsetsForSessions(
  sessionIds: string[],
): Promise<number[]> {
  if (sessionIds.length === 0) return [];
  const uid = await currentUid();
  const wanted = new Set(sessionIds);
  const snap = await getDocs(
    query(collection(db, "putts"), where("user_id", "==", uid)),
  );
  const offsets: number[] = [];
  for (const d of snap.docs) {
    const data = d.data();
    if (wanted.has(data.session_id) && data.offset_mm != null) {
      offsets.push(data.offset_mm);
    }
  }
  return offsets;
}

// Update a session's editable metadata (distance, break type, putter). Pass null
// to clear a field. Ownership is enforced by the security rules.
export async function updateSession(
  sessionId: string,
  metadata: {
    length_feet: number | null;
    break_type: string | null;
    putter_id: string | null;
  },
): Promise<void> {
  await currentUid();
  await updateDoc(doc(db, "sessions", sessionId), {
    length_feet: metadata.length_feet,
    break_type: metadata.break_type,
    putter_id: metadata.putter_id,
  });
}

// Delete a session and its putts. Firestore has no cascade, so delete the putts
// (one user-scoped query) and the session in one batch.
export async function deleteSession(sessionId: string): Promise<void> {
  const uid = await currentUid();
  const putts = await getDocs(
    query(
      collection(db, "putts"),
      where("user_id", "==", uid),
      where("session_id", "==", sessionId),
    ),
  );
  const batch = writeBatch(db);
  for (const p of putts.docs) batch.delete(p.ref);
  batch.delete(doc(db, "sessions", sessionId));
  await batch.commit();
}

// Delete one putt (by its putt_index) and keep the session's putt_count in sync.
// Remaining putts keep their indices (a delete leaves a gap, not a renumber).
export async function deletePutt(
  sessionId: string,
  puttIndex: number,
): Promise<void> {
  const uid = await currentUid();
  await deleteDoc(doc(db, "putts", puttDocId(sessionId, puttIndex)));
  // Recount and update putt_count so the session card / list stay accurate.
  const remaining = await getDocs(
    query(
      collection(db, "putts"),
      where("user_id", "==", uid),
      where("session_id", "==", sessionId),
    ),
  );
  await updateDoc(doc(db, "sessions", sessionId), {
    putt_count: remaining.size,
  });
}
