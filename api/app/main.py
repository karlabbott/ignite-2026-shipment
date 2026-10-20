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
from common.routing import plan_route, warm_offline_index

from .config import settings
from .db import Database, DatabaseUnavailable
from .models import (
    BoardRow,
    FailurePollState,
    FailureRunner,
    FailureInjectionResult,
    FailureVote,
    RoutePoint,
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
    """Fixed-window limiter with optional global capacity.

    Deliberately in-process and approximate. The threat model is a room full of
    people with phones and a sense of humour, not a botnet — and nginx in front
    of the web tier carries the heavier limits.
    """

    def __init__(
        self,
        per_client: int,
        window: int,
        global_limit: int | None = None,
    ) -> None:
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
            if self._global_limit is not None and len(self._global) >= self._global_limit:
                return False, "The demo is being enthusiastically enjoyed. Try again shortly."
            bucket = self._hits[client]
            self._trim(bucket, now)
            if len(bucket) >= self._per_client:
                return False, (
                    f"Limit is {self._per_client} shipments per "
                    f"{self._window} seconds. Give someone else a turn."
                )
            bucket.append(now)
            if self._global_limit is not None:
                self._global.append(now)
            # Keep the dict from growing unbounded over a long rehearsal day.
            if len(self._hits) > 5000:
                for key in [k for k, v in self._hits.items() if not v][:2500]:
                    self._hits.pop(key, None)
            return True, ""


client_limiter = RateLimiter(
    settings.create_rate_limit,
    settings.create_rate_window,
)
ip_limiter = RateLimiter(
    settings.create_ip_rate_limit,
    settings.create_rate_window,
    settings.create_global_limit,
)
vote_limiter = RateLimiter(2000, 60, 5000)


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
    warm_offline_index()
    stop = threading.Event()
    thread = threading.Thread(target=_heartbeat_loop, args=(stop,), daemon=True)
    thread.start()
    log.info("api tier online as %s", estate.identify(settings.tier))
    log.info(
        "route geocoding: %s",
        "Azure Maps with offline fallback"
        if settings.azure_maps_key
        else "offline global fallback (Azure Maps key not configured)",
    )
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


def client_identity(request: Request) -> str:
    token = request.headers.get("x-zava-client-token", "")
    if (
        16 <= len(token) <= 64
        and all(char.isalnum() or char in "_-" for char in token)
    ):
        return f"browser:{token}"
    return f"ip:{client_ip(request)}"


def enforce_shipment_create_limit(request: Request) -> None:
    checks = (
        (ip_limiter, f"ip:{client_ip(request)}"),
        (client_limiter, client_identity(request)),
    )
    for rate_limiter, identity in checks:
        allowed, reason = rate_limiter.check(identity)
        if not allowed:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=reason,
            )


def trusted_load_generator(request: Request) -> bool:
    supplied = request.headers.get("x-zava-loadgen-key", "")
    return bool(
        settings.loadgen_key
        and supplied
        and secrets.compare_digest(supplied, settings.loadgen_key)
    )


def trusted_presenter(request: Request) -> bool:
    supplied = request.headers.get("x-zava-presenter-key", "")
    return bool(
        settings.presenter_key
        and supplied
        and secrets.compare_digest(supplied, settings.presenter_key)
    )


