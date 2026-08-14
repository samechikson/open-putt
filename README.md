# Putting Gate

A golf putting-analysis app. A player rolls a putt through a physical **laser gate**
and the system measures how far **off-center** the ball crossed — reporting a
**push/pull** bias (in millimeters) plus the ball's **speed**. Over time it builds a
history of sessions and putts so a player can see their tendencies per putter, break,
and distance.

There are **two ways to measure a putt**, both feeding one shared backend and database:

1. **Hardware gate (primary).** A 3D-printed "bridge" gate with a laser and three
   time-of-flight distance sensors, driven by an ESP32. It detects each pass and
   computes the offset on-device, then sends it over **Bluetooth (BLE)** to the iOS
   app, which relays it to the backend under the signed-in user.
2. **Video / computer vision.** A player films a putt rolling through the gate and
   uploads the clip (from the web app); the backend runs an **OpenCV** pipeline that
   auto-calibrates the gate from the footage and measures each putt's crossing
   offset, direction, and speed.

Both paths produce the same shape of data (`sessions` → `putts`) and show up together
in the same history and stats.

---

## Repository layout

| Path | What it is |
|------|------------|
| `backend/` | Python / FastAPI service. The OpenCV analysis pipeline, the **sole database client**, and the sole storage/auth broker. Runs on Cloud Run. |
| `frontend/` | React 19 + TypeScript + Vite + Tailwind v4 web app. Upload clips, browse sessions/putts, manage putters. Served by Firebase Hosting. |
| `ios/` | SwiftUI app (`PuttingGate`). Connects to the hardware gate over BLE, relays putts to the backend, and shows history/settings. |
| `microcontroller/` | ESP32 (Arduino C++) firmware for the physical laser gate + ToF sensors, and its bring-up sketches. |
| `supabase/migrations/` | Applied Postgres migration history. |
| `backend/db/schema.sql` | Consolidated greenfield schema (idempotent) for spinning up a local DB. |
| `docs/` | Operator runbooks (currently the Firebase-auth migration runbook). |
| `start.sh` | One command to run the whole web stack locally in local mode. |

## Architecture

```
Hardware gate (ESP32) ──BLE──→ iOS app ─┐
                                        ├─→ Firebase Hosting /api/**   ┌─ Cloud Storage (GCS)  [video bytes]
Web app (upload clip) ──────────────────┤   (rewrite, same-origin)  ──┤
                                        │                             ├─ Cloud Run: FastAPI ──→ Postgres (Supabase)
                                        └─ Firebase Auth               │      │
                                           (ID-token verification)     │      └─→ Cloud Tasks ──→ POST /api/process (analysis worker)
                                                                       └───────
```

Key facts that shape everything:

- **The backend is the only thing that touches the database.** Browser, iOS, and the
  gate never talk to Postgres directly. Every read/write goes through a FastAPI
  endpoint that verifies a Firebase ID token and scopes the query by `user_id` (the
  Firebase UID) — `WHERE user_id = $uid`. There is no Row-Level Security; ownership is
  enforced in application SQL.
- **The API is mounted under `/api`.** Firebase Hosting rewrites `/api/**` to the
  Cloud Run service, so the web app makes **same-origin** calls (no CORS in prod).
  Every caller uses the `/api` prefix: web (`VITE_API_BASE=/api`), iOS
  (`AppSettings.backendBaseURL` ends in `/api`), and the Cloud Tasks callback.
- **Video analysis is async and CPU-bound.** Clients upload the clip straight to
  storage (signed URL), then call `/analyze-session`, which creates a `queued` session
  and hands the work to Cloud Tasks. A separate `/process` request (which owns a full
  CPU allocation) runs the OpenCV pipeline and drives the row to `done`/`error`.
  Clients **poll** `GET /api/sessions/{id}` for status.
- **Hardware-gate putts skip all of that.** They arrive already-measured over BLE and
  are persisted directly via `POST /api/device/putts` — no video, no Cloud Tasks, no
  analysis pass.
- **Video lifecycle:** clips upload to the transient `uploads/` prefix (deleted after
  1 day). On any terminal outcome — success *or* domain error — the clip is copied to
  the retained `sessions/` prefix (kept 90 days) so no captured putt is lost. Retained
  video is streamed back via short-lived signed GET URLs.

### Migration history (important context)

