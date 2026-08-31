#!/usr/bin/env bash
# Shared install helpers for every tier of the Zava Logistics estate.
#
# Sourced by api/install-sles.sh, web/install-ubuntu.sh and worker/install-rocky.sh.
# Everything here is idempotent so a half-finished install can simply be re-run.

set -euo pipefail

APP_ROOT=/opt/shipment
VENV=/opt/shipment/venv
ENV_DIR=/etc/shipment
ENV_FILE="${ENV_DIR}/shipment.env"
APP_USER=shipment
APP_GROUP=shipment

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this with sudo."
}

repo_root() {
  # Resolve the checkout containing this script, regardless of where it is run.
  cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd
}

ensure_user() {
  if ! getent group "${APP_GROUP}" >/dev/null; then
    log "creating group ${APP_GROUP}"
    groupadd --system "${APP_GROUP}"
  fi
  if ! getent passwd "${APP_USER}" >/dev/null; then
    log "creating service account ${APP_USER}"
    useradd --system --gid "${APP_GROUP}" --home-dir "${APP_ROOT}" \
            --shell /usr/sbin/nologin "${APP_USER}" 2>/dev/null \
      || useradd --system --gid "${APP_GROUP}" --home-dir "${APP_ROOT}" \
                 --shell /sbin/nologin "${APP_USER}"
  fi
}

install_payload() {
  # install_payload <repo_root> <tier_dir...>
  local root="$1"; shift
  log "installing application to ${APP_ROOT}"
  install -d -m 0755 -o root -g root "${APP_ROOT}"

  # common/ is vendored to every tier so each VM is independently deployable.
  rm -rf "${APP_ROOT}/common"
  cp -a "${root}/common" "${APP_ROOT}/common"

  local tier
  for tier in "$@"; do
    rm -rf "${APP_ROOT:?}/${tier}"
    cp -a "${root}/${tier}" "${APP_ROOT}/${tier}"
  done

  find "${APP_ROOT}" -name '__pycache__' -type d -prune -exec rm -rf {} +
  chown -R root:"${APP_GROUP}" "${APP_ROOT}"
  find "${APP_ROOT}/common" -type d -exec chmod 0755 {} +
  for tier in "$@"; do
    find "${APP_ROOT}/${tier}" -type d -exec chmod 0755 {} +
  done
  chmod -R go-w "${APP_ROOT}"
}

install_env_file() {
  # install_env_file <repo_root>
  local root="$1"
  install -d -m 0750 -o root -g "${APP_GROUP}" "${ENV_DIR}"
  if [[ -f "${ENV_FILE}" ]]; then
    log "keeping existing ${ENV_FILE}"
  else
    log "seeding ${ENV_FILE} from the example"
    install -m 0640 -o root -g "${APP_GROUP}" "${root}/shipment.env.example" "${ENV_FILE}"
    warn "Edit ${ENV_FILE} and set SHIPMENT_DB_PASSWORD before starting the service."
  fi
  chmod 0640 "${ENV_FILE}"
  chown root:"${APP_GROUP}" "${ENV_FILE}"
}

install_venv() {
  # install_venv <requirements_file>
  local requirements="$1"
  if [[ ! -x "${VENV}/bin/python" ]]; then
    log "creating virtualenv at ${VENV}"
    python3 -m venv "${VENV}"
  fi
  log "installing Python dependencies"
  "${VENV}/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null
  "${VENV}/bin/python" -m pip install --upgrade --requirement "${requirements}"
  chown -R root:"${APP_GROUP}" "${VENV}"
}

install_unit() {
  # install_unit <unit_path> <unit_name>
  local source="$1" name="$2"
  log "installing systemd unit ${name}"
  install -m 0644 -o root -g root "${source}" "/etc/systemd/system/${name}"
  systemctl daemon-reload
  systemctl enable "${name}"
}

restart_unit() {
  local name="$1"
  log "restarting ${name}"
  systemctl restart "${name}"
  sleep 2
  if ! systemctl is-active --quiet "${name}"; then
    systemctl --no-pager --lines=20 status "${name}" || true
    return 1
  fi
  systemctl --no-pager --lines=10 status "${name}"
}

open_firewall_port() {
  # Best effort across firewalld / ufw / neither. Never fatal: a lab VM without
  # a firewall running must not abort the install.
  local port="$1"
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    log "opening ${port}/tcp in firewalld"
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  elif command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "opening ${port}/tcp in ufw"
    ufw allow "${port}/tcp" >/dev/null
  else
    warn "no active firewall detected; leaving port ${port} alone"
  fi
}

report_identity() {
  log "tier identity as this VM sees it:"
  PYTHONPATH="${APP_ROOT}" "${VENV}/bin/python" - "$1" <<'PY'
import json
import sys

from common import estate

print(json.dumps(estate.identity_dict(sys.argv[1]), indent=2, default=str))
PY
}
