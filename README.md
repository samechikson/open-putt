# Putting Gate

A golf putting-analysis app. A player rolls a putt through a physical **laser gate**
and the system measures how far **off-center** the ball crossed — reporting a
**push/pull** bias (in millimeters) plus the ball's **speed**. Over time it builds a
history of sessions and putts so a player can see their tendencies per putter, break,
and distance.

**Putts are measured entirely by the hardware gate.** A 3D-printed "bridge" gate with
a laser and three time-of-flight distance sensors, driven by an ESP32, detects each
pass and computes the offset on-device, then sends it over **Bluetooth (BLE)** to the
iOS app, which relays it to the backend (`POST /api/device/putts`) under the signed-in
user. There's no video / computer-vision path — an earlier OpenCV video-upload pipeline
was removed (see [`docs/migration-firestore.md`](docs/migration-firestore.md)). Each
putt lands in one shared data model (`sessions` → `putts`) surfaced in history and stats.

---

## Repository layout

| Path | What it is |
|------|------------|
| `backend/` | Python / FastAPI service. Ingests hardware-gate putts into Firestore (Admin SDK) and serves iOS's reads + session-metadata API. On Cloud Run. |
| `frontend/` | React 19 + TypeScript + Vite + Tailwind v4 web app. Reads/writes Firestore **directly** via the Firebase Web SDK (no backend calls). Served by Firebase Hosting. |
| `ios/` | SwiftUI app (`PuttingGate`). Connects to the hardware gate over BLE, relays putts to the backend, and shows history/settings. |
| `microcontroller/` | ESP32 (Arduino C++) firmware for the physical laser gate + ToF sensors, and its bring-up sketches. |
| `backend/db/README.md` | The Firestore collection model (data lives in Firestore Native mode). |
| `firestore.rules` / `firestore.indexes.json` | Per-user client access for the web app; no composite indexes. |
| `docs/` | Operator runbooks (the Firestore + Firebase-auth migration runbooks). |
| `start.sh` | One command to run the whole web stack locally (with the Firestore emulator). |

## Architecture

```
Hardware gate (ESP32) ──BLE──→ iOS app ──→ Cloud Run: FastAPI (Admin SDK) ──┐
                                                                            ├─→ Firestore (Native)
Web app ──(Firebase Web SDK, rules-scoped)──────────────────────────────────┘
   └─ Firebase Auth (ID tokens)
```

Key facts that shape everything:

- **Two clients touch Firestore, split by trust.** The **web app** reads/writes
  Firestore directly via the Firebase Web SDK; `firestore.rules` is the enforcement
  boundary — a signed-in user can only touch docs whose `user_id` is their uid. The
  **backend** uses the Admin SDK (bypasses rules) for hardware-gate ingest and iOS's
  read / session-metadata API. Sessions and putts are *created* only by the backend
  on ingest (rules forbid clients creating them); the web only reads them, edits
  session metadata, or deletes.
- **Ownership is a `user_id` field on every doc.** The web's queries filter
  `user_id == uid` (which also makes them rule-legal); the backend filters the same
  in code. Get it wrong and data leaks.
- **The backend API is under `/api`.** iOS calls the Cloud Run URL directly
  (`AppSettings.backendBaseURL` ends in `/api`); Firebase Hosting also rewrites
  `/api/**` to Cloud Run, but the web app no longer uses the backend.
- **Hardware-gate putts are the only putt source.** They arrive already-measured over
  BLE and are persisted via `POST /api/device/putts` — no video, no analysis pass, no
  async job. A session is created (already complete) on its first putt and gains putts
  as the player putts.
- **No video, no heavy infra.** There is no Cloud Storage, no Cloud Tasks, no OpenCV,
  no signed URLs — the backend is a thin CRUD layer over Firestore.

### Migration history (important context)

This project first **migrated off Supabase Auth/PostgREST/RLS to Firebase Auth**
(keeping the DB on Postgres), then **migrated persistence off Postgres to
Firestore** (Native mode) — the current state. The old Supabase/Postgres pieces
(`psycopg`, `DATABASE_URL`, migrations, `db/schema.sql`) are gone; test data was
not migrated. See [`docs/migration-firestore.md`](docs/migration-firestore.md) and
the earlier [`docs/migration-firebase-auth.md`](docs/migration-firebase-auth.md).

---

## Backend (`backend/app/`)

FastAPI service. Routes are defined on an inner app and mounted at `/api` on the served
`application`.

| File | Responsibility |
|------|----------------|
| `main.py` | FastAPI app: the `POST /device/putts` gate ingest, session/putt reads, session-metadata edit + delete, and putters CRUD. Mounts the API under `/api`. A thin CRUD layer — no analysis. |
| `db.py` | The backend's Firestore client (Admin SDK; bypasses rules; lazy, fail-soft). Ingest + iOS's ownership-scoped reads/writes; single-field filters + Python-side ordering (no composite indexes). Field lists (`_SESSION_FIELDS`, etc.) stay in sync with the frontend TS types. See `backend/db/README.md`. |
| `auth.py` | `require_user` / `require_device` / `require_user_or_device` dependencies → the Firebase UID. In local dev `AUTH_DEV_UID` short-circuits verification. |

**Conventions:** blocking Firestore calls run in a threadpool via `run_in_threadpool`;
persistence is fail-soft (no Firestore configured → no-op so the app still runs);
clients are lazy/optional so modules import cleanly with no config; ingest is idempotent
by `(session_id, putt_index)` — the putt's Firestore doc id is `"{session_id}_{putt_index}"`,
so the gate can safely retry.

