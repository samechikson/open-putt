-- Revert the per-putt review-clip feature: the iOS app no longer records video,
-- so the column is unused. (Retained clips, if any, are left in Cloud Storage to
-- expire via the bucket lifecycle rule; nothing references them anymore.)

alter table putts drop column if exists video_path;
