import { apiFetch, apiJson, detailFromResponse } from "./api";

// Job lifecycle of a session's background analysis.
export type SessionStatus = "queued" | "processing" | "done" | "error";

// A session, as returned by the backend (which scopes every query to the
// signed-in user, so the client never has to filter by user).
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
  putter_id: string | null;
}

// The `putt_break` enum values with human labels, in menu order (mirror of
// backend/db/schema.sql). Used for the session metadata editor
// and for rendering a break type anywhere in the UI.
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

// Re-run analysis on a session's already-uploaded video, on demand. Resets the
// session to 'queued' server-side and reprocesses the retained clip (no
// re-upload); watch it via subscribeToSession for completion, as with an upload.
export async function reanalyzeSession(sessionId: string): Promise<void> {
  const res = await apiFetch(`/sessions/${sessionId}/reanalyze`, {
    method: "POST",
  });
  if (!res.ok) {
    throw new Error(await detailFromResponse(res, "Could not start re-analysis"));
  }
}

// Delete a session and its putts + video via the backend.
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

// A short-lived signed URL to stream a session's retained video.
export async function fetchSessionVideoUrl(sessionId: string): Promise<string> {
  const { url } = await apiJson<{ url: string }>(
    `/sessions/${sessionId}/video`,
    {},
    "Could not load video",
  );
  return url;
}

// Queue a Full Session video for background analysis. Uploads the video straight
// to Cloud Storage via a signed URL (avoiding Cloud Run's request-size limit),
// then starts analysis. Returns the session id; watch it via subscribeToSession
// for completion. The owner is derived from the auth token (attached by
// apiFetch), not sent in the body.
export async function uploadSession(
  file: File,
  fps: number | null,
): Promise<string> {
  // 1. Ask the backend for a signed upload URL.
  const initRes = await apiFetch("/uploads", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
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

  // 2. Upload the video directly to Cloud Storage (the signed URL needs no app
  //    auth, so this is a plain fetch, not apiFetch).
  const putRes = await fetch(upload_url, { method: "PUT", body: file });
  if (!putRes.ok) {
    throw new Error(`Video upload failed (HTTP ${putRes.status})`);
  }

  // 3. Start background analysis of the uploaded object.
  const startRes = await apiFetch("/analyze-session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      session_id,
      object_name,
      fps: fps ?? 0,
      file_name: file.name,
    }),
  });
  if (!startRes.ok) {
    throw new Error(await detailFromResponse(startRes, "Could not start analysis"));
  }
  const body = (await startRes.json()) as { session_id: string };
  return body.session_id;
}

