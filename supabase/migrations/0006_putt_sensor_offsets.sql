-- Persist the per-sensor offset readings from the hardware gate. Each device
-- putt is measured by three in-line ToF sensors; storing each sensor's offset
-- (not just the average) allows inspecting agreement/outliers between sensors.
-- A JSON array of numbers (or null where a sensor didn't see the ball), in the
-- device's mounting order. Video-pipeline putts have no per-sensor data and stay
-- NULL.

alter table putts add column if not exists sensor_offsets_mm jsonb;
