"""Web tier configuration.

Extends the API tier's settings so the web tier can publish its own heartbeat
using the same database variables, while adding its own upstream and branding.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from api.app.config import Settings as BaseSettings


def _env(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default


@dataclass(frozen=True)
class WebSettings(BaseSettings):
    tier: str = "web"

    api_base_url: str = field(
        default_factory=lambda: _env("SHIPMENT_API_URL", "http://192.168.90.12:8080").rstrip("/")
    )
    api_timeout_seconds: float = field(
        default_factory=lambda: _env_float("SHIPMENT_API_TIMEOUT", 5.0)
    )

    brand: str = field(default_factory=lambda: _env("SHIPMENT_BRAND", "Zava Logistics"))

    # The address shown on the dashboard for the audience-facing tracking page.
    #
    # Deliberately EMPTY by default. On Hyper-V there is no DNS pointing at this
    # lab, so the only honest answer is the address the browser actually used --
    # http://192.168.90.13/track. main.py derives that from the request host, so
    # the board is correct on day one with no configuration at all.
    #
    # Once the estate is in Azure and track.99b.org resolves, set
    # SHIPMENT_TRACK_URL in /etc/shipment/shipment.env to pin the public name.
    # That single line is the visible "we have real DNS now" moment.
    public_track_url: str = field(default_factory=lambda: _env("SHIPMENT_TRACK_URL", ""))
    refresh_ms: int = field(default_factory=lambda: _env_int("SHIPMENT_REFRESH_MS", 3000))


settings = WebSettings()
