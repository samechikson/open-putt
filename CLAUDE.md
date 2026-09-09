# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

**Open Putt** is a golf putting-analysis app. A player rolls a putt through a
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

- **`backend/`** — Python / FastAPI service. Now used **only** for the legacy
  ESP32 direct-post ingest path (`POST /api/device/putts` with a shared device
  token), writing to Firestore via the Admin SDK. The web and iOS apps no longer
  call it.
- **`frontend/`** — React 19 + TypeScript + Vite + Tailwind v4 web app. Reads and
  writes Firestore **directly** via the Firebase Web SDK (no backend calls): browse
  sessions/putts and stats, edit session metadata, manage putters. Served by
  Firebase Hosting.
- **`ios/`** — SwiftUI app (`PuttingGate`). A **BLE central** that pairs with the
  hardware gate and writes each putt **directly to Firestore** via the Firebase
  iOS SDK (`FirebaseFirestore`); also shows history/settings. No backend calls.
- **`microcontroller/`** — ESP32 (Arduino C++) firmware for the physical laser
  gate + ToF sensors. See its own `README.md` for wiring, geometry, and BLE.

Plus `backend/db/README.md` (the Firestore collection model), `firestore.rules` /
`firestore.indexes.json` (per-user client access for the web + iOS apps; no
composite indexes), and
`docs/` (operator runbooks). A top-level `README.md` gives the human-facing
overview.

## Architecture at a glance

```
Hardware gate (ESP32) ─BLE→ iOS app ──(Firebase iOS SDK)──┐
Web app ──────────────────(Firebase Web SDK)──────────────┼─→ Firestore (Native)
   └─ Firebase Auth (ID tokens)                            │   ▲ firestore.rules
ESP32 (legacy direct post) → Cloud Run: FastAPI (Admin SDK)┘   (Admin bypasses rules)
```

Key facts that shape everything:

- **The apps talk to Firestore directly; the backend barely exists.** Both the
  **web app** (Firebase Web SDK) and the **iOS app** (`FirebaseFirestore`) read and
  write Firestore directly, so `firestore.rules` is the enforcement boundary — a
  signed-in user can only touch docs whose `user_id` is their uid. The **backend**
  (Cloud Run, Admin SDK, *bypasses* rules) is now only the legacy ESP32 direct-post
  ingest path; if you don't run an ESP32 posting directly, nothing uses it.
- **Ownership is a `user_id` field on every doc.** Clients scope every query by it
  — `user_id == uid` is both the ownership filter and what makes the query
  rule-legal. Get this wrong and data leaks.
- **iOS is the primary ingest path.** It relays each hardware-gate putt over BLE
  and writes it straight to Firestore — creating the session (already complete) on
  its first putt and keeping `putt_count` in sync. It applies the load-bearing
  sign convention on write (see `SessionMetadataService.ingest`): `offset_mm` and
  the per-sensor offsets are **negated** from the firmware sign so the shared
  `golferSide` display helper (which negates the stored value) recovers the
  golfer's left/right; `direction` comes from the PUSH/PULL/CENTER label and is
  not negated.
- **No video, no heavy infra.** There is no Cloud Storage, no Cloud Tasks, no
  OpenCV, no signed URLs.

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
| `db.py` | The backend's Firestore client (Admin SDK; bypasses rules; lazy, fail-soft). Now exercised only by the ESP32 direct-post ingest path. Single-field filters + Python-side ordering (no composite indexes). Field lists (`_SESSION_FIELDS`, etc.) mirror the TS/Swift models. See `backend/db/README.md`. |
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
`/putters`). It reads/edits its own data **directly in Firestore via the Firebase
Web SDK** — there is no backend API call from the web app (it never creates
sessions/putts, only reads them, edits session metadata, deletes, and does the
full putter CRUD).

- `firebaseClient.ts` — Firebase app, `auth`, `db` (Firestore), and `currentUid()`
  (awaits auth init, returns the signed-in uid used to scope every query). Config
  comes from build-time `VITE_FIREBASE_*` env (public values, safe in the bundle).
