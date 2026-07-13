import { supabase } from "./supabaseClient";

// A row from the `putters` table. RLS restricts reads/writes to the signed-in
// user's own putters (auth.uid() = user_id), so the client never has to filter
// by user. Mirror of supabase/migrations/0003_putters.sql.
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

const PUTTER_COLUMNS = "id,name,brand,model,length_in,lie_deg,grip,is_active";

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

// The user's putters, active one(s) first then newest. Unlike sessions, writes
// happen client-side too (RLS permits them).
export async function fetchPutters(): Promise<PutterRow[]> {
  const { data, error } = await supabase
    .from("putters")
    .select(PUTTER_COLUMNS)
    .order("is_active", { ascending: false })
    .order("created_at", { ascending: false });
  if (error) throw new Error(error.message);
  return (data ?? []) as PutterRow[];
}

export async function createPutter(fields: PutterInput): Promise<PutterRow> {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) throw new Error("You must be signed in to add a putter.");
  const { data, error } = await supabase
    .from("putters")
    .insert({ ...fields, user_id: user.id })
    .select(PUTTER_COLUMNS)
    .single();
  if (error) throw new Error(error.message);
  return data as PutterRow;
}

export async function updatePutter(
  id: string,
  fields: PutterInput,
): Promise<void> {
  const { error } = await supabase.from("putters").update(fields).eq("id", id);
  if (error) throw new Error(error.message);
}

export async function deletePutter(id: string): Promise<void> {
  const { error } = await supabase.from("putters").delete().eq("id", id);
  if (error) throw new Error(error.message);
}

// Make one putter the user's active (default) putter, atomically clearing any
// previous active one (see the set_active_putter SQL function).
export async function setActivePutter(id: string): Promise<void> {
  const { error } = await supabase.rpc("set_active_putter", {
    p_putter_id: id,
  });
  if (error) throw new Error(error.message);
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
