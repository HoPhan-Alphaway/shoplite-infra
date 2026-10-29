#!/usr/bin/env bash
# Fills the Secret Manager "shells" created by Terraform (gcp/persistent). Run it from your own
# machine; values never go through Terraform, git or the cluster's state. NOT RUN YET.
#
#   bash scripts/seed-secrets.sh generate          # random secrets + realm RSA key (keeps existing ones)
#   bash scripts/seed-secrets.sh generate --rotate # new values for everything generated (breaks sessions)
#   bash scripts/seed-secrets.sh db <svc> <env>    # Neon credentials of one service DB (asks interactively)
#   bash scripts/seed-secrets.sh db keycloak       # Keycloak's database
#   bash scripts/seed-secrets.sh cloudflare-token  # API token for external-dns (asks, input hidden)
#   bash scripts/seed-secrets.sh origin-cert <cert.pem> <key.pem>   # Cloudflare Origin CA certificate
#   bash scripts/seed-secrets.sh status            # which secrets still have no value
#
# Needs: gcloud (logged in), openssl. Project: $PROJECT or shoplite-demo-1e7583.
# Secret values are never printed.
set -euo pipefail

# Git Bash on Windows: gcloud cannot find Python unless pointed at the one bundled with the Cloud SDK.
if [ -z "${CLOUDSDK_PYTHON:-}" ] && gc=$(command -v gcloud 2>/dev/null); then
  bp="$(dirname "$gc")/../platform/bundledpython/python.exe"
  [ -x "$bp" ] && export CLOUDSDK_PYTHON="$bp"
fi

PROJECT=${PROJECT:-shoplite-demo-1e7583}
ROTATE=false

has_version() { local out; out=$(gcloud secrets versions list "$1" --project "$PROJECT" --filter='state=ENABLED' --limit=1 --format='value(name)' 2>/dev/null | tr -d '\015') || true; [ -n "$out" ]; }
put() { gcloud secrets versions add "$1" --project "$PROJECT" --data-file=- >/dev/null; }
json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ensure_random <secret> <bytes>: random hex, only if the secret has no value yet (or --rotate).
ensure_random() {
  if ! $ROTATE && has_version "$1"; then echo "kept    $1"; return; fi
  # tr -d '\r\n': Windows builds of openssl end lines with CRLF, and a stray \r would end up in the secret.
  openssl rand -hex "$2" | tr -d '\r\n' | put "$1"
  echo "seeded  $1"
}

generate() {
  [[ "${1:-}" == "--rotate" ]] && ROTATE=true

  # One RSA key pair: Keycloak signs with the private half, Kong verifies with the public half.
  # The private key is stored as the PKCS#8 body (no header lines, one line), the format the
  # realm import expects (same as bootstrap/secrets.sh); the public key as PEM.
  if ! $ROTATE && has_version shoplite-realm-rsa-private-key && has_version shoplite-realm-rsa-public-key; then
    echo "kept    shoplite-realm-rsa-private-key / -public-key"
  else
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/key.pem" 2>/dev/null
    grep -v -- '-----' "$tmp/key.pem" | tr -d '\r\n' | put shoplite-realm-rsa-private-key
    openssl pkey -in "$tmp/key.pem" -pubout | tr -d '\r' | put shoplite-realm-rsa-public-key
    echo "seeded  shoplite-realm-rsa-private-key / -public-key"
  fi

  for s in order-service grafana argocd kafka-ui; do ensure_random "shoplite-$s-client-secret" 24; done
  for u in alice bob devops1 viewer1; do ensure_random "shoplite-$u-password" 6; done
  ensure_random shoplite-grafana-admin-password 12
  echo
  echo "Still to do by hand: db <svc> <env> (x9), cloudflare-token, origin-cert. Then: status"
}

db() {
  local svc=${1:?usage: db <service|keycloak> [env]} env=${2:-} name
  if [[ "$svc" == keycloak ]]; then name=shoplite-db-keycloak; else name="shoplite-db-$svc-${env:?env required (dev|prod)}"; fi
  read -rp "host (e.g. ep-xxx.us-east-2.aws.neon.tech): " host
  read -rp "port [5432]: " port; port=${port:-5432}
  read -rp "database name: " dbname
  read -rp "user: " user
  read -rsp "password (hidden): " pass; echo
  printf '{"host":"%s","port":"%s","dbname":"%s","username":"%s","password":"%s"}' \
    "$(json_escape <<<"$host")" "$port" "$(json_escape <<<"$dbname")" "$(json_escape <<<"$user")" "$(printf %s "$pass" | json_escape)" | put "$name"
  echo "seeded  $name"
}

cloudflare_token() {
  read -rsp "Cloudflare API token (Zone.DNS:Edit on the zone, hidden): " tok; echo
  printf %s "$tok" | put shoplite-cloudflare-api-token
  echo "seeded  shoplite-cloudflare-api-token"
}

origin_cert() {
  local crt=${1:?usage: origin-cert <cert.pem> <key.pem>} key=${2:?usage: origin-cert <cert.pem> <key.pem>}
  [ -r "$crt" ] && [ -r "$key" ] || { echo "cannot read $crt / $key"; exit 1; }
  grep -q 'BEGIN CERTIFICATE' "$crt" && grep -q 'PRIVATE KEY' "$key" || { echo "files do not look like a PEM certificate and key"; exit 1; }
  # JSON with real newlines escaped as \n.
  printf '{"tls.crt":"%s","tls.key":"%s"}' \
    "$(sed -e ':a;N;$!ba;s/\n/\\n/g' "$crt")" "$(sed -e ':a;N;$!ba;s/\n/\\n/g' "$key")" | put shoplite-tls-origin
  echo "seeded  shoplite-tls-origin"
}

status() {
  local missing=0
  for s in $(gcloud secrets list --project "$PROJECT" --filter='name~shoplite-' --format='value(name.basename())' | tr -d '\015' | sort); do
    if has_version "$s"; then printf '  ok       %s\n' "$s"; else printf '  MISSING  %s\n' "$s"; missing=1; fi
  done
  return $missing
}

case "${1:-}" in
  generate) shift; generate "$@" ;;
  db) shift; db "$@" ;;
  cloudflare-token) cloudflare_token ;;
  origin-cert) shift; origin_cert "$@" ;;
  status) status ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
