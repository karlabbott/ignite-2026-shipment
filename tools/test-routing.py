"""Focused checks for deterministic geographic route planning."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import common.routing as routing
from common.routing import plan_route


def names(origin: str, destination: str) -> list[str]:
    return [stop.name for stop in plan_route(origin, destination).stops]


seattle_vicksburg = names("Seattle, WA", "Vicksburg, MS")
assert seattle_vicksburg == ["Denver, CO", "Dallas, TX"], seattle_vicksburg

seattle_paris = names("Seattle, WA", "Paris, France")
assert seattle_paris
assert seattle_paris[-1] in {"London, UK", "Amsterdam, Netherlands"}, seattle_paris

springfield = plan_route("Springfield, Illinois", "Seattle, Washington")
assert springfield.source == "offline-geonames"

unknown = plan_route("Somewhere beyond the map", "Another imaginary place")
assert unknown.stops == ()
assert unknown.source == "legacy-fallback"
assert unknown.origin is None
assert unknown.destination is None

local = plan_route("Seattle, WA", "Tacoma, WA")
assert [stop.name for stop in local.stops] == [
    "Seattle, WA Sort Center",
    "Tacoma, WA Distribution Center",
]
assert local.origin is not None
assert local.destination is not None

antarctica = plan_route("Seattle, WA", "Antartica")
assert antarctica.destination is not None
assert antarctica.destination.name == "Ushuaia, Argentina"
assert antarctica.destination.source == "offline-country-gateway"
assert antarctica.stops

country = plan_route("Seattle, WA", "France")
assert country.destination is not None
assert country.destination.name == "Paris, France"
assert country.destination.source == "offline-country-gateway"

online_geocoder = routing._azure_maps_geocode
try:
    routing._azure_maps_geocode = lambda *_args, **_kwargs: (_ for _ in ()).throw(
        OSError("simulated outage")
    )
    failed_online = plan_route(
        "Seattle, WA",
        "Vicksburg, MS",
        azure_maps_key="configured-but-unavailable",
    )
    assert [stop.name for stop in failed_online.stops] == ["Denver, CO", "Dallas, TX"]
    assert failed_online.source == "offline-geonames"

    routing._azure_maps_geocode = lambda *_args, **_kwargs: (_ for _ in ()).throw(
        TypeError("simulated malformed response")
    )
    malformed_online = plan_route(
        "Seattle, WA",
        "Vicksburg, MS",
        azure_maps_key="configured-but-malformed",
    )
    assert [stop.name for stop in malformed_online.stops] == ["Denver, CO", "Dallas, TX"]
finally:
    routing._azure_maps_geocode = online_geocoder

print("All geographic routing checks passed.")