def require_presenter(request: Request) -> None:
    if not trusted_presenter(request):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Presenter key required",
        )


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
                                WHEN 'db'  THEN 3 WHEN 'worker' THEN 4 ELSE 5 END,
                      hostname
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
def get_board(
    limit: int = 0,
    offset: int = 0,
    db: Database = Depends(require_db),
) -> list[BoardRow]:
    limit = min(limit or settings.board_limit, 200)
    offset = min(max(offset, 0), 100_000)
    try:
        rows = db.query(
            """
            SELECT s.tracking_number, c.code AS carrier_code,
                   s.origin AS origin,
                   s.destination AS destination,
                   s.status,
                   (SELECT COUNT(*) FROM dbo.scan_events e
                     WHERE e.shipment_id = s.shipment_id) AS scan_count,
                   CASE s.status
                       WHEN 'PICKED_UP' THEN s.origin
                       WHEN 'IN_TRANSIT' THEN COALESCE(
                           (SELECT location FROM dbo.shipment_route_stops
                             WHERE shipment_id = s.shipment_id AND stop_sequence = 1),
                           N'In transit')
                       WHEN 'AT_HUB' THEN COALESCE(
                           (SELECT location FROM dbo.shipment_route_stops
                             WHERE shipment_id = s.shipment_id AND stop_sequence = 2),
                           (SELECT location FROM dbo.shipment_route_stops
                             WHERE shipment_id = s.shipment_id AND stop_sequence = 1),
                           CONCAT(c.hub_city, N' Hub'))
                       WHEN 'OUT_FOR_DELIVERY' THEN s.destination
                       WHEN 'DELIVERED' THEN s.destination
                       ELSE NULL
                   END AS last_location,
                   (SELECT TOP 1 e.worker_host FROM dbo.scan_events e
                     WHERE e.shipment_id = s.shipment_id
                     ORDER BY e.occurred_at DESC, e.scan_id DESC) AS last_scanned_by,
                   N'Audience' AS created_by, s.updated_at
              FROM dbo.shipments s
              JOIN dbo.carriers c ON c.carrier_id = s.carrier_id
             ORDER BY s.updated_at DESC, s.shipment_id DESC
            OFFSET %d ROWS FETCH NEXT %d ROWS ONLY
            """,
            (offset, limit),
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
    if not trusted_load_generator(request):
        enforce_shipment_create_limit(request)

    route = plan_route(
        payload.origin,
        payload.destination,
        azure_maps_key=settings.azure_maps_key,
        timeout_seconds=settings.geocoding_timeout_seconds,
    )
    resolved_origin = route.origin.name if route.origin else payload.origin
    resolved_destination = (
        route.destination.name if route.destination else payload.destination
    )
    stage_origin = (
        route.origin.stage_label[:100] if route.origin else "Custom origin"
    )
    stage_destination = (
        route.destination.stage_label[:100]
        if route.destination
        else "Custom destination"
    )
    if (
        resolved_origin != payload.origin
        or resolved_destination != payload.destination
    ):
        log.info(
            "resolved requested route %s -> %s as %s -> %s",
            payload.origin,
            payload.destination,
            resolved_origin,
            resolved_destination,
        )

    try:
        if route.source == "deep-space-route":
            db.execute(
                """
                MERGE dbo.carriers AS target
                USING (VALUES (
                    'IPS',
                    N'Intergalactic Planetary Shippers',
                    N'Brooklyn Orbital Dispatch'
                )) AS source (code, name, hub_city)
                ON target.code = source.code
                WHEN MATCHED THEN UPDATE SET
                    name = source.name,
                    hub_city = source.hub_city
                WHEN NOT MATCHED THEN INSERT (code, name, hub_city)
                    VALUES (source.code, source.name, source.hub_city);
                """
            )
            carrier = db.query_one(
                "SELECT carrier_id FROM dbo.carriers WHERE code = 'IPS'"
            )
            if carrier is None:
                raise HTTPException(
                    status_code=503,
                    detail="Intergalactic carrier unavailable",
                )
            carrier_id = carrier["carrier_id"]
        elif payload.carrier_code:
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
                         stage_origin, stage_destination, description,
                         weight_kg, status, created_by,
                         origin_latitude, origin_longitude,
                         destination_latitude, destination_longitude)
                    OUTPUT inserted.shipment_id
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'CREATED', %s,
                            %s, %s, %s, %s)
                    """,
                    (
                        tracking,
                        carrier_id,
                        payload.origin,
                        payload.destination,
                        stage_origin,
                        stage_destination,
                        payload.description,
                        payload.weight_kg,
                        payload.created_by,
                        route.origin.latitude if route.origin else None,
                        route.origin.longitude if route.origin else None,
                        route.destination.latitude if route.destination else None,
                        route.destination.longitude if route.destination else None,
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

        try:
            for sequence, stop in enumerate(route.stops, start=1):
                db.execute(
                    """
                    INSERT INTO dbo.shipment_route_stops
                        (shipment_id, stop_sequence, location, stage_location,
                         latitude, longitude, route_source)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        shipment_id,
                        sequence,
                        stop.name,
                        stop.stage_label[:120],
                        stop.latitude,
                        stop.longitude,
                        route.source,
                    ),
                )
        except DatabaseUnavailable as exc:
            log.warning(
                "created %s without persisted route stops: %s",
                tracking,
                exc,
            )
        try:
            db.query_one("EXEC dbo.usp_assign_golden_if_none %s", (shipment_id,))
        except DatabaseUnavailable as exc:
            log.warning("created %s without spotlight assignment: %s", tracking, exc)
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    if created is None:
        raise HTTPException(status_code=500, detail="Shipment vanished immediately after creation")
    log.info(
        "created %s for %s via %s",
        tracking,
        payload.created_by,
        " -> ".join(stop.name for stop in route.stops) or "direct route",
    )
    return Shipment(**_decorate(created))