This project **migrated off Supabase Auth/PostgREST/RLS to Firebase Auth**, while
**keeping the database on Supabase Postgres** (reached directly via `psycopg` through
Supabase's connection pooler as the service role). Infra also moved from
Vercel/Fly/Cloud SQL to **Firebase Hosting + Cloud Run**. See
[`docs/migration-firebase-auth.md`](docs/migration-firebase-auth.md). When you see
"Supabase" in the code, it almost always means "the Postgres database," not
auth/PostgREST.

---

## Backend (`backend/app/`)

FastAPI service. Routes are defined on an inner app and mounted at `/api` on the served
`application`.

| File | Responsibility |
|------|----------------|
| `main.py` | FastAPI app, all HTTP endpoints, async analysis orchestration (`_process_session`, local vs. Cloud Tasks worker paths). Mounts the API under `/api`. |
| `analyzer.py` | The OpenCV pipeline: auto-calibrate the gate + scale from the video, segment by motion, measure each putt's crossing offset/direction/speed. Entrypoints: `analyze_putt`, `analyze_session`, `detect_ball_in_frame`, `check_calibration_frame`. Raises `CalibrationError`. |
| `segmenter.py` | Motion helpers: `motion_levels`, `segment_motion`, `quiet_frames` (find still frames for calibration, split a multi-putt clip). |
| `db.py` | The **only** Postgres client. `psycopg` pool (lazy, fail-soft). All ownership-scoped queries. Column lists (`_SESSION_COLS`, etc.) stay in sync with the frontend TS types. |
| `cloud.py` | Google Cloud helpers (Cloud Storage + Cloud Tasks) with a **local-mode** fallback (local disk + in-process analysis). |
| `auth.py` | `require_user` dependency → returns the Firebase UID. In local dev `AUTH_DEV_UID` short-circuits verification. |

**Conventions:** blocking work (OpenCV, `psycopg`, GCS) runs in a threadpool via
`run_in_threadpool`; persistence is fail-soft (no DB configured → no-op so local
analysis still works); clients are lazy/optional so modules import cleanly with no
config; uploads are streamed in 1 MiB chunks (clips are 200 MB+); `/process` is
internal (constant-time `X-Tasks-Token` check, 200 = stop, 500 = retry); the pipeline
is idempotent by session id (the iOS/recording UUID) — re-analysis upserts the row and
replaces its putts wholesale.

**Selected endpoints** (all under `/api`): `POST /analyze-session`, `POST /process`
(internal), `POST /device/putts` (BLE gate ingest), `GET /sessions`,
`GET /sessions/{id}`, `GET /sessions/{id}/putts`, `GET /sessions/{id}/video`,
`GET /sessions/{id}/putts/{i}/frame`, `POST /calibration-check`, and CRUD for
`/putters`.

## Frontend (`frontend/src/`)

React 19, TypeScript, Vite, Tailwind v4 (`@tailwindcss/vite`), Oxlint. No router —
`App.tsx` does lightweight view switching (`dashboard` / `analyze` / `session` /
`putters`).

- `api.ts` — `apiFetch` / `apiJson` wrappers that attach the Firebase ID token as a
  `Bearer` header. **All backend access goes through here.**
- `analysis.ts` — shared types, `API_BASE` (default `/api`), fps helpers, and the
  golfer-perspective offset/side helpers (`golferSide`, `biasWord`). Note the
  **face-on mirror**: the camera films face-on, so the backend's image-right sign is
  flipped to report the golfer's left/right.
- `firebaseClient.ts` — Firebase app + `auth`; config from build-time `VITE_FIREBASE_*`
  env (public, safe in the bundle).
- `AuthContext.tsx` / `Login.tsx` — email/password auth.
- `sessions.ts` / `putters.ts` — typed client calls and column lists mirroring `db.py`.
- `Dashboard.tsx`, `AnalyzeView.tsx`, `SessionDetail.tsx`, `PuttersPage.tsx`,
  `VideoCard.tsx`, `ContributionGraph.tsx`, `SessionUploader.tsx`, `stats.ts` — views.

## iOS (`ios/PuttingGate/`)

SwiftUI + SwiftData, Firebase (`FirebaseCore` / `FirebaseAuth`). Entry point
`PuttingGateApp.swift` configures Firebase, builds the object graph, and gates the UI
behind auth. Three tabs: **Gate / History / Settings**.

The app is a **BLE central** that pairs with the hardware gate and relays each putt to
the backend:

- `Gate/` — `GateConnection` (BLE central; scans for and subscribes to the gate),
  `GatePutt` / `GatePuttRelay` (decode a putt notification and `POST /api/device/putts`),
  `GateCalibration` + `CalibrationStore` (center-calibration state).
- `Session/` — `SessionConfig` / `SessionConfigStore` (putter, distance, break for the
  current session), `SessionHistory`, `SessionMetadataService`.
- `Views/` — `GateView`, `HistoryView`, `SettingsView`, `CalibrationView`, `LoginView`.
- `Config/AppSettings.swift` — `backendBaseURL` is **hardcoded** to the prod Cloud Run
  URL (ends in `/api`).
- `Auth/`, `Theme/`, `Resources/` — auth, the warm "Organic" design system, assets.

`GoogleService-Info.plist` is bundled in the target; Firebase SDK is added via Swift
Package Manager.

## Microcontroller (`microcontroller/`)

ESP32 firmware for the physical gate. A golf ball rolls through a 3D-printed bridge; a
laser marks center and **three VL53L4CD** ToF distance sensors (behind a PCA9548 I2C
multiplexer, since they share address `0x29`) measure the ball's lateral position as it
passes. The device computes a per-sensor **push/pull offset** against a jig-measured
center calibration, plus speed from the sensor spacing.

Because the ESP32 has no WiFi in the field, it advertises over **BLE as `PuttingGate`**
and sends each finalized putt as a JSON notification; the iOS app receives it and
relays it to `POST /api/device/putts` under the signed-in user. The BLE service/
characteristic UUIDs must match `GateConnection.swift`.

- `putt_tracker/putt_tracker.ino` — the main program (laser, calibrate, detect, report,
  BLE).
- `sensors/`, `laser/`, `blink/` — bring-up/debug sketches.

Built with `arduino-cli`; **must** use the `huge_app` partition scheme (BLE overflows
the default). See [`microcontroller/README.md`](microcontroller/README.md) for wiring,
the measurement geometry/math, the detection algorithm, the BLE payload, and hard-won
gotchas.

## Database

Two sources of truth, kept consistent: `supabase/migrations/000X_*.sql` (applied
history) and `backend/db/schema.sql` (consolidated greenfield schema).

- **Tables:** `putters` (user-owned clubs, ≤1 active per user via a partial unique
  index), `sessions` (one row per analyzed video / gate session; `id` = recording UUID;
  a flattened calibration block; a `status` lifecycle enum), `putts` (one row per
  detected putt, `ON DELETE CASCADE` from sessions). Video putts carry a
  `crossing_frame` (the frame the ball crossed the gate); hardware putts carry
  `sensor_offsets_mm` (per-sensor readings; NULL for video putts).
- **Enums:** `putt_break`, `putt_direction`, `scale_source`, `session_status`.

**If you change a returned column set, update it in all three places:** the SQL,
`db.py`'s `_*_COLS`, and the frontend TS types (`sessions.ts` / `putters.ts` /
`analysis.ts`) — and sometimes iOS.

