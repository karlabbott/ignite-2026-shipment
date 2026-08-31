#!/usr/bin/env bash
# Install SQL Server 2025 on Red Hat Enterprise Linux 10 and lay down the
# Zava Logistics schema.
#
# SQL Server 2025 is required: RHEL 10 is only a supported platform from
# SQL Server 2025 CU1 onwards. SQL Server 2022 supports RHEL 8 and 9 only.
#
# Deliberately NOT installing walinuxactagent, cloud-init or the Azure Linux
# agent: this VM must look like a machine that has only ever lived on Hyper-V.
#
# Usage:
#   sudo SA_PASSWORD='...' APP_PASSWORD='...' ./db/install-mssql-rhel.sh

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run this with sudo."

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SA_PASSWORD="${SA_PASSWORD:-}"
APP_PASSWORD="${APP_PASSWORD:-}"
APP_USER="${APP_USER:-shipping_app}"
DB_NAME="${DB_NAME:-shipping}"
MSSQL_EDITION="${MSSQL_EDITION:-Developer}"
ALLOWED_CIDR="${ALLOWED_CIDR:-192.168.90.0/24}"

[[ -n "${SA_PASSWORD}" ]]  || die "Set SA_PASSWORD (12+ chars, mixed case, digit, symbol)."
[[ -n "${APP_PASSWORD}" ]] || die "Set APP_PASSWORD for the ${APP_USER} login."

# --------------------------------------------------------------- repositories
log "adding Microsoft repositories"
MAJOR="$(rpm -E %rhel)"
if [[ "${MAJOR}" -lt 10 ]]; then
  warn "This estate targets RHEL 10; detected RHEL ${MAJOR}."
fi

# Production repo. Do NOT substitute a preview repo here -- it yields
# unsupported pre-release builds.
curl -fsSL "https://packages.microsoft.com/config/rhel/${MAJOR}/mssql-server-2025.repo" \
  -o /etc/yum.repos.d/mssql-server.repo
curl -fsSL "https://packages.microsoft.com/config/rhel/${MAJOR}/prod.repo" \
  -o /etc/yum.repos.d/msprod.repo

log "installing SQL Server and command line tools"
dnf -y install mssql-server
ACCEPT_EULA=Y dnf -y install mssql-tools18

export PATH="${PATH}:/opt/mssql-tools18/bin"

# ------------------------------------------------------------------ configure
if [[ ! -f /var/opt/mssql/data/master.mdf ]]; then
  log "running initial SQL Server setup (edition: ${MSSQL_EDITION})"
  MSSQL_SA_PASSWORD="${SA_PASSWORD}" MSSQL_PID="${MSSQL_EDITION}" ACCEPT_EULA=Y \
    /opt/mssql/bin/mssql-conf -n setup accept-eula
else
  log "SQL Server already configured, skipping setup"
fi

systemctl enable --now mssql-server

log "waiting for SQL Server to accept connections"
for attempt in $(seq 1 30); do
  if sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -C -Q "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  [[ ${attempt} -eq 30 ]] && die "SQL Server did not come up. Check: journalctl -u mssql-server"
  sleep 2
done

# -------------------------------------------------------------------- firewall
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  log "allowing 1433/tcp from ${ALLOWED_CIDR}"
  firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOWED_CIDR} port port=1433 protocol=tcp accept" >/dev/null
  firewall-cmd --reload >/dev/null
else
  warn "firewalld is not running; port 1433 is governed by whatever else is in front of it"
fi

# ---------------------------------------------------------------------- schema
log "applying schema"
sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -C -b -i "${ROOT}/db/01-schema.sql"

log "creating application login ${APP_USER}"
# The app login gets exactly the rights it needs: read/write on the data tables
# and execute on the two helper procedures. No db_owner.
sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -C -b \
  -v appuser="${APP_USER}" apppass="${APP_PASSWORD}" dbname="${DB_NAME}" \
  -i "${ROOT}/db/03-app-login.sql"

log "seeding demo data"
sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -C -b -i "${ROOT}/db/02-seed.sql"

log "applying Zava Logistics data migration"
sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -C -b -i "${ROOT}/db/04-zava-rebrand.sql"

# The db tier has no Python service, so its heartbeat is written once here and
# refreshed by a lightweight timer -- see db/shipment-db-heartbeat.*
log "installing the database heartbeat timer"
install -m 0700 "${ROOT}/db/heartbeat.sh" /usr/local/sbin/shipment-db-heartbeat
install -m 0644 "${ROOT}/db/shipment-db-heartbeat.service" /etc/systemd/system/
install -m 0644 "${ROOT}/db/shipment-db-heartbeat.timer" /etc/systemd/system/
install -d -m 0750 /etc/shipment
printf 'SA_PASSWORD=%s\n' "${SA_PASSWORD}" > /etc/shipment/db-heartbeat.env
chmod 0600 /etc/shipment/db-heartbeat.env
systemctl daemon-reload
systemctl enable --now shipment-db-heartbeat.timer

log "Database tier installed."
log "Connection string for the other tiers:"
log "  SHIPMENT_DB_HOST=$(hostname -I | awk '{print $1}')"
log "  SHIPMENT_DB_USER=${APP_USER}"
log "Verify with: sqlcmd -S localhost -U ${APP_USER} -P '<password>' -C -d ${DB_NAME} -Q 'SELECT COUNT(*) FROM dbo.shipments'"