_SHIPMENT_SQL = """
SELECT s.tracking_number, c.code AS carrier_code, c.name AS carrier_name,
       s.origin, s.destination, s.description, s.weight_kg, s.status,
       s.created_by, s.created_at, s.updated_at
  FROM dbo.shipments s
  JOIN dbo.carriers  c ON c.carrier_id = s.carrier_id
 WHERE s.tracking_number = %s
"""


def _route_points(db: Database, tracking: str) -> list[RoutePoint]:
    rows = db.query(
        """
        SELECT point_sequence, point_kind, location, latitude, longitude
          FROM (
                SELECT 0 AS point_sequence, 'origin' AS point_kind,
                       s.origin AS location, s.origin_latitude AS latitude,
                       s.origin_longitude AS longitude
                  FROM dbo.shipments AS s
                 WHERE s.tracking_number = %s
                UNION ALL
                SELECT r.stop_sequence, 'hub', r.location, r.latitude, r.longitude
                  FROM dbo.shipment_route_stops AS r
                  JOIN dbo.shipments AS s ON s.shipment_id = r.shipment_id
                 WHERE s.tracking_number = %s
                UNION ALL
                SELECT 3, 'destination', s.destination,
                       s.destination_latitude, s.destination_longitude
                  FROM dbo.shipments AS s
                 WHERE s.tracking_number = %s
               ) AS points
         WHERE latitude IS NOT NULL AND longitude IS NOT NULL
         ORDER BY point_sequence
        """,
        (tracking, tracking, tracking),
    )
    return [
        RoutePoint(
            sequence=row["point_sequence"],
            kind=row["point_kind"],
            location=row["location"],
            latitude=float(row["latitude"]),
            longitude=float(row["longitude"]),
        )
        for row in rows
    ]


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
        route_points = _route_points(db, tracking)
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    detail = _decorate(row)
    detail["scans"] = [ScanEvent(**scan) for scan in scans]
    detail["history"] = [StatusChange(**change) for change in history]
    detail["route_points"] = route_points
    return ShipmentDetail(**detail)


