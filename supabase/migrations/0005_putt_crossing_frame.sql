-- Record the source-frame index where each putt crossed the gate (the bottom
-- laser line). The analyzer already computed this crossing frame but discarded
-- it; persisting it lets the frontend show a still of the moment the ball
-- crossed. Existing rows predate this and stay NULL (no still is shown for them
-- until the session is re-analyzed).

alter table putts add column if not exists crossing_frame int;