// Watch one session for status changes by polling the backend (replacing the
// old Supabase Realtime subscription — Cloud SQL has no push channel). Invokes
// onChange whenever the status changes, and stops polling once the analysis
// reaches a terminal state. Returns an unsubscribe function.
export function subscribeToSession(
  id: string,
  onChange: (row: SessionRow) => void,
): () => void {
  const POLL_MS = 2500;
  let cancelled = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let lastStatus: SessionStatus | undefined;

  const tick = async () => {
    try {
      const row = await fetchSession(id);
      if (cancelled || !row) return;
      if (row.status !== lastStatus) {
        lastStatus = row.status;
        onChange(row);
      }
      if (row.status === "done" || row.status === "error") return; // terminal
    } catch {
      // transient error; keep polling
    }
    if (!cancelled) timer = setTimeout(tick, POLL_MS);
  };
  timer = setTimeout(tick, POLL_MS);

  return () => {
    cancelled = true;
    if (timer) clearTimeout(timer);
  };
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

// A row from the `putts` table (raw tracking arrays are not persisted).
export interface PuttRow {
  putt_index: number;
  start_s: number | null;
  end_s: number | null;
  offset_mm: number | null;
  direction: string | null;
  speed_mps: number | null;
  track_count: number | null;
  // Source-frame index where the ball crossed the gate (bottom laser). Null for
  // putts analyzed before this was recorded — no crossing still is available.
  crossing_frame: number | null;
  // Per-sensor offsets from the hardware gate (device mounting order; null per
  // sensor that didn't see the ball). Null entirely for video-pipeline putts.
  sensor_offsets_mm: (number | null)[] | null;
}

export async function fetchPutts(sessionId: string): Promise<PuttRow[]> {
  return apiJson<PuttRow[]>(
    `/sessions/${sessionId}/putts`,
    {},
    "Could not load putts",
  );
}

// Parse one Server-Sent Events frame (fields separated by newlines) into its
// event name and joined data. Comment lines (": …", used for heartbeats) and
// dataless frames yield null.
function parseSseFrame(
  frame: string,
): { event: string; data: string } | null {
  let event = "message";
  const dataLines: string[] = [];
  for (const line of frame.split("\n")) {
    if (line === "" || line.startsWith(":")) continue; // blank / comment
    const colon = line.indexOf(":");
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") event = value;
    else if (field === "data") dataLines.push(value);
  }
  if (dataLines.length === 0) return null;
  return { event, data: dataLines.join("\n") };
}

// Watch a session's putts over a Server-Sent Events stream, invoking onChange
// with the full putt list whenever it changes — so new putts appear live (the
// hardware gate appends putts to an already-'done' session one at a time). The
// backend holds one connection and pushes changes (see the /putts/stream
// endpoint), replacing the client-side polling this used to do.
//
// We consume the stream with fetch (via apiFetch, so the Firebase Bearer token
// is attached) rather than the native EventSource, which can't send an auth
// header. A finalized session ends the stream cleanly ('complete'); any other
// drop (a network blip on a live gate session) reconnects after a short delay.
// Returns an unsubscribe function.
export function subscribeToPutts(
  id: string,
  onChange: (rows: PuttRow[]) => void,
): () => void {
  const RETRY_MS = 3000;
  let cancelled = false;
  let controller: AbortController | null = null;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;

  const scheduleRetry = () => {
    if (cancelled) return;
    retryTimer = setTimeout(() => void connect(), RETRY_MS);
  };

  const connect = async () => {
    if (cancelled) return;
    controller = new AbortController();
    // True once the server signals the stream is done (finalized session, or an
    // error like not-found); tells us not to reconnect on the stream's end.
    let done = false;
    try {
      const res = await apiFetch(`/sessions/${id}/putts/stream`, {
        signal: controller.signal,
        headers: { Accept: "text/event-stream" },
      });
      // A 404 means the session or the streaming endpoint isn't there (e.g. a
      // deleted session, or a backend without this route yet) — retrying can't
      // help, so stop. The baseline fetch still renders whatever details exist.
      if (res.status === 404) return;
      if (!res.ok || !res.body) throw new Error(`stream failed (${res.status})`);

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      for (;;) {
        const { value, done: streamDone } = await reader.read();
        if (streamDone) break;
        buffer += decoder.decode(value, { stream: true });
        // Frames are delimited by a blank line; process each complete one.
        let sep: number;
        while ((sep = buffer.indexOf("\n\n")) !== -1) {
          const evt = parseSseFrame(buffer.slice(0, sep));
          buffer = buffer.slice(sep + 2);
          if (!evt || cancelled) continue;
          if (evt.event === "putts") {
            onChange(JSON.parse(evt.data) as PuttRow[]);
          } else if (evt.event === "complete" || evt.event === "error") {
            done = true; // nothing more is coming; don't reconnect
          }
        }
      }
      if (!done) scheduleRetry(); // unexpected end of a live stream
    } catch (e) {
      if (cancelled || (e instanceof DOMException && e.name === "AbortError"))
        return;
      scheduleRetry();
    }
  };

  void connect();

  return () => {
    cancelled = true;
    if (retryTimer) clearTimeout(retryTimer);
    controller?.abort();
  };
}

// Fetch the gate-crossing still for a putt as an object URL. The frame endpoint
// needs the Bearer token (so a bare <img src> can't hit it directly); we fetch
// the JPEG as a blob and wrap it in an object URL. Callers must revoke the URL
// when done (URL.revokeObjectURL) to avoid leaks.
export async function fetchPuttFrameUrl(
  sessionId: string,
  puttIndex: number,
): Promise<string> {
  const res = await apiFetch(`/sessions/${sessionId}/putts/${puttIndex}/frame`);
  if (!res.ok) {
    throw new Error(await detailFromResponse(res, "Could not load frame"));
  }
  return URL.createObjectURL(await res.blob());
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
