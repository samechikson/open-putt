# Migration: Postgres (Supabase) → Firestore

This runbook records the move of the Open Putt backend's **persistence layer**
off Supabase Postgres onto **Firestore (Native mode)**. Firebase Auth was already
in place (see `migration-firebase-auth.md`); this change only swaps the database.
Existing data was disposable test data and was **not** migrated — the Postgres
database can be torn down.

> **Follow-up (video pipeline removed).** Shortly after this migration, the
> deprecated **video / OpenCV upload path was removed entirely** — putts are now
> ingested only from the hardware gate (relayed by the iOS app to
> `POST /api/device/putts`). See the [dedicated section below](#follow-up-removing-the-video-pipeline)
> for exactly what that deleted. The Firestore field lists in this document
> describe the *interim* shape; the current gate-only shape is in
> `backend/db/README.md`.

## What changed

- **`backend/app/db.py`** — rewritten on the Firestore Admin SDK
  (`google-cloud-firestore`). Every public function keeps its **exact signature
  and return shape**, so `main.py`, the frontend, and iOS are unchanged.
- **Data model** — three collections (`putters`, `sessions`, top-level `putts`);
  see `backend/db/README.md`. Ownership is a `user_id` field on every doc, checked
  in application code (the Admin SDK bypasses security rules).
- **`requirements.txt`** — dropped `psycopg[binary,pool]`, added an explicit
  `google-cloud-firestore` (also pulled in transitively by `firebase-admin`).
- **`start.sh`** — runs the **Firestore emulator** locally instead of Postgres.
- **`firebase.json` / `firestore.rules` / `firestore.indexes.json`** — added
  Firestore config: deny-all client rules, no composite indexes, emulator on
  `:8080`.
- **`backend/deploy/cloud-run.sh`** — enables `firestore.googleapis.com`, creates
  the Native database, grants the runtime SA `roles/datastore.user`, and drops the
  `DATABASE_URL` secret.
- **Removed** — `supabase/migrations/`, `backend/db/schema.sql`, and every
  `DATABASE_URL` / `psycopg` reference.

## Config differences

| | Postgres (before) | Firestore (after) |
|---|---|---|
| Client | `psycopg` pool from `DATABASE_URL` | Firestore Admin SDK (ADC + project id) |
| Prod auth to DB | `DATABASE_URL` secret | runtime SA + `roles/datastore.user` |
| Prod project id | — | `GOOGLE_CLOUD_PROJECT` (auto on Cloud Run) / `FIREBASE_PROJECT_ID` |
| Local dev | local Postgres | Firestore emulator (`FIRESTORE_EMULATOR_HOST`) |
| Schema | `db/schema.sql` + migrations | schemaless; model in `db/README.md` |

`db.py` is **fail-soft**: with no project id and no emulator host it no-ops, so
analysis still runs locally without persistence.

## Local development

1. Install the Firebase CLI and a Java runtime:
   ```bash
   npm i -g firebase-tools
   # Java: e.g. `brew install openjdk` on macOS
   ```
2. Run the stack — `start.sh` boots the emulator and wires it up automatically:
   ```bash
   ./start.sh
   ```
   The emulator listens on `localhost:8080`; the backend picks it up via
   `FIRESTORE_EMULATOR_HOST`. Emulator data is in-memory (wiped on stop).

## Deploying to production

`bash backend/deploy/cloud-run.sh` now provisions Firestore end to end:

- enables `firestore.googleapis.com`;
- `gcloud firestore databases create --location=<region> --type=firestore-native`
  (one-time; the location is **permanent**);
- grants `roles/datastore.user` to the runtime service account;
- deploys with `FIREBASE_PROJECT_ID` / `GCP_PROJECT` set (Cloud Run also injects
  `GOOGLE_CLOUD_PROJECT`), and **no** `DATABASE_URL` secret.

A code-only redeploy is still `bash backend/deploy/cloud-run.sh --fast`.

## Notes / gotchas

- **No composite indexes.** Queries filter a single field and sort/filter the rest
  in Python (`db.py`). If you ever add a query with two field constraints or a
  server-side `order_by` on a different field, Firestore will demand a composite
  index — add it to `firestore.indexes.json` and `firebase deploy --only
  firestore:indexes`, or prefer the single-field + Python pattern.
- **Deletes cascade in code.** Firestore has no `ON DELETE CASCADE`; deleting a
  session removes its putts via `_delete_putts_for_session`.
- **`putt_count`** is recomputed by counting putt docs after each ingest/delete.
- **Timestamps.** `created_at` is a server timestamp; reads convert it to ISO-8601,
  matching the old Postgres→FastAPI JSON shape, so the frontend needs no change.

## Follow-up: removing the video pipeline

The video / OpenCV upload path was **deprecated and then removed** — a player never
uploads a clip; every putt is measured by the hardware gate and relayed by the iOS
app to `POST /api/device/putts`. Sessions are now gate-only. What was deleted:

- **Backend code** — `analyzer.py` (the OpenCV pipeline), `segmenter.py` (motion
  helpers), `cloud.py` (Cloud Storage + Cloud Tasks helpers), and `backend/scripts/`
  (CV debugging scripts). `main.py` lost every video endpoint (`/analyze`,
  `/uploads`, `/analyze-session`, `/process`, `/sessions/{id}/reanalyze`,
  `/sessions/{id}/video`, `/sessions/{id}/putts/{i}/frame`, `/detect-ball`,
  `/calibration-check`, `/local-storage/*`) and `db.py` lost the video write path
  (`persist_session`, `create_pending_session`, `set_session_status`,
  `begin_reanalysis`, `get_session_video_path`, `get_putt_crossing_frame`).
- **Dependencies** — `opencv-contrib-python-headless`, `numpy`,
  `google-cloud-storage`, `google-cloud-tasks`, and `python-multipart` dropped from
  `requirements.txt`; `ffmpeg` dropped from the `Dockerfile`.
- **Data model slimmed** — sessions kept `created_at`, `length_feet`, `break_type`,
  `putt_count`, `putter_id` (dropped `captured_at`, `file_name`, `video_path`,
  `status`/`error`, `fps`/`frame_count`/`duration_s`/`segments_detected`, and the
  `cal_*` block). Putts kept `putt_index`, `offset_mm`, `direction`, `speed_mps`,
  `sensor_offsets_mm` (dropped `start_s`/`end_s`, `track_count`, `crossing_frame`,
  and the raw pixel fields). See `backend/db/README.md` for the current shape.
- **Infra** — `cloud-run.sh` no longer provisions the GCS bucket, Cloud Tasks
  queue, lifecycle rules, signer-SA IAM, or the `TASKS_INTERNAL_TOKEN` secret
  (existing cloud resources aren't torn down by the script — delete those by hand).
- **Frontend** — deleted `AnalyzeView`, `SessionUploader`, `VideoCard`; the web app
  is now a read/review surface (no upload/analyze/video-playback UI).
- **iOS** — `SessionRow` dropped the `status` / `captured_at` fields it decoded.

If you need the old video code, it's in the git history prior to this change.

## Follow-up: clients moved onto the Firebase SDK

After the above, both apps were taken **off the backend API** and onto the Firebase
SDK, talking to Firestore directly (scoped by `firestore.rules`). The backend now
only serves the legacy ESP32 direct-post ingest path.

- **`firestore.rules`** — went from deny-all → per-user: a signed-in user may
  read/write (and, for the iOS ingest, *create*) docs whose `user_id` is their uid.
  Rules changes take effect only on `firebase deploy --only firestore:rules` — the
  hosting workflow does **not** deploy them.
- **Web app** — `sessions.ts` / `putters.ts` rewritten on the Web SDK; `api.ts`
  (the Bearer-token fetch wrapper) deleted. The web app makes no backend calls.
- **iOS app** — added the `FirebaseFirestore` SPM product (wired by hand in
  `project.pbxproj`, mirroring `FirebaseAuth`). `SessionMetadataService` became the
  Firestore data layer (reads + `apply` + `deletePutt` + **`ingest`**); the ingest
  ports the old backend logic — session upsert, the `offset_mm` / per-sensor
  **sign-inversion**, and the recomputed `putt_count`. `GatePuttRelay` and
  `AppSettings` (backend URLs) were deleted; the model structs
  (`SessionRow` / `SessionPutt` / `Putter`) now build from `DocumentSnapshot`.

**Verifying the iOS build:** the `project.pbxproj` package edit can't be compiled
outside Xcode — open the project, let SPM resolve `firebase-ios-sdk`, and build. If
resolution fails, remove/re-add the `FirebaseFirestore` product via the target's
**Frameworks, Libraries, and Embedded Content** and rebuild.
