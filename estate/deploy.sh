#!/usr/bin/env bash
# Deploy Zava Logistics to the four-VM estate over SSH.
#
# Run from WSL once all four VMs have finished their unattended installs:
#     wsl -d Ubuntu-24.04 -e bash estate/deploy.sh
#
# Order matters: the database tier must be serving before the API and worker
# tiers start, or their first heartbeat fails and the health strip looks broken
# when it is only impatient.
#
# Idempotent. Safe to re-run after changing application code.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

DB_HOST="${DB_HOST:-192.168.90.11}"
API_HOST="${API_HOST:-192.168.90.12}"
WEB_HOST="${WEB_HOST:-192.168.90.13}"
WORKER_HOST="${WORKER_HOST:-192.168.90.14}"
SSH_USER="${SSH_USER:-estate}"
SSH_KEY="${SSH_KEY:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m    %s\n' "$*" >&2; }
die()  { printf '\033[1;31m [x]\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------- ssh key --
if [[ -z "${SSH_KEY}" ]]; then
  for candidate in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa" \
                   /mnt/c/Users/"${WIN_USER:-$USER}"/.ssh/id_rsa; do
    [[ -f "${candidate}" ]] && SSH_KEY="${candidate}" && break
  done
fi
[[ -f "${SSH_KEY}" ]] || die "No SSH private key found. Set SSH_KEY=/path/to/key"

# A key mounted from /mnt/c has 0777 permissions, which OpenSSH refuses. Copy it
# somewhere sane rather than making the user fix Windows ACLs.
if [[ "${SSH_KEY}" == /mnt/* ]]; then
  TEMP_KEY="$(mktemp)"
  cp "${SSH_KEY}" "${TEMP_KEY}"
  chmod 600 "${TEMP_KEY}"
  SSH_KEY="${TEMP_KEY}"
  trap 'rm -f "${TEMP_KEY}"' EXIT
fi

SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="${HOME}/.ssh/known_hosts_estate"
          -o ConnectTimeout=10 -o LogLevel=ERROR)

remote()  { ssh "${SSH_OPTS[@]}" "${SSH_USER}@$1" "${@:2}"; }
push()    { rsync -a --delete -e "ssh ${SSH_OPTS[*]}" "$2" "${SSH_USER}@$1:$3"; }

command -v rsync >/dev/null || die "rsync is required: sudo apt-get install -y rsync"

# ------------------------------------------------------------ reachability --
log "checking all four VMs are reachable"
declare -A TIERS=(
  ["${DB_HOST}"]="rhel-db"
  ["${API_HOST}"]="sles-api"
  ["${WEB_HOST}"]="ubuntu-web"
  ["${WORKER_HOST}"]="rocky-worker"
)
for host in "${!TIERS[@]}"; do
  if remote "${host}" 'true' 2>/dev/null; then
    distro="$(remote "${host}" '. /etc/os-release && echo "$PRETTY_NAME"')"
    ok "$(printf '%-14s' "${TIERS[$host]}") ${host}  ${distro}"
  else
    die "Cannot SSH to ${TIERS[$host]} at ${host}. Is the VM up and the install finished?"
  fi
done

# --------------------------------------------------------------- passwords --
if [[ -z "${SA_PASSWORD:-}" ]]; then
  read -rsp "SQL Server 'sa' password (12+ chars, mixed case, digit, symbol): " SA_PASSWORD; echo
fi
if [[ -z "${APP_PASSWORD:-}" ]]; then
  read -rsp "Password for the shipping_app SQL login: " APP_PASSWORD; echo
fi
[[ -n "${SA_PASSWORD}" && -n "${APP_PASSWORD}" ]] || die "Both passwords are required."

STAGE=/home/${SSH_USER}/shipment-src

stage_repo() {
  local host="$1"
  remote "${host}" "rm -rf ${STAGE} && mkdir -p ${STAGE}"
  # Only what the tiers need; no .git, no answer ISOs, no local venvs.
  rsync -a --delete \
    --exclude '.git' --exclude '__pycache__' --exclude '*.pyc' \
    --exclude 'estate/out' --exclude '.venv' \
    -e "ssh ${SSH_OPTS[*]}" \
    "${REPO}/" "${SSH_USER}@${host}:${STAGE}/"
}

write_env() {
  # write_env <host>  -- render /etc/shipment/shipment.env with real values
  local host="$1"
  local maps_key=""
  if [[ "${host}" == "${API_HOST}" ]]; then
    maps_key="${SHIPMENT_AZURE_MAPS_KEY:-}"
  fi
  remote "${host}" "sudo install -d -m 0750 /etc/shipment"
  remote "${host}" "sudo tee /etc/shipment/shipment.env >/dev/null" <<ENV
SHIPMENT_DB_HOST=${DB_HOST}
SHIPMENT_DB_PORT=1433
SHIPMENT_DB_NAME=shipping
SHIPMENT_DB_USER=shipping_app
SHIPMENT_DB_PASSWORD=${APP_PASSWORD}
SHIPMENT_DB_LOGIN_TIMEOUT=5
SHIPMENT_DB_QUERY_TIMEOUT=10
SHIPMENT_DB_RETRY_SECONDS=3
SHIPMENT_SITE=on-prem/hyper-v
SHIPMENT_HEARTBEAT_SECONDS=10
SHIPMENT_BOARD_LIMIT=60
SHIPMENT_CREATE_RATE_LIMIT=5
SHIPMENT_CREATE_RATE_WINDOW=60
SHIPMENT_CREATE_GLOBAL_LIMIT=240
SHIPMENT_CORS_ORIGINS=https://dash.99b.org,https://track.99b.org,http://${WEB_HOST}
SHIPMENT_AZURE_MAPS_KEY=${maps_key}
SHIPMENT_GEOCODING_TIMEOUT=2
SHIPMENT_API_URL=http://${API_HOST}:8080
SHIPMENT_API_TIMEOUT=5
SHIPMENT_BRAND=Zava Logistics
# Blank on purpose. Nothing resolves to this lab, so the web tier derives the
# tracking address from the request and shows http://${WEB_HOST}/track.
# Set this to https://track.99b.org only once the estate is in Azure.
SHIPMENT_TRACK_URL=
SHIPMENT_REFRESH_MS=3000
SHIPMENT_POLL_SECONDS=1
SHIPMENT_MAX_IDLE_SECONDS=5
SHIPMENT_ERROR_BACKOFF=5
SHIPMENT_SCAN_DELAY_MIN=1.5
SHIPMENT_SCAN_DELAY_MAX=4.0
SHIPMENT_DRIFT_ENABLED=true
SHIPMENT_DRIFT_INTERVAL=20
SHIPMENT_DRIFT_BATCH=3
SHIPMENT_DRIFT_MIN_AGE=45
ENV
  remote "${host}" "sudo chmod 0640 /etc/shipment/shipment.env"
}

# ------------------------------------------------------------------ 1. db ----
log "[1/4] database tier -> rhel-db (${DB_HOST})"
stage_repo "${DB_HOST}"
remote "${DB_HOST}" "cd ${STAGE} && sudo SA_PASSWORD='${SA_PASSWORD}' APP_PASSWORD='${APP_PASSWORD}' bash db/install-mssql-rhel.sh"
ok "SQL Server installed and seeded"

log "waiting for SQL Server to accept remote connections"
for attempt in $(seq 1 30); do
  if remote "${API_HOST}" "timeout 3 bash -c '</dev/tcp/${DB_HOST}/1433'" 2>/dev/null; then
    ok "1433 reachable from the API tier"
    break
  fi
  [[ ${attempt} -eq 30 ]] && die "Cannot reach ${DB_HOST}:1433 from ${API_HOST}. Check firewalld on rhel-db."
  sleep 2
done

# ----------------------------------------------------------------- 2. api ----
log "[2/4] API tier -> sles-api (${API_HOST})"
stage_repo "${API_HOST}"
write_env "${API_HOST}"
remote "${API_HOST}" "cd ${STAGE} && sudo bash api/install-sles.sh"
ok "API tier installed"

# -------------------------------------------------------------- 3. worker ----
log "[3/4] worker tier -> rocky-worker (${WORKER_HOST})"
stage_repo "${WORKER_HOST}"
write_env "${WORKER_HOST}"
remote "${WORKER_HOST}" "cd ${STAGE} && sudo bash worker/install-rocky.sh"
ok "worker installed"

# ----------------------------------------------------------------- 4. web ----
log "[4/4] web tier -> ubuntu-web (${WEB_HOST})"
stage_repo "${WEB_HOST}"
write_env "${WEB_HOST}"
remote "${WEB_HOST}" "cd ${STAGE} && sudo bash web/install-ubuntu.sh"
ok "web tier installed"

# ------------------------------------------------------------------ verify ---
log "running the end-to-end smoke test"
sleep 5
if WEB="http://${WEB_HOST}" bash "${REPO}/tools/smoke-test.sh"; then
  printf '\n\033[1;32mEstate deployed.\033[0m\n'
  printf '  Dashboard  http://%s/\n'      "${WEB_HOST}"
  printf '  Tracking   http://%s/track\n' "${WEB_HOST}"
  printf '\nTake the post-deploy checkpoint now:\n'
  printf '  .\\estate\\Checkpoint-ShipmentEstate.ps1 -Name app-deployed\n\n'
else
  die "Smoke test failed. Check: journalctl -u shipment-api -u shipment-worker -u shipment-web"
fi
