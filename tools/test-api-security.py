"""Focused regression checks for public API abuse and projection controls."""

from __future__ import annotations

import sys
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from fastapi import HTTPException
from starlette.requests import Request

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from api.app import main
from api.app.models import ShipmentCreate
from common.routing import Location, RoutePlan


def request(
    *,
    address: str = "203.0.113.10",
    token: str = "",
    loadgen_key: str = "",
) -> Request:
    headers = []
    if token:
        headers.append((b"x-zava-client-token", token.encode()))
    if loadgen_key:
        headers.append((b"x-zava-loadgen-key", loadgen_key.encode()))
    return Request(
        {
            "type": "http",
            "http_version": "1.1",
            "method": "POST",
            "scheme": "https",
            "path": "/api/shipments",
            "raw_path": b"/api/shipments",
            "query_string": b"",
            "root_path": "",
            "headers": headers,
            "client": (address, 54321),
            "server": ("api", 8080),
        }
    )


def expect_http(status_code: int, action) -> HTTPException:
    try:
        action()
    except HTTPException as exc:
        assert exc.status_code == status_code, exc
        return exc
    raise AssertionError(f"Expected HTTP {status_code}")


original_ip_limiter = main.ip_limiter
original_client_limiter = main.client_limiter
main.ip_limiter = main.RateLimiter(3, 60, 100)
main.client_limiter = main.RateLimiter(1, 60)
try:
    for suffix in ("A", "B", "C"):
        main.enforce_shipment_create_limit(
            request(token=f"token-rotation-{suffix}0000")
        )
    expect_http(
        429,
        lambda: main.enforce_shipment_create_limit(
            request(token="token-rotation-D0000")
        ),
    )
finally:
    main.ip_limiter = original_ip_limiter
    main.client_limiter = original_client_limiter


