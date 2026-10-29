#!/usr/bin/env bash
# Delete the GKE cluster and everything that costs money while it exists. NOT RUN YET.
#
#   bash scripts/gke-down.sh          # asks first
#   bash scripts/gke-down.sh --yes
#
# Why not just `terraform destroy`? Deleting a cluster does not delete the Persistent Disks
# created for PersistentVolumeClaims (Kafka, Prometheus, Loki, Tempo...) and may leave
# load balancer resources behind. They would keep billing. So this script:
#   1. stops Argo CD (otherwise it recreates what we delete)
#   2. deletes workloads, PVCs and LoadBalancer Services in the app namespaces, so GKE removes the disks and LB itself
#   3. destroys the cluster stack with Terraform
#   4. reports anything still left in the project, without deleting it
# Persistent data lives elsewhere (Neon, GCS, Secret Manager, git) and is not touched.
set -euo pipefail

# Git Bash on Windows: gcloud cannot find Python unless pointed at the one bundled with the Cloud SDK.
if [ -z "${CLOUDSDK_PYTHON:-}" ] && gc=$(command -v gcloud 2>/dev/null); then
  bp="$(dirname "$gc")/../platform/bundledpython/python.exe"
  [ -x "$bp" ] && export CLOUDSDK_PYTHON="$bp"
fi

HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJECT=${PROJECT:-shoplite-demo-1e7583}
YES=false; [[ "${1:-}" == "--yes" ]] && YES=true

for bin in gcloud terraform kubectl; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done
say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

ctx=$(kubectl config current-context 2>/dev/null || true)
if [[ "$ctx" == gke_${PROJECT}_* ]]; then
  say "Current kubectl context: $ctx"
else
  echo "kubectl context is '$ctx', not a GKE cluster of $PROJECT. Skipping the in-cluster cleanup."
  ctx=""
fi

if ! $YES; then
  read -rp "Destroy the cluster (and its disks and load balancer)? [y/N] " ans
  [[ "$ans" == [yY]* ]] || exit 1
fi

if [ -n "$ctx" ]; then
  say "1. Stop Argo CD so it does not recreate anything"
  kubectl -n argocd scale statefulset --all --replicas=0 || true
  kubectl -n argocd scale deployment --all --replicas=0 || true

  say "2. Remove what owns cloud resources (PVC -> Persistent Disk, Service -> load balancer)"
  # Everything except Kubernetes' own namespaces and argocd.
  for ns in $(kubectl get ns -o name | sed 's#namespace/##' | grep -v -E '^(kube-|default$|argocd$|external-secrets$|cert-manager$)'); do
    kubectl -n "$ns" delete statefulset,deployment,daemonset,job,cronjob --all --wait=false >/dev/null 2>&1 || true
    kubectl -n "$ns" delete pvc --all --wait=false >/dev/null 2>&1 || true
  done
  kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
    while read -r ns name; do [ -n "$name" ] && kubectl -n "$ns" delete svc "$name" --wait=false || true; done

  echo "Waiting up to 5 minutes for the volumes to be released..."
  for _ in $(seq 1 30); do
    left=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
    [ "$left" -eq 0 ] && break
    sleep 10
  done
  echo "PersistentVolumes left: $(kubectl get pv --no-headers 2>/dev/null | wc -l)"
fi

say "3. Terraform destroy (cluster stack only)"
cd "$HERE/gcp/cluster"
terraform init -input=false -backend-config=../backend.hcl -backend-config="prefix=cluster" >/dev/null
terraform destroy -input=false $($YES && echo -auto-approve)

[ -n "$ctx" ] && { kubectl config delete-context "$ctx" >/dev/null 2>&1 || true; }

say "4. Anything still billing in $PROJECT?"
echo "-- disks:";            gcloud compute disks list --project "$PROJECT" --format='table(name,sizeGb,zone.basename())' || true
echo "-- forwarding rules:"; gcloud compute forwarding-rules list --project "$PROJECT" --format='table(name,IPAddress,region.basename())' || true
echo "-- static addresses:"; gcloud compute addresses list --project "$PROJECT" --format='table(name,address,status)' || true
echo
echo "Empty lists above = nothing left. Delete leftovers with:  gcloud compute disks delete <name> --zone <zone> --project $PROJECT"
