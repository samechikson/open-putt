#!/usr/bin/env bash
# Provision + deploy the Putting Gate backend on Google Cloud
# (Cloud Run + Cloud Tasks + Cloud Storage). Run from the repo root after
# `gcloud auth login`. Idempotent-ish: re-running create steps may error if the
# resource exists — that's fine, skip and continue.
#
#   bash backend/deploy/cloud-run.sh
#
# Requires: gcloud CLI, a billing-enabled project, and backend/.env with
# SUPABASE_URL and SUPABASE_SECRET_KEY (used to seed Secret Manager).
set -euo pipefail

# Run from the repo root regardless of where the script is invoked, so the
# `backend/...` relative paths below resolve.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

# ---- Config (edit as needed) ------------------------------------------------
PROJECT="putting-gate"
REGION="us-central1"
REPO="putting-gate"                       # Artifact Registry repo
SERVICE="putting-gate-backend"            # Cloud Run service
BUCKET="gs://${PROJECT}-uploads"          # must be globally unique
QUEUE="putting-gate-jobs"                 # Cloud Tasks queue
SA_NAME="putting-gate-run"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
# Database: Supabase Postgres, reached directly with psycopg via its connection
# pooler. The connection string (DATABASE_URL) is seeded into Secret Manager from
# backend/.env (see docs/migration-firebase-auth.md).
# Frontend origin, used for the GCS bucket CORS (direct browser uploads) and the
# backend's CORS_ALLOW_ORIGINS secret. The web app is served from Firebase
# Hosting, which also proxies /api to this service (so API calls are same-origin).
CORS_ORIGIN="https://putting-gate.web.app"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/${SERVICE}"

gcloud config set project "$PROJECT"

# Build the container with layer caching (backend/deploy/cloudbuild.yaml). Only
# the small backend/ context is uploaded (see backend/.gcloudignore).
build_image () {
  gcloud builds submit backend \
    --config=backend/deploy/cloudbuild.yaml \
    --substitutions=_IMAGE="$IMAGE"
}

# Fast redeploy: skip provisioning (steps 1-6b) and just rebuild + ship the
# image. Env vars, secrets and the service account are preserved from the
# current revision. Use for code-only changes:
#   bash backend/deploy/cloud-run.sh --fast
if [[ "${1:-}" == "--fast" ]]; then
  build_image
  gcloud run deploy "$SERVICE" --region="$REGION" --image="${IMAGE}:latest"
  echo "Redeployed: $(gcloud run services describe "$SERVICE" \
    --region="$REGION" --format='value(status.url)')"
  exit 0
fi

# ---- 1. Enable APIs ---------------------------------------------------------
gcloud services enable \
  run.googleapis.com cloudtasks.googleapis.com storage.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com cloudbuild.googleapis.com

# ---- 2. Artifact Registry ---------------------------------------------------
gcloud artifacts repositories create "$REPO" \
  --repository-format=docker --location="$REGION" || true

# ---- 3. Cloud Storage bucket (+ 1-day lifecycle cleanup) --------------------
gcloud storage buckets create "$BUCKET" --location="$REGION" --uniform-bucket-level-access || true
# Transient uploads under uploads/ are deleted after 1 day; retained session
# videos under sessions/ are kept 90 days for playback.
cat > /tmp/lifecycle.json <<'JSON'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":1,"matchesPrefix":["uploads/"]}},
  {"action":{"type":"Delete"},"condition":{"age":90,"matchesPrefix":["sessions/"]}}
]}
JSON
gcloud storage buckets update "$BUCKET" --lifecycle-file=/tmp/lifecycle.json

# ---- 4. Cloud Tasks queue ---------------------------------------------------
gcloud tasks queues create "$QUEUE" --location="$REGION" || true
# Bound concurrency to protect the small instance; tune as needed.
gcloud tasks queues update "$QUEUE" --location="$REGION" \
  --max-concurrent-dispatches=2 --max-attempts=3

# ---- 5. Secrets -------------------------------------------------------------
# Seed from backend/.env; generate a random internal token for /process auth.
set -a; source backend/.env; set +a

