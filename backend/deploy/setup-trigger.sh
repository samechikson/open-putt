#!/usr/bin/env bash
# One-time setup: auto-deploy the backend to Cloud Run whenever backend/**
# changes on main, via a GitHub-connected Cloud Build trigger.
#
#   bash backend/deploy/setup-trigger.sh
#
# PREREQUISITE (one-time, in the console — this is an OAuth step the CLI can't
# do headless): connect the GitHub repo to Cloud Build so a trigger can read it:
#   Cloud Console → Cloud Build → Triggers → "Connect repository" →
#   GitHub (Cloud Build GitHub App) → authorize samechikson/putting-gate-app.
# Once connected, run this script to grant IAM and create the trigger.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

PROJECT="putting-gate"
SERVICE="putting-gate-backend"
REPO_OWNER="samechikson"
REPO_NAME="putting-gate-app"
RUNTIME_SA="putting-gate-run@${PROJECT}.iam.gserviceaccount.com"

gcloud config set project "$PROJECT"

# The Cloud Build service account runs the trigger. It needs to: push to
# Artifact Registry, deploy Cloud Run revisions, and "act as" the runtime
# service account the service runs under.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${CB_SA}" --role=roles/artifactregistry.writer
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${CB_SA}" --role=roles/run.developer
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --member="serviceAccount:${CB_SA}" --role=roles/iam.serviceAccountUser

# Create the push-to-main trigger, scoped to backend changes so frontend/iOS
# commits don't redeploy. Re-running is a no-op if the trigger already exists.
gcloud builds triggers create github \
  --name=deploy-backend-on-main \
  --repo-owner="$REPO_OWNER" \
  --repo-name="$REPO_NAME" \
  --branch-pattern='^main$' \
  --included-files='backend/**' \
  --build-config=backend/deploy/cloudbuild.deploy.yaml \
  || echo "Trigger 'deploy-backend-on-main' may already exist — edit it in the console or delete and re-run."

echo
echo "Done. Pushes to main that touch backend/** will now build + deploy."
echo "Watch runs at: https://console.cloud.google.com/cloud-build/builds?project=${PROJECT}"
