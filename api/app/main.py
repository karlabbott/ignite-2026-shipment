"""Zava Logistics API — FastAPI service for the SUSE tier.

Endpoints
---------
GET  /healthz                             liveness + identity + db reachability
GET  /api/estate                          every tier's heartbeat (health strip)
GET  /api/board                           the live shipment board
GET  /api/stats                           counters for the dashboard header
POST /api/shipments                       create a shipment (audience path)
GET  /api/shipments/{tracking}            full detail incl. scans and history
POST /api/shipments/{tracking}/advance    enqueue one pipeline step
"""

from __future__ import annotations

import logging
import random
import secrets
import threading
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware

from common import estate, pipeline

from .config import settings
from .db import Database, DatabaseUnavailable
from .models import (
    BoardRow,
    ScanEvent,
    Shipment,
    ShipmentCreate,
    ShipmentDetail,
    Stats,
    StatusChange,
    TierHealth,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
)
log = logging.getLogger("shipment.api")

database = Database(settings)


# --------------------------------------------------------------------------- #
# Rate limiting
# --------------------------------------------------------------------------- #
class RateLimiter:
    """Fixed-window limiter, per client and global.

    Deliberately in-process and approximate. The threat model is a room full of
    people with phones and a sense of humour, not a botnet — and nginx in front
    of the web tier carries the heavier limits.
    """

    def __init__(self, per_client: int, window: int, global_limit: int) -> None:
        self._per_client = per_client
        self._window = window
        self._global_limit = global_limit
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._global: deque[float] = deque()
        self._lock = threading.Lock()

    def _trim(self, bucket: deque[float], now: float) -> None:
        cutoff = now - self._window
        while bucket and bucket[0] < cutoff:
            bucket.popleft()

    def check(self, client: str) -> tuple[bool, str]:
        now = time.monotonic()
        with self._lock:
            self._trim(self._global, now)
            if len(self._global) >= self._global_limit:
                return False, "The demo is being enthusiastically enjoyed. Try again shortly."
            bucket = self._hits[client]
            self._trim(bucket, now)
            if len(bucket) >= self._per_client:
                return False, (
                    f"Limit is {self._per_client} shipments per "
                    f"{self._window} seconds. Give someone else a turn."
                )
            bucket.append(now)
            self._global.append(now)
            # Keep the dict from growing unbounded over a long rehearsal day.
            if len(self._hits) > 5000:
                for key in [k for k, v in self._hits.items() if not v][:2500]:
                    self._hits.pop(key, None)
            return True, ""


limiter = RateLimiter(
    settings.create_rate_limit,
    settings.create_rate_window,
    settings.create_global_limit,
)


# --------------------------------------------------------------------------- #
# Heartbeat
# --------------------------------------------------------------------------- #
def _heartbeat_loop(stop: threading.Event) -> None:
    """Publish this tier's identity to the database on a timer.

    Runs in its own thread and never raises: if the database is gone, the tier
    simply stops appearing in the health strip, which is exactly the signal the
    audience should see.
    """
    identity = estate.identify(settings.tier)
    while not stop.wait(settings.heartbeat_seconds):
        try:
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
                    f"fastapi/{settings.db_host}",
                ),
            )
        except DatabaseUnavailable as exc:
            log.warning("heartbeat skipped, database unavailable: %s", exc)
        except Exception:  # never let the heartbeat thread die
            log.exception("unexpected heartbeat failure")


@asynccontextmanager
async def lifespan(app: FastAPI):
    for problem in settings.sanity_check():
        log.error("configuration problem: %s", problem)
    stop = threading.Event()
    thread = threading.Thread(target=_heartbeat_loop, args=(stop,), daemon=True)
    thread.start()
    log.info("api tier online as %s", estate.identify(settings.tier))
    try:
        yield
    finally:
        stop.set()
        thread.join(timeout=2)
        database.close()


app = FastAPI(
    title="Zava Logistics API",
    version="1.0.0",
    summary="Shipment tracking across a mixed Linux estate",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def client_ip(request: Request) -> str:
    """Real client address, honouring the single nginx hop in front of us."""
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def require_db() -> Database:
    return database


def _new_tracking_number() -> str:
    """ZAV + 8 digits. Collisions are handled by retrying the insert."""
    return f"ZAV{secrets.randbelow(90_000_000) + 10_000_000:08d}"


def _decorate(row: dict[str, Any]) -> dict[str, Any]:
    row = dict(row)
    row["status_narrative"] = pipeline.narrative_for(row["status"])
    row["progress_percent"] = pipeline.progress_percent(row["status"])
    return row


def _db_error(exc: DatabaseUnavailable) -> HTTPException:
    """Turn a dead database into an honest 503 the dashboard can render.

    The message is surfaced verbatim on the health strip on purpose: 'the RHEL
    box is not answering on 1433' is the whole point of that beat in the demo.
    """
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail={
            "error": "database_unavailable",
            "target": f"{settings.db_host}:{settings.db_port}",
            "message": str(exc),
        },
    )


