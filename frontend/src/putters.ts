import { apiFetch, apiJson, detailFromResponse } from "./api";

// A putter, as returned by the backend (which scopes every query to the
// signed-in user). Mirror of backend/db/schema.sql.
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

// The user's putters, active one(s) first then newest.
export async function fetchPutters(): Promise<PutterRow[]> {
  return apiJson<PutterRow[]>("/putters", {}, "Could not load putters");
}

export async function createPutter(fields: PutterInput): Promise<PutterRow> {
  return apiJson<PutterRow>(
    "/putters",
    { method: "POST", body: JSON.stringify(fields) },
    "Could not add putter",
  );
}

export async function updatePutter(
  id: string,
  fields: PutterInput,
): Promise<void> {
  await apiJson<PutterRow>(
    `/putters/${id}`,
    { method: "PATCH", body: JSON.stringify(fields) },
    "Could not update putter",
  );
}

export async function deletePutter(id: string): Promise<void> {
  const res = await apiFetch(`/putters/${id}`, { method: "DELETE" });
  if (!res.ok) throw new Error(await detailFromResponse(res, "Could not delete putter"));
}

// Make one putter the user's active (default) putter, atomically clearing any
// previous active one (see set_active_putter in backend/app/db.py).
export async function setActivePutter(id: string): Promise<void> {
  const res = await apiFetch(`/putters/${id}/activate`, { method: "POST" });
  if (!res.ok) throw new Error(await detailFromResponse(res, "Could not set active putter"));
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
