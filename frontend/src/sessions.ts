import { supabase } from "./supabaseClient";
import { API_BASE } from "./analysis";

// Job lifecycle of a session's background analysis.
export type SessionStatus = "queued" | "processing" | "done" | "error";

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
  status: SessionStatus;
  error: string | null;
  video_path: string | null;
}

const SESSION_COLUMNS =
  "id,created_at,captured_at,file_name,length_feet,break_type,putt_count,duration_s,segments_detected,status,error,video_path";

// A short-lived signed URL to stream a session's retained video.
export async function fetchSessionVideoUrl(sessionId: string): Promise<string> {
  const res = await fetch(`${API_BASE}/sessions/${sessionId}/video`);
  if (!res.ok) {
    throw new Error(await detailFromResponse(res, "Could not load video"));
  }
  const body = (await res.json()) as { url: string };
  return body.url;
}

async function detailFromResponse(res: Response, fallback: string): Promise<string> {
  try {
    const body = await res.json();
    if (body?.detail) return body.detail as string;
  } catch {
    // non-JSON body; use the fallback
  }
  return fallback;
}

// Queue a Full Session video for background analysis. Uploads the video straight
// to Cloud Storage via a signed URL (avoiding Cloud Run's request-size limit),
// then starts analysis. Returns the session id; watch the row via
// subscribeToSession for completion.
export async function uploadSession(
  file: File,
  fps: number | null,
): Promise<string> {
  const {
    data: { session },
  } = await supabase.auth.getSession();
  const authHeaders: HeadersInit = session
    ? { Authorization: `Bearer ${session.access_token}` }
    : {};

  // 1. Ask the backend for a signed upload URL.
  const initRes = await fetch(`${API_BASE}/uploads`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders },
    body: JSON.stringify({ filename: file.name }),
  });
  if (!initRes.ok) {
    throw new Error(await detailFromResponse(initRes, "Could not start upload"));
  }
  const { session_id, object_name, upload_url } = (await initRes.json()) as {
    session_id: string;
    object_name: string;
    upload_url: string;
  };

  // 2. Upload the video directly to Cloud Storage.
  const putRes = await fetch(upload_url, { method: "PUT", body: file });
  if (!putRes.ok) {
    throw new Error(`Video upload failed (HTTP ${putRes.status})`);
  }

  // 3. Start background analysis of the uploaded object.
  const startRes = await fetch(`${API_BASE}/analyze-session`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders },
    body: JSON.stringify({
      session_id,
      object_name,
      fps: fps ?? 0,
      file_name: file.name,
      user_id: session?.user.id ?? null,
    }),
  });
  if (!startRes.ok) {
    throw new Error(await detailFromResponse(startRes, "Could not start analysis"));
  }
  const body = (await startRes.json()) as { session_id: string };
  return body.session_id;
}

// Subscribe to changes on one session row (Supabase Realtime). Delivery is
// governed by RLS, so a user only gets updates for their own sessions. Returns
// an unsubscribe function.
export function subscribeToSession(
  id: string,
  onChange: (row: SessionRow) => void,
): () => void {
  const channel = supabase
    .channel(`session:${id}`)
    .on(
      "postgres_changes",
      { event: "UPDATE", schema: "public", table: "sessions", filter: `id=eq.${id}` },
      (payload) => onChange(payload.new as SessionRow),
    )
    .subscribe();
  return () => {
    supabase.removeChannel(channel);
  };
}

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
