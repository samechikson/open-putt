# Putting Gate

A golf putting-analysis tool. A player rolls a putt through a physical 3d printed gate
and the system measures how far **off-center** the ball crossed in millimeters as well as the ball's **speed**. 
Over time it builds a history of sessions and putts so a player can see their tendencies per putter, break,
and distance.

The project includes a 3D-printed "bridge" with
a laser and three time-of-flight distance sensors, driven by an ESP32, detects each
pass and computes the offset on-device, then sends it over **Bluetooth (BLE)** to an
iOS app, which writes it **directly to Firestore** via the Firebase iOS SDK under the
signed-in user.

---

## Repository layout

| Path | What it is |
|------|------------|
| `microcontroller/` | ESP32 (Arduino C++) firmware for the physical laser gate + ToF sensors, and its bring-up sketches. |
| `ios/` | SwiftUI app (`PuttingGate`). Connects to the hardware gate over BLE and writes each putt **directly to Firestore** via the Firebase iOS SDK; shows history/settings. |
| `frontend/` | React 19 + TypeScript + Vite + Tailwind v4 web app for showing history of putting sessions. Reads/writes Firestore **directly** via the Firebase Web SDK (no backend calls). Served by Firebase Hosting. |
| `backend/` (optional) | Python / FastAPI service on Google Cloud Run. Now only the legacy ESP32 direct-post ingest path (`POST /api/device/putts`, Admin SDK). |
| `backend/db/README.md` | The Firestore collection model (data lives in Firestore Native mode). |
| `firestore.rules` / `firestore.indexes.json` | Per-user client access for the web + iOS apps; no composite indexes. |
| `docs/` | Operator runbooks (the Firestore + Firebase-auth migration runbooks). |
| `start.sh` | One command to run the whole web stack locally (with the Firestore emulator). |

---

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

SwiftUI, Firebase (`FirebaseCore` / `FirebaseAuth` / `FirebaseFirestore`). Entry point
`PuttingGateApp.swift` configures Firebase, builds the object graph, and gates the UI
behind auth. Three tabs: **Gate / History / Settings**.

The app is a **BLE central** that pairs with the hardware gate and writes each putt
**directly to Firestore** via the Firebase iOS SDK (no backend):

- `Gate/` — `GateConnection` (BLE central; scans for/subscribes to the gate, decodes
  each `GatePutt`, applies center calibration, and hands it to the service to persist),
  `GatePutt`, `GateCalibration` + `CalibrationStore` (center-calibration state).
- `Session/` — `SessionMetadataService` (the **Firestore data layer**: reads
  sessions/putts/putters, edits metadata, deletes, and `ingest`s gate putts),
  `SessionConfig` / `SessionConfigStore`, `SessionHistory`, and the `SessionRow` /
  `SessionPutt` / `Putter` models (built from `DocumentSnapshot`).
- `Views/` — `GateView`, `HistoryView`, `SessionDetailView`, `SettingsView`,
  `CalibrationView`, `LoginView`.
- `Auth/`, `Theme/`, `Resources/` — auth, the warm "Organic" design system, assets.

`GoogleService-Info.plist` is bundled in the target; Firebase products are added via
Swift Package Manager (`FirebaseFirestore` is wired into `project.pbxproj`).

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
[`backend/db/README.md`](backend/db/README.md). Accessed by the **web and iOS apps**
directly (Firebase SDK, scoped by `firestore.rules`); the **backend** (Admin SDK,
bypasses rules) writes only via the legacy ESP32 direct-post path.

- **Collections:** `putters/{uuid}` (user-owned clubs, ≤1 active per user), `sessions/{sessionId}`
  (one doc per gate session; `sessionId` = the iOS session UUID; fields `length_feet`,
  `break_type`, `putter_id`, `putt_count`), and a top-level `putts/{sessionId_index}`
  (one doc per putt, id `"{session_id}_{putt_index}"`, denormalizing `session_id` +
  `user_id`; deletes cascade in code). Putts carry `offset_mm`, `direction`,
  `speed_mps`, and `sensor_offsets_mm` (per-sensor readings).
- iOS creates sessions/putts on ingest; both apps read/edit/delete their own (rules
  scope everything by `user_id`). Every query filters a single field, so no composite
  indexes are needed.

**If you change a returned field set, update it in all three places:** `db.py`'s
`_*_FIELDS`, `backend/db/README.md`, and the frontend TS types (`sessions.ts` /
`putters.ts` / `analysis.ts`) — and sometimes iOS.

## Backend (`backend/app/`) - DEPRECATED

FastAPI service. Routes are defined on an inner app and mounted at `/api` on the served
`application`.

| File | Responsibility |
|------|----------------|
| `main.py` | FastAPI app: the `POST /device/putts` gate ingest, session/putt reads, session-metadata edit + delete, and putters CRUD. Mounts the API under `/api`. A thin CRUD layer — no analysis. |
| `db.py` | The backend's Firestore client (Admin SDK; bypasses rules; lazy, fail-soft). Now exercised only by the ESP32 direct-post path; single-field filters + Python-side ordering (no composite indexes). Field lists (`_SESSION_FIELDS`, etc.) stay in sync with the TS/Swift models. See `backend/db/README.md`. |
| `auth.py` | `require_user` / `require_device` / `require_user_or_device` dependencies → the Firebase UID. In local dev `AUTH_DEV_UID` short-circuits verification. |

**Conventions:** blocking Firestore calls run in a threadpool via `run_in_threadpool`;
persistence is fail-soft (no Firestore configured → no-op so the app still runs);
clients are lazy/optional so modules import cleanly with no config; ingest is idempotent
by `(session_id, putt_index)` — the putt's Firestore doc id is `"{session_id}_{putt_index}"`,
so the gate can safely retry.

The read / metadata / putter endpoints still exist under `/api`, but **no client
calls them any more** (both apps use the Firebase SDK directly). The only live
endpoint is `POST /device/putts` — the legacy ESP32 direct-post ingest (shared
`X-Device-Token`).
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