@app.get("/api/presentation", tags=["shipments"])
def presentation_data(
    limit: int = 30,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    """Recent geocoded routes plus the stable shipment used as the demo thread."""
    limit = min(max(limit, 1), 60)
    try:
        rows = db.query(
            """
            WITH recent AS (
                SELECT TOP (%d)
                       shipment_id, tracking_number,
                       CASE WHEN is_golden = 1 THEN origin
                            ELSE COALESCE(stage_origin, N'Custom origin') END AS origin,
                       CASE WHEN is_golden = 1 THEN destination
                            ELSE COALESCE(stage_destination, N'Custom destination') END AS destination,
                       status,
                       created_at, updated_at, is_golden,
                       demo_hold_status,
                       origin_latitude, origin_longitude,
                       destination_latitude, destination_longitude
                  FROM dbo.shipments
                 WHERE origin_latitude IS NOT NULL
                   AND destination_latitude IS NOT NULL
                 ORDER BY created_at DESC, shipment_id DESC
            ),
            selected AS (
                SELECT * FROM recent
                UNION
                SELECT shipment_id, tracking_number,
                       CASE WHEN is_golden = 1 THEN origin
                            ELSE COALESCE(stage_origin, N'Custom origin') END AS origin,
                       CASE WHEN is_golden = 1 THEN destination
                            ELSE COALESCE(stage_destination, N'Custom destination') END AS destination,
                       status,
                       created_at, updated_at, is_golden,
                       demo_hold_status,
                       origin_latitude, origin_longitude,
                       destination_latitude, destination_longitude
                  FROM dbo.shipments
                 WHERE is_golden = 1
                   AND origin_latitude IS NOT NULL
                   AND destination_latitude IS NOT NULL
            )
            SELECT selected.*, r.stop_sequence,
                   CASE WHEN selected.is_golden = 1 THEN r.location
                        ELSE COALESCE(r.stage_location, N'Route stop') END AS stop_location,
                   r.latitude AS stop_latitude, r.longitude AS stop_longitude
              FROM selected
              LEFT JOIN dbo.shipment_route_stops AS r
                ON r.shipment_id = selected.shipment_id
             ORDER BY selected.created_at DESC, selected.shipment_id DESC,
                      r.stop_sequence
            """ % limit
        )
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    shipments: list[dict[str, Any]] = []
    by_id: dict[int, dict[str, Any]] = {}
    for row in rows:
        shipment_id = row["shipment_id"]
        shipment = by_id.get(shipment_id)
        if shipment is None:
            shipment = {
                "tracking_number": row["tracking_number"],
                "origin": row["origin"],
                "destination": row["destination"],
                "status": row["status"],
                "status_narrative": pipeline.narrative_for(row["status"]),
                "progress_percent": pipeline.progress_percent(row["status"]),
                "created_by": "Audience",
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "is_golden": bool(row["is_golden"]),
                "hold_status": row["demo_hold_status"],
                "is_held": row["demo_hold_status"] == row["status"],
                "_destination_latitude": float(row["destination_latitude"]),
                "_destination_longitude": float(row["destination_longitude"]),
                "route_points": [
                    {
                        "sequence": 0,
                        "kind": "origin",
                        "location": row["origin"],
                        "latitude": float(row["origin_latitude"]),
                        "longitude": float(row["origin_longitude"]),
                    }
                ],
            }
            by_id[shipment_id] = shipment
            shipments.append(shipment)

        if row["stop_sequence"] is not None:
            shipment["route_points"].append(
                {
                    "sequence": row["stop_sequence"],
                    "kind": "hub",
                    "location": row["stop_location"],
                    "latitude": float(row["stop_latitude"]),
                    "longitude": float(row["stop_longitude"]),
                }
            )

    for shipment in shipments:
        shipment["route_points"].append(
            {
                "sequence": 3,
                "kind": "destination",
                "location": shipment["destination"],
                "latitude": shipment.pop("_destination_latitude"),
                "longitude": shipment.pop("_destination_longitude"),
            }
        )
        shipment["route_points"].sort(key=lambda point: point["sequence"])

    golden = next((shipment for shipment in shipments if shipment["is_golden"]), None)
    return {"golden": golden, "shipments": shipments}


FAILURE_CHOICES = (
    ("freeze_azurelinux", "Freeze the Azure Linux worker"),
    ("degrade_worker_sql", "Degrade worker-to-SQL networking"),
    ("delay_worker_claims", "Delay worker queue claims"),
)


def _failure_poll(db: Database, poll_id: int | None = None) -> dict[str, Any]:
    where = "WHERE p.poll_id = %s" if poll_id is not None else "WHERE p.state <> 'closed'"
    params = (poll_id,) if poll_id is not None else ()
    row = db.query_one(
        f"""
        SELECT TOP (1) p.poll_id, p.state, p.winner_code, p.opened_at,
               p.locked_at, p.injected_at, p.recovered_at, p.closed_at
          FROM dbo.failure_polls p
          {where}
         ORDER BY p.poll_id DESC
        """,
        params,
    )
    if row is None:
        return {
            "poll_id": None,
            "state": "closed",
            "winner_code": None,
            "total_votes": 0,
            "choices": [
                {"code": code, "label": label, "votes": 0}
                for code, label in FAILURE_CHOICES
            ],
        }

    counts = {
        item["choice_code"]: item["vote_count"]
        for item in db.query(
            """
            SELECT choice_code, COUNT(*) AS vote_count
              FROM dbo.failure_votes
             WHERE poll_id = %s
             GROUP BY choice_code
            """,
            (row["poll_id"],),
        )
    }
    choices = [
        {"code": code, "label": label, "votes": counts.get(code, 0)}
        for code, label in FAILURE_CHOICES
    ]
    row["choices"] = choices
    row["total_votes"] = sum(choice["votes"] for choice in choices)
    return row


def _public_failure_poll(poll: dict[str, Any]) -> dict[str, Any]:
    if poll["state"] != "open":
        return poll
    public = dict(poll)
    public["winner_code"] = None
    public["choices"] = [
        {"code": choice["code"], "label": choice["label"]}
        for choice in poll["choices"]
    ]
    return public


@app.get("/api/poll", tags=["audience"])
def current_failure_poll(db: Database = Depends(require_db)) -> dict[str, Any]:
    try:
        return _public_failure_poll(_failure_poll(db))
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


@app.post("/api/poll/vote", tags=["audience"])
def cast_failure_vote(
    vote: FailureVote,
    request: Request,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    allowed, _ = vote_limiter.check(f"browser:{vote.voter_token}")
    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Voting is at capacity. Try again shortly.",
        )
    try:
        result = db.query_one(
            "EXEC dbo.usp_cast_failure_vote %s, %s, %s",
            (vote.poll_id, vote.voter_token, vote.choice_code),
        )
        if not result or not result["accepted"]:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Voting is not open for this poll",
            )
        return _public_failure_poll(_failure_poll(db, vote.poll_id))
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


