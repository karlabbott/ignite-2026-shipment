#!/usr/bin/env bash
# Install the Zava Logistics worker on Rocky Linux.
#
# The worker vendors the API tier's db/config modules, so `api/` is deployed
# alongside `worker/` even though uvicorn never runs here.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../tools/lib-install.sh"

require_root
ROOT="$(repo_root)"

log "installing OS packages"
dnf -y install python3 python3-pip python3-devel gcc curl

ensure_user
install_payload "${ROOT}" worker api
install_env_file "${ROOT}"
install_venv "${ROOT}/worker/requirements.txt"
install_unit "${ROOT}/worker/shipment-worker.service" shipment-worker.service
restart_unit shipment-worker.service
report_identity worker

log "Worker installed."
log "Watch it move shipments with: journalctl -fu shipment-worker.service"
