#!/usr/bin/env bash
# Install the Zava Logistics web tier on Ubuntu Server.
#
# uvicorn binds to 127.0.0.1:8000 and nginx terminates on :80, so TLS and the
# public rate limits live in one obvious place.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../tools/lib-install.sh"

require_root
ROOT="$(repo_root)"

log "installing OS packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  python3 python3-venv python3-dev build-essential nginx curl

ensure_user
# The web tier vendors api/ purely for its config and db modules (heartbeat).
install_payload "${ROOT}" web api
install_env_file "${ROOT}"
install_venv "${ROOT}/web/requirements.txt"
install_unit "${ROOT}/web/shipment-web.service" shipment-web.service

log "configuring nginx"
install -m 0644 "${ROOT}/web/nginx-shipment.conf" /etc/nginx/sites-available/shipment
ln -sfn /etc/nginx/sites-available/shipment /etc/nginx/sites-enabled/shipment
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx

open_firewall_port 80
open_firewall_port 443
restart_unit shipment-web.service
report_identity web

HOST_IP="$(hostname -I | awk '{print $1}')"
log "Web tier installed."
log "Dashboard: http://${HOST_IP}/"
log "Tracking:  http://${HOST_IP}/track"
