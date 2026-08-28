"""Configuration for the API tier.

Everything is read from the environment, which systemd loads from
/etc/shipment/shipment.env. That single file is the only thing that has to change
when the estate lands in Azure with new addresses.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _env(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def _env_list(name: str, default: str) -> list[str]:
    raw = _env(name, default)
    return [item.strip() for item in raw.split(",") if item.strip()]


@dataclass(frozen=True)
class Settings:
    tier: str = "api"

    db_host: str = field(default_factory=lambda: _env("SHIPMENT_DB_HOST", "192.168.90.11"))
    db_port: int = field(default_factory=lambda: _env_int("SHIPMENT_DB_PORT", 1433))
    db_name: str = field(default_factory=lambda: _env("SHIPMENT_DB_NAME", "shipping"))
    db_user: str = field(default_factory=lambda: _env("SHIPMENT_DB_USER", "shipping_app"))
    db_password: str = field(default_factory=lambda: _env("SHIPMENT_DB_PASSWORD", ""))
    db_login_timeout: int = field(default_factory=lambda: _env_int("SHIPMENT_DB_LOGIN_TIMEOUT", 5))
    db_query_timeout: int = field(default_factory=lambda: _env_int("SHIPMENT_DB_QUERY_TIMEOUT", 10))
    db_retry_seconds: int = field(default_factory=lambda: _env_int("SHIPMENT_DB_RETRY_SECONDS", 3))

    heartbeat_seconds: int = field(default_factory=lambda: _env_int("SHIPMENT_HEARTBEAT_SECONDS", 10))
    board_limit: int = field(default_factory=lambda: _env_int("SHIPMENT_BOARD_LIMIT", 60))

    #: Per-source-IP shipment creations allowed per window. The audience will
    #: absolutely try to break this, so it is enforced here as well as at nginx.
    create_rate_limit: int = field(default_factory=lambda: _env_int("SHIPMENT_CREATE_RATE_LIMIT", 5))
    create_rate_window: int = field(default_factory=lambda: _env_int("SHIPMENT_CREATE_RATE_WINDOW", 60))
    create_global_limit: int = field(default_factory=lambda: _env_int("SHIPMENT_CREATE_GLOBAL_LIMIT", 240))

    cors_origins: list[str] = field(
        default_factory=lambda: _env_list(
            "SHIPMENT_CORS_ORIGINS",
            "https://dash.99b.org,https://track.99b.org,http://192.168.90.13",
        )
    )

    def sanity_check(self) -> list[str]:
        """Return a list of configuration problems worth shouting about at start."""
        problems: list[str] = []
        if not self.db_password:
            problems.append(
                "SHIPMENT_DB_PASSWORD is empty - set it in /etc/shipment/shipment.env"
            )
        return problems


settings = Settings()
