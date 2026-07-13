import { API_BASE } from "./analysis";
import { auth } from "./firebaseClient";

// Thin wrapper around fetch for backend (Cloud Run) calls. Attaches the current
// user's Firebase ID token as a Bearer header so the backend can verify the
// caller and scope data by user. The DB is no longer reachable from the browser
// directly (as it was with Supabase + RLS); everything goes through here.

async function authHeaders(): Promise<Record<string, string>> {
  const user = auth.currentUser;
  if (!user) return {};
  const token = await user.getIdToken();
  return { Authorization: `Bearer ${token}` };
}

export async function apiFetch(
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    ...((init.headers as Record<string, string>) ?? {}),
    ...(await authHeaders()),
  };
  return fetch(`${API_BASE}${path}`, { ...init, headers });
}

// Pull a human message out of an error response body ({detail: ...}).
export async function detailFromResponse(
  res: Response,
  fallback: string,
): Promise<string> {
  try {
    const body = await res.json();
    if (body?.detail) return body.detail as string;
  } catch {
    // non-JSON body; use the fallback
  }
  return fallback;
}

// GET/POST JSON helper: sends/receives JSON and throws on !ok with the server's
// detail message.
export async function apiJson<T>(
  path: string,
  init: RequestInit = {},
  errorFallback = "Request failed",
): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...((init.headers as Record<string, string>) ?? {}),
  };
  const res = await apiFetch(path, { ...init, headers });
  if (!res.ok) throw new Error(await detailFromResponse(res, errorFallback));
  return (await res.json()) as T;
}
