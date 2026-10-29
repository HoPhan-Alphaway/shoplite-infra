#!/usr/bin/env bash
# One-time: create the GCS bucket that holds Terraform state for both stacks.
# Terraform cannot create its own state bucket (chicken and egg), so this is the only
# resource made by a script. Idempotent. NOT RUN YET - read it, then run it yourself.
#
#   bash scripts/bootstrap-state.sh [project-id] [region]
set -euo pipefail

# Git Bash on Windows: gcloud cannot find Python unless pointed at the one bundled with the Cloud SDK.
if [ -z "${CLOUDSDK_PYTHON:-}" ] && gc=$(command -v gcloud 2>/dev/null); then
  bp="$(dirname "$gc")/../platform/bundledpython/python.exe"
  [ -x "$bp" ] && export CLOUDSDK_PYTHON="$bp"
fi

PROJECT=${1:-shoplite-demo-1e7583}
REGION=${2:-us-central1}
BUCKET="${PROJECT}-tfstate"

if gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT" >/dev/null 2>&1; then
  echo "bucket gs://$BUCKET already exists"
else
  gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT" --location "$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi

# Keep old versions of the state file, so a bad apply can be recovered from.
gcloud storage buckets update "gs://$BUCKET" --project "$PROJECT" --versioning

echo
echo "Next: create gcp/backend.hcl with   bucket = \"$BUCKET\""
