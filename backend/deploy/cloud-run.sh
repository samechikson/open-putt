#!/usr/bin/env bash
# Provision + deploy the Putting Gate backend on Google Cloud (Cloud Run +
# Firestore). Run from the repo root after `gcloud auth login`. Idempotent-ish:
# re-running create steps may error if the resource exists — that's fine, skip
# and continue.
#
#   bash backend/deploy/cloud-run.sh
#
# Requires: gcloud CLI and a billing-enabled project. Persistence is Firestore
# (Native mode), reached by the runtime service account via the Admin SDK — no
# connection string or DB secret needed. The backend ingests hardware-gate putts
# relayed by the iOS app; there's no video pipeline (so no Cloud Storage or Cloud
# Tasks).
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
SA_NAME="putting-gate-run"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
# Frontend origin, used for the backend's CORS_ALLOW_ORIGINS secret. The web app
# is served from Firebase Hosting, which also proxies /api to this service (so
# API calls are same-origin).
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

# Fast redeploy: skip provisioning and just rebuild + ship the image. Env vars,
# secrets and the service account are preserved from the current revision. Use
# for code-only changes:
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
  run.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com cloudbuild.googleapis.com firestore.googleapis.com

# ---- 2. Artifact Registry ---------------------------------------------------
gcloud artifacts repositories create "$REPO" \
  --repository-format=docker --location="$REGION" || true

# ---- 3. Firestore (Native mode) database ------------------------------------
# One (default) database per project. Creating it is a one-time op; re-runs error
# harmlessly once it exists. Location can be regional (matches Cloud Run) or a
# multi-region — it's fixed at creation and can't be changed later.
gcloud firestore databases create --location="$REGION" --type=firestore-native \
  || echo "Firestore database already exists (or is being created) — continuing."

# ---- 4. Secrets -------------------------------------------------------------
# Seed from backend/.env (DEVICE_INGEST_TOKEN / DEVICE_INGEST_UID must already be
# present there or as existing secrets).
set -a; source backend/.env; set +a

create_secret () {  # name value — replaces the latest version
  printf '%s' "$2" | gcloud secrets create "$1" --data-file=- 2>/dev/null \
    || printf '%s' "$2" | gcloud secrets versions add "$1" --data-file=-
}
create_secret CORS_ALLOW_ORIGINS   "$CORS_ORIGIN"

# ---- 5. Runtime service account + IAM --------------------------------------
gcloud iam service-accounts create "$SA_NAME" --display-name="Putting Gate Cloud Run" || true
# A newly created service account takes a few seconds to propagate before IAM
# bindings will accept it; wait until it's resolvable.
for _ in $(seq 1 20); do
  gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 && break
  echo "Waiting for service account ${SA_EMAIL} to propagate..."
  sleep 3
done
# Firestore read/write (the Admin SDK uses the Datastore role).
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" --role=roles/datastore.user
for S in CORS_ALLOW_ORIGINS DEVICE_INGEST_TOKEN DEVICE_INGEST_UID; do
  gcloud secrets add-iam-policy-binding "$S" \
    --member="serviceAccount:${SA_EMAIL}" --role=roles/secretmanager.secretAccessor
done

# ---- 6. Deploy (cached build from backend/Dockerfile) ----------------------
build_image
gcloud run deploy "$SERVICE" \
  --image="${IMAGE}:latest" \
  --region="$REGION" \
  --service-account="$SA_EMAIL" \
  --allow-unauthenticated \
  --cpu=1 --memory=512Mi --timeout=60 --concurrency=80 --min-instances=0 --max-instances=3 \
  --set-env-vars="FIREBASE_PROJECT_ID=${PROJECT}" \
  --set-secrets="CORS_ALLOW_ORIGINS=CORS_ALLOW_ORIGINS:latest,DEVICE_INGEST_TOKEN=DEVICE_INGEST_TOKEN:latest,DEVICE_INGEST_UID=DEVICE_INGEST_UID:latest"

URL="$(gcloud run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')"

echo
echo "Deployed: $URL  (API served under ${URL}/api)"
echo "Next:"
echo "  • Frontend: served by Firebase Hosting, which proxies /api/** here"
echo "    (firebase.json); run 'firebase deploy --only hosting'"
echo "  • iOS AppSettings.backendBaseURL is ${URL}/api"
echo "  • Smoke test: curl $URL/api/health   (should return {\"status\":\"ok\"})"
