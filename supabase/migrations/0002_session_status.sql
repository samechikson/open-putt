-- Async analysis: sessions are created up-front (status 'queued') and processed
-- in the background, so the API can return immediately instead of holding a
-- multi-minute request open. The frontend watches the row via Realtime.

create type session_status as enum ('queued', 'processing', 'done', 'error');

alter table sessions
  add column status session_status not null default 'done',  -- existing rows predate async → treat as done
  add column error  text;                                     -- human-readable failure message when status = 'error'

-- Stream sessions row changes to subscribed clients (Realtime Postgres Changes).
-- Delivery is still governed by the existing "own sessions" RLS select policy,
-- so users only receive updates for their own sessions.
alter publication supabase_realtime add table sessions;
