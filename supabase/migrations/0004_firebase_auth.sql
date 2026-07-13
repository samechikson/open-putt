-- Move to backend-mediated access with Firebase Auth as the identity provider,
-- while keeping the data here in Supabase Postgres.
--
-- The browser and iOS app no longer connect to Postgres directly (they used to,
-- under RLS): the backend is now the only DB client. It connects as the service
-- role (bypassing RLS) and enforces ownership itself with `where user_id = $uid`.
-- Auth moved from Supabase to Firebase, so `user_id` is now a Firebase UID (an
-- arbitrary string, not a UUID) with no foreign key to `auth.users`.

-- 1. Drop the client-facing RLS policies — unused now, and they reference
--    auth.uid() / the uuid user_id we're about to widen. RLS stays enabled (so
--    the anon key, if ever used, sees nothing); the service role bypasses it.
drop policy if exists "own sessions" on sessions;
drop policy if exists "own putts" on putts;
drop policy if exists "own putters read" on putters;
drop policy if exists "own putters insert" on putters;
drop policy if exists "own putters update" on putters;
drop policy if exists "own putters delete" on putters;

-- 2. The atomic active-putter switch now lives in the backend (a transaction in
--    app/db.py), and the old function relied on auth.uid().
drop function if exists set_active_putter(uuid);

-- 3. Drop the FKs to auth.users and widen user_id to text (Firebase UIDs).
--    Existing UUID values cast cleanly to text and still match the migrated
--    Firebase users, which are imported with localId = their old Supabase UUID.
--    (Dependent indexes on user_id are rebuilt automatically by the type change.)
alter table sessions drop constraint if exists sessions_user_id_fkey;
alter table putters  drop constraint if exists putters_user_id_fkey;
alter table sessions alter column user_id type text using user_id::text;
alter table putters  alter column user_id type text using user_id::text;
