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

booger = plan_route("Seattle, WA", "Booger, AR", azure_maps_key="configured")
assert booger.destination is not None
assert booger.destination.name == "Booger Hollow, AR"
assert booger.destination.stage_label == "Booger Hollow, AR"
assert booger.destination.source == "known-location"
assert [stop.name for stop in booger.stops] == ["Denver, CO", "Dallas, TX"]

ignite_booger = names("San Francisco, CA", "Booger, Arkansas")
assert ignite_booger == ["Los Angeles, CA", "Dallas, TX"], ignite_booger

seattle_paris = names("Seattle, WA", "Paris, France")
assert seattle_paris
assert seattle_paris[-1] in {"London, UK", "Amsterdam, Netherlands"}, seattle_paris

springfield = plan_route("Springfield, Illinois", "Seattle, Washington")
assert springfield.source == "offline-geonames"
assert springfield.origin is not None
assert springfield.origin.stage_label == "Springfield, IL"

generic_space = plan_route("Seattle, WA", "Kepler-999z")
assert generic_space.destination is not None
assert generic_space.destination.name.startswith("Kepler-999z ")
assert generic_space.destination.stage_label == "Interstellar Freight Anchorage"

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
assert antarctica.destination.name == "Palmer Station, Antarctica"
assert antarctica.destination.source == "special-logistics-destination"
assert [stop.name for stop in antarctica.stops] == [
    "Santiago, Chile",
    "Punta Arenas Maritime Terminal, Chile",
]
assert antarctica.source == "special-logistics-route"

country = plan_route("Seattle, WA", "France")
assert country.destination is not None
assert country.destination.name == "Paris, France"
assert country.destination.source == "offline-country-gateway"

jupiter_neptune = plan_route("Jupiter", "Neptune")
assert jupiter_neptune.origin is not None
assert jupiter_neptune.origin.name == "Europa Orbital Logistics Hub, Jupiter System"
assert jupiter_neptune.destination is not None
assert jupiter_neptune.destination.name == "Triton Orbital Receiving, Neptune System"
assert [stop.name for stop in jupiter_neptune.stops] == [
    "Callisto Deep-Space Freight Terminal, Jupiter System",
    "Saturn Gravity-Assist Relay",
]
assert jupiter_neptune.source == "deep-space-route"

interstellar = plan_route("Seattle, WA", "Kepler-186f")
assert interstellar.destination is not None
assert interstellar.destination.name == "Kepler-186f Interstellar Freight Anchorage"
assert [stop.name for stop in interstellar.stops] == [
    "Brooklyn Intergalactic Dispatch Center",
    "Lunar Gateway Cargo Relay",
]
assert interstellar.source == "deep-space-route"

galaxy = plan_route("Andromeda Galaxy", "Earth")
assert galaxy.origin is not None
assert galaxy.origin.name == "Andromeda Galaxy Deep-Space Receiving Array"
assert galaxy.destination is not None
assert galaxy.destination.name == "Low Earth Orbit Cargo Gateway"
assert galaxy.source == "deep-space-route"

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
