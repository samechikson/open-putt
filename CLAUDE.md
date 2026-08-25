# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

**Putting Gate** is a golf putting-analysis app. A player rolls a putt through a
physical "laser gate" (a laser dot defining where the ball crosses); the app
measures how far off-center the ball crossed and reports a push/pull bias (in mm)
and speed.

**Putts are measured entirely by the hardware gate.** A 3D-printed bridge gate
with a laser and three ToF distance sensors, driven by an ESP32, measures the
offset on-device and sends each putt over **Bluetooth (BLE)** to the iOS app,
which relays it to the backend (`POST /api/device/putts`). There's no video / no
computer-vision path: a player never uploads a clip. (An earlier OpenCV
video-upload pipeline was **removed** — see `docs/migration-firestore.md` and the
git history if you need the old shape.)

The components:

- **`backend/`** — Python / FastAPI service. Ingests hardware-gate putts and is
  the **sole database client** and the **sole auth broker**.
- **`frontend/`** — React 19 + TypeScript + Vite + Tailwind v4 web app. A
  read/review surface: browse sessions/putts and stats, edit session metadata,
  manage putters. Served by Firebase Hosting.
- **`ios/`** — SwiftUI app (`PuttingGate`). A **BLE central** that pairs with the
  hardware gate, relays each putt to the backend, and shows history/settings.
- **`microcontroller/`** — ESP32 (Arduino C++) firmware for the physical laser
  gate + ToF sensors. See its own `README.md` for wiring, geometry, and BLE.

Plus `backend/db/README.md` (the Firestore collection model), `firestore.rules` /
`firestore.indexes.json` (deny-all client access; no composite indexes), and
`docs/` (operator runbooks). A top-level `README.md` gives the human-facing
overview.

## Architecture at a glance

```
Hardware gate (ESP32) ─BLE→ iOS app ──┐
                                      ├─→ Firebase Hosting ──→ Cloud Run: FastAPI ──→ Firestore (Native)
Web app (browse/review) ──────────────┘   /api/** rewrite,
                                      ┌─ Firebase Auth          same-origin
                                      └─ (ID-token verify)
```

Key facts that shape everything:

- **The backend is the only thing that touches the database.** The browser and
  iOS clients never talk to Firestore directly (and the gate reaches it only via
  the iOS relay). Every read/write goes through a FastAPI endpoint that verifies a
  Firebase ID token and scopes the query by `user_id` (the Firebase UID) — every
  query filters `user_id == uid`. The backend uses the Firestore **Admin SDK**
  (service account), which bypasses security rules, so `firestore.rules` denies
  all direct client access and ownership is enforced in application code.
- **The API is mounted under `/api`.** `backend/app/main.py` defines routes on an
  inner app and mounts it at `/api` on the served `application`. Firebase Hosting
  rewrites `/api/**` to the Cloud Run service, so the web app makes **same-origin**
  calls (no CORS in prod). Every caller uses the `/api` prefix: web
  (`VITE_API_BASE=/api`) and iOS (`AppSettings.backendBaseURL` ends in `/api`).
- **Hardware-gate putts are the only putt source.** They arrive already-measured
  over BLE and are persisted directly via `POST /api/device/putts` (`main.py`) —
  no video, no analysis pass, no async job, no polling for status. A session is
  created on its first putt (already complete) and keeps gaining putts as the
  player putts; the client polls `GET /api/sessions/{id}/putts` while a session is
  recent to pick up new ones. Each putt carries per-sensor offsets.
- **No video, no heavy infra.** There is no Cloud Storage, no Cloud Tasks, no
  OpenCV, no signed URLs — the backend is a thin CRUD API over Firestore. A putt
  request does a few small Firestore writes and returns.

### Migration history (important context)

