"""Thin pymssql wrapper shared by the API and worker tiers.

pymssql is used rather than pyodbc on purpose: it installs from PyPI with no
system ODBC driver, which keeps the install script identical across SLES, Rocky
and Ubuntu. Cross-distro package archaeology is not the story we are telling.
"""

from __future__ import annotations

import contextlib
import logging
import threading
import time
from collections.abc import Iterator
from typing import Any

import pymssql

from .config import Settings

log = logging.getLogger("shipment.db")


class DatabaseUnavailable(RuntimeError):
    """Raised when rhel-db cannot be reached.

    This is an expected, first-class condition during the demo: the database VM
    is migrated and briefly does not exist. Every caller is expected to degrade
    gracefully rather than crash, so the tier still answers /healthz and the
    dashboard can show *why* the board has stopped moving.
    """


class Database:
    """Serialised connection holder with lazy reconnect.

    Deliberately not a pool. The load is a few dozen requests per second at most,
    and a single connection guarded by a lock is far easier to reason about when
    something goes wrong on stage.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._lock = threading.Lock()
        self._conn: pymssql.Connection | None = None
        self._last_error: str | None = None
        self._last_failure_at: float = 0.0

    @property
    def last_error(self) -> str | None:
        return self._last_error

    def _connect(self) -> pymssql.Connection:
        settings = self._settings
        log.info("connecting to %s:%s/%s", settings.db_host, settings.db_port, settings.db_name)
        return pymssql.connect(
            server=settings.db_host,
            port=str(settings.db_port),
            user=settings.db_user,
            password=settings.db_password,
            database=settings.db_name,
            timeout=settings.db_query_timeout,
            login_timeout=settings.db_login_timeout,
            autocommit=True,
            as_dict=True,
        )

    def _ensure(self) -> pymssql.Connection:
        if self._conn is not None:
            return self._conn
        # Back off briefly after a failure so a dead database does not turn into
        # a connection storm visible in the demo logs.
        since_failure = time.monotonic() - self._last_failure_at
        if self._last_failure_at and since_failure < self._settings.db_retry_seconds:
            raise DatabaseUnavailable(self._last_error or "database unavailable")
        try:
            self._conn = self._connect()
            self._last_error = None
            self._last_failure_at = 0.0
        except Exception as exc:  # pymssql raises a wide family of errors
            self._last_error = str(exc)
            self._last_failure_at = time.monotonic()
            raise DatabaseUnavailable(str(exc)) from exc
        return self._conn

    def _discard(self, exc: Exception) -> None:
        self._last_error = str(exc)
        self._last_failure_at = time.monotonic()
        if self._conn is not None:
            with contextlib.suppress(Exception):
                self._conn.close()
        self._conn = None

    @contextlib.contextmanager
    def cursor(self) -> Iterator[pymssql.Cursor]:
        with self._lock:
            conn = self._ensure()
            try:
                with conn.cursor() as cur:
                    yield cur
            except DatabaseUnavailable:
                raise
            except Exception as exc:
                self._discard(exc)
                raise DatabaseUnavailable(str(exc)) from exc

    def query(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        with self.cursor() as cur:
            cur.execute(sql, params)
            return list(cur.fetchall() or [])

    def query_one(self, sql: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
        rows = self.query(sql, params)
        return rows[0] if rows else None

    def execute(self, sql: str, params: tuple[Any, ...] = ()) -> int:
        with self.cursor() as cur:
            cur.execute(sql, params)
            return cur.rowcount

    def ping(self) -> tuple[bool, str | None, float | None]:
        """Return (reachable, error, latency_ms) — drives the health strip."""
        started = time.monotonic()
        try:
            self.query("SELECT 1 AS ok")
        except DatabaseUnavailable as exc:
            return False, str(exc), None
        return True, None, round((time.monotonic() - started) * 1000, 1)

    def close(self) -> None:
        with self._lock:
            if self._conn is not None:
                with contextlib.suppress(Exception):
                    self._conn.close()
                self._conn = None
