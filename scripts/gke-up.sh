#!/usr/bin/env bash
# Build the GKE cluster from nothing and hand it to Argo CD. NOT RUN YET.
#
#   bash scripts/gke-up.sh            # asks before spending money
#   bash scripts/gke-up.sh --yes      # no questions
#
# Steps: Terraform cluster stack -> kubectl credentials -> Argo CD (helm, once) -> root app.
# After that Argo CD builds everything else from git (gcp/ stays persistent between runs).
# Expect roughly 20-30 minutes in total (to be measured on the first run).
#
# Prerequisites, once: gcp/persistent applied, scripts/seed-secrets.sh run (status: no MISSING),
# the gitops branch with clusters/gke-us merged to main (Argo CD reads main).
set -euo pipefail

# Git Bash on Windows: gcloud cannot find Python unless pointed at the one bundled with the Cloud SDK.
if [ -z "${CLOUDSDK_PYTHON:-}" ] && gc=$(command -v gcloud 2>/dev/null); then
  bp="$(dirname "$gc")/../platform/bundledpython/python.exe"
  [ -x "$bp" ] && export CLOUDSDK_PYTHON="$bp"
fi

HERE=$(cd "$(dirname "$0")/.." && pwd)
GITOPS=${GITOPS_DIR:-$HERE/../shoplite-gitops}
PROJECT=${PROJECT:-shoplite-demo-1e7583}
ARGOCD_CHART_VERSION=10.10.2 # keep in sync with shoplite-gitops/platform/argocd.yaml
YES=false; [[ "${1:-}" == "--yes" ]] && YES=true

for bin in gcloud terraform kubectl helm; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done
[ -f "$GITOPS/bootstrap/gke-root-app.yaml" ] || { echo "gitops repo not found at $GITOPS (set GITOPS_DIR)"; exit 1; }
[ -f "$HERE/gcp/backend.hcl" ] || { echo "missing gcp/backend.hcl (see gcp/backend.hcl.example)"; exit 1; }

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

say "0. Preflight"
bash "$HERE/scripts/seed-secrets.sh" status || {
  echo "Some secrets have no value yet: Argo CD apps would wait for them. Seed them first (seed-secrets.sh)."
  $YES || exit 1
}
if ! $YES; then
  cat <<EOF

This creates a GKE cluster in project $PROJECT: 2 x n2-standard-4 plus a load balancer.
Estimated cost while it runs: about \$0.45/hour (estimate, not verified). Destroy it with gke-down.sh.
EOF
  read -rp "Continue? [y/N] " ans; [[ "$ans" == [yY]* ]] || exit 1
fi

say "1. Terraform: VPC, GKE cluster, node pool, Workload Identity bindings"
cd "$HERE/gcp/cluster"
[ -f terraform.tfvars ] || cp terraform.tfvars.example terraform.tfvars
terraform init -input=false -backend-config=../backend.hcl -backend-config="prefix=cluster"
terraform apply -input=false $($YES && echo -auto-approve)

say "2. kubectl credentials"
eval "$(terraform output -raw get_credentials)"
kubectl get nodes

say "3. Argo CD (installed once with helm; afterwards it upgrades itself from git)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values "$GITOPS/bootstrap/argocd-values.yaml" \
  --values "$GITOPS/clusters/gke-us/argocd-values.yaml" \
  --wait --timeout 10m

say "4. Root app: from here git is in charge"
kubectl apply -f "$GITOPS/bootstrap/gke-root-app.yaml"

cat <<EOF

Done. Argo CD now builds the platform (waves: external-secrets, secrets, kong, argocd, operators, keycloak, apps).

  Watch:     kubectl get applications -n argocd -w
  Records:   external-dns creates the DNS records once Kong has its load balancer address
  Finish:    open https://argocd.<your-domain> (log in via Keycloak as devops1) when 'keycloak' is Healthy
  Tear down: bash scripts/gke-down.sh      (do not just close the laptop: the nodes cost money)
EOF
