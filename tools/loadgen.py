#!/usr/bin/env python3
"""Background load generator for the NinetyNine Freight board.

Creates shipments at a modest, human-plausible rate and advances existing ones,
so the dashboard looks like a working freight operation rather than a demo with
twelve rows in it. Run this from the presenter laptop during walk-in music.

    ./tools/loadgen.py --web http://192.168.90.13 --rate 6

It talks to the web tier rather than the API tier on purpose: it exercises the
exact same path an attendee's phone takes, including nginx and the rate limits.
"""

from __future__ import annotations

import argparse
import json
import random
import signal
import sys
import time
import urllib.error
import urllib.request
from typing import Any

CITIES = [
    "Seattle, WA", "Portland, OR", "Boise, ID", "Denver, CO", "Chicago, IL",
    "Austin, TX", "Atlanta, GA", "Boston, MA", "Phoenix, AZ", "Nashville, TN",
    "Miami, FL", "Raleigh, NC", "Minneapolis, MN", "Columbus, OH",
    "Salt Lake City, UT", "Kansas City, MO", "Detroit, MI", "Pittsburgh, PA",
]

GOODS = [
    "Server chassis, 2U", "Network switches (x4)", "Cold chain, pharma",
    "Machine parts", "Trade show crate", "Avionics, AOG", "Retail apparel",
    "Marine hardware", "Lab equipment", "Palletised consumables",
    "Printed materials", "Automotive spares", "Rack rails and cage nuts",
    "Fibre patch panels", "Spare drives, sealed",
]

SHIPPERS = [
    "northwind", "contoso", "fabrikam", "adventureworks", "tailwind",
    "proseware", "litware", "wingtip", "relecloud", "vanarsdel",
]

running = True


def _stop(_signum: int, _frame: Any) -> None:
    global running
    running = False
    print("\nstopping...", file=sys.stderr)


def request(url: str, *, method: str = "GET", body: dict | None = None,
            timeout: float = 8.0) -> tuple[int, Any]:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if data else {}
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
    parser.add_argument("--rate", type=float, default=6.0,
                        help="new shipments per minute (default: 6)")
    parser.add_argument("--advance", type=float, default=0.4,
                        help="probability of nudging an existing shipment each tick")
    parser.add_argument("--once", type=int, default=0,
                        help="create exactly N shipments and exit")
    args = parser.parse_args()

    base = args.web.rstrip("/")
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    interval = 60.0 / max(args.rate, 0.1)
    created = 0
    print(f"load generator -> {base} (~{args.rate}/min, ctrl-c to stop)", file=sys.stderr)

    while running:
        origin, destination = random.sample(CITIES, 2)
        payload = {
            "origin": origin,
            "destination": destination,
            "description": random.choice(GOODS),
            "weight_kg": round(random.uniform(0.5, 180.0), 2),
            "created_by": random.choice(SHIPPERS),
        }
        code, body = request(f"{base}/api/shipments", method="POST", body=payload)
        if code == 201 and body:
            created += 1
            print(f"created {body['tracking_number']}  {origin} -> {destination}")
        elif code == 429:
            # Expected once the room gets busy; back off rather than hammering.
            print("rate limited, backing off", file=sys.stderr)
            time.sleep(interval * 2)
        else:
            print(f"create failed ({code}): {body}", file=sys.stderr)
            time.sleep(min(interval, 5))

        if args.once and created >= args.once:
            break

        # Nudge a random in-flight shipment so the board keeps moving even when
        # the drift loop on the worker is disabled.
        if random.random() < args.advance:
            code, board = request(f"{base}/api/board?limit=40")
            if code == 200 and isinstance(board, list):
                candidates = [r for r in board if r.get("status") != "DELIVERED"]
                if candidates:
                    target = random.choice(candidates)["tracking_number"]
                    request(f"{base}/api/shipments/{target}/advance", method="POST")

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
