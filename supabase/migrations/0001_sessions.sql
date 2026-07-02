-- Persistence for putting sessions and their per-putt analytics.
-- One `sessions` row per analyzed video (iOS Recording metadata + session-level
-- analysis + flattened calibration); one `putts` row per detected putt.

-- Enums mirror the app's fixed value sets.
create type putt_break as enum (
  'straight','leftToRight','rightToLeft',
  'uphillStraight','uphillLeftToRight','uphillRightToLeft',
  'downhillStraight','downhillLeftToRight','downhillRightToLeft'
);
create type putt_direction as enum ('left','right','center');
create type scale_source   as enum ('ball_radius','gate_width_override');

create table sessions (
  id                uuid primary key,            -- iOS recording_id (idempotent upsert key)
  user_id           uuid references auth.users on delete cascade,  -- nullable until iOS auth exists
  created_at        timestamptz not null default now(),
  analyzed_at       timestamptz not null default now(),

  -- iOS-captured metadata
  file_name         text,
  captured_at       timestamptz,
  ios_duration_s    double precision,            -- iOS-reported clip duration
  length_feet       int,
  break_type        putt_break,

  -- optional: path to the stored clip in Supabase Storage
  video_path        text,

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
  cal_scale_source  scale_source
);

create table putts (
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
  unique (session_id, putt_index)
);

create index putts_session_id_idx on putts (session_id);
create index sessions_user_captured_idx on sessions (user_id, captured_at desc);

-- RLS: authenticated users see only their own rows; the backend writes with the
-- service_role key, which bypasses RLS.
alter table sessions enable row level security;
alter table putts    enable row level security;

create policy "own sessions" on sessions
  for select using (auth.uid() = user_id);
create policy "own putts" on putts
  for select using (
    exists (select 1 from sessions s where s.id = putts.session_id and s.user_id = auth.uid())
  );
