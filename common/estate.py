"""Shared helpers used identically by every tier in the estate.

This module is deliberately dependency-light (stdlib only) so it can be vendored
into the API, web and worker tiers without dragging a package manager into the
story. Its whole job is to answer one question loudly: *where am I running?*
"""

from __future__ import annotations

import functools
import json
import os
import platform
import socket
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from typing import Any

IMDS_URL = (
    "http://169.254.169.254/metadata/instance/compute"
    "?api-version=2021-02-01"
)
IMDS_TIMEOUT_SECONDS = 1.0

_STARTED_AT = time.time()


@dataclass(frozen=True)
class TierIdentity:
    """Everything the health strip needs to render one tile."""

    tier: str
    hostname: str
    distro: str
    kernel: str
    platform_name: str
    location: str
    vm_size: str | None
    resource_group: str | None


def _read_os_release() -> dict[str, str]:
    values: dict[str, str] = {}
    for path in ("/etc/os-release", "/usr/lib/os-release"):
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, _, raw = line.partition("=")
                    values[key] = raw.strip().strip('"')
            break
        except OSError:
            continue
    return values


def distro_pretty_name() -> str:
    """Human-readable distro string, e.g. 'Red Hat Enterprise Linux 9.6 (Plow)'."""
    values = _read_os_release()
    return (
        values.get("PRETTY_NAME")
        or values.get("NAME")
        or f"{platform.system()} {platform.release()}"
    )


def distro_id() -> str:
    """Short distro id: rhel, sles, ubuntu, rocky, ..."""
    return _read_os_release().get("ID", "unknown").strip('"').lower()


@functools.lru_cache(maxsize=1)
def azure_metadata() -> dict[str, Any] | None:
    """Query Azure IMDS. Returns None when not running on an Azure VM.

    Cached because the answer cannot change within the life of a process, and
    because a one-second timeout on every health poll would be visible on stage.
    """
    request = urllib.request.Request(IMDS_URL, headers={"Metadata": "true"})
    try:
        with urllib.request.urlopen(request, timeout=IMDS_TIMEOUT_SECONDS) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return None


def identify(tier: str) -> TierIdentity:
    """Build this process's identity tile."""
    metadata = azure_metadata()
    if metadata:
        location = f"azure/{metadata.get('location', 'unknown')}"
        vm_size = metadata.get("vmSize")
        resource_group = metadata.get("resourceGroupName")
        platform_name = "Azure"
    else:
        location = os.environ.get("SHIPMENT_SITE", "on-prem/hyper-v")
        vm_size = None
        resource_group = None
        platform_name = "Hyper-V"

    return TierIdentity(
        tier=tier,
        hostname=socket.gethostname(),
        distro=distro_pretty_name(),
        kernel=platform.release(),
        platform_name=platform_name,
        location=location,
        vm_size=vm_size,
        resource_group=resource_group,
    )


def identity_dict(tier: str) -> dict[str, Any]:
    payload = asdict(identify(tier))
    payload["uptime_seconds"] = round(time.time() - _STARTED_AT, 1)
    return payload


def env_str(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def env_float(name: str, default: float) -> float:
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default
