-- Putters: the clubs a user putts with. Each user owns their own putters, can
-- associate a session with one, and marks one as their "active" putter (the
-- default selection when tagging a session).
--
-- Unlike `sessions`/`putts` (written only by the backend service role, with
-- select-only RLS on the client), putters are simple user-owned rows with no
-- storage/pipeline concerns, so the browser reads AND writes them directly under
-- RLS scoped to auth.uid() = user_id.

create table putters (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade,
  name       text not null,

  -- optional spec
  brand      text,
  model      text,
  length_in  double precision,   -- shaft length, inches
  lie_deg    double precision,   -- lie angle, degrees
  grip       text,               -- free-text grip description

  is_active  boolean not null default false,  -- the user's default putter
  created_at timestamptz not null default now()
);

create index putters_user_id_idx on putters (user_id);

-- At most one active putter per user (partial unique index over the flag).
create unique index putters_one_active_per_user
  on putters (user_id) where is_active;

-- Associate a session with a putter. Nullable, and `set null` so deleting a
-- putter leaves its sessions intact (just un-tagged).
alter table sessions
  add column putter_id uuid references putters on delete set null;

create index sessions_putter_id_idx on sessions (putter_id);

-- RLS: owners can read and write their own putters (mirror of the "own sessions"
-- select policy, extended with insert/update/delete since the client writes here).
alter table putters enable row level security;

create policy "own putters read"   on putters
  for select using (auth.uid() = user_id);
create policy "own putters insert" on putters
  for insert with check (auth.uid() = user_id);
create policy "own putters update" on putters
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own putters delete" on putters
  for delete using (auth.uid() = user_id);

-- Atomically switch the active putter. Clearing the old active row first avoids
-- transiently violating putters_one_active_per_user. Security-invoker so the
-- caller's RLS (auth.uid()) still applies; the explicit user_id filters are a
-- belt-and-suspenders guard.
create function set_active_putter(p_putter_id uuid) returns void
language plpgsql security invoker as $$
begin
  update putters set is_active = false
    where user_id = auth.uid() and is_active;
  update putters set is_active = true
    where id = p_putter_id and user_id = auth.uid();
end;
$$;
