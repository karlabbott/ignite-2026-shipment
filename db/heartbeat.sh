#!/usr/bin/env bash
# Publish the database tier's own identity into dbo.tier_heartbeats.
#
# The db tier runs no Python, so rather than install a whole service just to say
# "I am alive", a systemd timer runs this every 10 seconds. It also means the db
# tile on the health strip is written by SQL Server itself -- if this stops
# reporting, the database really is gone.

set -euo pipefail

export PATH="${PATH}:/opt/mssql-tools18/bin:/opt/mssql-tools/bin"

: "${SA_PASSWORD:?SA_PASSWORD must be set (see /etc/shipment/db-heartbeat.env)}"
DB_NAME="${DB_NAME:-shipping}"

HOSTNAME_VALUE="$(hostname)"
DISTRO="$(. /etc/os-release && printf '%s' "${PRETTY_NAME}")"
KERNEL="$(uname -r)"

# Ask IMDS whether we are on Azure yet. One second timeout so a Hyper-V host
# does not stall the timer.
IMDS="$(curl -s -m 1 -H 'Metadata: true' \
  'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' || true)"

if [[ -n "${IMDS}" && "${IMDS}" == *'"location"'* ]]; then
  PLATFORM="Azure"
  LOCATION="azure/$(printf '%s' "${IMDS}" | sed -n 's/.*"location":"\([^"]*\)".*/\1/p')"
  VM_SIZE="$(printf '%s' "${IMDS}" | sed -n 's/.*"vmSize":"\([^"]*\)".*/\1/p')"
else
  PLATFORM="Hyper-V"
  LOCATION="${SHIPMENT_SITE:-on-prem/hyper-v}"
  VM_SIZE=""
fi

# SQL Server version string, so the tile can prove which engine is answering.
DETAIL="$(sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -C -h -1 -W -Q \
  "SET NOCOUNT ON; SELECT CONCAT('SQL Server ', SERVERPROPERTY('ProductMajorVersion'), ' ', SERVERPROPERTY('Edition'))" \
  2>/dev/null | head -n 1 || printf 'SQL Server')"

sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -C -b -d "${DB_NAME}" -Q "
EXEC dbo.usp_record_heartbeat
     @tier     = N'db',
     @hostname = N'$(printf '%s' "${HOSTNAME_VALUE}" | sed "s/'/''/g")',
     @distro   = N'$(printf '%s' "${DISTRO}" | sed "s/'/''/g")',
     @kernel   = N'$(printf '%s' "${KERNEL}" | sed "s/'/''/g")',
     @platform = N'${PLATFORM}',
     @location = N'$(printf '%s' "${LOCATION}" | sed "s/'/''/g")',
     @vm_size  = $( [[ -n "${VM_SIZE}" ]] && printf "N'%s'" "${VM_SIZE}" || printf 'NULL' ),
     @detail   = N'$(printf '%s' "${DETAIL}" | tr -d '\r' | sed "s/'/''/g")';
" >/dev/null
