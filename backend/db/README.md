# Firestore data model

Persistence is **Firestore (Native mode)**. The backend (`backend/app/db.py`) is
the only client — it connects with the Admin SDK (service-account credentials on
Cloud Run; the Firestore **emulator** locally), which bypasses security rules, so
ownership is enforced in application code by a `user_id` (the Firebase UID) on
every document. `firestore.rules` therefore denies all *direct* client access.

There is no schema/migration file: Firestore is schemaless, and this project
migrated off Postgres (the old `supabase/migrations/` + `db/schema.sql` are gone;
existing data was disposable test data). See `docs/migration-firestore.md`.

## Collections

### `putters/{putterId}`
`putterId` is a uuid4 generated on create. One doc per user-owned club.

| field | notes |
|-------|-------|
| `user_id` | Firebase UID (owner) |
| `name` | required |
| `brand`, `model`, `length_in`, `lie_deg`, `grip` | optional spec |
| `is_active` | at most one `true` per user (enforced in `set_active_putter`) |
| `created_at` | server timestamp |

### `sessions/{sessionId}`
`sessionId` is the iOS session UUID — the idempotent upsert key. One doc per
hardware-gate session; it's created (already complete) on the session's first
relayed putt and gains putts as the player putts.

Fields: `user_id`, `created_at` (server ts), `length_feet`, `break_type`,
`putt_count` (denormalized), and `putter_id` (nulled when the putter is deleted).
`length_feet` / `break_type` / `putter_id` are set via `PATCH /sessions/{id}`.

### `putts/{sessionId_index}`
A **top-level** collection (not a subcollection). The doc id is
`"{session_id}_{putt_index}"`, which makes the hardware gate's per-(session,
index) upsert naturally idempotent. Each doc denormalizes `session_id` and
`user_id` from its session so putts can be queried and ownership-checked without
a join.

Fields: `session_id`, `user_id`, `putt_index`, `offset_mm`, `direction`,
`speed_mps` (null when the ball tripped only one sensor), and `sensor_offsets_mm`
(the per-sensor offsets behind the average).

## Query strategy (no composite indexes)

Every query filters on a **single** field (equality) and does any remaining
ordering / secondary filtering in Python — session and putt counts per user are
small. That's why `firestore.indexes.json` is empty: Firestore auto-creates the
single-field indexes these queries need.

**If you change a returned field set, update it in all three places:** `db.py`'s
`_*_FIELDS`, and the frontend TS types (`sessions.ts` / `putters.ts` /
`analysis.ts`).