This project first **migrated off Supabase Auth/PostgREST/RLS to Firebase Auth**
(keeping the DB on Postgres), then **migrated persistence off Postgres to
Firestore** (Native mode) — the current state. The old Supabase/Postgres pieces
(`psycopg`, `DATABASE_URL`, `supabase/migrations/`, `backend/db/schema.sql`) are
gone; existing data was disposable test data and was not migrated. See
`docs/migration-firestore.md` for the Firestore runbook and
`docs/migration-firebase-auth.md` for the earlier (now historical) auth move. A
lingering "Supabase" reference in a doc means the old Postgres database.

## Backend (`backend/app/`)

| File | Responsibility |
|------|----------------|
| `main.py` | FastAPI app: the `POST /device/putts` BLE-gate ingest, the session/putt reads, session-metadata edit + delete, and putters CRUD. Mounts the API under `/api`. A thin CRUD layer — no analysis. |
| `db.py` | The **only** Firestore client (Admin SDK; lazy, fail-soft). All ownership-scoped queries. Uses single-field filters + Python-side ordering so no composite indexes are needed. Field lists (`_SESSION_FIELDS`, etc.) are kept in sync with the frontend TS types. See `backend/db/README.md` for the collection model. |
| `auth.py` | `require_user` / `require_device` / `require_user_or_device` FastAPI dependencies → the Firebase UID. In local dev `AUTH_DEV_UID` short-circuits verification. |

### Conventions

- **Blocking work runs in a threadpool.** Every Firestore call is synchronous and
  blocking; endpoints wrap them in `run_in_threadpool(...)` so the event loop
  stays responsive.
- **Fail-soft persistence.** If no Firestore is configured (no project id / no
  emulator), `db.py` functions no-op / return empty so the app imports and runs
  without a database.
- **Lazy, optional clients.** `db.py` and `auth.py` create their Firebase/Firestore
  clients lazily so the module imports cleanly with no config (e.g. in tests).
- **Idempotent by session id + putt index.** The session `id` is the iOS session
  UUID; each putt's Firestore doc id is `"{session_id}_{putt_index}"`, so the
  gate can safely retry a putt (the upsert is per-(session, index)).
