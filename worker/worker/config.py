"""Worker configuration.

Subclasses the API tier's Settings so both tiers read identical database
variables from /etc/shipment/shipment.env and cannot drift apart.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from api.app.config import Settings as BaseSettings


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


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class WorkerSettings(BaseSettings):
    tier: str = "worker"

    poll_seconds: float = field(default_factory=lambda: _env_float("SHIPMENT_POLL_SECONDS", 1.0))
    max_idle_seconds: float = field(default_factory=lambda: _env_float("SHIPMENT_MAX_IDLE_SECONDS", 5.0))
    error_backoff_seconds: float = field(default_factory=lambda: _env_float("SHIPMENT_ERROR_BACKOFF", 5.0))

    #: Random pause per scan so the board animates at a watchable pace.
    scan_delay_min: float = field(default_factory=lambda: _env_float("SHIPMENT_SCAN_DELAY_MIN", 1.5))
    scan_delay_max: float = field(default_factory=lambda: _env_float("SHIPMENT_SCAN_DELAY_MAX", 4.0))

    drift_enabled: bool = field(default_factory=lambda: _env_bool("SHIPMENT_DRIFT_ENABLED", True))
    drift_interval_seconds: float = field(default_factory=lambda: _env_float("SHIPMENT_DRIFT_INTERVAL", 20.0))
    drift_batch: int = field(default_factory=lambda: _env_int("SHIPMENT_DRIFT_BATCH", 3))
    drift_min_age_seconds: int = field(default_factory=lambda: _env_int("SHIPMENT_DRIFT_MIN_AGE", 45))

    @property
    def scan_delay_range(self) -> tuple[float, float]:
        low = max(0.0, self.scan_delay_min)
        high = max(low, self.scan_delay_max)
        return low, high

    @property
    def line_haul_stops(self) -> list[str]:
        raw = os.environ.get("SHIPMENT_LINE_HAUL_STOPS", "")
        if raw.strip():
            return [item.strip() for item in raw.split(",") if item.strip()]
        return [
            "Ellensburg, WA",
            "Boise, ID",
            "Salt Lake City, UT",
            "Cheyenne, WY",
            "North Platte, NE",
            "Des Moines, IA",
            "Joliet, IL",
            "Toledo, OH",
            "Harrisburg, PA",
        ]


settings = WorkerSettings()