@app.post("/api/presenter/polls", tags=["presenter"])
def open_failure_poll(
    request: Request,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    require_presenter(request)
    try:
        result = db.query_one("EXEC dbo.usp_open_failure_poll")
        if not result or not result["opened"]:
            raise HTTPException(status_code=409, detail="Repair or resolve the active fault before opening another poll")
        return _failure_poll(db, result["poll_id"])
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


@app.get("/api/presenter/polls/{poll_id}", tags=["presenter"])
def presenter_failure_poll(
    poll_id: int,
    request: Request,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    require_presenter(request)
    try:
        poll = _failure_poll(db, poll_id)
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc
    if poll["poll_id"] is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Poll not found")
    return poll


@app.post("/api/presenter/polls/{poll_id}/lock", tags=["presenter"])
def lock_failure_poll(
    poll_id: int,
    request: Request,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    require_presenter(request)
    try:
        result = db.query_one("EXEC dbo.usp_lock_failure_poll %s", (poll_id,))
        if not result or not result["locked"]:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Poll is not open",
            )
        return _failure_poll(db, poll_id)
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


@app.post("/api/presenter/polls/{poll_id}/state", tags=["presenter"])
def set_failure_poll_state(
    poll_id: int,
    change: FailurePollState,
    request: Request,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    require_presenter(request)
    try:
        result = db.query_one(
            "EXEC dbo.usp_set_failure_poll_state %s, %s",
            (poll_id, change.state),
        )
        if not result or not result["updated"]:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Invalid poll state transition",
            )
        return _failure_poll(db, poll_id)
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


def _injection_status(db: Database, poll_id: int) -> dict[str, Any]:
    runner = db.query_one("""
        SELECT CAST(CASE WHEN EXISTS (
            SELECT 1 FROM dbo.failure_runners
            WHERE last_seen > DATEADD(second, -15, SYSUTCDATETIME())
        ) THEN 1 ELSE 0 END AS BIT) AS online
    """)
    job = db.query_one(
        """
        SELECT j.state, CAST(CASE WHEN EXISTS (
            SELECT 1 FROM dbo.failure_runners r
            WHERE r.runner_id = j.runner_id
              AND r.last_seen > DATEADD(second, -15, SYSUTCDATETIME())
        ) THEN 1 ELSE 0 END AS BIT) AS runner_online
        FROM dbo.failure_injection_jobs j WHERE j.poll_id = %s
        """, (poll_id,)
    )
    online = job["runner_online"] if job and job["state"] == "running" else runner["online"]
    return {"runner_online": bool(online), "state": job["state"] if job else None}


@app.get("/api/presenter/polls/{poll_id}/injection", tags=["presenter"])
def failure_injection_status(
    poll_id: int, request: Request, db: Database = Depends(require_db),
) -> dict[str, Any]:
    require_presenter(request)
    try:
        return _injection_status(db, poll_id)
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


@app.post("/api/presenter/polls/{poll_id}/inject", tags=["presenter"])
def request_failure_injection(
    poll_id: int, request: Request, db: Database = Depends(require_db),
) -> dict[str, Any]:
    require_presenter(request)
    try:
        result = db.query_one("EXEC dbo.usp_request_failure_injection %s", (poll_id,))
        reason = result["reason"]
        if reason not in ("queued", "already_requested"):
            raise HTTPException(
                status_code=503 if reason == "runner_offline" else 409,
                detail={
                    "runner_offline": "Private runner is offline. No fault was requested.",
                    "poll_not_locked": "Only the latest locked poll can request its winning fault.",
                    "fault_unresolved": "Repair or resolve the existing fault first.",
                }[reason],
            )
        return _injection_status(db, poll_id)
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


@app.post("/api/presenter/runner/claim", tags=["presenter"])
def claim_failure_injection(
    runner: FailureRunner, request: Request, db: Database = Depends(require_db),
) -> dict[str, Any]:
    require_presenter(request)
    try:
        return db.query_one("EXEC dbo.usp_claim_failure_injection %s", (str(runner.runner_id),))
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


@app.post("/api/presenter/polls/{poll_id}/injection/result", tags=["presenter"])
def finish_failure_injection(
    poll_id: int, result: FailureInjectionResult, request: Request,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    require_presenter(request)
    try:
        updated = db.query_one(
            "EXEC dbo.usp_finish_failure_injection %s, %s, %s",
            (poll_id, str(result.runner_id), result.succeeded),
        )
        if not updated or not updated["updated"]:
            raise HTTPException(status_code=409, detail="This runner does not own an active injection")
        return _injection_status(db, poll_id)
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc


@app.post("/api/presentation/golden/release", tags=["shipments"])
def release_golden_shipment(
    request: Request,
    db: Database = Depends(require_db),
) -> dict[str, Any]:
    """Release the held continuity shipment after the Azure endpoint returns."""
    if not trusted_load_generator(request) and not trusted_presenter(request):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Presenter key required")
    try:
        db.execute("EXEC dbo.usp_release_golden_shipment")
        row = db.query_one(
            "SELECT tracking_number, status FROM dbo.shipments WHERE is_golden = 1"
        )
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc
    return {
        "released": True,
        "tracking_number": row["tracking_number"] if row else None,
        "status": row["status"] if row else None,
    }


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
    if not trusted_load_generator(request):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Load generator key required",
        )

    try:
        row = db.query_one(
            """
            SELECT shipment_id, status, demo_hold_status
              FROM dbo.shipments
             WHERE tracking_number = %s
            """,
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
        if row["demo_hold_status"] == row["status"]:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This presentation shipment is held until migration completes",
            )
        db.execute(
            "INSERT INTO dbo.scan_queue (shipment_id, requested_by) VALUES (%s, %s)",
            (row["shipment_id"], "load-generator"),
        )
    except DatabaseUnavailable as exc:
        raise _db_error(exc) from exc

    return {
        "tracking_number": tracking,
        "queued": True,
        "status": row["status"],
        "next_status": pipeline.next_status(row["status"]),
    }