- **Two ingest auth modes.** `POST /device/putts` accepts either a signed-in user
  (the iOS app relaying under the user's Bearer token) or the legacy ESP32 direct
  post with a shared `X-Device-Token` (`DEVICE_INGEST_TOKEN` / `DEVICE_INGEST_UID`).

## Frontend (`frontend/src/`)

React 19, TypeScript, Vite 8, Tailwind CSS v4 (via `@tailwindcss/vite`), Oxlint.
Routing is `react-router` in `App.tsx` (`/` dashboard, `/sessions/:id`,
`/putters`). It's a read/review surface — sessions and putts are created by the
gate, not the web app.

- `api.ts` — `apiFetch` / `apiJson` wrappers that attach the Firebase ID token as
  a `Bearer` header. **All backend access goes through here.**
- `analysis.ts` — `API_BASE` (default `/api`) and the golfer-perspective
  offset/side helpers (`golferSide`, `biasWord`). `golferSide` negates the stored
  `offset_mm`, which is pre-inverted on ingest (see `main.py`'s `/device/putts`),
  to recover the golfer's left/right.
- `firebaseClient.ts` — Firebase app + `auth`. Config comes from build-time
  `VITE_FIREBASE_*` env (public values, safe in the bundle).
- `AuthContext.tsx` / `Login.tsx` — email/password auth UI + context.
- `sessions.ts` / `putters.ts` — typed client calls and field lists that mirror
  `db.py`'s `_SESSION_FIELDS` / `_PUTTER_FIELDS`.
- `Dashboard.tsx`, `SessionDetail.tsx`, `PuttersPage.tsx`, `ContributionGraph.tsx`,
  `stats.ts` — views and building blocks.

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

**Firestore (Native mode)** — schemaless, so there's no migration file. The full
collection model lives in `backend/db/README.md`. In brief:

- `putters/{uuid}` — user-owned clubs (≤1 active per user, enforced in
  `set_active_putter`).
- `sessions/{sessionId}` — one doc per gate session; `sessionId` = the iOS
  session UUID (idempotent upsert key). Fields: `user_id`, `created_at`,
  `length_feet`, `break_type`, `putter_id`, `putt_count`.
- `putts/{sessionId_index}` — a **top-level** collection, one doc per putt, doc id
  `"{session_id}_{putt_index}"`. Each doc denormalizes `session_id` and `user_id`
  from its session (so putts are queryable/ownable without a join). Deleting a
  session cascades in `db.py` (`_delete_putts_for_session`). Fields: `offset_mm`,
  `direction`, `speed_mps`, `sensor_offsets_mm` (per-sensor readings). Enum-like
  values (`break_type`, `direction`) are plain strings, validated in `main.py`.

Every query filters on a single field and orders/filters the rest in Python, so
`firestore.indexes.json` needs no composite indexes.

**If you change a returned field set, update it in all three places:** `db.py`'s
`_*_FIELDS`, the frontend TS types (`sessions.ts` / `putters.ts` / `analysis.ts`),
and `backend/db/README.md`.

## Development workflows

### Run the whole stack locally

```bash
./start.sh
```

This sets `AUTH_DEV_UID=local-dev` (skips Firebase token verification, attributes
all data to one dev user). It creates `backend/.venv`, runs uvicorn on `:8000`
(`app.main:application`, `--reload`), and `npm run dev` on `:5173`. Frontend
proxies `/api` → `localhost:8000` (see `vite.config.ts`).

**Database for local dev:** `start.sh` launches the **Firestore emulator**
(`localhost:8080`) and points the backend at it via `FIRESTORE_EMULATOR_HOST`, so
persistence works without touching real Firestore. This needs the Firebase CLI
(`npm i -g firebase-tools`) and a Java runtime; if `firebase` isn't found the
script warns and runs without persistence (the app still runs, nothing persists).
Emulator config is in `firebase.json`.

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
AUTH_DEV_UID=dev .venv/bin/uvicorn app.main:application --reload --port 8000
```

Point it at a running Firestore emulator with `FIRESTORE_EMULATOR_HOST=localhost:8080`
to exercise persistence. There is no automated test suite yet, so **verify
changes by exercising the flow** — post a putt to `/api/device/putts` (or relay
one from the gate via iOS) and confirm it reads back from `/api/sessions/{id}/putts`.

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
- **Backend** deploys to Cloud Run via `bash backend/deploy/cloud-run.sh`
  (provisioning: APIs, Artifact Registry, **Firestore Native database**, Secret
  Manager, service account + IAM, then build & deploy). The runtime SA gets
  `roles/datastore.user` for Firestore. Use `--fast` for a code-only
  rebuild+redeploy. Container is `backend/Dockerfile` (Python 3.13-slim; single
  uvicorn worker — scale via Cloud Run instances). Secrets: `CORS_ALLOW_ORIGINS`,
  `DEVICE_INGEST_TOKEN` / `DEVICE_INGEST_UID` (the legacy direct-post device
  auth); no DB secret — Firestore uses the runtime SA.

## Working in this repo

- **Git:** develop on the designated feature branch; commit with clear messages;
  push with `git push -u origin <branch>`. Do **not** open a PR unless explicitly
  asked. `main` auto-deploys the frontend, so be deliberate about what lands there.
- **Cross-cutting changes:** a change to the data shape usually spans `db.py`'s
  `_*_FIELDS` + `backend/db/README.md` + frontend TS (and sometimes iOS). Trace
  the field through all layers.
- **The sign convention is load-bearing.** `/device/putts` pre-inverts the stored
  `offset_mm` (and per-sensor offsets) so the shared `golferSide` helper (web +
  iOS), which negates it, reports the golfer's left/right. Keep the two in sync.
- **Auth branches on `AUTH_DEV_UID`** (skip vs. verify tokens) and persistence on
  whether Firestore is configured (project id / emulator vs. fail-soft no-op).