# --------------------------------------------------------------------------- #
# Health and estate
# --------------------------------------------------------------------------- #
@app.get("/healthz", tags=["health"])
def healthz(response: Response) -> dict[str, Any]:
    reachable, error, latency_ms = database.ping()
    payload = estate.identity_dict(settings.tier)
    payload["database"] = {
        "target": f"{settings.db_host}:{settings.db_port}",
        "reachable": reachable,
        "latency_ms": latency_ms,
        "error": error,
    }
    payload["healthy"] = reachable
    if not reachable:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return payload


@app.get("/api/estate", response_model=list[TierHealth], tags=["health"])
def get_estate(db: Database = Depends(require_db)) -> list[TierHealth]:
    """Every tier's last known identity, newest heartbeat wins.

    A tier that has not checked in for three heartbeat intervals is reported
    unhealthy rather than omitted, so the dashboard can grey the tile out instead
    of silently shrinking the strip.
    """
    try:
        rows = db.query(
            """
            SELECT tier, hostname, distro, kernel, platform, location, vm_size,
                   detail, last_seen,
                   DATEDIFF(second, last_seen, SYSUTCDATETIME()) AS age_seconds
              FROM dbo.tier_heartbeats
             ORDER BY CASE tier WHEN 'web' THEN 1 WHEN 'api' THEN 2
                                WHEN 'db'  THEN 3 WHEN 'worker' THEN 4 ELSE 5 END
            """
        )
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    stale_after = settings.heartbeat_seconds * 3
    result: list[TierHealth] = []
    for row in rows:
        age = row.pop("age_seconds", None) or 0
        row["healthy"] = age <= stale_after
        result.append(TierHealth(**row))
    return result


# --------------------------------------------------------------------------- #
# Board and stats
# --------------------------------------------------------------------------- #
@app.get("/api/board", response_model=list[BoardRow], tags=["shipments"])
def get_board(limit: int = 0, db: Database = Depends(require_db)) -> list[BoardRow]:
    limit = min(limit or settings.board_limit, 200)
    try:
        rows = db.query(
            """
            SELECT TOP (%d) tracking_number, carrier_code, origin, destination,
                   status, scan_count, last_location, last_scanned_by,
                   created_by, updated_at
              FROM dbo.vw_shipment_board
            """,
            (limit,),
        )
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc
    return [BoardRow(**_decorate(row)) for row in rows]


@app.get("/api/stats", response_model=Stats, tags=["shipments"])
def get_stats(db: Database = Depends(require_db)) -> Stats:
    try:
        by_status = {
            row["status"]: row["n"]
            for row in db.query(
                "SELECT status, COUNT(*) AS n FROM dbo.shipments GROUP BY status"
            )
        }
        queue_depth = (
            db.query_one(
                "SELECT COUNT(*) AS n FROM dbo.scan_queue WHERE processed_at IS NULL"
            )
            or {"n": 0}
        )["n"]
        recent = (
            db.query_one(
                """
                SELECT COUNT(*) AS n FROM dbo.scan_events
                 WHERE occurred_at >= DATEADD(minute, -5, SYSUTCDATETIME())
                """
            )
            or {"n": 0}
        )["n"]
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    total = sum(by_status.values())
    delivered = by_status.get(pipeline.DELIVERED, 0)
    return Stats(
        total=total,
        delivered=delivered,
        in_flight=total - delivered,
        queue_depth=queue_depth,
        scans_last_5m=recent,
        by_status=by_status,
    )


