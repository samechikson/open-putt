import { API_BASE } from "./analysis";
import { auth } from "./firebaseClient";

// Thin wrapper around fetch for backend (Cloud Run) calls. Attaches the current
// user's Firebase ID token as a Bearer header so the backend can verify the
// caller and scope data by user. The DB is no longer reachable from the browser
// directly (as it was with Supabase + RLS); everything goes through here.

async function authHeaders(
  forceRefresh = false,
): Promise<Record<string, string>> {
  // Wait for Firebase to finish restoring any persisted session before reading
  // the user. On a cold page load `auth.currentUser` is briefly null while auth
  // initializes; without this the first request(s) could go out with no token
  // and 401. `authStateReady` resolves immediately once initialization is done.
  await auth.authStateReady();
  const user = auth.currentUser;
  if (!user) return {};
  const token = await user.getIdToken(forceRefresh);
  return { Authorization: `Bearer ${token}` };
}

export async function apiFetch(
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const baseHeaders = (init.headers as Record<string, string>) ?? {};
  const send = async (auth: Record<string, string>) =>
    fetch(`${API_BASE}${path}`, {
      ...init,
      headers: { ...baseHeaders, ...auth },
    });

  const res = await send(await authHeaders());
  // A 401 right after load usually means the token was missing or stale (auth
  // had only just initialized). Force a fresh token and retry once. Every
  // apiFetch body is a string or FormData, so it's safe to replay.
  if (res.status === 401 && auth.currentUser) {
    return send(await authHeaders(true));
  }
  return res;
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
