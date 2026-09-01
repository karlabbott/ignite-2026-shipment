#!/usr/bin/env python3
"""Controlled traffic generator for the Zava Logistics scale-out demonstration.

The default rate deliberately sits between the approximate capacity of one
worker and two workers. One worker builds a visible queue; adding the Azure
Linux worker increases throughput enough to drain it while traffic continues.

    ./tools/loadgen.py --web http://192.168.90.13 --rate 32

It talks to the web tier rather than the API tier on purpose: it exercises the
same nginx, web, API, routing, database, and queue path as an attendee shipment.
The private load-generator key bypasses only the audience creation rate limit.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import sys
import time
import urllib.error
import urllib.request
from typing import Any

CITIES = [
    "Seattle, WA", "Vancouver, Canada", "Mexico City, Mexico",
    "New York, NY", "Toronto, Canada", "Montreal, Canada", "Miami, FL",
    "Sao Paulo, Brazil", "Buenos Aires, Argentina", "Santiago, Chile",
    "Lima, Peru", "Bogota, Colombia",
    "London, UK", "Paris, France", "Madrid, Spain", "Dublin, Ireland",
    "Amsterdam, Netherlands", "Frankfurt, Germany", "Rome, Italy",
    "Warsaw, Poland", "Stockholm, Sweden",
    "Johannesburg, South Africa", "Cape Town, South Africa", "Nairobi, Kenya",
    "Lagos, Nigeria", "Cairo, Egypt", "Casablanca, Morocco",
    "Dubai, UAE", "Mumbai, India", "Delhi, India", "Bangkok, Thailand",
    "Singapore", "Hong Kong", "Seoul, South Korea", "Tokyo, Japan",
    "Osaka, Japan", "Sydney, Australia", "Melbourne, Australia",
    "Auckland, New Zealand",
]

GOODS = [
    "Store replenishment inventory", "Point-of-sale terminals",
    "Handheld inventory scanners", "Digital signage displays",
    "Seasonal campaign kits", "Store fixtures and shelving",
    "E-commerce pickup supplies", "Customer returns", "Employee devices",
]

SHIPPERS = [
    "store-0042", "store-0118", "store-0247", "store-0315", "store-0440",
    "distribution-west", "distribution-central", "distribution-east",
    "commerce-returns", "store-openings",
]

running = True


def _stop(_signum: int, _frame: Any) -> None:
    global running
    running = False
    print("\nstopping...", file=sys.stderr)


def request(
    url: str,
    *,
    method: str = "GET",
    body: dict | None = None,
    key: str = "",
    timeout: float = 8.0,
) -> tuple[int, Any]:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"user-agent": "zava-logistics-loadgen/1.0"}
    if data:
        headers["content-type"] = "application/json"
    if key:
        headers["x-zava-loadgen-key"] = key
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode())
        except Exception:
            return exc.code, None
    except Exception as exc:
        return 0, {"error": str(exc)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web", default="http://192.168.90.13",
                        help="base URL of the web tier")
    parser.add_argument("--failover-web", default="",
                        help="switch to this URL when the original estate is unavailable")
    parser.add_argument("--rate", type=float, default=32.0,
                        help="new shipments per minute (default: 32)")
    parser.add_argument("--advance", type=float, default=0.0,
                        help="probability of nudging an existing shipment each tick")
    parser.add_argument("--once", type=int, default=0,
                        help="create exactly N shipments and exit")
    parser.add_argument("--duration", type=float, default=0,
                        help="stop after this many seconds; zero runs until stopped")
    parser.add_argument("--stats-every", type=float, default=10,
                        help="print queue and throughput every N seconds")
    parser.add_argument("--key", default=os.environ.get("SHIPMENT_LOADGEN_KEY", ""),
                        help="private load key; defaults to SHIPMENT_LOADGEN_KEY")
    args = parser.parse_args()

    base = args.web.rstrip("/")
    failover_base = args.failover_web.rstrip("/")
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    interval = 60.0 / max(args.rate, 0.1)
    created = 0
    started = time.monotonic()
    next_stats = started
    print(f"load generator -> {base} (~{args.rate}/min, ctrl-c to stop)", file=sys.stderr)

    while running:
        if args.duration and time.monotonic() - started >= args.duration:
            break
        origin, destination = random.sample(CITIES, 2)
        payload = {
            "origin": origin,
            "destination": destination,
            "description": random.choice(GOODS),
            "weight_kg": round(random.uniform(0.5, 180.0), 2),
            "created_by": random.choice(SHIPPERS),
        }
        code, body = request(
            f"{base}/api/shipments", method="POST", body=payload, key=args.key
        )
        if code == 201 and body:
            created += 1
            print(f"created {body['tracking_number']}  {origin} -> {destination}")
        elif code == 429:
            # Expected once the room gets busy; back off rather than hammering.
            print("rate limited, backing off", file=sys.stderr)
            time.sleep(interval * 2)
        else:
            print(f"create failed ({code}): {body}", file=sys.stderr)
            if code in (0, 502, 503, 504) and failover_base and base != failover_base:
                probe_code, _ = request(f"{failover_base}/api/stats", key=args.key)
                if probe_code == 200:
                    base = failover_base
                    print(f"service restored -> {base}", file=sys.stderr)
                    release_code, release = request(
                        f"{base}/api/presentation/golden/release",
                        method="POST",
                        key=args.key,
                    )
                    if release_code == 200:
                        print(
                            f"released golden shipment {release.get('tracking_number')}",
                            file=sys.stderr,
                        )
                    else:
                        print(
                            f"golden release failed ({release_code}): {release}",
                            file=sys.stderr,
                        )
            time.sleep(min(interval, 5))

        if args.once and created >= args.once:
            break

        # Nudge a random in-flight shipment so the board keeps moving even when
        # the drift loop on the worker is disabled.
        if random.random() < args.advance:
            code, board = request(f"{base}/api/board?limit=40", key=args.key)
            if code == 200 and isinstance(board, list):
                candidates = [r for r in board if r.get("status") != "DELIVERED"]
                if candidates:
                    target = random.choice(candidates)["tracking_number"]
                    request(
                        f"{base}/api/shipments/{target}/advance",
                        method="POST",
                        key=args.key,
                    )

        if time.monotonic() >= next_stats:
            code, stats = request(f"{base}/api/stats", key=args.key)
            if code == 200:
                print(
                    f"queue={stats['queue_depth']}  "
                    f"scans/5m={stats['scans_last_5m']}  "
                    f"in-flight={stats['in_flight']}",
                    file=sys.stderr,
                )
            next_stats = time.monotonic() + max(args.stats_every, 1)

        slept = 0.0
        step = 0.25
        target_sleep = random.uniform(interval * 0.5, interval * 1.5)
        while running and slept < target_sleep:
            time.sleep(step)
            slept += step

    print(f"created {created} shipment(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
