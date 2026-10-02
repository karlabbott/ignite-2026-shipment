#!/usr/bin/env bash
# Install the Zava Logistics worker on Azure Linux 4.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../tools/lib-install.sh"

require_root
ROOT="$(repo_root)"

log "installing Azure Linux packages"
tdnf -y install \
  python3 \
  python3-pip \
  python3-devel \
  gcc \
  freetds \
  freetds-devel \
  curl \
  iproute-tc

ensure_user
install_payload "${ROOT}" worker api
install_env_file "${ROOT}"
install_venv "${ROOT}/worker/requirements.txt"
install_unit "${ROOT}/worker/shipment-worker.service" shipment-worker.service
restart_unit shipment-worker.service
report_identity worker

log "Azure Linux worker installed."
log "Watch it move shipments with: journalctl -fu shipment-worker.service"
