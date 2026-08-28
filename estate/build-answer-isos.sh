#!/usr/bin/env bash
# Build the unattended-install answer ISOs for the NinetyNine Freight estate.
#
# Run this inside WSL:
#   wsl -d Ubuntu -e bash estate/build-answer-isos.sh
#
# It produces four small ISOs in estate/out/ that get attached as a second DVD
# drive to each VM:
#
#   rhel10-db-oemdrv.iso        label OEMDRV   -> Anaconda auto-detects ks.cfg
#   rocky10-worker-cidata.iso   label CIDATA   -> cloud-init seeds the RLC+ image
#   ubuntu26-web-cidata.iso     label CIDATA   -> subiquity NoCloud datasource
#   sles16-api-profile.iso      label AGAMA    -> fallback if HTTP is unavailable
#
# Secrets are injected here, at build time, and never committed. The answer
# files in git contain !!SSH_PUBKEY!! and !!PASSWORD_HASH!! placeholders.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${HERE}/out"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- dependencies --
missing=()
command -v xorriso  >/dev/null || missing+=(xorriso)
command -v openssl  >/dev/null || missing+=(openssl)
if (( ${#missing[@]} )); then
  log "installing: ${missing[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y -qq xorriso openssl
fi

# ------------------------------------------------------------------ secrets --
# SSH public key: defaults to the Windows-side key, overridable.
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
if [[ -z "${SSH_PUBKEY_FILE}" ]]; then
  for candidate in \
    "${HOME}/.ssh/id_ed25519.pub" \
    "${HOME}/.ssh/id_rsa.pub" \
    /mnt/c/Users/"${WIN_USER:-$USER}"/.ssh/id_rsa.pub
  do
    [[ -f "${candidate}" ]] && SSH_PUBKEY_FILE="${candidate}" && break
  done
fi
[[ -f "${SSH_PUBKEY_FILE}" ]] || die "No SSH public key found. Set SSH_PUBKEY_FILE=/path/to/key.pub"
SSH_PUBKEY="$(tr -d '\r\n' < "${SSH_PUBKEY_FILE}")"
log "using SSH key: ${SSH_PUBKEY_FILE}"

# Console password for the estate account. Key auth is the normal path; this
# exists so you can log in at the Hyper-V console when SSH is exactly the thing
# that is broken -- which, in this lab, it will be.
if [[ -z "${ESTATE_PASSWORD:-}" ]]; then
  read -rsp "Console password for the 'estate' account: " ESTATE_PASSWORD; echo
  [[ -n "${ESTATE_PASSWORD}" ]] || die "A console password is required."
fi
PASSWORD_HASH="$(openssl passwd -6 "${ESTATE_PASSWORD}")"

# A SLES registration code is optional. The default baseline build leaves SLES
# unregistered so it can be registered interactively after the install. When a
# code is supplied, it is added to the generated Agama profile only.
SCC_REG_CODE="${SCC_REG_CODE:-}"
[[ -n "${SCC_REG_CODE}" ]] || log "SLES will be registered manually after installation."

# The RHEL 10 kickstart `rhsm` command only supports an organization ID and
# activation key (not a username/password). The boot ISO registers with Red
# Hat CDN before Anaconda installs packages. Prompt by default; callers that
# automate a rebuild can instead provide these as one-shot environment
# variables. They are rendered only into estate/out/, never into Git.
if [[ -z "${RHSM_ORGANIZATION:-}" ]]; then
  read -rp "Red Hat organization ID: " RHSM_ORGANIZATION
fi
if [[ -z "${RHSM_ACTIVATION_KEY:-}" ]]; then
  read -rsp "Red Hat activation key: " RHSM_ACTIVATION_KEY; echo
fi
[[ -n "${RHSM_ORGANIZATION}" ]] || die "A Red Hat organization ID is required for the RHEL boot ISO."
[[ -n "${RHSM_ACTIVATION_KEY}" ]] || die "A Red Hat activation key is required for the RHEL boot ISO."

# The lab uses static guest networking, so it needs the same DNS servers as
# the Windows host. Discover them automatically via PowerShell; this makes the
# generated media portable between office, home and conference networks. The
# prompt is only a fallback if Windows DNS discovery is unavailable.
if [[ -z "${ESTATE_DNS_SERVERS:-}" ]]; then
  POWERSHELL=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  if [[ -x "${POWERSHELL}" ]]; then
    ESTATE_DNS_SERVERS="$(
      "${POWERSHELL}" -NoProfile -Command \
        '$dns = Get-DnsClientServerAddress -AddressFamily IPv4 |
          Where-Object { $_.ServerAddresses.Count -gt 0 } |
          Select-Object -First 1 -ExpandProperty ServerAddresses;
         $dns -join ","' 2>/dev/null | tr -d '\r\n'
    )"
  fi
fi
if [[ -z "${ESTATE_DNS_SERVERS:-}" ]]; then
  read -rp "DNS servers for the lab (comma-separated): " ESTATE_DNS_SERVERS
fi
[[ -n "${ESTATE_DNS_SERVERS}" ]] || die "At least one DNS server is required."

# Keep the active host resolver first, then add public fallbacks. This covers
# office networks that require corporate DNS and home networks where the local
# resolver is absent or temporarily unavailable, without committing either.
case ",${ESTATE_DNS_SERVERS}," in
  *,1.1.1.1,*) ;;
  *) ESTATE_DNS_SERVERS="${ESTATE_DNS_SERVERS},1.1.1.1" ;;
