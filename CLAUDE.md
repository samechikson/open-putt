# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

**Putting Gate** is a golf putting-analysis app. A player rolls a putt through a
physical "laser gate" (a laser dot defining where the ball crosses); the app
measures how far off-center the ball crossed and reports a push/pull bias (in mm)
and speed.

There are **two ways to measure a putt**, both feeding one shared backend and DB:

1. **Hardware gate (primary path today).** A 3D-printed bridge gate with a laser
   and three ToF distance sensors, driven by an ESP32, measures the offset
   on-device and sends each putt over **Bluetooth (BLE)** to the iOS app, which
   relays it to the backend. No video, no CV analysis pass.
2. **Video / computer vision.** A player films a putt and uploads the clip (from
   the web app); the backend runs an **OpenCV** pipeline that auto-calibrates the
   gate from the footage and measures each putt's crossing offset/direction/speed.

Both paths produce the same `sessions` → `putts` data and share history/stats.

The components:

- **`backend/`** — Python / FastAPI service. Does the computer-vision analysis
  (OpenCV), ingests hardware-gate putts, and is the **sole database client** and
  the **sole storage/auth broker**.
- **`frontend/`** — React 19 + TypeScript + Vite + Tailwind v4 web app. Upload a
  clip, view sessions/putts, manage putters. Served by Firebase Hosting.
- **`ios/`** — SwiftUI app (`PuttingGate`). A **BLE central** that pairs with the
  hardware gate, relays each putt to the backend, and shows history/settings.
- **`microcontroller/`** — ESP32 (Arduino C++) firmware for the physical laser
  gate + ToF sensors. See its own `README.md` for wiring, geometry, and BLE.

Plus `supabase/migrations/` (DB migration history), `backend/db/schema.sql`
(consolidated greenfield schema), and `docs/` (operator runbooks). A top-level
`README.md` gives the human-facing overview.

## Architecture at a glance

```
Hardware gate (ESP32) ─BLE→ iOS app ─┐                        ┌─ Cloud Storage (GCS)  [video]
                                     ├─→ Firebase Hosting  ────┤
Web app (upload clip) ───────────────┘   /api/** rewrite,     ├─ Cloud Run: FastAPI ──→ Postgres (Supabase)
                                         same-origin           │      │
                                     ┌─ Firebase Auth          │      └─→ Cloud Tasks ──→ POST /api/process (worker)
                                     └─ (ID-token verify)      └───────
```

Key facts that shape everything:

- **The backend is the only thing that touches the database.** The browser and
  iOS clients never talk to Postgres directly (and the gate reaches it only via
  the iOS relay). Every read/write goes through a FastAPI endpoint that verifies a
  Firebase ID token and scopes the query by `user_id` (the Firebase UID) —
  `WHERE user_id = $uid`. There is no Row-Level Security; ownership is enforced in
  application SQL.
- **The API is mounted under `/api`.** `backend/app/main.py` defines routes on an
  inner app and mounts it at `/api` on the served `application`. Firebase Hosting
  rewrites `/api/**` to the Cloud Run service, so the web app makes **same-origin**
  calls (no CORS in prod). Every caller uses the `/api` prefix: web
  (`VITE_API_BASE=/api`), iOS (`AppSettings.backendBaseURL` ends in `/api`), and
  the Cloud Tasks callback (`PROCESS_URL=.../api/process`).
- **Video analysis is async and CPU-bound.** Clients upload the video straight to
  storage (signed URL), then call `/analyze-session`, which creates a `queued`
  session row and hands the work to Cloud Tasks. A separate `/process` request
  (which owns a full CPU allocation) runs the OpenCV pipeline and drives the row
  to `done`/`error`. Clients **poll** `GET /api/sessions/{id}` for status.
- **Hardware-gate putts skip all of that.** They arrive already-measured over BLE
  and are persisted directly via `POST /api/device/putts` (`main.py`) — no video,
  no Cloud Tasks, no analysis pass, no polling. They carry per-sensor offsets.
