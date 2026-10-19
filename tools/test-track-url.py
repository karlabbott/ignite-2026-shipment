"""Verify the dashboard advertises a reachable tracking address.

On Hyper-V there is no DNS for the lab, so the address printed on the board must
be whatever host the browser actually used. After migration, SHIPMENT_TRACK_URL
pins the real public name. This test covers both states plus the nginx
X-Forwarded-Host path, because the web tier always sits behind a proxy.

Run:  .venv\\Scripts\\python.exe tools\\test-track-url.py
"""

import os
import asyncio
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "web"))

# Keep the web tier from trying to reach the estate during the test.
os.environ.setdefault("SHIPMENT_DB_HOST", "127.0.0.1")
os.environ.setdefault("SHIPMENT_HEARTBEAT_SECONDS", "3600")

failures = []


def check(name, got, want):
    status = "ok  " if got == want else "FAIL"
    if got != want:
        failures.append(name)
    print(f"  [{status}] {name}\n         got  {got!r}\n         want {want!r}")


def build_request(headers, scheme="http"):
    from starlette.requests import Request

    raw = [(k.lower().encode(), v.encode()) for k, v in headers.items()]
    return Request(
        {
            "type": "http",
            "http_version": "1.1",
            "method": "GET",
            "scheme": scheme,
            "path": "/",
            "raw_path": b"/",
            "query_string": b"",
            "root_path": "",
            "headers": raw,
            "client": ("192.168.90.50", 51234),
            "server": ("127.0.0.1", 8000),
        }
    )


print("\nHyper-V (no DNS, no SHIPMENT_TRACK_URL set)")
os.environ.pop("SHIPMENT_TRACK_URL", None)
import importlib

import app.config as webconfig
import app.main as webmain

importlib.reload(webconfig)
importlib.reload(webmain)

check(
    "direct hit on the web VM by IP",
    webmain._track_url(build_request({"host": "192.168.90.13"})),
    "http://192.168.90.13/track",
)
check(
    "behind nginx, which forwards the original host",
    webmain._track_url(
        build_request({"host": "127.0.0.1:8000", "x-forwarded-host": "192.168.90.13"})
    ),
    "http://192.168.90.13/track",
)
check(
    "laptop port-forward during development",
    webmain._track_url(build_request({"host": "localhost:8000"})),
    "http://localhost:8000/track",
)

print("\nAzure (DNS exists, SHIPMENT_TRACK_URL pinned)")
os.environ["SHIPMENT_TRACK_URL"] = "https://track.99b.org"
importlib.reload(webconfig)
importlib.reload(webmain)

check(
    "override wins over the request host",
    webmain._track_url(build_request({"host": "10.20.0.4"})),
    "https://track.99b.org",
)
check(
    "override wins behind the Azure front end too",
    webmain._track_url(
        build_request(
            {"host": "shipment-web.internal", "x-forwarded-proto": "https"}, scheme="http"
        )
    ),
    "https://track.99b.org",
)

print()
controls = asyncio.run(webmain.voting_controls(build_request({"host": "dash.99b.org"})))
check("presenter voting page renders", controls.status_code, 200)
check("presenter voting page has close control", b'id="close-voting"' in controls.body, True)
if failures:
    print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
    sys.exit(1)
print("All track-url checks passed.")
