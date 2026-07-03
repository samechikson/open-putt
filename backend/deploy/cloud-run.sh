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
CORS_ORIGIN="https://putting-gate-app.vercel.app"

gcloud config set project "$PROJECT"

# ---- 1. Enable APIs ---------------------------------------------------------
gcloud services enable \
  run.googleapis.com cloudtasks.googleapis.com storage.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com cloudbuild.googleapis.com

# ---- 2. Artifact Registry ---------------------------------------------------
gcloud artifacts repositories create "$REPO" \
  --repository-format=docker --location="$REGION" || true

# ---- 3. Cloud Storage bucket (+ 1-day lifecycle cleanup) --------------------
gcloud storage buckets create "$BUCKET" --location="$REGION" --uniform-bucket-level-access || true
cat > /tmp/lifecycle.json <<'JSON'
{"rule":[{"action":{"type":"Delete"},"condition":{"age":1}}]}
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
TASKS_INTERNAL_TOKEN="$(openssl rand -hex 32)"

create_secret () {  # name value
  printf '%s' "$2" | gcloud secrets create "$1" --data-file=- 2>/dev/null \
    || printf '%s' "$2" | gcloud secrets versions add "$1" --data-file=-
}
create_secret SUPABASE_URL         "$SUPABASE_URL"
create_secret SUPABASE_SECRET_KEY  "$SUPABASE_SECRET_KEY"
create_secret CORS_ALLOW_ORIGINS   "$CORS_ORIGIN"
create_secret TASKS_INTERNAL_TOKEN "$TASKS_INTERNAL_TOKEN"

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
for S in SUPABASE_URL SUPABASE_SECRET_KEY CORS_ALLOW_ORIGINS TASKS_INTERNAL_TOKEN; do
  gcloud secrets add-iam-policy-binding "$S" \
    --member="serviceAccount:${SA_EMAIL}" --role=roles/secretmanager.secretAccessor
done

# ---- 7. First deploy (builds from backend/Dockerfile) ----------------------
# PROCESS_URL isn't known yet; deploy once, then set it and redeploy.
gcloud run deploy "$SERVICE" \
  --source=backend \
  --region="$REGION" \
  --service-account="$SA_EMAIL" \
  --allow-unauthenticated \
  --cpu=2 --memory=2Gi --timeout=3600 --concurrency=2 --min-instances=0 --max-instances=3 \
  --set-env-vars="GCP_PROJECT=${PROJECT},GCS_BUCKET=${PROJECT}-uploads,TASKS_QUEUE=${QUEUE},TASKS_LOCATION=${REGION}" \
  --set-secrets="SUPABASE_URL=SUPABASE_URL:latest,SUPABASE_SECRET_KEY=SUPABASE_SECRET_KEY:latest,CORS_ALLOW_ORIGINS=CORS_ALLOW_ORIGINS:latest,TASKS_INTERNAL_TOKEN=TASKS_INTERNAL_TOKEN:latest"

# ---- 8. Wire PROCESS_URL and redeploy env ----------------------------------
URL="$(gcloud run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')"
gcloud run services update "$SERVICE" --region="$REGION" \
  --update-env-vars="PROCESS_URL=${URL}/process"

echo
echo "Deployed: $URL"
echo "Next:"
echo "  • Set Vercel env VITE_API_BASE=$URL and redeploy the frontend"
echo "  • Update ios AppSettings.backendBaseURL to $URL"
echo "  • Smoke test: curl -X POST $URL/analyze-session -F video=@backend/tests/fixtures/IMG_0012.MOV"
