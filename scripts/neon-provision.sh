#!/usr/bin/env bash
# Creates the Postgres roles and databases on Neon for every service (see services.txt) and stores each
# one's credentials in Secret Manager. Run it from your own machine. NOT RUN AGAINST NEON YET.
#
#   NEON_PROJECT_ID=<id> bash scripts/neon-provision.sh --dry-run   # only reads: shows what would change
#   NEON_PROJECT_ID=<id> bash scripts/neon-provision.sh             # creates what is missing
#   NEON_PROJECT_ID=<id> bash scripts/neon-provision.sh --rotate    # also resets the password of existing roles
#
# What it makes, for <service> in services.txt and <env> in dev, prod, plus Keycloak:
#   role + database  <service with _>_<env>   (user_service_dev, ... ; the role owns the database)
#   role + database  keycloak
#   secret           shoplite-db-<service>-<env>, shoplite-db-keycloak   (JSON: host, port, dbname, username, password)
# Same JSON shape as `seed-secrets.sh db`, which stays as the manual fallback.
#
# Idempotent: what exists is kept. A role that exists but has no secret value yet (an earlier run stopped half
# way) gets a new password. Passwords are never printed: they go from the Neon API straight into Secret Manager.
#
# Needs: gcloud (logged in, secrets already created by `terraform apply` in gcp/persistent), curl, node.
# Env: NEON_PROJECT_ID (required); NEON_API_KEY (else asked, hidden); PROJECT (GCP, default shoplite-demo-1e7583);
#      NEON_API (default https://console.neon.tech/api/v2).
set -euo pipefail

# Git Bash on Windows: gcloud cannot find Python unless pointed at the one bundled with the Cloud SDK.
if [ -z "${CLOUDSDK_PYTHON:-}" ] && gc=$(command -v gcloud 2>/dev/null); then
  bp="$(dirname "$gc")/../platform/bundledpython/python.exe"
  [ -x "$bp" ] && export CLOUDSDK_PYTHON="$bp"
fi

HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJECT=${PROJECT:-shoplite-demo-1e7583}
API=${NEON_API:-https://console.neon.tech/api/v2}
ENVS=(dev prod)
DRY=false; ROTATE=false
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=true ;;
    --rotate) ROTATE=true ;;
    *) sed -n '2,10p' "$0"; exit 1 ;;
  esac
done

for bin in gcloud curl node; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done
: "${NEON_PROJECT_ID:?set NEON_PROJECT_ID (Neon console -> project -> Settings)}"
if [ -z "${NEON_API_KEY:-}" ]; then read -rsp "Neon API key (hidden): " NEON_API_KEY; echo; fi
[ -r "$HERE/services.txt" ] || { echo "missing $HERE/services.txt"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
# Keep the key out of the process list: curl reads the header from a private file.
printf 'header = "Authorization: Bearer %s"\n' "$NEON_API_KEY" >"$TMP/auth"; chmod 600 "$TMP/auth"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
has_version() { local out; out=$(gcloud secrets versions list "$1" --project "$PROJECT" --filter='state=ENABLED' --limit=1 --format='value(name)' 2>/dev/null | tr -d '\015') || true; [ -n "$out" ]; }
put() { gcloud secrets versions add "$1" --project "$PROJECT" --data-file=- >/dev/null; }

# api METHOD PATH [JSON]: body goes to $TMP/body, status to $HTTP. Retries while Neon has the branch locked (423),
# rate-limits (429) or hiccups (5xx / no answer). Never echoes the body: a success may carry a password.
api() {
  local method=$1 path=$2 data=${3:-} try
  local args=(-sS -o "$TMP/body" -w '%{http_code}' -X "$method" --config "$TMP/auth" -H 'Accept: application/json')
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data "$data")
  for try in $(seq 1 30); do
    HTTP=$(curl "${args[@]}" "$API$path") || HTTP=000
    case "$HTTP" in 000|423|429|5??) sleep 2 ;; *) return 0 ;; esac
  done
}
# need_ok <what>: stop with Neon's error text (error bodies hold no secrets).
need_ok() {
  case "$HTTP" in 2??) return 0 ;; esac
  echo "Neon API: $1 failed (HTTP $HTTP): $(head -c 300 "$TMP/body")" >&2
  exit 1
}
# q <js expr over j>: read $TMP/body as JSON `j` and print the expression.
q() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")||"null");const r=eval(process.argv[2]);if(r!=null)console.log(r)' "$TMP/body" "$1"; }

