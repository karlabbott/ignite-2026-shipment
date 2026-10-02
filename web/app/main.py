"""Zava Logistics web tier.

Serves three things:

* ``/``        the live shipment board and estate health strip (dash.99b.org)
* ``/track``   the audience-facing create-and-follow page (track.99b.org)
* ``/api/*``   a thin proxy to the SUSE API tier

The proxy exists so the browser only ever talks to one origin, and — more
usefully for the demo — so the web tier can report *why* the API tier is
unreachable rather than leaving the audience looking at a silent JavaScript
error. Every upstream failure is translated into a rendered banner.

This tier holds no business logic and never touches the database directly except
to publish its own heartbeat.
"""

from __future__ import annotations

import logging
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request, Response, status
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from common import estate

from .config import settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
)
log = logging.getLogger("shipment.web")

BASE_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

client: httpx.AsyncClient | None = None


def _heartbeat_loop(stop: threading.Event) -> None:
    """Publish the web tier's identity straight to the database.

    The web tier deliberately does not route its heartbeat through the API: if it
    did, a dead API tier would take the web tile off the health strip too, and the
    audience would not be able to tell which box actually broke.
    """
    try:
        from api.app.db import Database, DatabaseUnavailable
    except ImportError:
        log.warning("database module unavailable; web tier will not publish a heartbeat")
        return

    database = Database(settings)
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
                    f"upstream {settings.api_base_url}",
                ),
            )
        except DatabaseUnavailable as exc:
            log.warning("heartbeat skipped, database unavailable: %s", exc)
        except Exception:
            log.exception("unexpected heartbeat failure")
    database.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    global client
    client = httpx.AsyncClient(
        base_url=settings.api_base_url,
        timeout=httpx.Timeout(settings.api_timeout_seconds),
        headers={"user-agent": "zava-logistics-web/1.0"},
    )
    stop = threading.Event()
    thread = threading.Thread(target=_heartbeat_loop, args=(stop,), daemon=True)
    thread.start()
    log.info("web tier online as %s -> %s", estate.identify(settings.tier), settings.api_base_url)
    try:
        yield
    finally:
        stop.set()
        thread.join(timeout=2)
        await client.aclose()


app = FastAPI(title="Zava Logistics", version="1.0.0", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


# --------------------------------------------------------------------------- #
# Upstream proxy
# --------------------------------------------------------------------------- #
async def call_api(
    method: str,
    path: str,
    *,
    params: dict[str, Any] | None = None,
    json_body: Any = None,
    forward_from: Request | None = None,
) -> tuple[int, Any]:
    """Call the API tier and normalise every failure into a JSON-able payload."""
    assert client is not None
    headers: dict[str, str] = {}
    if forward_from is not None:
        # Preserve the real client address so the API tier's rate limiter sees
        # attendees rather than a single nginx source.
        existing = forward_from.headers.get("x-forwarded-for")
        if existing or forward_from.client:
            # nginx appends the socket peer to any incoming X-Forwarded-For
            # chain. Trust only that final address, not a caller-supplied prefix.
            headers["x-forwarded-for"] = (
                existing.split(",")[-1].strip()
                if existing
                else forward_from.client.host
            )
        loadgen_key = forward_from.headers.get("x-zava-loadgen-key")
        if loadgen_key:
            headers["x-zava-loadgen-key"] = loadgen_key
        presenter_key = forward_from.headers.get("x-zava-presenter-key")
        if presenter_key:
            headers["x-zava-presenter-key"] = presenter_key
        client_token = forward_from.headers.get("x-zava-client-token")
        if client_token:
            headers["x-zava-client-token"] = client_token

    try:
        response = await client.request(
            method, path, params=params, json=json_body, headers=headers
        )
    except httpx.ConnectError as exc:
        return status.HTTP_502_BAD_GATEWAY, {
            "error": "api_unreachable",
            "target": settings.api_base_url,
            "message": f"Cannot reach the API tier: {exc}",
        }
    except httpx.TimeoutException:
        return status.HTTP_504_GATEWAY_TIMEOUT, {
            "error": "api_timeout",
            "target": settings.api_base_url,
            "message": f"API tier did not answer within {settings.api_timeout_seconds}s",
        }
    except httpx.HTTPError as exc:
        return status.HTTP_502_BAD_GATEWAY, {
            "error": "api_error",
            "target": settings.api_base_url,
            "message": str(exc),
        }

    try:
        return response.status_code, response.json()
    except ValueError:
        return response.status_code, {"error": "bad_upstream_payload", "message": response.text[:400]}


# --------------------------------------------------------------------------- #
# Pages
# --------------------------------------------------------------------------- #
def _track_url(request: Request) -> str:
    """Return the address to advertise for the public tracking page.

    On Hyper-V there is no DNS for this lab, so hard-coding a hostname would put
    an address on the stage screen that nobody can reach. Instead we echo back
    the host the browser actually used -- which on-prem is
    ``http://192.168.90.13/track``.

    ``X-Forwarded-*`` is honoured because nginx sits in front of us, so the
    scheme and host reflect what the client saw rather than the loopback bind.

    Setting ``SHIPMENT_TRACK_URL`` overrides all of this. That is the switch you
    flip after the migration, once ``track.99b.org`` resolves to the Azure load
    balancer instead of nothing at all.
    """
    if settings.public_track_url:
        return settings.public_track_url

    forwarded_host = request.headers.get("x-forwarded-host")
    host = forwarded_host or request.headers.get("host") or "192.168.90.13"
    scheme = request.headers.get("x-forwarded-proto") or request.url.scheme
    return f"{scheme}://{host.split(',')[0].strip()}/track"


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
async def dashboard(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "brand": settings.brand,
            "track_url": _track_url(request),
            "return_url": settings.return_url,
            "refresh_ms": settings.refresh_ms,
        },
    )


