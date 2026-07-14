#!/bin/bash
set -e

# Run the whole stack locally. The backend runs in LOCAL_MODE: uploads go to a
# local directory and analysis runs in-process, so no GCS / Cloud Tasks are
# needed. Persistence, auth and Realtime still use the (hosted) Supabase in
# backend/.env — point that at a separate Supabase project if you don't want
# local testing to touch production data.
export LOCAL_MODE=1

# Auth: skip Firebase token verification locally and attribute all data to a
# single dev user. Unset this to exercise real Firebase ID tokens.
export AUTH_DEV_UID="${AUTH_DEV_UID:-local-dev-user}"

# Database: point at a Postgres to exercise persistence + the sessions/putters
# endpoints. Precedence is shell DATABASE_URL, then backend/.env (loaded by the
# app via load_dotenv), then a local Postgres fallback (createdb putting_gate &&
# psql putting_gate -f backend/db/schema.sql). Only export the fallback when
# neither source provides a URL — exporting it unconditionally would shadow the
# one in backend/.env, since load_dotenv() does not override an already-set env
# var, and the pool would then time out against a Postgres that isn't running.
if [ -z "$DATABASE_URL" ] && ! grep -qs '^DATABASE_URL=' backend/.env; then
  export DATABASE_URL="postgresql://localhost/putting_gate"
fi

# Backend
cd backend
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
  .venv/bin/pip install -r requirements.txt
fi
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
