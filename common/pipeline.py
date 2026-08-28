"""The shipment status pipeline, shared by the API and the worker.

Kept in `common/` because both tiers must agree on the transition rules, and
because "the worker and the API disagree about state" is a debugging rabbit hole
that has no place in a 45 minute breakout.
"""

from __future__ import annotations

CREATED = "CREATED"
PICKED_UP = "PICKED_UP"
IN_TRANSIT = "IN_TRANSIT"
AT_HUB = "AT_HUB"
OUT_FOR_DELIVERY = "OUT_FOR_DELIVERY"
DELIVERED = "DELIVERED"
EXCEPTION = "EXCEPTION"

#: Ordered happy path. The worker walks a shipment down this list one step per
#: queued scan, which is what makes the board visibly move during the demo.
PIPELINE: tuple[str, ...] = (
    CREATED,
    PICKED_UP,
    IN_TRANSIT,
    AT_HUB,
    OUT_FOR_DELIVERY,
    DELIVERED,
)

TERMINAL: frozenset[str] = frozenset({DELIVERED})

#: Scan type recorded when a shipment enters each status.
SCAN_TYPE_FOR_STATUS: dict[str, str] = {
    PICKED_UP: "PICKUP_SCAN",
    IN_TRANSIT: "DEPART_SCAN",
    AT_HUB: "HUB_ARRIVE_SCAN",
    OUT_FOR_DELIVERY: "LOAD_TO_VEHICLE",
    DELIVERED: "DELIVERY_SCAN",
    EXCEPTION: "EXCEPTION_SCAN",
}

#: Human sentence shown on the public tracking page.
NARRATIVE_FOR_STATUS: dict[str, str] = {
    CREATED: "Label created, awaiting collection",
    PICKED_UP: "Collected from shipper",
    IN_TRANSIT: "In transit on the line haul",
    AT_HUB: "Arrived at the destination hub",
    OUT_FOR_DELIVERY: "Out for delivery",
    DELIVERED: "Delivered",
    EXCEPTION: "Delivery exception — held for review",
}


def next_status(current: str) -> str | None:
    """Return the next status in the pipeline, or None if there is nowhere to go."""
    if current == EXCEPTION:
        return AT_HUB  # exceptions rejoin the pipeline at the hub
    try:
        index = PIPELINE.index(current)
    except ValueError:
        return None
    if index + 1 >= len(PIPELINE):
        return None
    return PIPELINE[index + 1]


def is_terminal(status: str) -> bool:
    return status in TERMINAL


def scan_type_for(status: str) -> str:
    return SCAN_TYPE_FOR_STATUS.get(status, "STATUS_SCAN")


def narrative_for(status: str) -> str:
    return NARRATIVE_FOR_STATUS.get(status, status.replace("_", " ").title())


def progress_percent(status: str) -> int:
    """0-100 completion, for the progress bar on the tracking page."""
    if status == EXCEPTION:
        return 50
    try:
        index = PIPELINE.index(status)
    except ValueError:
        return 0
    return round(index / (len(PIPELINE) - 1) * 100)