- **Video lifecycle:** clips upload to the transient `uploads/` prefix (deleted
  after 1 day). On any terminal outcome — success *or* domain error — the clip is
  copied to the retained `sessions/` prefix (kept 90 days) so no captured putt is
  ever lost. Retained video is streamed back via short-lived signed GET URLs.

### Migration history (important context)

This project **migrated off Supabase Auth/PostgREST/RLS to Firebase Auth**, while
**keeping the database on Supabase Postgres** (reached directly via `psycopg`
through Supabase's connection pooler as the service role). Infra references were
also moved from Vercel/Fly/Cloud SQL to **Firebase Hosting + Cloud Run**. See
`docs/migration-firebase-auth.md` for the full runbook. When you see "Supabase"
in the code, it almost always means "the Postgres database," not auth/PostgREST.

## Backend (`backend/app/`)

| File | Responsibility |
|------|----------------|
| `main.py` | FastAPI app, all HTTP endpoints, the async analysis orchestration (`_process_session`, local vs. Cloud Tasks worker paths), and the `POST /device/putts` BLE-gate ingest. Mounts the API under `/api`. |
| `analyzer.py` | The OpenCV pipeline: auto-calibrate the gate + scale from the video, segment by motion, measure each putt's crossing offset/direction/speed. Public entrypoints: `analyze_putt`, `analyze_session`, `detect_ball_in_frame`, `check_calibration_frame`. Raises `CalibrationError`. |
| `segmenter.py` | Motion analysis helpers: `motion_levels`, `segment_motion`, `quiet_frames` (used to find still frames for calibration and to split a multi-putt clip). |
| `db.py` | The **only** Postgres client. `psycopg` connection pool (lazy, fail-soft). All ownership-scoped queries. Column lists (`_SESSION_COLS`, etc.) are kept in sync with the frontend TS types. |
| `cloud.py` | Google Cloud helpers (Cloud Storage + Cloud Tasks) with a **local-mode** fallback that uses local disk + in-process analysis. Mode-aware API: `object_exists`, `download_to_temp`, `copy_object`, `upload_url_for`, `enqueue_process_task`, etc. |
| `auth.py` | `require_user` FastAPI dependency → returns the Firebase UID. In local dev `AUTH_DEV_UID` short-circuits verification. |

### Conventions

- **Blocking work runs in a threadpool.** The OpenCV analysis and every `psycopg`
  / GCS call are synchronous and blocking; endpoints wrap them in
  `run_in_threadpool(...)` so the event loop stays responsive.
- **Fail-soft persistence.** If no DB is configured, `db.py` functions no-op /
  return empty so local analysis still works without a database.
- **Lazy, optional clients.** `db.py`, `cloud.py`, and `auth.py` all create their
  Google/Firebase/psycopg clients lazily so the module imports cleanly with no
  config (e.g. in tests).
- **Uploads are streamed** in 1 MiB chunks (never `await upload.read()` whole) —
  session clips are 200 MB+.
- **`/process` is internal.** It's authenticated by a constant-time comparison
  against `TASKS_INTERNAL_TOKEN` in the `X-Tasks-Token` header. It returns 200 for
  terminal outcomes (so Cloud Tasks stops) and 500 for infra errors (so it
  retries, up to `TASKS_MAX_RETRIES`).
- **Idempotent by session id.** The session `id` is the iOS recording/session
  UUID. Re-uploads/re-analysis upsert the row and replace the putts wholesale.

## Frontend (`frontend/src/`)

React 19, TypeScript, Vite 8, Tailwind CSS v4 (via `@tailwindcss/vite`), Oxlint.
No router — `App.tsx` does lightweight view switching (`dashboard` / `analyze` /
`session` / `putters`).

- `api.ts` — `apiFetch` / `apiJson` wrappers that attach the Firebase ID token as
  a `Bearer` header. **All backend access goes through here.**
- `analysis.ts` — shared types (`SessionResult`, `SessionPutt`, `CalibrationValues`,
  …), `API_BASE` (default `/api`), fps helpers, and the golfer-perspective
  offset/side helpers (`golferSide`, `biasWord`). Note the **face-on mirror**: the
  camera films face-on, so the backend's image-right sign is flipped to report the
  golfer's left/right.
- `firebaseClient.ts` — Firebase app + `auth`. Config comes from build-time
  `VITE_FIREBASE_*` env (public values, safe in the bundle).
- `AuthContext.tsx` / `Login.tsx` — email/password auth UI + context.
- `sessions.ts` / `putters.ts` — typed client calls and column lists that mirror
  `db.py`'s `_SESSION_COLS` / `_PUTTER_COLS`.
- `Dashboard.tsx`, `AnalyzeView.tsx`, `SessionDetail.tsx`, `PuttersPage.tsx`,
  `VideoCard.tsx`, `ContributionGraph.tsx`, `SessionUploader.tsx`, `stats.ts` —
  views and building blocks.

## iOS (`ios/PuttingGate/`)

SwiftUI + SwiftData, Firebase (`FirebaseCore` / `FirebaseAuth`). Entry point
`PuttingGateApp.swift` configures Firebase, builds the object graph, and gates the
UI behind auth. Tabs: **Gate / History / Settings** (`MainTabView`).

The app is a **BLE central** that pairs with the hardware gate and relays each
putt to the backend — it no longer records or uploads video itself.

- `Gate/` — `GateConnection` (BLE central; scans for and subscribes to the
  `PuttingGate` peripheral), `GatePutt` / `GatePuttRelay` (decode a putt
  notification and `POST /api/device/putts`), `GateCalibration` +
  `CalibrationStore` (center-calibration state). BLE service/characteristic UUIDs
  must match the firmware (`microcontroller/putt_tracker`).
- `Session/` — `SessionConfig` / `SessionConfigStore` (putter, distance, break for
  the current session; a length/break change starts a new session),
  `SessionHistory`, `SessionMetadataService`.
- `Views/` — `GateView`, `HistoryView`, `SettingsView`, `CalibrationView`,
  `LoginView`.
- `Config/AppSettings.swift` — `backendBaseURL` is **hardcoded** to the prod Cloud
  Run URL (ends in `/api`).
- `Auth/`, `Theme/` (the "Organic" design system), `Resources/`.

`GoogleService-Info.plist` is bundled in the target. Firebase SDK is added via
Swift Package Manager (see the migration runbook, step 6).

## Database

Two sources of truth, kept consistent:

- `supabase/migrations/000X_*.sql` — the **applied migration history** against the
  live Supabase Postgres. Notable steps: `0004_firebase_auth.sql` widened
  `user_id` from `uuid` to `text` and dropped RLS/PostgREST-era pieces and the
  `auth.users` FKs; `0005` added `putts.crossing_frame`; `0006` added
  `putts.sensor_offsets_mm` for hardware-gate putts (0007/0008 added then dropped
  a per-putt video column).
- `backend/db/schema.sql` — the equivalent **consolidated greenfield schema**,
  handy for spinning up a local Postgres for tests. Idempotent.

Tables: `putters` (user-owned clubs, ≤1 active per user via a partial unique
index), `sessions` (one row per analyzed video / gate session; `id` = the iOS
session UUID; a flattened calibration block; `status` lifecycle enum), `putts`
(one row per detected putt, `ON DELETE CASCADE` from sessions). Video putts carry
a `crossing_frame` (the frame the ball crossed the gate); hardware putts carry
`sensor_offsets_mm` (per-sensor readings, NULL for video putts). Enums:
`putt_break`, `putt_direction`, `scale_source`, `session_status`.

**If you change a returned column set, update it in all three places:** the SQL,
`db.py`'s `_*_COLS`, and the frontend TS types (`sessions.ts` / `putters.ts` /
`analysis.ts`).