---

## Development

### Run the whole web stack locally

```bash
./start.sh
```

Sets `LOCAL_MODE=1` (storage → local disk, analysis in-process, no GCS/Cloud Tasks) and
`AUTH_DEV_UID=local-dev-user` (skips Firebase verification, attributes all data to one
dev user). Creates `backend/.venv`, runs uvicorn on `:8000`
(`app.main:application --reload`), and `npm run dev` on `:5173` (Vite proxies `/api` →
`localhost:8000`).

**Local database:** `DATABASE_URL` precedence is shell env → `backend/.env` → a
`postgresql://localhost/putting_gate` fallback. To exercise persistence:
`createdb putting_gate && psql putting_gate -f backend/db/schema.sql`. Without a DB,
analysis still works but nothing persists.

### Frontend only

```bash
cd frontend
npm install
npm run dev      # Vite dev server
npm run build    # tsc -b && vite build → frontend/dist
npm run lint     # oxlint
```

Needs `frontend/.env.local` with the `VITE_FIREBASE_*` values for real auth.

### Backend only

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
LOCAL_MODE=1 AUTH_DEV_UID=dev .venv/bin/uvicorn app.main:application --reload --port 8000
```

`backend/scripts/check_*.py` are ad-hoc CV debugging scripts. `backend/tests/` currently
holds only fixtures — there is no automated test suite yet, so **verify changes by
exercising the flow** (upload a clip locally and watch the session go
`queued → processing → done`).

### iOS

Open `ios/PuttingGate.xcodeproj` in Xcode, build & run. Requires the Firebase SPM
package and `GoogleService-Info.plist` in the target. To exercise the gate you need the
physical ESP32 device advertising over BLE.

### Microcontroller

From a sketch folder:

```bash
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --upload -p /dev/cu.usbserial-0001 .
arduino-cli monitor -p /dev/cu.usbserial-0001 -c baudrate=115200
```

---

## Deployment

- **Frontend** auto-deploys to Firebase Hosting on push to `main` touching
  `frontend/**`, `firebase.json`, or the workflow
  (`.github/workflows/deploy-frontend.yml`). Vite bakes the `VITE_*` env into the bundle
  at build time.
- **Backend** deploys to Cloud Run via `bash backend/deploy/cloud-run.sh` (full
  provisioning; `--fast` for a code-only rebuild+redeploy). Container is
  `backend/Dockerfile` (Python 3.13-slim + ffmpeg; single uvicorn worker — scale via
  Cloud Run instances). Secrets: `DATABASE_URL`, `CORS_ALLOW_ORIGINS`,
  `TASKS_INTERNAL_TOKEN`. Signed URLs use the IAM `signBlob` API (the runtime service
  account needs `serviceAccountTokenCreator` on itself).

> `main` auto-deploys the frontend — be deliberate about what lands there.

---

For deeper guidance on conventions and cross-cutting changes, see
[`CLAUDE.md`](CLAUDE.md).
