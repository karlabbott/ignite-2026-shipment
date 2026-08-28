"""NinetyNine Freight worker — the only tier that changes shipment state.

Three loops run in one process:

* **claim loop** — pulls work from ``dbo.scan_queue`` and advances one shipment
  one step, writing a scan event and a status history row.
* **drift loop** — periodically nudges in-flight shipments along so the board is
  never static during a talk, even if nobody in the room is creating shipments.
* **heartbeat loop** — publishes this VM's identity so the health strip can show
  the worker moving from Hyper-V to Azure.

The worker reuses the API tier's database module verbatim. That is intentional:
the two tiers should fail against a missing database in exactly the same way.
"""

from __future__ import annotations

import logging
import random
import signal
import sys
import threading
import time
from typing import Any

from api.app.db import Database, DatabaseUnavailable
from common import estate, pipeline

from .config import settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
)
log = logging.getLogger("shipment.worker")

database = Database(settings)
identity = estate.identify(settings.tier)
shutdown = threading.Event()


# --------------------------------------------------------------------------- #
# Scan locations
# --------------------------------------------------------------------------- #
def _location_for(status: str, shipment: dict[str, Any]) -> str:
    """Pick a plausible location string for the scan we are about to write."""
    if status == pipeline.PICKED_UP:
        return shipment["origin"]
    if status in (pipeline.OUT_FOR_DELIVERY, pipeline.DELIVERED):
        return shipment["destination"]
    if status == pipeline.AT_HUB:
        return f"{shipment['carrier_hub']} Hub"
    return random.choice(settings.line_haul_stops)


