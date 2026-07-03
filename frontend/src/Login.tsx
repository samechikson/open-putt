import { useState } from "react";
import { supabase } from "./supabaseClient";

type Mode = "signin" | "signup";

export default function Login() {
  const [mode, setMode] = useState<Mode>("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Shown after sign-up when Supabase requires email confirmation.
  const [notice, setNotice] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      if (mode === "signup") {
        const { data, error } = await supabase.auth.signUp({ email, password });
        if (error) throw error;
        // If email confirmation is on, there's no session yet — tell the user.
        if (!data.session) {
          setNotice("Check your email to confirm your account, then sign in.");
          setMode("signin");
        }
      } else {
        const { error } = await supabase.auth.signInWithPassword({
          email,
          password,
        });
        if (error) throw error;
      }
      // On success the AuthProvider's listener swaps in the app; nothing to do.
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Authentication failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-[#0d0d0d] text-[#d0d0d0] flex items-center justify-center px-4">
      <div className="w-full max-w-sm">
        <h1 className="text-2xl font-bold text-white mb-1 text-center">
          Putting Gate
        </h1>
        <p className="text-sm text-[#888] mb-6 text-center">
          {mode === "signin"
            ? "Sign in to your account"
            : "Create an account"}
        </p>

        <form
          onSubmit={submit}
          className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 flex flex-col gap-3"
        >
          <label className="text-xs font-semibold uppercase tracking-widest text-[#aaa]">
            Email
            <input
              type="email"
              required
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="mt-1 block w-full bg-[#111] border border-[#444] rounded-md text-sm text-white px-3 py-2 normal-case tracking-normal font-normal"
            />
          </label>

          <label className="text-xs font-semibold uppercase tracking-widest text-[#aaa]">
            Password
            <input
              type="password"
              required
              minLength={6}
              autoComplete={
                mode === "signin" ? "current-password" : "new-password"
              }
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="mt-1 block w-full bg-[#111] border border-[#444] rounded-md text-sm text-white px-3 py-2 normal-case tracking-normal font-normal"
            />
          </label>

          {error && <p className="text-xs text-[#f87171]">{error}</p>}
          {notice && <p className="text-xs text-[#22c55e]">{notice}</p>}

          <button
            type="submit"
            disabled={busy}
            className="mt-1 px-4 py-2 bg-[#22c55e] hover:bg-[#16a34a] disabled:opacity-50 disabled:cursor-not-allowed rounded-lg text-sm text-black font-semibold transition-all cursor-pointer"
          >
            {busy
              ? "Working…"
              : mode === "signin"
                ? "Sign in"
                : "Sign up"}
          </button>
        </form>

        <p className="text-sm text-[#888] mt-4 text-center">
          {mode === "signin" ? "No account?" : "Already have an account?"}{" "}
          <button
            type="button"
            onClick={() => {
              setMode(mode === "signin" ? "signup" : "signin");
              setError(null);
              setNotice(null);
            }}
            className="text-[#22c55e] hover:underline cursor-pointer"
          >
            {mode === "signin" ? "Sign up" : "Sign in"}
          </button>
        </p>
      </div>
    </div>
  );
}
