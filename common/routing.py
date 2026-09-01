"""Geographically plausible shipment routing.

Azure Maps is the preferred geocoder. A bundled GeoNames city index is the
demo-safe fallback, so creating and moving shipments never depends on an
external service being available after the route is planned.
"""

from __future__ import annotations

import json
import http.client
import logging
import math
import re
import urllib.parse
import urllib.request
from dataclasses import dataclass
from functools import lru_cache
from itertools import permutations
from typing import Any

import geonamescache

log = logging.getLogger("shipment.routing")


@dataclass(frozen=True)
class Location:
    name: str
    latitude: float
    longitude: float
    source: str


@dataclass(frozen=True)
class RoutePlan:
    origin: Location | None
    destination: Location | None
    stops: tuple[Location, ...]
    source: str


HUBS: tuple[Location, ...] = tuple(
    Location(name, latitude, longitude, "hub-network")
    for name, latitude, longitude in (
        ("Seattle, WA", 47.6062, -122.3321),
        ("Portland, OR", 45.5152, -122.6784),
        ("Los Angeles, CA", 34.0522, -118.2437),
        ("Denver, CO", 39.7392, -104.9903),
        ("Dallas, TX", 32.7767, -96.7970),
        ("Chicago, IL", 41.8781, -87.6298),
        ("Memphis, TN", 35.1495, -90.0490),
        ("Atlanta, GA", 33.7490, -84.3880),
        ("New York, NY", 40.7128, -74.0060),
        ("Miami, FL", 25.7617, -80.1918),
        ("Toronto, Canada", 43.6532, -79.3832),
        ("Mexico City, Mexico", 19.4326, -99.1332),
        ("Bogota, Colombia", 4.7110, -74.0721),
        ("Lima, Peru", -12.0464, -77.0428),
        ("Sao Paulo, Brazil", -23.5505, -46.6333),
        ("Buenos Aires, Argentina", -34.6037, -58.3816),
        ("Santiago, Chile", -33.4489, -70.6693),
        ("London, UK", 51.5074, -0.1278),
        ("Amsterdam, Netherlands", 52.3676, 4.9041),
        ("Paris, France", 48.8566, 2.3522),
        ("Frankfurt, Germany", 50.1109, 8.6821),
        ("Madrid, Spain", 40.4168, -3.7038),
        ("Milan, Italy", 45.4642, 9.1900),
        ("Warsaw, Poland", 52.2297, 21.0122),
        ("Istanbul, Turkiye", 41.0082, 28.9784),
        ("Cairo, Egypt", 30.0444, 31.2357),
        ("Lagos, Nigeria", 6.5244, 3.3792),
        ("Nairobi, Kenya", -1.2921, 36.8219),
        ("Johannesburg, South Africa", -26.2041, 28.0473),
        ("Dubai, UAE", 25.2048, 55.2708),
        ("Mumbai, India", 19.0760, 72.8777),
        ("Delhi, India", 28.6139, 77.2090),
        ("Singapore", 1.3521, 103.8198),
        ("Hong Kong", 22.3193, 114.1694),
        ("Shanghai, China", 31.2304, 121.4737),
        ("Seoul, South Korea", 37.5665, 126.9780),
        ("Tokyo, Japan", 35.6762, 139.6503),
        ("Sydney, Australia", -33.8688, 151.2093),
        ("Melbourne, Australia", -37.8136, 144.9631),
        ("Auckland, New Zealand", -36.8509, 174.7645),
    )
)


