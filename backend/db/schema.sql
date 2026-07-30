-- Consolidated PostgreSQL schema for the Putting Gate app.
--
-- The live database is Supabase Postgres (evolved via supabase/migrations/,
-- through 0004 which brings it to this shape). This single file is the
-- equivalent greenfield schema — handy for spinning up a local Postgres for
-- tests. It drops the Supabase-specific pieces, since the backend is now the
-- only DB client (no GoTrue/PostgREST/RLS in the request path):
--   * user_id is `text` (Firebase UIDs are strings, not UUIDs) and has no FK to
--     an `auth.users` table (there is none here).
--   * No Row-Level Security / policies — the backend is the only DB client and
--     enforces ownership in every query (WHERE user_id = $uid).
--   * No `set_active_putter()` function (done as a backend transaction) and no
--     Realtime publication (the frontend polls the session status endpoint).
-- Everything else — enums, constraints, indexes, FKs between our own tables — is
-- kept as-is. Idempotent so it can be re-applied safely.

create extension if not exists pgcrypto;  -- gen_random_uuid()

-- ---- Enums (mirror the app's fixed value sets) -----------------------------
do $$ begin
  create type putt_break as enum (
    'straight','leftToRight','rightToLeft',
    'uphillStraight','uphillLeftToRight','uphillRightToLeft',
    'downhillStraight','downhillLeftToRight','downhillRightToLeft'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type putt_direction as enum ('left','right','center');
exception when duplicate_object then null; end $$;

do $$ begin
  create type scale_source as enum ('ball_radius','gate_width_override');
exception when duplicate_object then null; end $$;

do $$ begin
  create type session_status as enum ('queued','processing','done','error');
exception when duplicate_object then null; end $$;

-- ---- putters ---------------------------------------------------------------
-- User-owned clubs. Created before `sessions` because sessions.putter_id
-- references this table.
create table if not exists putters (
  id         uuid primary key default gen_random_uuid(),
  user_id    text not null,                    -- Firebase UID
  name       text not null,

  -- optional spec
  brand      text,
  model      text,
  length_in  double precision,   -- shaft length, inches
  lie_deg    double precision,   -- lie angle, degrees
  grip       text,               -- free-text grip description

  is_active  boolean not null default false,   -- the user's default putter
  created_at timestamptz not null default now()
);

create index if not exists putters_user_id_idx on putters (user_id);

-- At most one active putter per user (partial unique index over the flag).
create unique index if not exists putters_one_active_per_user
  on putters (user_id) where is_active;

-- ---- sessions --------------------------------------------------------------
-- One row per analyzed video. `id` = the iOS recording UUID (idempotent upsert
-- key). Written only by the backend.
create table if not exists sessions (
  id                uuid primary key,            -- iOS recording_id
  user_id           text,                        -- Firebase UID; null for legacy rows

  created_at        timestamptz not null default now(),
  analyzed_at       timestamptz not null default now(),

  -- iOS-captured metadata
  file_name         text,
  captured_at       timestamptz,
  ios_duration_s    double precision,            -- iOS-reported clip duration
  length_feet       int,
  break_type        putt_break,

  -- path to the retained clip in Cloud Storage
  video_path        text,

  -- background-analysis lifecycle
  status            session_status not null default 'done',
  error             text,

  -- session-level analysis
  fps               double precision,
  frame_count       int,
  duration_s        double precision,            -- analysis-derived duration
  segments_detected int,
  putt_count        int not null default 0,      -- denormalized len(putts)

  -- flattened calibration block
  cal_gate_center_x int,
  cal_gate_line_y   int,
  cal_aim_top_x     double precision,            -- null when top laser dot missing
  cal_aim_top_y     double precision,
  cal_ball_radius_px double precision,
  cal_mm_per_px     double precision,
  cal_frame         int,
  cal_scale_source  scale_source,

  -- tagged putter; set null so deleting a putter leaves its sessions un-tagged
  putter_id         uuid references putters on delete set null
);

create index if not exists sessions_user_captured_idx
  on sessions (user_id, captured_at desc);
create index if not exists sessions_putter_id_idx on sessions (putter_id);

-- ---- putts -----------------------------------------------------------------
-- One row per detected putt within a session.
create table if not exists putts (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references sessions on delete cascade,
  putt_index   int  not null,                    -- result "index" within the session
  start_frame  int, end_frame int,
  start_s      double precision, end_s double precision,
  offset_px    double precision,
  offset_mm    double precision,
  direction    putt_direction,
  speed_mps    double precision,                 -- nullable (may be absent)
  track_count  int,
  crossing_x   double precision,                 -- from crossing_pos[0]
  crossing_y   double precision,                 -- from crossing_pos[1]
  crossing_frame int,                            -- source-frame index at the gate crossing
  sensor_offsets_mm jsonb,                        -- per-sensor offsets (hardware gate); null for video putts
  video_path   text,                             -- per-putt review clip (hardware gate); null for video putts
  unique (session_id, putt_index)
);

create index if not exists putts_session_id_idx on putts (session_id);