create_secret () {  # name value — replaces the latest version
  printf '%s' "$2" | gcloud secrets create "$1" --data-file=- 2>/dev/null \
    || printf '%s' "$2" | gcloud secrets versions add "$1" --data-file=-
}
create_secret DATABASE_URL         "$DATABASE_URL"
create_secret CORS_ALLOW_ORIGINS   "$CORS_ORIGIN"
# The internal token protects /process; generate once and keep it stable across
# re-runs (rotating it would 403 any in-flight tasks).
gcloud secrets describe TASKS_INTERNAL_TOKEN >/dev/null 2>&1 \
  || printf '%s' "$(openssl rand -hex 32)" | gcloud secrets create TASKS_INTERNAL_TOKEN --data-file=-

# ---- 6. Runtime service account + IAM --------------------------------------
gcloud iam service-accounts create "$SA_NAME" --display-name="Putting Gate Cloud Run" || true
# A newly created service account takes a few seconds to propagate before IAM
# bindings will accept it; wait until it's resolvable.
for _ in $(seq 1 20); do
  gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 && break
  echo "Waiting for service account ${SA_EMAIL} to propagate..."
  sleep 3
done
gcloud storage buckets add-iam-policy-binding "$BUCKET" \
  --member="serviceAccount:${SA_EMAIL}" --role=roles/storage.objectAdmin
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" --role=roles/cloudtasks.enqueuer
# Sign upload URLs via the IAM signBlob API (no private key on Cloud Run):
# the SA must be able to create tokens for itself.
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="serviceAccount:${SA_EMAIL}" --role=roles/iam.serviceAccountTokenCreator
for S in DATABASE_URL CORS_ALLOW_ORIGINS TASKS_INTERNAL_TOKEN; do
  gcloud secrets add-iam-policy-binding "$S" \
    --member="serviceAccount:${SA_EMAIL}" --role=roles/secretmanager.secretAccessor
done

# ---- 6b. Bucket CORS so browsers can PUT directly to GCS --------------------
cat > /tmp/gcs-cors.json <<JSON
[{"origin":["${CORS_ORIGIN}","http://localhost:5173"],"method":["PUT","GET"],"responseHeader":["Content-Type"],"maxAgeSeconds":3600}]
JSON
gcloud storage buckets update "$BUCKET" --cors-file=/tmp/gcs-cors.json

# ---- 7. First deploy (cached build from backend/Dockerfile) ----------------
# PROCESS_URL isn't known yet; deploy once, then set it and redeploy.
build_image
gcloud run deploy "$SERVICE" \
  --image="${IMAGE}:latest" \
  --region="$REGION" \
  --service-account="$SA_EMAIL" \
  --allow-unauthenticated \
  --cpu=2 --memory=2Gi --timeout=3600 --concurrency=2 --min-instances=0 --max-instances=3 \
  --set-env-vars="GCP_PROJECT=${PROJECT},GCS_BUCKET=${PROJECT}-uploads,TASKS_QUEUE=${QUEUE},TASKS_LOCATION=${REGION},GCS_SIGNER_SA=${SA_EMAIL},FIREBASE_PROJECT_ID=${PROJECT}" \
  --set-secrets="DATABASE_URL=DATABASE_URL:latest,CORS_ALLOW_ORIGINS=CORS_ALLOW_ORIGINS:latest,TASKS_INTERNAL_TOKEN=TASKS_INTERNAL_TOKEN:latest"

# ---- 8. Wire PROCESS_URL and redeploy env ----------------------------------
URL="$(gcloud run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')"
# The API is mounted under /api (see backend/app/main.py), so the Cloud Tasks
# callback targets /api/process.
gcloud run services update "$SERVICE" --region="$REGION" \
  --update-env-vars="PROCESS_URL=${URL}/api/process"

echo
echo "Deployed: $URL  (API served under ${URL}/api)"
echo "Next:"
echo "  • Frontend: served by Firebase Hosting, which proxies /api/** here"
echo "    (firebase.json); run 'firebase deploy --only hosting'"
echo "  • iOS AppSettings.backendBaseURL is ${URL}/api"
echo "  • Smoke test: curl -X POST $URL/api/uploads -H 'Content-Type: application/json' -d '{\"filename\":\"clip.mov\"}'"
echo "    (should return a signed upload_url; PUT a file to it, then POST /api/analyze-session)"
