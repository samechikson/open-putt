import { createClient } from "@supabase/supabase-js";

// Public (anon/publishable) Supabase config. These are safe to ship to the
// browser — row-level security governs what the key can actually do. Values come
// from Vite env (see .env.local locally, Vercel env vars in production).
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as
  | string
  | undefined;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    "Missing VITE_SUPABASE_URL or VITE_SUPABASE_ANON_KEY. Set them in " +
      "frontend/.env.local (dev) and the Vercel project env (prod).",
  );
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey);
