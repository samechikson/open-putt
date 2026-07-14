# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

**Putting Gate** is a golf putting-analysis app. A player films a putt rolling
through a physical "laser gate" (two laser dots defining a line the ball crosses);
the app measures how far off-center the ball crossed and reports a push/pull bias,
speed, and direction. It has three clients over one shared backend:

- **`backend/`** — Python / FastAPI service. Does the computer-vision analysis
  (OpenCV) and is the **sole database client** and the **sole storage/auth broker**.
- **`frontend/`** — React 19 + TypeScript + Vite + Tailwind v4 web app. Upload a
  clip, view sessions/putts, manage putters. Served by Firebase Hosting.
- **`ios/`** — SwiftUI app (`PuttingGate`). Records putts on-device and uploads
  them for analysis.

Plus `supabase/migrations/` (DB migration history), `backend/db/schema.sql`
(consolidated greenfield schema), and `docs/` (operator runbooks).

## Architecture at a glance

```
iOS app ─┐                              ┌─ Cloud Storage (GCS)   [video bytes]
         ├─→ Firebase Hosting /api/** ──┤
Web app ─┘   (rewrite, same-origin)     ├─ Cloud Run: FastAPI ──→ Postgres (Supabase)
                                        │      │
                                        │      └─→ Cloud Tasks ──→ POST /api/process (analysis worker)
                                        └─ Firebase Auth (ID-token verification)
```

Key facts that shape everything:

- **The backend is the only thing that touches the database.** The browser and
  iOS clients never talk to Postgres directly. Every read/write goes through a
  FastAPI endpoint that verifies a Firebase ID token and scopes the query by
  `user_id` (the Firebase UID) — `WHERE user_id = $uid`. There is no Row-Level
  Security; ownership is enforced in application SQL.
- **The API is mounted under `/api`.** `backend/app/main.py` defines routes on an
  inner app and mounts it at `/api` on the served `application`. Firebase Hosting
  rewrites `/api/**` to the Cloud Run service, so the web app makes **same-origin**
  calls (no CORS in prod). Every caller uses the `/api` prefix: web
  (`VITE_API_BASE=/api`), iOS (`AppSettings.backendBaseURL` ends in `/api`), and
  the Cloud Tasks callback (`PROCESS_URL=.../api/process`).
- **Analysis is async and CPU-bound.** Clients upload the video straight to
  storage (signed URL), then call `/analyze-session`, which creates a `queued`
  session row and hands the work to Cloud Tasks. A separate `/process` request
  (which owns a full CPU allocation) runs the OpenCV pipeline and drives the row
  to `done`/`error`. Clients **poll** `GET /api/sessions/{id}` for status.
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
| `main.py` | FastAPI app, all HTTP endpoints, the async analysis orchestration (`_process_session`, local vs. Cloud Tasks worker paths). Mounts the API under `/api`. |
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
- **Idempotent by session id.** The session `id` is the iOS recording UUID.
  Re-uploads/re-analysis upsert the row and replace the putts wholesale.

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
UI behind auth (`RootView`). Tabs: Record / History / Settings.

- `Config/AppSettings.swift` — `backendBaseURL` is **hardcoded** to the prod Cloud
  Run URL (ends in `/api`); capture resolution + exposure bias settings.
- `Capture/` — `CameraRecorder`, `CameraPreview`, `CaptureTest` (pre-flight that
  posts a frame to `/calibration-check`).
- `Upload/UploadService.swift` — signed-URL upload flow, sends the Firebase ID
  token, resumes pending uploads on launch.
- `Auth/`, `Views/`, `Model/`, `Coordinator/` — auth, screens, SwiftData models,
  recording coordinator.

`GoogleService-Info.plist` is bundled in the target. Firebase SDK is added via
Swift Package Manager (see the migration runbook, step 6).

## Database

Two sources of truth, kept consistent:

- `supabase/migrations/000X_*.sql` — the **applied migration history** against the
  live Supabase Postgres (through `0004_firebase_auth.sql`, which widened
  `user_id` from `uuid` to `text`, dropped RLS/PostgREST-era pieces, and dropped
  the `auth.users` FKs).
- `backend/db/schema.sql` — the equivalent **consolidated greenfield schema**,
  handy for spinning up a local Postgres for tests. Idempotent.

Tables: `putters` (user-owned clubs, ≤1 active per user via a partial unique
index), `sessions` (one row per analyzed video; `id` = iOS recording UUID; a
flattened calibration block; `status` lifecycle enum), `putts` (one row per
detected putt, `ON DELETE CASCADE` from sessions). Enums: `putt_break`,
`putt_direction`, `scale_source`, `session_status`.

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
package and `GoogleService-Info.plist` in the target.

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
