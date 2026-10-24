"""Pydantic request/response models and evidence validation."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .config import DEFAULTS

_CFG = DEFAULTS


def parse_iso_datetime(value: str) -> datetime:
    """Parse an ISO-8601 date-time string into an aware UTC datetime.

    Naive values are interpreted as UTC. Date-only strings are rejected.
    """
    text = value.strip()
    if len(text) < 11 or text[10] not in ("T", "t", " "):
        raise ValueError("timestamp must be an ISO-8601 date-time")
    try:
        dt = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ValueError("timestamp must be an ISO-8601 date-time") from exc
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


class EvidenceIn(BaseModel):
    """One IMPACT or CLEAN_CROSSING observation, real or simulated."""

    model_config = ConfigDict(extra="ignore")

    device_id: str = Field(min_length=1, max_length=_CFG.MAX_DEVICE_ID_LEN)
    type: Literal["impact", "clean_crossing"]
    latitude: float = Field(ge=-90, le=90, allow_inf_nan=False)
    longitude: float = Field(ge=-180, le=180, allow_inf_nan=False)
    timestamp: datetime
    speed_mps: Optional[float] = Field(default=None, ge=0, allow_inf_nan=False)
    gps_accuracy_m: Optional[float] = Field(
        default=None, gt=0, le=_CFG.MAX_GPS_ACCURACY_M, allow_inf_nan=False
    )
    # Impact-only fields: validated for impacts, ignored (stored null) for clean crossings.
    impact_score: Optional[float] = None
    peak_acceleration: Optional[float] = None
    peak_jerk: Optional[float] = None
    rotation_rate: Optional[float] = None
    # Required for clean crossings; ignored for impacts (the server clusters).
    road_defect_id: Optional[int] = None
    is_simulated: bool = False

    @field_validator("timestamp", mode="before")
    @classmethod
    def _parse_timestamp(cls, value: object) -> datetime:
        if not isinstance(value, str):
            raise ValueError("timestamp must be an ISO-8601 date-time string")
        dt = parse_iso_datetime(value)
        now = datetime.now(timezone.utc)
        if dt - now > timedelta(seconds=_CFG.MAX_FUTURE_SKEW_S):
            raise ValueError(
                f"timestamp is more than {_CFG.MAX_FUTURE_SKEW_S:g} s in the future"
            )
        return dt

    @model_validator(mode="after")
    def _type_dependent_fields(self) -> "EvidenceIn":
        if self.type == "impact":
            score = self.impact_score
            if score is None:
                raise ValueError("impact_score is required for impact evidence")
            if not (0 <= score <= 100):
                raise ValueError("impact_score must be within [0, 100]")
            for name in ("peak_acceleration", "peak_jerk", "rotation_rate"):
                v = getattr(self, name)
                if v is not None and not (v >= 0 and v != float("inf")):
                    raise ValueError(f"{name} must be >= 0")
        else:
            if self.road_defect_id is None:
                raise ValueError("road_defect_id is required for clean_crossing evidence")
        return self


class DefectOut(BaseModel):
    id: int
    latitude: float
    longitude: float
    state: Literal["SUSPECTED", "CONFIRMED", "LIKELY_REPAIRED", "RESOLVED"]
    confidence: float
    severity: float
    positive_observation_count: int
    positive_unique_device_count: int
    clean_crossing_count: int
    clean_unique_device_count: int
    first_seen: str
    last_seen: str
    created_at: str
    updated_at: str


class Transition(BaseModel):
    model_config = ConfigDict(populate_by_name=True, serialize_by_alias=True)

    from_: str = Field(alias="from")
    to: str


class IngestResult(BaseModel):
    evidence_id: int
    duplicate: bool
    created: bool
    transition: Optional[Transition]
    defect: DefectOut