# --- services -> (role/database, secret) pairs -----------------------------------------------------
PAIRS=("keycloak shoplite-db-keycloak")
while read -r svc; do
  for env in "${ENVS[@]}"; do PAIRS+=("${svc//-/_}_${env} shoplite-db-${svc}-${env}"); done
done < <(grep -v -E '^[[:space:]]*(#|$)' "$HERE/services.txt" | tr -d '\r')

say "Preflight: do the Secret Manager shells exist? (terraform apply in gcp/persistent)"
for p in "${PAIRS[@]}"; do
  read -r _ secret <<<"$p"
  gcloud secrets describe "$secret" --project "$PROJECT" >/dev/null 2>&1 || { echo "secret $secret does not exist: run terraform apply in gcp/persistent first"; exit 1; }
done
echo "${#PAIRS[@]} secrets found"

say "Neon project $NEON_PROJECT_ID"
api GET "/projects/$NEON_PROJECT_ID/branches"; need_ok "list branches"
BRANCH=$(q 'j.branches.find(b=>b.default||b.primary)?.id')
[ -n "$BRANCH" ] || { echo "no default branch found"; exit 1; }
B="/projects/$NEON_PROJECT_ID/branches/$BRANCH"
api GET "$B/endpoints"; need_ok "list endpoints"
HOST=$(q 'j.endpoints.find(e=>e.type==="read_write")?.host')
[ -n "$HOST" ] || { echo "no read_write endpoint found"; exit 1; }
api GET "$B/roles"; need_ok "list roles";         ROLES=$(q 'j.roles.map(r=>r.name).join("\n")')
api GET "$B/databases"; need_ok "list databases"; DBS=$(q 'j.databases.map(d=>d.name).join("\n")')
echo "branch $BRANCH, direct host $HOST"

say "Roles, databases, secrets"
for p in "${PAIRS[@]}"; do
  read -r name secret <<<"$p"
  have_secret=false; has_version "$secret" && have_secret=true
  role_exists=false; grep -qx "$name" <<<"$ROLES" && role_exists=true
  db_exists=false;   grep -qx "$name" <<<"$DBS" && db_exists=true

  if $role_exists && $have_secret && ! $ROTATE; then action="keep role+secret"
  elif $role_exists; then action="reset password, write secret"
  else action="create role, write secret"; fi
  $db_exists || action="$action, create database"

  if $DRY; then printf '  would  %-26s %s\n' "$name" "$action"; continue; fi

  pw=""
  if $role_exists && $have_secret && ! $ROTATE; then
    :
  elif $role_exists; then
    api POST "$B/roles/$name/reset_password"; need_ok "reset password of $name"
    pw=$(q 'j.role.password')
  else
    api POST "$B/roles" "{\"role\":{\"name\":\"$name\"}}"; need_ok "create role $name"
    pw=$(q 'j.role.password')
  fi
  if ! $db_exists; then
    api POST "$B/databases" "{\"database\":{\"name\":\"$name\",\"owner_name\":\"$name\"}}"; need_ok "create database $name"
  fi
  if [ -n "$pw" ]; then
    HOST="$HOST" DBN="$name" PW="$pw" node -e \
      'const e=process.env;process.stdout.write(JSON.stringify({host:e.HOST,port:"5432",dbname:e.DBN,username:e.DBN,password:e.PW}))' | put "$secret"
  elif $role_exists && ! $have_secret; then
    echo "no password returned for $name"; exit 1
  fi
  printf '  done   %-26s %s\n' "$name" "$action"
  sleep 1
done

echo
$DRY && echo "Dry run: nothing was changed." || echo "Check with: bash scripts/seed-secrets.sh status"
