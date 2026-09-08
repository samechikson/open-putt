# Setting up your own Putting Gate

This guide walks you through running Putting Gate on **your own infrastructure** —
your own Firebase project, your own iOS build, your own hardware gate. The repo
ships no shared backend; everything is scoped to a Firebase project *you* create,
so your putts live in your database and nobody else's.

If you just want to understand what the pieces are, read the top-level
[`README.md`](README.md) first. This document is the practical "clone → run" path.

## What you'll stand up

```
Hardware gate (ESP32) ─BLE→ iOS app ──(Firebase iOS SDK)──┐
Web app ──────────────────(Firebase Web SDK)──────────────┼─→ YOUR Firestore
   └─ Firebase Auth (email/password)                       │   ▲ firestore.rules
                                                            │
(optional) ESP32 direct-post → Cloud Run: FastAPI ─────────┘
```

The **only required cloud service is a Firebase project** (Auth + Firestore). The
FastAPI backend is optional — it exists only for an ESP32 that posts putts
directly over WiFi, which the reference hardware does *not* do (it uses BLE to the
phone). You can ignore the whole `backend/` directory unless you specifically want
that path.

## Prerequisites

| For | You need |
|-----|----------|
| Everything | A Google account and the [Firebase CLI](https://firebase.google.com/docs/cli) (`npm i -g firebase-tools`), Node.js 20+ |
| Web app | The above |
| iOS app | A Mac with Xcode 15+, and an Apple ID (a free one is fine for running on your own device) |
| Hardware | An ESP32 dev board, 3× VL53L4CD ToF sensors, a laser module, and [`arduino-cli`](https://arduino.github.io/arduino-cli/) — parts in [`PARTS_LIST.md`](PARTS_LIST.md), wiring in [`microcontroller/README.md`](microcontroller/README.md) |
| Backend (optional) | A billing-enabled Google Cloud project and the `gcloud` CLI |

---

## 1. Create your Firebase project

1. Go to the [Firebase console](https://console.firebase.google.com/) and **create a
   project**. Note its **Project ID** (e.g. `my-putting-gate`) — you'll use it
   everywhere below.
2. **Enable Authentication → Sign-in method → Email/Password.** The apps gate all
   data behind a signed-in user; email/password is the only provider wired up.
3. **Create a Firestore database** (Build → Firestore Database → Create database) in
   **Native mode**. Pick a region close to you.
4. From the repo root, point the Firebase CLI at your project and deploy the
   security rules and indexes:

   ```bash
   firebase login
   firebase use --add            # pick your project, alias it "default"
   firebase deploy --only firestore:rules,firestore:indexes
   ```

   `firebase use --add` writes a `.firebaserc` (gitignored). **The rules are the
   security boundary** — a signed-in user can only touch documents whose `user_id`
   is their uid. The web and iOS apps are broken/insecure until the rules are live,
   so don't skip this.

> **A note on "API keys":** The Firebase web/iOS API keys are **not secrets** — they
> identify your project to Firebase and are meant to ship in client apps. Access is
> controlled by `firestore.rules`, not by hiding the key. That's why the web config
> is fine to bake into the bundle. Real secrets (service-account keys) never belong
> in the repo; the `.gitignore` blocks the common filenames.

---

## 2. Web app (`frontend/`)

1. In the Firebase console, add a **Web app** to your project (Project settings →
   Your apps → Web). Copy the `firebaseConfig` values it shows you.
2. Create `frontend/.env.local` (gitignored) from these values:

   ```bash
   # frontend/.env.local
   VITE_FIREBASE_API_KEY=AIza...
   VITE_FIREBASE_AUTH_DOMAIN=my-putting-gate.firebaseapp.com
   VITE_FIREBASE_PROJECT_ID=my-putting-gate
   VITE_FIREBASE_APP_ID=1:1234567890:web:abcdef...
   # Optional (present in the console config; not strictly required by the app):
   VITE_FIREBASE_STORAGE_BUCKET=my-putting-gate.firebasestorage.app
   VITE_FIREBASE_MESSAGING_SENDER_ID=1234567890
   ```

3. Run it:

   ```bash
   cd frontend
   npm install
   npm run dev            # http://localhost:5173
   ```

   Create an account on the login screen (email/password) — that account owns the
   data you'll see.

4. **Deploy (optional).** To host it on Firebase Hosting:

   ```bash
   cd frontend && npm run build && cd ..
   firebase deploy --only hosting
   ```

   The repo also has a GitHub Actions workflow
   ([`.github/workflows/deploy-frontend.yml`](.github/workflows/deploy-frontend.yml))
   that auto-deploys on push to `main`. It's **fork-friendly** — nothing is
   hard-coded to a specific project, and the job skips itself until you configure
   it, so an unconfigured fork won't show failing runs. To enable it, go to
   **Settings → Secrets and variables → Actions** in your fork and set:
   - **Variables** (Repository variables): `VITE_FIREBASE_API_KEY`,
     `VITE_FIREBASE_AUTH_DOMAIN`, `VITE_FIREBASE_PROJECT_ID`,
     `VITE_FIREBASE_APP_ID`, `VITE_FIREBASE_STORAGE_BUCKET`,
     `VITE_FIREBASE_MESSAGING_SENDER_ID` — the same values as your
     `frontend/.env.local`. The workflow reuses `VITE_FIREBASE_PROJECT_ID` as the
     deploy target, so you don't set the project id twice.
   - **Secret**: `FIREBASE_SERVICE_ACCOUNT` — a service-account key JSON with
     permission to deploy Firebase Hosting (Firebase console → Project settings →
     Service accounts → Generate new private key; paste the whole JSON as the
     secret value).

   If you'd rather not use CI at all, delete the workflow and deploy manually with
   the command above.

---

## 3. iOS app (`ios/PuttingGate/`)

The iOS app is a BLE central that reads putts from the hardware gate and writes them
to your Firestore. **BLE does not work in the Simulator** — you need a real iPhone
and the physical gate to exercise the full flow, though the app builds and its
history/settings screens run in the Simulator.

1. In the Firebase console, add an **iOS app** to your project. Give it **your own
   bundle identifier** (e.g. `com.yourname.puttinggate`).
2. Download the generated **`GoogleService-Info.plist`** and save it at
   `ios/PuttingGate/GoogleService-Info.plist`. This path is **gitignored** — your
   real config never gets committed. A placeholder
   [`GoogleService-Info.plist.example`](ios/PuttingGate/GoogleService-Info.plist.example)
   shows the shape.
3. Open `ios/PuttingGate.xcodeproj` in Xcode and set **your** signing identity:
   - Target **PuttingGate** → **Signing & Capabilities** → select your **Team**.
   - Set **Bundle Identifier** to the one you registered in step 1.

   > The checked-in project file references the original author's Apple team
   > (`DEVELOPMENT_TEAM`) and bundle id (`com.puttinggate.app`). Xcode will
   > override these with your selection; just don't commit your team id back.
4. Firebase is added via Swift Package Manager and should resolve on first open
   (File → Packages → Resolve if needed). Build & run on your device.

---

## 4. Hardware gate (`microcontroller/`)

Full parts list is in [`PARTS_LIST.md`](PARTS_LIST.md); wiring, sensor geometry, the
detection math, and the BLE payload are documented in
[`microcontroller/README.md`](microcontroller/README.md).

1. Assemble the gate and wire the three ToF sensors + laser to the ESP32 per that
   README.
2. Flash the firmware (the `huge_app` partition scheme is **required** — BLE
   overflows the default):

   ```bash
   cd microcontroller/putt_tracker
   arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --upload -p /dev/cu.usbserial-0001 .
   arduino-cli monitor -p /dev/cu.usbserial-0001 -c baudrate=115200
   ```

3. The gate advertises over BLE as **`PuttingGate`**. The service/characteristic
   UUIDs in the firmware must match the iOS app (`GateConnection.swift`) — they do
   out of the box; only change them if you change both sides.

The reference firmware has **no WiFi and no device token** — it talks only BLE to
the phone, so there's nothing secret to configure on the device.

---

## 5. Backend on Cloud Run (optional — skip unless you need it)

You only need this if you want an ESP32 that posts putts **directly** over WiFi
(bypassing the phone), or you otherwise want the FastAPI ingest service. The
reference setup does **not** use it.

The deploy script [`backend/deploy/cloud-run.sh`](backend/deploy/cloud-run.sh) is
parameterized by environment variables — you don't edit the file. Only `PROJECT`
(your Google Cloud project id) is required; `REGION`, `AR_REPO`, `SERVICE`,
`SA_NAME`, and `CORS_ORIGIN` have sensible defaults (`CORS_ORIGIN` defaults to your
project's Firebase Hosting domain, `https://<PROJECT>.web.app`):

```bash
# after `gcloud auth login`, against a billing-enabled project
PROJECT=my-gcp-project bash backend/deploy/cloud-run.sh
# override a default if you need to:
PROJECT=my-gcp-project REGION=europe-west1 bash backend/deploy/cloud-run.sh
```

Before running, put `DEVICE_INGEST_TOKEN` and `DEVICE_INGEST_UID` in `backend/.env`
(the script seeds them into Secret Manager). Use `--fast` for a code-only
rebuild+redeploy.

The service authenticates the ESP32 with a shared token you set as secrets
(`DEVICE_INGEST_TOKEN` / `DEVICE_INGEST_UID`). The runtime service account gets
Firestore access via Application Default Credentials — no key file needed. See the
comments in the deploy script and [`CLAUDE.md`](CLAUDE.md) for the details.

To run the backend locally against the Firestore emulator, use `./start.sh` from the
repo root (it launches the emulator, the backend on `:8000`, and the web app on
`:5173`, attributing all data to a single dev user).

---

## Local development with the emulator

`./start.sh` runs the whole web stack locally with the **Firestore emulator**, so you
can develop without touching real Firestore:

```bash
./start.sh
```

It needs the Firebase CLI and a Java runtime for the emulator. It sets
`AUTH_DEV_UID=local-dev` (skips token verification and attributes all data to one dev
user), so you don't even need a real login for local web work. If `firebase` isn't
installed it warns and runs without persistence.

---

## Checklist

- [ ] Firebase project created; Email/Password auth enabled; Firestore (Native) created
- [ ] `firebase deploy --only firestore:rules,firestore:indexes` run
- [ ] `frontend/.env.local` filled from your Web app config; `npm run dev` works
- [ ] iOS app added in Firebase; `GoogleService-Info.plist` dropped in; your Team + bundle id set in Xcode
- [ ] Firmware flashed with `huge_app`; gate advertises as `PuttingGate`
- [ ] (optional) backend deploy script edited to your project and deployed
