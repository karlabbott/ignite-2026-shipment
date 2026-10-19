"""Request and response models for the API tier."""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator


class ShipmentCreate(BaseModel):
    """What the public tracking form posts.

    Validation is intentionally strict: this endpoint is reachable from a QR code
    on a conference screen, so every field is length-capped and stripped.
    """

    origin: str = Field(min_length=2, max_length=60)
    destination: str = Field(min_length=2, max_length=60)
    description: str = Field(default="General freight", max_length=120)
    weight_kg: float = Field(default=1.0, gt=0, le=999.99)
    carrier_code: str | None = Field(default=None, max_length=8)
    created_by: str = Field(default="attendee", max_length=60)

    @field_validator("origin", "destination", "description", "created_by")
    @classmethod
    def _tidy(cls, value: str) -> str:
        cleaned = " ".join(value.split())
        if not cleaned:
            raise ValueError("must not be blank")
        return cleaned

    @field_validator("carrier_code")
    @classmethod
    def _upper(cls, value: str | None) -> str | None:
        return value.upper().strip() if value else None


class ScanEvent(BaseModel):
    scan_id: int
    scan_type: str
    location: str
    notes: str | None = None
    worker_host: str
    worker_site: str
    occurred_at: datetime


class StatusChange(BaseModel):
    from_status: str | None
    to_status: str
    changed_by: str
    changed_at: datetime


class RoutePoint(BaseModel):
    sequence: int
    kind: str
    location: str
    latitude: float
    longitude: float


class Shipment(BaseModel):
    tracking_number: str
    carrier_code: str
    carrier_name: str
    origin: str
    destination: str
    description: str
    weight_kg: float
    status: str
    status_narrative: str
    progress_percent: int
    created_by: str
    created_at: datetime
    updated_at: datetime


class ShipmentDetail(Shipment):
    scans: list[ScanEvent] = Field(default_factory=list)
    history: list[StatusChange] = Field(default_factory=list)
    route_points: list[RoutePoint] = Field(default_factory=list)


class BoardRow(BaseModel):
    tracking_number: str
    carrier_code: str
    origin: str
    destination: str
    status: str
    status_narrative: str
    progress_percent: int
    scan_count: int
    last_location: str | None = None
    last_scanned_by: str | None = None
    created_by: str
    updated_at: datetime


class TierHealth(BaseModel):
    tier: str
    hostname: str
    distro: str
    kernel: str
    platform: str
    location: str
    vm_size: str | None = None
    detail: str | None = None
    last_seen: datetime | None = None
    healthy: bool = True


FailureChoice = Literal[
    "freeze_azurelinux",
    "degrade_worker_sql",
    "delay_worker_claims",
]


class FailureVote(BaseModel):
    poll_id: int = Field(gt=0)
    voter_token: str = Field(min_length=16, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    choice_code: FailureChoice


class FailurePollState(BaseModel):
    state: Literal["injected", "recovered", "closed"]


class FailureRunner(BaseModel):
    runner_id: UUID


class FailureInjectionResult(FailureRunner):
    succeeded: bool


class Stats(BaseModel):
    total: int
    delivered: int
    in_flight: int
    queue_depth: int
    scans_last_5m: int
    by_status: dict[str, int]