- `sessions.ts` / `putters.ts` — the Firestore data layer: typed reads/writes via
  the Web SDK, using single-equality-filter queries + client-side sorting (so no
  composite indexes, and the queries satisfy the rules). Field shapes mirror
  `db.py`'s `_SESSION_FIELDS` / `_PUTTER_FIELDS`. Deletes cascade here
  (`deleteSession` removes the session's putts) since Firestore has no cascade.
- `analysis.ts` — the golfer-perspective offset/side helpers (`golferSide`,
  `biasWord`). `golferSide` negates the stored `offset_mm`, which is pre-inverted
  on ingest (see `main.py`'s `/device/putts`), to recover the golfer's left/right.
- `AuthContext.tsx` / `Login.tsx` — email/password auth UI + context.
- `Dashboard.tsx`, `SessionDetail.tsx`, `PuttersPage.tsx`, `ContributionGraph.tsx`,
  `stats.ts` — views and building blocks.

## iOS (`ios/PuttingGate/`)

SwiftUI, Firebase (`FirebaseCore` / `FirebaseAuth` / `FirebaseFirestore`). Entry
point `PuttingGateApp.swift` configures Firebase, builds the object graph, and
gates the UI behind auth. Tabs: **Gate / History / Settings** (`MainTabView`).

The app is a **BLE central** that pairs with the hardware gate and writes each
putt **directly to Firestore** via the Firebase iOS SDK — no backend calls, no
video.

- `Gate/` — `GateConnection` (BLE central; scans for and subscribes to the
  `PuttingGate` peripheral, decodes each putt notification into a `GatePutt`,
  applies any center calibration, and hands it to the service to persist),
  `GatePutt`, `GateCalibration` + `CalibrationStore` (center-calibration state).
  BLE service/characteristic UUIDs must match the firmware
  (`microcontroller/putt_tracker`).
- `Session/` — `SessionMetadataService` (the **Firestore data layer**: reads
  sessions/putts/putters, edits session metadata, deletes, and `ingest`s gate
  putts — session upsert, sign-inversion, `putt_count`), `SessionConfig` /
  `SessionConfigStore` (putter, distance, break; a length/break change starts a
  new session), `SessionHistory`, and the `SessionRow` / `SessionPutt` / `Putter`
  models (built from `DocumentSnapshot`).
- `Views/` — `GateView`, `HistoryView`, `SessionDetailView`, `SettingsView`,
  `CalibrationView`, `LoginView`.
- `Auth/` (Firebase Auth wrapper), `Theme/` (the "Organic" design system),
  `Resources/`.

`GoogleService-Info.plist` is bundled in the target. Firebase products are added
via Swift Package Manager — `FirebaseFirestore` is wired in `project.pbxproj`
(mirroring the `FirebaseAuth` entries; the file group is a synchronized group, so
adding/removing `.swift` files needs no project edit).

## Database

**Firestore (Native mode)** — schemaless, so there's no migration file. The
**web and iOS apps** both access it directly via the Firebase SDK, scoped by
`firestore.rules` (a signed-in user may only touch docs whose `user_id` is their
uid, and may create their own). The **backend** (Admin SDK, bypasses rules) writes
only via the legacy ESP32 direct-post path. The full collection model lives in
`backend/db/README.md`. In brief:

- `putters/{uuid}` — user-owned clubs (≤1 active per user, enforced in
  `set_active_putter`).
- `sessions/{sessionId}` — one doc per gate session; `sessionId` = the iOS
  session UUID (idempotent upsert key). Fields: `user_id`, `created_at`,
  `length_feet`, `break_type`, `putter_id`, `putt_count`.
- `putts/{sessionId_index}` — a **top-level** collection, one doc per putt, doc id
  `"{session_id}_{putt_index}"`. Each doc denormalizes `session_id` and `user_id`
  from its session (so putts are queryable/ownable without a join). Deleting a
  session cascades (in the web's `deleteSession` and the backend's
  `_delete_putts_for_session`). Fields: `offset_mm`, `direction`, `speed_mps`,
  `sensor_offsets_mm` (per-sensor readings). Enum-like values (`break_type`,
  `direction`) are plain strings, validated client-side (web) and in `main.py` (iOS).

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
- **Firestore rules/indexes are NOT in that workflow** (it deploys hosting only).
  Since the web app relies on `firestore.rules` for access, deploy rules after any
  change with `firebase deploy --only firestore:rules,firestore:indexes` (needs a
  login with Firebase Rules admin). The web app is broken until the rules are live.
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
- **The sign convention is load-bearing, and now enforced in two writers.** Both
  iOS ingest (`SessionMetadataService.ingest`) and the backend's `/device/putts`
  (ESP32 path) pre-invert the stored `offset_mm` (and per-sensor offsets) so the
  shared `golferSide` display helper (web + iOS), which negates it, reports the
  golfer's left/right. Keep all three in sync.
- **Auth branches on `AUTH_DEV_UID`** (skip vs. verify tokens) and persistence on
  whether Firestore is configured (project id / emulator vs. fail-soft no-op).