@app.get("/track", response_class=HTMLResponse, include_in_schema=False)
async def track_page(request: Request, n: str = "") -> HTMLResponse:
    return templates.TemplateResponse(
        request,
        "track.html",
        {
            "brand": settings.brand,
            "prefill": n.strip().upper()[:20],
            "refresh_ms": settings.refresh_ms,
        },
    )


@app.get("/vote", response_class=HTMLResponse, include_in_schema=False)
async def vote_page(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(
        request,
        "vote.html",
        {
            "brand": settings.brand,
            "refresh_ms": settings.refresh_ms,
        },
    )


# --------------------------------------------------------------------------- #
# Health
# --------------------------------------------------------------------------- #
@app.get("/healthz", tags=["health"])
async def healthz(response: Response) -> dict[str, Any]:
    code, payload = await call_api("GET", "/healthz")
    upstream_ok = code == status.HTTP_200_OK
    result = estate.identity_dict(settings.tier)
    result["upstream"] = {
        "target": settings.api_base_url,
        "reachable": upstream_ok,
        "status_code": code,
        "detail": payload if not upstream_ok else None,
    }
    result["healthy"] = upstream_ok
    if not upstream_ok:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return result


@app.get("/api/estate", tags=["health"])
async def estate_view() -> JSONResponse:
    """The health strip.

    Always returns 200 with a ``web`` tile filled in locally, so the dashboard can
    render *something* truthful even when the rest of the estate is mid-migration.
    """
    code, payload = await call_api("GET", "/api/estate")
    local = estate.identity_dict(settings.tier)
    web_tile = {
        "tier": "web",
        "hostname": local["hostname"],
        "distro": local["distro"],
        "kernel": local["kernel"],
        "platform": local["platform_name"],
        "location": local["location"],
        "vm_size": local["vm_size"],
        "detail": f"upstream {settings.api_base_url}",
        "last_seen": None,
        "healthy": True,
    }

    if code != status.HTTP_200_OK or not isinstance(payload, list):
        return JSONResponse(
            {
                "tiers": [web_tile],
                "degraded": True,
                "reason": payload if isinstance(payload, dict) else {"error": "api_error"},
            }
        )

    tiers = [tile for tile in payload if tile.get("tier") != "web"]
    return JSONResponse({"tiers": [web_tile, *tiers], "degraded": False, "reason": None})


# --------------------------------------------------------------------------- #
# Proxied data endpoints
# --------------------------------------------------------------------------- #
@app.get("/api/board", tags=["shipments"])
async def board(limit: int = 0, offset: int = 0) -> JSONResponse:
    params = {}
    if limit:
        params["limit"] = min(max(limit, 1), 200)
    if offset:
        params["offset"] = min(max(offset, 0), 100_000)
    code, payload = await call_api("GET", "/api/board", params=params or None)
    return JSONResponse(payload, status_code=code)


@app.get("/api/stats", tags=["shipments"])
async def stats() -> JSONResponse:
    code, payload = await call_api("GET", "/api/stats")
    return JSONResponse(payload, status_code=code)


@app.get("/api/presentation", tags=["shipments"])
async def presentation(limit: int = 30) -> JSONResponse:
    code, payload = await call_api(
        "GET",
        "/api/presentation",
        params={"limit": min(max(limit, 1), 60)},
    )
    return JSONResponse(payload, status_code=code)


@app.post("/api/presentation/golden/release", tags=["shipments"])
async def release_golden(request: Request) -> JSONResponse:
    code, payload = await call_api(
        "POST", "/api/presentation/golden/release", forward_from=request
    )
    return JSONResponse(payload, status_code=code)


@app.get("/api/poll", tags=["audience"])
async def current_poll() -> JSONResponse:
    code, payload = await call_api("GET", "/api/poll")
    return JSONResponse(payload, status_code=code)


@app.post("/api/poll/vote", tags=["audience"])
async def vote(request: Request) -> JSONResponse:
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="Expected a JSON body") from None
    code, payload = await call_api(
        "POST", "/api/poll/vote", json_body=body, forward_from=request
    )
    return JSONResponse(payload, status_code=code)


