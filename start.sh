#!/bin/bash
set -e

# Run the whole stack locally. The backend runs in LOCAL_MODE only for storage:
# uploads go to a local directory and analysis runs in-process, so no GCS /
# Cloud Tasks are needed. Auth and persistence behave exactly as deployed —
# real Firebase ID-token verification, and the Postgres in backend/.env.
export LOCAL_MODE=1

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

# Database: point at a Postgres to exercise persistence + the sessions/putters
# endpoints. Precedence is shell DATABASE_URL, then backend/.env (loaded by the
# app via load_dotenv), then a local Postgres fallback (createdb putting_gate &&
# psql putting_gate -f backend/db/schema.sql). Only export the fallback when
# neither source provides a URL — exporting it unconditionally would shadow the
# one in backend/.env, since load_dotenv() does not override an already-set env
# var, and the pool would then time out against a Postgres that isn't running.
if [ -z "$DATABASE_URL" ] && ! grep -qs '^DATABASE_URL=' backend/.env backend/.env.local; then
  export DATABASE_URL="postgresql://localhost/putting_gate"
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

trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; wait $BACKEND_PID $FRONTEND_PID 2>/dev/null" INT TERM EXIT
wait $BACKEND_PID $FRONTEND_PID
