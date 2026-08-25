#!/bin/bash
set -e

# Run the whole stack locally. Persistence goes to a local Firestore emulator
# (see below), and auth uses a fixed dev UID by default. Putts are ingested from
# the hardware gate via the iOS app; the web frontend is a read/review surface.

# Auth: verify real Firebase ID tokens, identical to production. This needs
# Application Default Credentials — run `gcloud auth application-default login`
# once (Cloud Run uses its runtime service account) — and the Firebase project
# id. Only default the project when neither the shell nor backend/.env sets it,
# so we don't shadow a value in backend/.env (load_dotenv won't override an
# already-exported var).
if [ -z "$FIREBASE_PROJECT_ID" ] && ! grep -qs '^FIREBASE_PROJECT_ID=' backend/.env backend/.env.local; then
  export FIREBASE_PROJECT_ID="putting-gate"
fi

# Local auth bypass: skip Firebase token verification and act as this fixed UID,
# so local dev needs no Application Default Credentials. Set it to your real
# Firebase UID to load your own sessions from the DB (data is scoped by user_id).
# Same precedence as above — don't shadow a value in the shell or the env files.
if [ -z "$AUTH_DEV_UID" ] && ! grep -qs '^AUTH_DEV_UID=' backend/.env backend/.env.local; then
  export AUTH_DEV_UID="local-dev"
fi

# Database: a local Firestore emulator, so persistence + the sessions/putters
# endpoints work without touching the real Firestore. The backend picks it up via
# FIRESTORE_EMULATOR_HOST (db.py routes all reads/writes to the emulator when it's
# set). Needs the Firebase CLI (`npm i -g firebase-tools`) and a Java runtime.
# GOOGLE_CLOUD_PROJECT gives both the emulator and the client a project id; the
# value is arbitrary against the emulator.
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-${FIREBASE_PROJECT_ID:-putting-gate}}"
FIRESTORE_EMULATOR_PID=""
if [ -z "$FIRESTORE_EMULATOR_HOST" ]; then
  if command -v firebase >/dev/null 2>&1; then
    export FIRESTORE_EMULATOR_HOST="localhost:8080"
    echo "Starting Firestore emulator on ${FIRESTORE_EMULATOR_HOST}..."
    firebase emulators:start --only firestore --project "$GOOGLE_CLOUD_PROJECT" &
    FIRESTORE_EMULATOR_PID=$!
    # Give the emulator a moment to bind its port before the backend connects.
    sleep 4
  else
    echo "WARNING: firebase CLI not found — persistence is disabled this run."
    echo "  Install it with: npm i -g firebase-tools"
  fi
fi

# Backend
cd backend
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi
# Sync deps every run so an existing venv still picks up new requirements
# (e.g. firebase-admin, needed now that auth verifies tokens locally).
.venv/bin/pip install -q -r requirements.txt
.venv/bin/uvicorn app.main:application --reload --port 8000 &
BACKEND_PID=$!

# Frontend
cd ../frontend
npm run dev &
FRONTEND_PID=$!

echo "Backend: http://localhost:8000"
echo "Frontend: http://localhost:5173"
echo "Press Ctrl-C to stop both."

trap "kill $BACKEND_PID $FRONTEND_PID $FIRESTORE_EMULATOR_PID 2>/dev/null; wait $BACKEND_PID $FRONTEND_PID $FIRESTORE_EMULATOR_PID 2>/dev/null" INT TERM EXIT
wait $BACKEND_PID $FRONTEND_PID
