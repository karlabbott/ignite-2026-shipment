#!/usr/bin/env bash
# End-to-end check of the NinetyNine Freight estate.
#
# Run from anywhere that can reach the web tier. Exits non-zero on the first
# real failure so it can be wired into a rehearsal script.
#
#   ./tools/smoke-test.sh                       # against the default lab web tier
#   WEB=https://dash.99b.org ./tools/smoke-test.sh

set -euo pipefail

WEB="${WEB:-http://192.168.90.13}"
TIMEOUT="${TIMEOUT:-8}"
PATIENCE="${PATIENCE:-45}"   # seconds to wait for the worker to produce a scan

pass() { printf '\033[1;32m  ok\033[0m   %s\n' "$*"; }
fail() { printf '\033[1;31m FAIL\033[0m  %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

command -v curl >/dev/null || fail "curl is required"
command -v python3 >/dev/null || fail "python3 is required"

json() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval('d$1'))" 2>/dev/null; }

# ------------------------------------------------------------------ web tier --
info "web tier at ${WEB}"
WEB_HEALTH="$(curl -fsS -m "${TIMEOUT}" "${WEB}/healthz" 2>/dev/null || true)"
[[ -n "${WEB_HEALTH}" ]] || fail "web tier did not answer /healthz"
printf '%s' "${WEB_HEALTH}" | json >/dev/null || fail "web tier returned non-JSON from /healthz"
pass "web tier is up: $(printf '%s' "${WEB_HEALTH}" | field "['hostname']") ($(printf '%s' "${WEB_HEALTH}" | field "['platform_name']"))"

UPSTREAM_OK="$(printf '%s' "${WEB_HEALTH}" | field "['upstream']['reachable']")"
[[ "${UPSTREAM_OK}" == "True" ]] || fail "web tier cannot reach the API tier: $(printf '%s' "${WEB_HEALTH}" | field "['upstream']['detail']")"
pass "web tier can reach the API tier"

# ------------------------------------------------------------------- estate --
info "estate health strip"
ESTATE="$(curl -fsS -m "${TIMEOUT}" "${WEB}/api/estate")" || fail "/api/estate failed"
printf '%s' "${ESTATE}" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
tiers = {tile["tier"]: tile for tile in payload.get("tiers", [])}
missing = [tier for tier in ("web", "api", "db", "worker") if tier not in tiers]
if missing:
    print("  missing tiers: {}".format(", ".join(missing)), file=sys.stderr)
    raise SystemExit(1)
for name, tile in tiers.items():
    state = "ok" if tile.get("healthy", True) else "STALE"
    print("  {:<7} {:<18} {:<8} {}  {}".format(
        name, tile["hostname"], tile["platform"], state, tile["distro"]
    ))
' || fail "one or more tiers are not reporting"
pass "all four tiers are reporting"

# -------------------------------------------------------------------- board --
info "board and stats"
curl -fsS -m "${TIMEOUT}" "${WEB}/api/stats" | json >/dev/null || fail "/api/stats failed"
curl -fsS -m "${TIMEOUT}" "${WEB}/api/board" | json >/dev/null || fail "/api/board failed"
pass "board and stats render"

# -------------------------------------------------------- create and follow --
info "creating a shipment end to end"
CREATED="$(curl -fsS -m "${TIMEOUT}" -X POST "${WEB}/api/shipments" \
  -H 'content-type: application/json' \
  -d '{"origin":"Seattle, WA","destination":"Chicago, IL","description":"Smoke test","weight_kg":1.0,"created_by":"smoke-test"}')" \
  || fail "could not create a shipment"

TRACKING="$(printf '%s' "${CREATED}" | field "['tracking_number']")"
[[ -n "${TRACKING}" ]] || fail "no tracking number returned"
pass "created ${TRACKING}"

info "waiting up to ${PATIENCE}s for the worker to scan it"
DEADLINE=$(( $(date +%s) + PATIENCE ))
while :; do
  DETAIL="$(curl -fsS -m "${TIMEOUT}" "${WEB}/api/shipments/${TRACKING}" || true)"
  SCANS="$(printf '%s' "${DETAIL}" | field "len(d['scans'])" || echo 0)"
  if [[ "${SCANS}" =~ ^[0-9]+$ ]] && (( SCANS > 0 )); then
    WHO="$(printf '%s' "${DETAIL}" | field "d['scans'][0]['worker_host']")"
    WHERE="$(printf '%s' "${DETAIL}" | field "d['scans'][0]['worker_site']")"
    STATUS="$(printf '%s' "${DETAIL}" | field "d['status']")"
    pass "worker advanced it to ${STATUS}, scanned by ${WHO} (${WHERE})"
    break
  fi
  (( $(date +%s) < DEADLINE )) || fail "no scan appeared within ${PATIENCE}s - is the worker tier running?"
  sleep 2
done

printf '\n\033[1;32mEstate healthy.\033[0m Follow it at %s/track?n=%s\n' "${WEB}" "${TRACKING}"
