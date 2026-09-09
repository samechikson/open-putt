import { useState } from "react";
import {
  createUserWithEmailAndPassword,
  sendPasswordResetEmail,
  signInWithEmailAndPassword,
} from "firebase/auth";
import { auth } from "./firebaseClient";
import Logo from "./Logo";

type Mode = "signin" | "signup";

// Map Firebase auth error codes to friendly messages (fall back to a generic).
function authErrorMessage(err: unknown): string {
  const code =
    typeof err === "object" && err && "code" in err
      ? String((err as { code: unknown }).code)
      : "";
  switch (code) {
    case "auth/invalid-credential":
    case "auth/wrong-password":
    case "auth/user-not-found":
      return "Incorrect email or password.";
    case "auth/email-already-in-use":
      return "That email is already registered. Sign in instead.";
    case "auth/weak-password":
      return "Password must be at least 6 characters.";
    case "auth/invalid-email":
      return "Enter a valid email address.";
    case "auth/too-many-requests":
      return "Too many attempts. Try again later.";
    default:
      return err instanceof Error ? err.message : "Authentication failed";
  }
}

export default function Login() {
  const [mode, setMode] = useState<Mode>("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      if (mode === "signup") {
        await createUserWithEmailAndPassword(auth, email, password);
      } else {
        await signInWithEmailAndPassword(auth, email, password);
      }
      // On success the AuthProvider's listener swaps in the app; nothing to do.
    } catch (err: unknown) {
      setError(authErrorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  // Send a password-reset email (needed by users migrated from Supabase, who
  // must set a new password).
  const resetPassword = async () => {
    if (!email) {
      setError("Enter your email above first, then tap Forgot password.");
      return;
    }
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      await sendPasswordResetEmail(auth, email);
      setNotice("Password reset email sent. Check your inbox.");
    } catch (err: unknown) {
      setError(authErrorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      style={{
        minHeight: "100svh",
        background: "var(--color-bg)",
        color: "var(--color-text)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 40,
      }}
    >
      <div style={{ width: "100%", maxWidth: 360 }}>
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            gap: 10,
            marginBottom: 28,
          }}
        >
          <Logo size={44} />
          <div style={{ fontFamily: "var(--font-heading)", fontSize: 26 }}>
            Open Putt
          </div>
          <div style={{ fontSize: 14, color: "var(--color-neutral-700)" }}>
            {mode === "signin"
              ? "Sign in to your account"
              : "Create an account"}
          </div>
        </div>

        <form
          onSubmit={submit}
          className="card elev-md"
          style={{ gap: 16 }}
        >
          <div className="field">
            <label htmlFor="login-email">Email</label>
            <input
              id="login-email"
              className="input"
              type="email"
              required
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </div>

          <div className="field">
            <label htmlFor="login-password">Password</label>
            <input
              id="login-password"
              className="input"
              type="password"
              required
              minLength={6}
              autoComplete={
                mode === "signin" ? "current-password" : "new-password"
              }
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </div>

          {error && (
            <p style={{ margin: 0, fontSize: 13, color: "var(--color-accent-800)" }}>
              {error}
            </p>
          )}
          {notice && (
            <p style={{ margin: 0, fontSize: 13, color: "var(--color-accent-2-700)" }}>
              {notice}
            </p>
          )}

          <button
            type="submit"
            disabled={busy}
            className="btn btn-primary btn-block"
          >
            {busy
              ? "Working…"
              : mode === "signin"
                ? "Sign in"
                : "Sign up"}
          </button>
        </form>

        {mode === "signin" && (
          <div style={{ textAlign: "center", marginTop: 14, fontSize: 13 }}>
            <button
              type="button"
              onClick={resetPassword}
              disabled={busy}
              className="nav-link"
              style={{ color: "var(--color-accent-700)" }}
            >
              Forgot password?
            </button>
          </div>
        )}

        <div
          style={{
            textAlign: "center",
            marginTop: 12,
            fontSize: 14,
            color: "var(--color-neutral-700)",
          }}
        >
          {mode === "signin" ? "No account? " : "Already have an account? "}
          <button
            type="button"
            onClick={() => {
              setMode(mode === "signin" ? "signup" : "signin");
              setError(null);
              setNotice(null);
            }}
            className="nav-link"
            style={{ color: "var(--color-accent-700)", fontWeight: 600 }}
          >
            {mode === "signin" ? "Sign up" : "Sign in"}
          </button>
        </div>
      </div>
    </div>
  );
}