class CreateDb:
    def __init__(self) -> None:
        self.shipment_insert: tuple[Any, ...] | None = None
        self.route_insert: tuple[Any, ...] | None = None

    def query(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        assert "SELECT carrier_id FROM dbo.carriers" in sql
        return [{"carrier_id": 7}]

    def query_one(
        self,
        sql: str,
        params: tuple[Any, ...] = (),
    ) -> dict[str, Any] | None:
        if "INSERT INTO dbo.shipments" in sql:
            self.shipment_insert = params
            return {"shipment_id": 42}
        if sql == main._SHIPMENT_SQL:
            assert self.shipment_insert is not None
            return {
                "tracking_number": params[0],
                "carrier_code": "ZL",
                "carrier_name": "Zava Logistics",
                "origin": self.shipment_insert[2],
                "destination": self.shipment_insert[3],
                "description": self.shipment_insert[6],
                "weight_kg": self.shipment_insert[7],
                "status": "CREATED",
                "created_by": self.shipment_insert[8],
                "created_at": datetime.now(UTC),
                "updated_at": datetime.now(UTC),
            }
        if "usp_assign_golden_if_none" in sql:
            return {"assigned": 0}
        raise AssertionError(sql)

    def execute(self, sql: str, params: tuple[Any, ...] = ()) -> None:
        if "INSERT INTO dbo.shipment_route_stops" in sql:
            self.route_insert = params


raw_origin = "Offensive origin text"
raw_destination = "Offensive destination text"
raw_description = "Offensive description text"
raw_handle = "Offensive handle"
safe_route = RoutePlan(
    origin=Location(raw_origin, 37.7749, -122.4194, "offline-geonames", "San Francisco, CA"),
    destination=Location(
        raw_destination,
        35.4751,
        -93.1857,
        "known-location",
        "Booger Hollow, AR",
    ),
    stops=(
        Location(
            f"{raw_destination} Distribution Center",
            35.4751,
            -93.1857,
            "synthetic-terminal",
            "Booger Hollow, AR Distribution Center",
        ),
    ),
    source="hybrid",
)
original_plan_route = main.plan_route
original_settings = main.settings
main.plan_route = lambda *_args, **_kwargs: safe_route
main.settings = replace(main.settings, loadgen_key="test-loadgen-key")
create_db = CreateDb()
try:
    created = main.create_shipment(
        ShipmentCreate(
            origin=raw_origin,
            destination=raw_destination,
            description=raw_description,
            created_by=raw_handle,
        ),
        request(loadgen_key="test-loadgen-key"),
        create_db,
    )
finally:
    main.plan_route = original_plan_route

assert created.origin == raw_origin
assert created.destination == raw_destination
assert created.description == raw_description
assert created.created_by == raw_handle
assert create_db.shipment_insert is not None
assert create_db.shipment_insert[4:6] == (
    "San Francisco, CA",
    "Booger Hollow, AR",
)
assert create_db.route_insert is not None
assert create_db.route_insert[2:4] == (
    f"{raw_destination} Distribution Center",
    "Booger Hollow, AR Distribution Center",
)


class ProjectionDb:
    def __init__(self) -> None:
        self.queries: list[str] = []

    def query(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        self.queries.append(sql)
        if "WITH recent AS" in sql:
            return [
                {
                    "shipment_id": 42,
                    "tracking_number": "ZAV12345678",
                    "origin": "San Francisco, CA",
                    "destination": "Booger Hollow, AR",
                    "status": "IN_TRANSIT",
                    "created_by": raw_handle,
                    "created_at": datetime.now(UTC),
                    "updated_at": datetime.now(UTC),
                    "is_golden": False,
                    "demo_hold_status": None,
                    "origin_latitude": 37.7749,
                    "origin_longitude": -122.4194,
                    "destination_latitude": 35.4751,
                    "destination_longitude": -93.1857,
                    "stop_sequence": 1,
                    "stop_location": "Denver, CO",
                    "stop_latitude": 39.7392,
                    "stop_longitude": -104.9903,
                }
            ]
        return [
            {
                "tracking_number": "ZAV12345678",
                "carrier_code": "ZL",
                "origin": "San Francisco, CA",
                "destination": "Booger Hollow, AR",
                "status": "IN_TRANSIT",
                "scan_count": 1,
                "last_location": "Denver, CO",
                "last_scanned_by": "worker-1",
                "created_by": "Audience",
                "updated_at": datetime.now(UTC),
            }
        ]


projection_db = ProjectionDb()
board = main.get_board(db=projection_db)
presentation = main.presentation_data(db=projection_db)
projected = f"{board!r} {presentation!r}"
for attendee_text in (
    raw_origin,
    raw_destination,
    raw_description,
    raw_handle,
):
    assert attendee_text not in projected
assert "COALESCE(s.stage_origin" in projection_db.queries[0]
assert "N'Audience' AS created_by" in projection_db.queries[0]
assert "COALESCE(stage_origin" in projection_db.queries[1]
assert "COALESCE(r.stage_location" in projection_db.queries[1]
assert "created_by" not in projection_db.queries[1]


class AdvanceDb:
    def __init__(self) -> None:
        self.queued = False

    def query_one(
        self,
        sql: str,
        params: tuple[Any, ...] = (),
    ) -> dict[str, Any]:
        return {
            "shipment_id": 42,
            "status": "CREATED",
            "demo_hold_status": None,
        }

    def execute(self, sql: str, params: tuple[Any, ...] = ()) -> None:
        assert params == (42, "load-generator")
        self.queued = True


advance_db = AdvanceDb()
expect_http(
    403,
    lambda: main.advance_shipment("ZAV12345678", request(), advance_db),
)
advanced = main.advance_shipment(
    "ZAV12345678",
    request(loadgen_key="test-loadgen-key"),
    advance_db,
)
assert advanced["queued"] is True
assert advance_db.queued

main.settings = original_settings
print("All API security checks passed.")