def _normalise(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


@lru_cache(maxsize=1)
def _city_index() -> dict[str, list[dict[str, Any]]]:
    index: dict[str, list[dict[str, Any]]] = {}
    for city in geonamescache.GeonamesCache().get_cities().values():
        names = {city["name"], *(city.get("alternatenames") or [])}
        for name in names:
            key = _normalise(name)
            if key:
                index.setdefault(key, []).append(city)
    return index


@lru_cache(maxsize=1)
def _qualifier_codes() -> tuple[dict[str, str], dict[str, str]]:
    cache = geonamescache.GeonamesCache()
    states: dict[str, str] = {}
    for code, state in cache.get_us_states().items():
        states[_normalise(code)] = code
        states[_normalise(state["name"])] = code

    countries: dict[str, str] = {}
    for code, country in cache.get_countries().items():
        countries[_normalise(code)] = code
        countries[_normalise(country["name"])] = code
        countries[_normalise(country["iso3"])] = code
    return states, countries


def warm_offline_index() -> None:
    """Load the fallback data before audience requests arrive."""
    _city_index()
    _qualifier_codes()


@lru_cache(maxsize=2048)
def _offline_geocode(query: str) -> Location | None:
    parts = [part.strip() for part in query.split(",") if part.strip()]
    if not parts:
        return None

    candidates = _city_index().get(_normalise(parts[0]), [])
    if not candidates:
        candidates = _city_index().get(_normalise(query), [])
    if not candidates:
        return None

    qualifiers = {_normalise(part) for part in parts[1:]}
    states, countries = _qualifier_codes()
    state_codes = {states[value] for value in qualifiers if value in states}
    country_codes = {countries[value] for value in qualifiers if value in countries}

    def score(city: dict[str, Any]) -> tuple[int, int]:
        matches = 0
        if city.get("admin1code") in state_codes:
            matches += 2
        if city.get("countrycode") in country_codes:
            matches += 2
        return matches, int(city.get("population") or 0)

    city = max(candidates, key=score)
    return Location(
        name=query,
        latitude=float(city["latitude"]),
        longitude=float(city["longitude"]),
        source="offline-geonames",
    )


@lru_cache(maxsize=2048)
def _azure_maps_geocode(query: str, key: str, timeout_seconds: float) -> Location | None:
    params = urllib.parse.urlencode(
        {
            "api-version": "1.0",
            "query": query,
            "limit": 1,
            "entityType": "Municipality",
            "subscription-key": key,
        }
    )
    request = urllib.request.Request(
        f"https://atlas.microsoft.com/search/address/json?{params}",
        headers={"User-Agent": "zava-logistics-routing/1.0"},
    )
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        payload = json.load(response)

    results = payload.get("results") or []
    if not results:
        return None
    position = results[0].get("position") or {}
    if "lat" not in position or "lon" not in position:
        return None
    return Location(
        name=query,
        latitude=float(position["lat"]),
        longitude=float(position["lon"]),
        source="azure-maps",
    )


def _resolve(query: str, azure_maps_key: str, timeout_seconds: float) -> Location | None:
    if azure_maps_key:
        try:
            resolved = _azure_maps_geocode(query, azure_maps_key, timeout_seconds)
            if resolved is not None:
                return resolved
            log.warning("Azure Maps returned no location for %r; using offline routing", query)
        except (
            OSError,
            TimeoutError,
            ValueError,
            TypeError,
            AttributeError,
            IndexError,
            KeyError,
            http.client.HTTPException,
        ) as exc:
            log.warning("Azure Maps geocoding failed for %r: %s; using offline routing", query, exc)
    return _offline_geocode(query)


def _distance(left: Location, right: Location) -> float:
    """Great-circle distance in kilometres."""
    lat1, lon1 = math.radians(left.latitude), math.radians(left.longitude)
    lat2, lon2 = math.radians(right.latitude), math.radians(right.longitude)
    delta_lat = lat2 - lat1
    delta_lon = lon2 - lon1
    a = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
    )
    return 6371.0 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _select_hubs(origin: Location, destination: Location) -> tuple[Location, ...]:
    direct = _distance(origin, destination)
    if direct < 80:
        return ()

    candidates = [
        hub
        for hub in HUBS
        if _distance(origin, hub) > 80 and _distance(destination, hub) > 80
    ]

    pair_choices: list[tuple[float, tuple[Location, Location]]] = []
    if direct >= 600:
        for first, second in permutations(candidates, 2):
            first_leg = _distance(origin, first)
            first_remaining = _distance(first, destination)
            second_remaining = _distance(second, destination)
            if first_leg > direct * 0.75 + 200:
                continue
            if first_remaining >= direct * 0.94 or second_remaining >= first_remaining * 0.94:
                continue
            route_distance = (
                first_leg
                + _distance(first, second)
                + second_remaining
            )
            if route_distance > direct * 1.55 + 250:
                continue
            pair_choices.append((route_distance, (first, second)))
    if pair_choices:
        return min(pair_choices, key=lambda choice: choice[0])[1]

    single_choices: list[tuple[float, Location]] = []
    for hub in candidates:
        route_distance = _distance(origin, hub) + _distance(hub, destination)
        if route_distance <= direct * 1.7 + 150:
            single_choices.append((route_distance, hub))
    if single_choices:
        return (min(single_choices, key=lambda choice: choice[0])[1],)
    return ()


def plan_route(
    origin_name: str,
    destination_name: str,
    *,
    azure_maps_key: str = "",
    timeout_seconds: float = 2.0,
) -> RoutePlan:
    """Return up to two plausible logistics hubs between the endpoints."""
    origin = _resolve(origin_name, azure_maps_key, timeout_seconds)
    destination = _resolve(destination_name, azure_maps_key, timeout_seconds)
    if origin is None or destination is None:
        return RoutePlan(
            origin=origin,
            destination=destination,
            stops=(),
            source="legacy-fallback",
        )

    sources = {origin.source, destination.source}
    source = sources.pop() if len(sources) == 1 else "hybrid"
    hubs = _select_hubs(origin, destination)
    if not hubs:
        hubs = (
            Location(
                f"{origin_name} Sort Center",
                origin.latitude,
                origin.longitude,
                "synthetic-terminal",
            ),
            Location(
                f"{destination_name} Distribution Center",
                destination.latitude,
                destination.longitude,
                "synthetic-terminal",
            ),
        )
    elif len(hubs) == 1:
        hubs = (
            hubs[0],
            Location(
                f"{destination_name} Distribution Center",
                destination.latitude,
                destination.longitude,
                "synthetic-terminal",
            ),
        )
    return RoutePlan(
        origin=origin,
        destination=destination,
        stops=hubs,
        source=source,
    )