**Selected endpoints** (all under `/api`): `POST /device/putts` (BLE gate ingest, auth as
the signed-in user *or* the legacy device token), `GET /sessions`, `GET /sessions/{id}`,
`GET /sessions/{id}/putts`, `POST /putts/offsets`, `PATCH /sessions/{id}` (metadata),
`DELETE /sessions/{id}`, `DELETE /sessions/{id}/putts/{i}`, and CRUD for `/putters`.

## Frontend (`frontend/src/`)

React 19, TypeScript, Vite, Tailwind v4 (`@tailwindcss/vite`), Oxlint. Routing is
`react-router` in `App.tsx` (`/` dashboard, `/sessions/:id`, `/putters`). It reads and
writes its own data **directly in Firestore via the Firebase Web SDK** — no backend
API calls (it never creates sessions/putts, only reads/edits/deletes them and does the
full putter CRUD).

- `firebaseClient.ts` — Firebase app, `auth`, `db` (Firestore), and `currentUid()`
  (the signed-in uid that scopes every query); config from build-time `VITE_FIREBASE_*`
  env (public, safe in the bundle).
- `sessions.ts` / `putters.ts` — the Firestore data layer (Web SDK reads/writes),
  single-equality-filter queries + client-side sort (index-free, rule-legal), field
  shapes mirroring `db.py`. Deletes cascade here (`deleteSession` removes its putts).
- `analysis.ts` — the golfer-perspective offset/side helpers (`golferSide`, `biasWord`).
  `golferSide` negates the stored `offset_mm` (pre-inverted on ingest) to recover the
  golfer's left/right.
- `AuthContext.tsx` / `Login.tsx` — email/password auth.
- `Dashboard.tsx`, `SessionDetail.tsx`, `PuttersPage.tsx`, `ContributionGraph.tsx`,
  `stats.ts` — views and building blocks.

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

**Firestore (Native mode)** — schemaless; the collection model is documented in
[`backend/db/README.md`](backend/db/README.md). Accessed by the **web app** directly
(Firebase Web SDK, scoped by `firestore.rules`) and the **backend** (Admin SDK, bypasses
rules) for ingest + iOS.

- **Collections:** `putters/{uuid}` (user-owned clubs, ≤1 active per user), `sessions/{sessionId}`
  (one doc per gate session; `sessionId` = the iOS session UUID; fields `length_feet`,
  `break_type`, `putter_id`, `putt_count`), and a top-level `putts/{sessionId_index}`
  (one doc per putt, id `"{session_id}_{putt_index}"`, denormalizing `session_id` +
  `user_id`; deletes cascade in code). Putts carry `offset_mm`, `direction`,
  `speed_mps`, and `sensor_offsets_mm` (per-sensor readings).
- Sessions/putts are created only by the backend on ingest (rules forbid clients
  creating them); the web reads/edits/deletes. Every query filters a single field, so
  no composite indexes are needed.

**If you change a returned field set, update it in all three places:** `db.py`'s
`_*_FIELDS`, `backend/db/README.md`, and the frontend TS types (`sessions.ts` /
`putters.ts` / `analysis.ts`) — and sometimes iOS.

---

## Development

### Run the whole web stack locally

```bash
./start.sh
```

Sets `AUTH_DEV_UID=local-dev` (skips Firebase verification, attributes all data to one
dev user). Creates `backend/.venv`, runs uvicorn on `:8000`
(`app.main:application --reload`), and `npm run dev` on `:5173` (Vite proxies `/api` →
`localhost:8000`).

**Local database:** `start.sh` launches the **Firestore emulator** (`localhost:8080`)
and points the backend at it via `FIRESTORE_EMULATOR_HOST`, so persistence works
without touching real Firestore. Needs the Firebase CLI (`npm i -g firebase-tools`)
and a Java runtime; without `firebase` on PATH the script warns and runs without
persistence (the app still runs, nothing persists).

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
AUTH_DEV_UID=dev FIRESTORE_EMULATOR_HOST=localhost:8080 \
  .venv/bin/uvicorn app.main:application --reload --port 8000
```

There is no automated test suite yet, so **verify changes by exercising the flow** —
post a putt to `/api/device/putts` (or relay one from the gate via iOS) and confirm it
reads back from `/api/sessions/{id}/putts`.

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
- **Firestore rules/indexes** are *not* in that workflow (hosting only). The web app
  depends on `firestore.rules`, so deploy them after any change:
  `firebase deploy --only firestore:rules,firestore:indexes`.
- **Backend** deploys to Cloud Run via `bash backend/deploy/cloud-run.sh` (provisioning;
  `--fast` for a code-only rebuild+redeploy). Container is `backend/Dockerfile`
  (Python 3.13-slim; single uvicorn worker — scale via Cloud Run instances). It also
  provisions a **Firestore Native database** and grants the runtime SA
  `roles/datastore.user`. Secrets: `CORS_ALLOW_ORIGINS`, `DEVICE_INGEST_TOKEN` /
  `DEVICE_INGEST_UID` (the legacy direct-post device auth); no DB secret — Firestore
  uses the runtime SA.

> `main` auto-deploys the frontend — be deliberate about what lands there.

---

For deeper guidance on conventions and cross-cutting changes, see
[`CLAUDE.md`](CLAUDE.md).
