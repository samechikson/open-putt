import { supabase } from "./supabaseClient";

// A row from the `sessions` table. RLS restricts reads to the signed-in user's
// own sessions (auth.uid() = user_id), so the client never has to filter.
export interface SessionRow {
  id: string;
  created_at: string;
  captured_at: string | null;
  file_name: string | null;
  length_feet: number | null;
  break_type: string | null;
  putt_count: number;
  duration_s: number | null;
  segments_detected: number | null;
}

const SESSION_COLUMNS =
  "id,created_at,captured_at,file_name,length_feet,break_type,putt_count,duration_s,segments_detected";

export async function fetchSessions(): Promise<SessionRow[]> {
  const { data, error } = await supabase
    .from("sessions")
    .select(SESSION_COLUMNS)
    .order("created_at", { ascending: false });
  if (error) throw new Error(error.message);
  return (data ?? []) as SessionRow[];
}

export async function fetchSession(id: string): Promise<SessionRow | null> {
  const { data, error } = await supabase
    .from("sessions")
    .select(SESSION_COLUMNS)
    .eq("id", id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return (data as SessionRow) ?? null;
}

// A row from the `putts` table (raw tracking arrays are not persisted).
export interface PuttRow {
  putt_index: number;
  start_s: number | null;
  end_s: number | null;
  offset_mm: number | null;
  direction: string | null;
  speed_mps: number | null;
  track_count: number | null;
}

export async function fetchPutts(sessionId: string): Promise<PuttRow[]> {
  const { data, error } = await supabase
    .from("putts")
    .select("putt_index,start_s,end_s,offset_mm,direction,speed_mps,track_count")
    .eq("session_id", sessionId)
    .order("putt_index", { ascending: true });
  if (error) throw new Error(error.message);
  return (data ?? []) as PuttRow[];
}
