# Putting Gate

This repo has the code and instructions to build a 3D printed golf putting-analysis tool to measure a player's putting accuracy and speed.

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

## Getting started

- **Build a gate and run it end-to-end** — gather parts, print the enclosure, wire
  and flash the electronics, and roll your first putt:
  [`ASSEMBLY.md`](ASSEMBLY.md).
- **Run the software on your own infrastructure** — your Firebase project, the web +
  iOS apps, and the optional backend: [`SETUP.md`](SETUP.md).

Each component has a deeper doc: [`microcontroller/README.md`](microcontroller/README.md)
(hardware wiring, geometry, firmware), [`cad/README.md`](cad/README.md) (the printable
enclosure), [`backend/db/README.md`](backend/db/README.md) (the Firestore data model),
and [`CLAUDE.md`](CLAUDE.md) (architecture and conventions).

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

## License

Released under the [MIT License](LICENSE).

---

For deeper guidance on conventions and cross-cutting changes, see
[`CLAUDE.md`](CLAUDE.md).