## Development workflows

### Run the whole stack locally

```bash
./start.sh
```

This sets `LOCAL_MODE=1` (storage → local disk, analysis runs in-process, no
GCS/Cloud Tasks needed) and `AUTH_DEV_UID=local-dev-user` (skips Firebase token
verification, attributes all data to one dev user). It creates `backend/.venv`,
runs uvicorn on `:8000` (`app.main:application`, `--reload`), and `npm run dev`
on `:5173`. Frontend proxies `/api` → `localhost:8000` (see `vite.config.ts`).

**Database for local dev:** `DATABASE_URL` precedence is shell env → `backend/.env`
→ a `postgresql://localhost/putting_gate` fallback (only exported if neither of
the first two provides one — do **not** unconditionally export it, or it shadows
`backend/.env`). To exercise persistence locally: `createdb putting_gate && psql
putting_gate -f backend/db/schema.sql`. Without a DB, analysis still works but
nothing persists.

### Frontend only

```bash
cd frontend
npm install
npm run dev      # Vite dev server
npm run build    # tsc -b && vite build  → frontend/dist
npm run lint     # oxlint
```

Needs `frontend/.env.local` with the `VITE_FIREBASE_*` values for real auth.

### Backend only

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
LOCAL_MODE=1 AUTH_DEV_UID=dev .venv/bin/uvicorn app.main:application --reload --port 8000
```

`backend/scripts/check_*.py` are ad-hoc CV debugging scripts (motion, detection,
segments) — run against a video file to inspect the pipeline. `backend/tests/`
currently holds only fixtures (`.gitkeep`); there is no automated test suite yet,
so **verify changes by exercising the flow** (upload a clip locally and watch the
session go `queued → processing → done`).

### iOS

Open `ios/PuttingGate.xcodeproj` in Xcode, build & run. Requires the Firebase SPM
package and `GoogleService-Info.plist` in the target. BLE won't work in the
Simulator — to exercise the gate you need a real device and the physical ESP32
peripheral advertising nearby.

### Microcontroller

ESP32 firmware built with `arduino-cli`. Flash from a sketch folder — the
`huge_app` partition scheme is **required** (BLE overflows the default):

```bash
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --upload -p /dev/cu.usbserial-0001 .
arduino-cli monitor -p /dev/cu.usbserial-0001 -c baudrate=115200
```

`microcontroller/putt_tracker/putt_tracker.ino` is the main program; `sensors/`,
`laser/`, `blink/` are bring-up sketches. See `microcontroller/README.md` for the
full wiring, measurement geometry/math, detection algorithm, BLE payload, and
gotchas.

## Deployment

- **Frontend** auto-deploys to Firebase Hosting on push to `main` that touches
  `frontend/**`, `firebase.json`, or the workflow
  (`.github/workflows/deploy-frontend.yml`). Vite bakes the `VITE_*` env (Firebase
  config from repo **variables**, not secrets) into the bundle at build time.
- **Backend** deploys to Cloud Run via `bash backend/deploy/cloud-run.sh` (full
  provisioning: APIs, Artifact Registry, GCS bucket + lifecycle rules, Cloud Tasks
  queue, Secret Manager, service account + IAM, then build & deploy). Use
  `--fast` for a code-only rebuild+redeploy. Container is `backend/Dockerfile`
  (Python 3.13-slim + ffmpeg; single uvicorn worker — scale via Cloud Run
  instances, not in-process workers). Secrets: `DATABASE_URL`,
  `CORS_ALLOW_ORIGINS`, `TASKS_INTERNAL_TOKEN`.

Signed URLs on Cloud Run use the IAM `signBlob` API (no local private key); the
runtime service account (`GCS_SIGNER_SA`) needs `serviceAccountTokenCreator` on
itself.

## Working in this repo

- **Git:** develop on the designated feature branch; commit with clear messages;
  push with `git push -u origin <branch>`. Do **not** open a PR unless explicitly
  asked. `main` auto-deploys the frontend, so be deliberate about what lands there.
- **Cross-cutting changes:** a change to the data shape usually spans SQL +
  `db.py` + frontend TS (and sometimes iOS). Trace the column through all layers.
- **Keep player-facing messages actionable.** The analyzer maps low-level CV
  failures to plain guidance ("Couldn't find the laser gate…", "add light…"); the
  pre-flight `/calibration-check` and post-analysis errors share the same message
  constants so both speak with one voice.
- **Local mode ≠ prod.** Behavior branches on `cloud.is_local()` (in-process vs.
  Cloud Tasks) and `AUTH_DEV_UID` (skip vs. verify tokens). Test both paths in
  mind when changing the analysis orchestration or auth.
