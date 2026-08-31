#!/usr/bin/env bash
# Install the NinetyNine Freight API tier on SUSE Linux Enterprise Server 16.
#
# SLES 16 ships Python 3.13 as `python313` and uses SELinux rather than
# AppArmor. Both matter later: SELinux is what the CIS hardening act tunes.
#
# Assumes a genuinely on-prem-flavoured host: static IP, no walinuxagent, no
# Azure cloud-init. Nothing here installs an Azure agent -- that omission is a
# deliberate part of the migration story.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../tools/lib-install.sh"

require_root
ROOT="$(repo_root)"

log "installing OS packages"
if rpm -q python313 python313-pip python313-devel gcc curl >/dev/null 2>&1; then
  log "required SLES 16 packages are already installed"
else
  zypper --non-interactive refresh
  # python313 on SLES 16; fall back to the generic name on 15.x.
  zypper --non-interactive install --no-recommends \
    python313 python313-pip python313-devel gcc curl \
    || zypper --non-interactive install --no-recommends \
         python3 python3-pip python3-devel gcc curl
fi

# Make sure `python3` resolves before the venv is built.
if ! command -v python3 >/dev/null && command -v python3.13 >/dev/null; then
  ln -sf "$(command -v python3.13)" /usr/bin/python3
fi

ensure_user
install_payload "${ROOT}" api
install_env_file "${ROOT}"
install_venv "${ROOT}/api/requirements.txt"
install_unit "${ROOT}/api/shipment-api.service" shipment-api.service
open_firewall_port 8080
restart_unit shipment-api.service
report_identity api

log "API tier installed."
log "Verify with: curl -s http://localhost:8080/healthz | python3 -m json.tool"
