"""Fusion engine: pure, deterministic functions with no I/O or clock access.

Every weight and threshold comes from ``Config`` (``app/config.py``).
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Sequence
from statistics import median

from .config import DEFAULTS, Config

SUSPECTED = "SUSPECTED"
CONFIRMED = "CONFIRMED"
LIKELY_REPAIRED = "LIKELY_REPAIRED"
RESOLVED = "RESOLVED"
STATES = (SUSPECTED, CONFIRMED, LIKELY_REPAIRED, RESOLVED)

EARTH_RADIUS_M = 6_371_000.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in meters between two lat/lon points."""
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = phi2 - phi1
    dlmb = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlmb / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def find_cluster(
    defects: Iterable[tuple[int, float, float]],
    lat: float,
    lon: float,
    radius_m: float = DEFAULTS.CLUSTER_RADIUS_M,
) -> int | None:
    """Return the id of the nearest defect within ``radius_m``, else None.

    ``defects`` is an iterable of ``(id, latitude, longitude)`` for active
    (non-resolved) defects. Ties go to the first defect encountered.
    """
    best_id: int | None = None
    best_d = math.inf
    for defect_id, d_lat, d_lon in defects:
        d = haversine_m(lat, lon, d_lat, d_lon)
        if d < best_d:
            best_id, best_d = defect_id, d
    if best_id is not None and best_d <= radius_m:
        return best_id
    return None


def compute_confidence(p: int, o: int, n: int, c: int, cfg: Config = DEFAULTS) -> float:
    """Bayesian-inspired confidence alpha / (alpha + beta)."""
    alpha = cfg.PRIOR_ALPHA + cfg.W_POS_DEVICE * p + cfg.W_POS_REPEAT * max(o - p, 0)
    beta = cfg.PRIOR_BETA + cfg.W_NEG_DEVICE * n + cfg.W_NEG_REPEAT * max(c - n, 0)
    return alpha / (alpha + beta)


def aggregate_severity(
    impacts_newest_first: Sequence[tuple[str, float]],
    window: int = DEFAULTS.SEVERITY_WINDOW,
) -> float:
    """Median of per-device medians over the ``window`` newest impacts.

    ``impacts_newest_first`` holds ``(device_id, impact_score)`` ordered by
    timestamp, newest first. Returns 0.0 when there are no impacts.
    """
    per_device: dict[str, list[float]] = {}
    for device_id, score in impacts_newest_first[:window]:
        per_device.setdefault(device_id, []).append(float(score))
    if not per_device:
        return 0.0
    value = median(median(scores) for scores in per_device.values())
    return min(100.0, max(0.0, float(value)))


def next_state(state: str, p: int, n: int, confidence: float, cfg: Config = DEFAULTS) -> str:
    """Apply lifecycle rules in precedence order RESOLVED → LIKELY_REPAIRED → CONFIRMED."""
    conf = round(confidence, cfg.CONFIDENCE_ROUND_DECIMALS)

    if state in (CONFIRMED, LIKELY_REPAIRED) and (
        n >= cfg.RESOLVED_MIN_NEG_DEVICES and conf < cfg.RESOLVED_MAX_CONFIDENCE
    ):
        return RESOLVED
    if state == CONFIRMED and (
        n >= cfg.LIKELY_REPAIRED_MIN_NEG_DEVICES and conf < cfg.LIKELY_REPAIRED_MAX_CONFIDENCE
    ):
        return LIKELY_REPAIRED
    if state in (SUSPECTED, LIKELY_REPAIRED) and (
        p >= cfg.CONFIRM_MIN_POS_DEVICES and conf >= cfg.CONFIRM_MIN_CONFIDENCE
    ):
        return CONFIRMED
    return state
