import {
  collection,
  doc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  writeBatch,
  type DocumentData,
} from "firebase/firestore";
import { db, currentUid } from "./firebaseClient";

// A putter, stored in the `putters/{id}` Firestore collection and scoped to the
// signed-in user by its `user_id` field (enforced in firestore.rules).
export interface PutterRow {
  id: string;
  name: string;
  brand: string | null;
  model: string | null;
  length_in: number | null;
  lie_deg: number | null;
  grip: string | null;
  is_active: boolean;
}

// The editable fields of a putter (everything except id and the active flag,
// which is managed via setActivePutter). Nulls clear an optional field.
export interface PutterInput {
  name: string;
  brand: string | null;
  model: string | null;
  length_in: number | null;
  lie_deg: number | null;
  grip: string | null;
}

function toRow(id: string, data: DocumentData): PutterRow {
  return {
    id,
    name: data.name,
    brand: data.brand ?? null,
    model: data.model ?? null,
    length_in: data.length_in ?? null,
    lie_deg: data.lie_deg ?? null,
    grip: data.grip ?? null,
    is_active: !!data.is_active,
  };
}

// A comparable millis value for a doc's created_at (a Firestore Timestamp), for
// newest-first sorting. Missing timestamps sort oldest.
function createdMillis(data: DocumentData): number {
  const c = data.created_at;
  return c && typeof c.toMillis === "function" ? c.toMillis() : 0;
}

// The user's putters, active one(s) first then newest. A single equality filter
// (user_id) keeps this index-free; ordering is done client-side.
export async function fetchPutters(): Promise<PutterRow[]> {
  const uid = await currentUid();
  const snap = await getDocs(
    query(collection(db, "putters"), where("user_id", "==", uid)),
  );
  const docs = snap.docs.slice();
  // Two stable passes: newest-first, then active-first.
  docs.sort((a, b) => createdMillis(b.data()) - createdMillis(a.data()));
  docs.sort(
    (a, b) => (b.data().is_active ? 1 : 0) - (a.data().is_active ? 1 : 0),
  );
  return docs.map((d) => toRow(d.id, d.data()));
}

export async function createPutter(fields: PutterInput): Promise<PutterRow> {
  const uid = await currentUid();
  // UUID doc id (matches the backend's convention, so a putter id is a valid
  // UUID wherever the backend still validates one — e.g. iOS session tagging).
  const id = crypto.randomUUID();
  await setDoc(doc(db, "putters", id), {
    user_id: uid,
    name: fields.name,
    brand: fields.brand,
    model: fields.model,
    length_in: fields.length_in,
    lie_deg: fields.lie_deg,
    grip: fields.grip,
    is_active: false,
    created_at: serverTimestamp(),
  });
  return { id, ...fields, is_active: false };
}

export async function updatePutter(
  id: string,
  fields: PutterInput,
): Promise<void> {
  await currentUid(); // ensure signed in; ownership enforced by rules
  await updateDoc(doc(db, "putters", id), {
    name: fields.name,
    brand: fields.brand,
    model: fields.model,
    length_in: fields.length_in,
    lie_deg: fields.lie_deg,
    grip: fields.grip,
  });
}

export async function deletePutter(id: string): Promise<void> {
  const uid = await currentUid();
  // Un-tag any sessions that referenced this putter (the backend used ON DELETE
  // SET NULL; Firestore has no cascade, so do it here).
  const tagged = await getDocs(
    query(
      collection(db, "sessions"),
      where("user_id", "==", uid),
      where("putter_id", "==", id),
    ),
  );
  const batch = writeBatch(db);
  for (const s of tagged.docs) batch.update(s.ref, { putter_id: null });
  batch.delete(doc(db, "putters", id));
  await batch.commit();
}

// Make one putter the user's active (default) putter, clearing any previously
// active one. A batched write keeps the "at most one active" invariant.
export async function setActivePutter(id: string): Promise<void> {
  const uid = await currentUid();
  const active = await getDocs(
    query(
      collection(db, "putters"),
      where("user_id", "==", uid),
      where("is_active", "==", true),
    ),
  );
  const batch = writeBatch(db);
  for (const p of active.docs) {
    if (p.id !== id) batch.update(p.ref, { is_active: false });
  }
  batch.update(doc(db, "putters", id), { is_active: true });
  await batch.commit();
}

// A short one-line spec summary for a putter (e.g. "34\" · 70° · SuperStroke"),
// or null when no optional fields are set.
export function putterSpec(p: PutterRow): string | null {
  const parts: string[] = [];
  if (p.length_in != null) parts.push(`${p.length_in}"`);
  if (p.lie_deg != null) parts.push(`${p.lie_deg}°`);
  const madeBy = [p.brand, p.model].filter(Boolean).join(" ");
  if (madeBy) parts.push(madeBy);
  if (p.grip) parts.push(p.grip);
  return parts.length ? parts.join(" · ") : null;
}