esac
case ",${ESTATE_DNS_SERVERS}," in
  *,8.8.8.8,*) ;;
  *) ESTATE_DNS_SERVERS="${ESTATE_DNS_SERVERS},8.8.8.8" ;;
esac

render() {
  # render <src> <dst>  -- substitute placeholders without echoing secrets
  local src="$1" dst="$2"
  SSH_PUBKEY="${SSH_PUBKEY}" PASSWORD_HASH="${PASSWORD_HASH}" \
  SCC_REG_CODE="${SCC_REG_CODE}" RHSM_ORGANIZATION="${RHSM_ORGANIZATION}" \
  RHSM_ACTIVATION_KEY="${RHSM_ACTIVATION_KEY}" \
  ESTATE_DNS_SERVERS="${ESTATE_DNS_SERVERS}" python3 - "${src}" "${dst}" <<'PY'
import json
import os
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as handle:
    body = handle.read()

for token, value in (
    ("!!SSH_PUBKEY!!", os.environ["SSH_PUBKEY"]),
    ("!!PASSWORD_HASH!!", os.environ["PASSWORD_HASH"]),
    ("!!RHSM_ORGANIZATION!!", os.environ["RHSM_ORGANIZATION"]),
    ("!!RHSM_ACTIVATION_KEY!!", os.environ["RHSM_ACTIVATION_KEY"]),
    ("!!DNS_SERVERS!!", os.environ["ESTATE_DNS_SERVERS"]),
):
    body = body.replace(token, value)

# Anaconda's RHEL 10 kickstart parser does not accept shell-style trailing
# backslashes. Keep wrapped directives readable in the template, but flatten
# only wrapped network/user directives in the generated ks.cfg. Do not replace
# continuations globally: %post shell scripts may legitimately contain them.
if dst.endswith("ks.cfg"):
    rendered = []
    lines = body.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith(("network ", "user ")):
            directive = line.rstrip().rstrip("\\").rstrip()
            while (index + 1 < len(lines)
                   and lines[index + 1].lstrip().startswith("--")):
                index += 1
                directive += " " + lines[index].strip().rstrip("\\").rstrip()
            rendered.append(directive)
        else:
            rendered.append(line)
        index += 1
    body = "\n".join(rendered) + "\n"

registration_code = os.environ.get("SCC_REG_CODE", "")
registration = ""
if registration_code:
    registration = ",\n    \"registrationCode\": " + json.dumps(registration_code)
body = body.replace("!!SCC_REGISTRATION!!", registration)
body = body.replace(
    "!!DNS_SERVERS_JSON!!",
    ", ".join(json.dumps(server.strip()) for server in os.environ["ESTATE_DNS_SERVERS"].split(",") if server.strip()),
)

if "!!" in body:
    leftovers = {line.strip() for line in body.splitlines() if "!!" in line}
    print(f"warning: unsubstituted placeholders in {dst}:", file=sys.stderr)
    for line in sorted(leftovers):
        print(f"  {line}", file=sys.stderr)

with open(dst, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(body)
PY
}

mkdir -p "${OUT}"

# --------------------------------------------------------- Anaconda: OEMDRV --
# Anaconda scans removable media for a volume labelled OEMDRV and reads
# /ks.cfg from it automatically. No boot arguments needed at all.
build_oemdrv() {
  local name="$1" source="$2"
  log "building ${name} (OEMDRV)"
  local dir="${WORK}/${name}"
  mkdir -p "${dir}"
  render "${source}" "${dir}/ks.cfg"
  xorriso -as mkisofs -quiet \
    -volid OEMDRV -rational-rock -joliet \
    -output "${OUT}/${name}.iso" "${dir}"
}

build_oemdrv rhel10-db-oemdrv      "${HERE}/kickstart/rhel10-db.ks"

# ------------------------------------------- cloud-init NoCloud: rocky-worker --
# RLC+ is published as a qcow2 cloud image, not an installer ISO, so the worker
# is not kickstarted at all -- it boots the converted image and configures
# itself from this seed. cloud-init requires the volume label to be exactly
# CIDATA and the files to be named user-data / meta-data.
log "building rocky10-worker-cidata (CIDATA)"
RLCSEED="${WORK}/rlcseed"
mkdir -p "${RLCSEED}"
render "${HERE}/cloudinit/rlc-worker-user-data" "${RLCSEED}/user-data"
cp "${HERE}/cloudinit/rlc-worker-network-config" "${RLCSEED}/network-config"
cat > "${RLCSEED}/meta-data" <<'EOF'
instance-id: rocky-worker-01
local-hostname: rocky-worker
EOF
xorriso -as mkisofs -quiet \
  -volid CIDATA -rational-rock -joliet \
  -output "${OUT}/rocky10-worker-cidata.iso" "${RLCSEED}"

# ------------------------------------------------------ subiquity: CIDATA ----
log "building ubuntu26-web-cidata (CIDATA)"
CIDATA="${WORK}/cidata"
mkdir -p "${CIDATA}"
render "${HERE}/autoinstall/user-data" "${CIDATA}/user-data"
cp "${HERE}/autoinstall/meta-data" "${CIDATA}/meta-data"
: > "${CIDATA}/vendor-data"
xorriso -as mkisofs -quiet \
  -volid CIDATA -rational-rock -joliet \
  -output "${OUT}/ubuntu26-web-cidata.iso" "${CIDATA}"

# ------------------------------------------------------------ Agama: AGAMA --
# Agama does not auto-detect a labelled volume, so this ISO is the fallback for
# when the HTTP answer server is not reachable. Boot argument in that case:
#   inst.auto=cd:/sles16-api.json
log "building sles16-api-profile (AGAMA)"
AGAMA="${WORK}/agama"
mkdir -p "${AGAMA}"
render "${HERE}/agama/sles16-api.json" "${AGAMA}/sles16-api.json"
xorriso -as mkisofs -quiet \
  -volid AGAMA -rational-rock -joliet \
  -output "${OUT}/sles16-api-profile.iso" "${AGAMA}"

# The HTTP answer server serves the rendered profile from the same directory.
mkdir -p "${OUT}/http"
cp "${AGAMA}/sles16-api.json" "${OUT}/http/sles16-api.json"

chmod 600 "${OUT}"/*.iso "${OUT}/http/sles16-api.json"

log "done. Answer ISOs in ${OUT}:"
ls -la "${OUT}"/*.iso
cat <<'NOTE'

These ISOs contain a password hash and your SSH public key.
estate/out/ is gitignored -- keep it that way.

NOTE