@app.post("/api/presenter/polls", tags=["presenter"])
async def open_poll(request: Request) -> JSONResponse:
    code, payload = await call_api(
        "POST", "/api/presenter/polls", forward_from=request
    )
    return JSONResponse(payload, status_code=code)


@app.get("/api/presenter/polls/{poll_id}", tags=["presenter"])
async def presenter_poll(poll_id: int, request: Request) -> JSONResponse:
    code, payload = await call_api(
        "GET", f"/api/presenter/polls/{poll_id}", forward_from=request
    )
    return JSONResponse(payload, status_code=code)


@app.post("/api/presenter/polls/{poll_id}/lock", tags=["presenter"])
async def lock_poll(poll_id: int, request: Request) -> JSONResponse:
    code, payload = await call_api(
        "POST", f"/api/presenter/polls/{poll_id}/lock", forward_from=request
    )
    return JSONResponse(payload, status_code=code)


@app.post("/api/presenter/polls/{poll_id}/state", tags=["presenter"])
async def update_poll_state(poll_id: int, request: Request) -> JSONResponse:
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="Expected a JSON body") from None
    code, payload = await call_api(
        "POST",
        f"/api/presenter/polls/{poll_id}/state",
        json_body=body,
        forward_from=request,
    )
    return JSONResponse(payload, status_code=code)


@app.get("/api/shipments/{tracking}", tags=["shipments"])
async def shipment(tracking: str) -> JSONResponse:
    code, payload = await call_api("GET", f"/api/shipments/{tracking.strip().upper()[:20]}")
    return JSONResponse(payload, status_code=code)


@app.post("/api/shipments", tags=["shipments"])
async def create(request: Request) -> JSONResponse:
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="Expected a JSON body") from None
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Expected a JSON object")
    code, payload = await call_api("POST", "/api/shipments", json_body=body, forward_from=request)
    return JSONResponse(payload, status_code=code)


@app.post("/api/shipments/{tracking}/advance", tags=["shipments"])
async def advance(tracking: str, request: Request) -> JSONResponse:
    code, payload = await call_api(
        "POST",
        f"/api/shipments/{tracking.strip().upper()[:20]}/advance",
        forward_from=request,
    )
    return JSONResponse(payload, status_code=code)
