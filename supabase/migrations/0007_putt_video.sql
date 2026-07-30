-- Per-putt review video. Each putt from the hardware gate can carry a short clip
-- (the ~2 s of iPhone footage before the ball crossed), stored in Cloud Storage
-- under the retained `sessions/` prefix. Video-pipeline putts don't use this
-- (their footage is the session video) and stay NULL.

alter table putts add column if not exists video_path text;