# --------------------------------------------------------------------------- #
# Core transition
# --------------------------------------------------------------------------- #
def advance_one(shipment_id: int, requested_by: str) -> str | None:
    """Move a single shipment one step. Returns the new status, or None.

    Everything is written in one round trip per statement against an autocommit
    connection. There is no transaction spanning the three writes on purpose: if
    the database disappears mid-step the worst case is a scan without a status
    change, which self-heals on the next pass and is far easier to explain than a
    stuck open transaction during a live demo.
    """
    row = database.query_one(
        """
        SELECT s.shipment_id, s.tracking_number, s.status, s.origin, s.destination,
               c.hub_city AS carrier_hub
          FROM dbo.shipments s
          JOIN dbo.carriers  c ON c.carrier_id = s.carrier_id
         WHERE s.shipment_id = %s
        """,
        (shipment_id,),
    )
    if row is None:
        log.warning("queue referenced unknown shipment %s", shipment_id)
        return None

    current = row["status"]
    following = pipeline.next_status(current)
    if following is None:
        log.debug("%s already terminal (%s)", row["tracking_number"], current)
        return None

    location = _location_for(following, row)
    database.execute(
        """
        INSERT INTO dbo.scan_events
            (shipment_id, scan_type, location, notes, worker_host, worker_site)
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (
            shipment_id,
            pipeline.scan_type_for(following),
            location,
            pipeline.narrative_for(following),
            identity.hostname,
            identity.location,
        ),
    )
    database.execute(
        """
        INSERT INTO dbo.status_history (shipment_id, from_status, to_status, changed_by)
        VALUES (%s, %s, %s, %s)
        """,
        (shipment_id, current, following, f"worker:{identity.hostname}"),
    )
    database.execute(
        "UPDATE dbo.shipments SET status = %s, updated_at = SYSUTCDATETIME() WHERE shipment_id = %s",
        (following, shipment_id),
    )
    log.info(
        "%s %s -> %s at %s (requested by %s)",
        row["tracking_number"], current, following, location, requested_by,
    )
    return following


# --------------------------------------------------------------------------- #
# Loops
# --------------------------------------------------------------------------- #
def claim_loop() -> None:
    idle_backoff = settings.poll_seconds
    while not shutdown.is_set():
        try:
            claimed = database.query("EXEC dbo.usp_claim_scan %s", (identity.hostname,))
        except DatabaseUnavailable as exc:
            log.warning("database unavailable, retrying: %s", exc)
            shutdown.wait(settings.error_backoff_seconds)
            continue

        if not claimed:
            shutdown.wait(idle_backoff)
            idle_backoff = min(idle_backoff * 1.5, settings.max_idle_seconds)
            continue

        idle_backoff = settings.poll_seconds
        for item in claimed:
            if shutdown.is_set():
                break
            # A deliberate pause so the board animates at human speed rather than
            # teleporting every shipment to DELIVERED the instant it is created.
            shutdown.wait(random.uniform(*settings.scan_delay_range))
            try:
                advance_one(item["shipment_id"], item["requested_by"])
                database.execute(
                    "UPDATE dbo.scan_queue SET processed_at = SYSUTCDATETIME() WHERE queue_id = %s",
                    (item["queue_id"],),
                )
            except DatabaseUnavailable as exc:
                log.warning("lost the database mid-scan, will retry: %s", exc)
                break
            except Exception as exc:
                log.exception("failed to process queue item %s", item["queue_id"])
                try:
                    database.execute(
                        "UPDATE dbo.scan_queue SET last_error = %s WHERE queue_id = %s",
                        (str(exc)[:400], item["queue_id"]),
                    )
                except DatabaseUnavailable:
                    pass


def drift_loop() -> None:
    """Keep the board alive without audience input.

    Picks a few in-flight shipments that have not moved recently and enqueues a
    step for each. This is what makes the dashboard worth leaving on screen for
    the whole session.
    """
    if not settings.drift_enabled:
        log.info("ambient drift disabled")
        return
    while not shutdown.wait(settings.drift_interval_seconds):
        try:
            rows = database.query(
                """
                SELECT TOP (%d) s.shipment_id
                  FROM dbo.shipments s
                 WHERE s.status <> 'DELIVERED'
                   AND s.updated_at < DATEADD(second, -%d, SYSUTCDATETIME())
                   AND NOT EXISTS (SELECT 1 FROM dbo.scan_queue q
                                    WHERE q.shipment_id = s.shipment_id
                                      AND q.processed_at IS NULL)
                 ORDER BY s.updated_at ASC
                """,
                (settings.drift_batch, settings.drift_min_age_seconds),
            )
            for row in rows:
                database.execute(
                    "INSERT INTO dbo.scan_queue (shipment_id, requested_by) VALUES (%s, %s)",
                    (row["shipment_id"], "drift"),
                )
            if rows:
                log.info("drift queued %d shipment(s)", len(rows))
        except DatabaseUnavailable as exc:
            log.warning("drift skipped, database unavailable: %s", exc)
        except Exception:
            log.exception("unexpected drift failure")


def heartbeat_loop() -> None:
    while not shutdown.wait(settings.heartbeat_seconds):
        try:
            depth = database.query_one(
                "SELECT COUNT(*) AS n FROM dbo.scan_queue WHERE processed_at IS NULL"
            )
            database.execute(
                "EXEC dbo.usp_record_heartbeat %s, %s, %s, %s, %s, %s, %s, %s",
                (
                    identity.tier,
                    identity.hostname,
                    identity.distro,
                    identity.kernel,
                    identity.platform_name,
                    identity.location,
                    identity.vm_size,
                    f"queue depth {(depth or {'n': 0})['n']}",
                ),
            )
        except DatabaseUnavailable as exc:
            log.warning("heartbeat skipped, database unavailable: %s", exc)
        except Exception:
            log.exception("unexpected heartbeat failure")


def _handle_signal(signum: int, _frame: Any) -> None:
    log.info("received signal %s, shutting down", signum)
    shutdown.set()


def main() -> int:
    for problem in settings.sanity_check():
        log.error("configuration problem: %s", problem)
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    log.info("worker online as %s on %s", identity.hostname, identity.distro)
    log.info("platform=%s location=%s", identity.platform_name, identity.location)

    threads = [
        threading.Thread(target=claim_loop, name="claim", daemon=True),
        threading.Thread(target=drift_loop, name="drift", daemon=True),
        threading.Thread(target=heartbeat_loop, name="heartbeat", daemon=True),
    ]
    for thread in threads:
        thread.start()

    try:
        while not shutdown.is_set():
            time.sleep(0.5)
    except KeyboardInterrupt:
        shutdown.set()

    for thread in threads:
        thread.join(timeout=3)
    database.close()
    log.info("worker stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