# --------------------------------------------------------------------------- #
# Shipments
# --------------------------------------------------------------------------- #
@app.post(
    "/api/shipments",
    response_model=Shipment,
    status_code=status.HTTP_201_CREATED,
    tags=["shipments"],
)
def create_shipment(
    payload: ShipmentCreate,
    request: Request,
    db: Database = Depends(require_db),
) -> Shipment:
    """Create a shipment and immediately queue its first pipeline step.

    This is the endpoint the audience hits from the QR code, so it is rate
    limited and every string has already been length-capped by pydantic.
    """
    allowed, reason = limiter.check(client_ip(request))
    if not allowed:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=reason)

    try:
        if payload.carrier_code:
            carrier = db.query_one(
                "SELECT carrier_id FROM dbo.carriers WHERE code = %s",
                (payload.carrier_code,),
            )
            if carrier is None:
                raise HTTPException(status_code=400, detail="Unknown carrier code")
            carrier_id = carrier["carrier_id"]
        else:
            carriers = db.query("SELECT carrier_id FROM dbo.carriers")
            if not carriers:
                raise HTTPException(status_code=503, detail="No carriers configured")
            carrier_id = random.choice(carriers)["carrier_id"]

        shipment_id: int | None = None
        tracking = ""
        for _ in range(5):
            tracking = _new_tracking_number()
            try:
                row = db.query_one(
                    """
                    INSERT INTO dbo.shipments
                        (tracking_number, carrier_id, origin, destination,
                         description, weight_kg, status, created_by)
                    OUTPUT inserted.shipment_id
                    VALUES (%s, %s, %s, %s, %s, %s, 'CREATED', %s)
                    """,
                    (
                        tracking,
                        carrier_id,
                        payload.origin,
                        payload.destination,
                        payload.description,
                        payload.weight_kg,
                        payload.created_by,
                    ),
                )
            except DatabaseUnavailable:
                raise
            else:
                if row:
                    shipment_id = row["shipment_id"]
                    break

        if shipment_id is None:
            raise HTTPException(status_code=500, detail="Could not allocate tracking number")

        db.execute(
            """
            INSERT INTO dbo.status_history (shipment_id, from_status, to_status, changed_by)
            VALUES (%s, NULL, 'CREATED', %s)
            """,
            (shipment_id, payload.created_by),
        )
        db.execute(
            "INSERT INTO dbo.scan_queue (shipment_id, requested_by) VALUES (%s, %s)",
            (shipment_id, payload.created_by),
        )
        created = db.query_one(_SHIPMENT_SQL, (tracking,))
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    if created is None:
        raise HTTPException(status_code=500, detail="Shipment vanished immediately after creation")
    log.info("created %s for %s", tracking, payload.created_by)
    return Shipment(**_decorate(created))


_SHIPMENT_SQL = """
SELECT s.tracking_number, c.code AS carrier_code, c.name AS carrier_name,
       s.origin, s.destination, s.description, s.weight_kg, s.status,
       s.created_by, s.created_at, s.updated_at
  FROM dbo.shipments s
  JOIN dbo.carriers  c ON c.carrier_id = s.carrier_id
 WHERE s.tracking_number = %s
"""


@app.get(
    "/api/shipments/{tracking}",
    response_model=ShipmentDetail,
    tags=["shipments"],
)
def get_shipment(tracking: str, db: Database = Depends(require_db)) -> ShipmentDetail:
    tracking = tracking.strip().upper()[:20]
    try:
        row = db.query_one(_SHIPMENT_SQL, (tracking,))
        if row is None:
            raise HTTPException(status_code=404, detail="No such tracking number")
        scans = db.query(
            """
            SELECT TOP (50) e.scan_id, e.scan_type, e.location, e.notes,
                   e.worker_host, e.worker_site, e.occurred_at
              FROM dbo.scan_events e
              JOIN dbo.shipments s ON s.shipment_id = e.shipment_id
             WHERE s.tracking_number = %s
             ORDER BY e.occurred_at DESC, e.scan_id DESC
            """,
            (tracking,),
        )
        history = db.query(
            """
            SELECT TOP (50) h.from_status, h.to_status, h.changed_by, h.changed_at
              FROM dbo.status_history h
              JOIN dbo.shipments s ON s.shipment_id = h.shipment_id
             WHERE s.tracking_number = %s
             ORDER BY h.changed_at DESC, h.history_id DESC
            """,
            (tracking,),
        )
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    detail = _decorate(row)
    detail["scans"] = [ScanEvent(**scan) for scan in scans]
    detail["history"] = [StatusChange(**change) for change in history]
    return ShipmentDetail(**detail)


@app.post("/api/shipments/{tracking}/advance", tags=["shipments"])
def advance_shipment(
    tracking: str,
    request: Request,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    """Queue one pipeline step for this shipment.

    The API never advances a shipment itself — it only enqueues. All state
    transitions happen on the Rocky worker, so the demo can prove the worker tier
    is alive by watching shipments move.
    """
    tracking = tracking.strip().upper()[:20]
    allowed, reason = limiter.check(client_ip(request))
    if not allowed:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=reason)

    try:
        row = db.query_one(
            "SELECT shipment_id, status FROM dbo.shipments WHERE tracking_number = %s",
            (tracking,),
        )
        if row is None:
            raise HTTPException(status_code=404, detail="No such tracking number")
        if pipeline.is_terminal(row["status"]):
            return {
                "tracking_number": tracking,
                "queued": False,
                "status": row["status"],
                "message": "Shipment already delivered",
            }
        db.execute(
            "INSERT INTO dbo.scan_queue (shipment_id, requested_by) VALUES (%s, %s)",
            (row["shipment_id"], f"api:{client_ip(request)}"),
        )
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    return {
        "tracking_number": tracking,
        "queued": True,
        "status": row["status"],
        "next_status": pipeline.next_status(row["status"]),
    }
