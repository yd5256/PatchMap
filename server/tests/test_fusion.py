"""Pure fusion-engine tests: no database, no HTTP client.

Property-style checks use parametrized tables and exhaustive small grids
(no Hypothesis, per the design).
"""

from __future__ import annotations

import itertools
import math

import pytest

from app.config import DEFAULTS
from app.fusion import (
    CONFIRMED,
    EARTH_RADIUS_M,
    LIKELY_REPAIRED,
    RESOLVED,
    SUSPECTED,
    aggregate_severity,
    compute_confidence,
    find_cluster,
    haversine_m,
    next_state,
)

DEMO_LAT, DEMO_LON = 42.35500, -71.06500
M_PER_DEG_LAT = EARTH_RADIUS_M * math.pi / 180.0


def north_of(lat: float, lon: float, meters: float) -> tuple[float, float]:
    return lat + meters / M_PER_DEG_LAT, lon


def east_of(lat: float, lon: float, meters: float) -> tuple[float, float]:
    return lat, lon + meters / (M_PER_DEG_LAT * math.cos(math.radians(lat)))


# --- haversine --------------------------------------------------------------


@pytest.mark.parametrize(
    "p1, p2, expected_m, tol",
    [
        ((DEMO_LAT, DEMO_LON), (DEMO_LAT, DEMO_LON), 0.0, 1e-9),
        ((0.0, 0.0), (1.0, 0.0), M_PER_DEG_LAT, 1e-6),
        ((0.0, 0.0), (0.0, 1.0), M_PER_DEG_LAT, 1e-6),
        ((0.0, 0.0), (0.0, 180.0), math.pi * EARTH_RADIUS_M, 1e-3),
        ((DEMO_LAT, DEMO_LON), north_of(DEMO_LAT, DEMO_LON, 12.0), 12.0, 1e-6),
        ((DEMO_LAT, DEMO_LON), east_of(DEMO_LAT, DEMO_LON, 40.0), 40.0, 1e-3),
        # Boston (Demo_Coordinate) to New York City Hall: ~306 km
        ((DEMO_LAT, DEMO_LON), (40.7128, -74.0060), 306_000.0, 2_000.0),
    ],
)
def test_haversine_distances(p1, p2, expected_m, tol):
    assert haversine_m(*p1, *p2) == pytest.approx(expected_m, abs=tol)
    # Symmetric
    assert haversine_m(*p1, *p2) == pytest.approx(haversine_m(*p2, *p1), abs=1e-9)


# --- clustering (Property 2) ------------------------------------------------


@pytest.mark.parametrize(
    "offset_m, expected",
    [(0.0, 1), (5.0, 1), (11.99, 1), (12.01, None), (50.0, None)],
)
def test_find_cluster_inside_and_outside_radius(offset_m, expected):
    """**Validates: Requirements 3.1, 3.2, 3.3**"""
    lat, lon = north_of(DEMO_LAT, DEMO_LON, offset_m)
    assert find_cluster([(1, DEMO_LAT, DEMO_LON)], lat, lon, DEFAULTS.CLUSTER_RADIUS_M) == expected


def test_find_cluster_boundary_is_inclusive():
    """A point exactly at the radius attaches (≤ 12 m)."""
    lat, lon = north_of(DEMO_LAT, DEMO_LON, 12.0)
    d = haversine_m(lat, lon, DEMO_LAT, DEMO_LON)
    assert find_cluster([(7, DEMO_LAT, DEMO_LON)], lat, lon, d) == 7


def test_find_cluster_no_defects():
    assert find_cluster([], DEMO_LAT, DEMO_LON, DEFAULTS.CLUSTER_RADIUS_M) is None


@pytest.mark.parametrize("order", list(itertools.permutations([0, 1, 2])))
def test_find_cluster_picks_nearest(order):
    """**Validates: Requirements 3.1, 3.2**"""
    candidates = [
        (10, *north_of(DEMO_LAT, DEMO_LON, 8.0)),
        (20, *east_of(DEMO_LAT, DEMO_LON, 3.0)),
        (30, *north_of(DEMO_LAT, DEMO_LON, -11.0)),
    ]
    defects = [candidates[i] for i in order]
    assert find_cluster(defects, DEMO_LAT, DEMO_LON, DEFAULTS.CLUSTER_RADIUS_M) == 20


# --- confidence (Properties 3, 4, 5, 11) ------------------------------------


@pytest.mark.parametrize(
    "p, o, n, c, expected",
    [
        (0, 0, 0, 0, 1 / 4),
        (1, 1, 0, 0, 0.50),
        (2, 2, 0, 0, 0.625),
        (3, 3, 0, 0, 0.70),
        (5, 5, 0, 0, 11 / 14),
        (11, 11, 0, 0, 23 / 26),
        (1, 3, 0, 0, 3.5 / 6.5),
        (3, 3, 1, 3, 7 / (7 + 4.5 + 0.3)),
        (11, 11, 14, 14, 23 / 47),
        (11, 11, 21, 21, 0.40),
        (11, 11, 22, 22, 23 / 59),
    ],
)
def test_confidence_closed_form(p, o, n, c, expected):
    """**Validates: Requirements 4.1, 4.2, 5.8, 22.2, 22.3, 22.4**"""
    assert compute_confidence(p, o, n, c, DEFAULTS) == pytest.approx(expected, abs=1e-12)


def test_confidence_rounded_values_for_demo():
    assert round(compute_confidence(3, 3, 0, 0), 6) == 0.700000
    assert round(compute_confidence(11, 11, 0, 0), 2) == 0.88
    assert round(compute_confidence(11, 11, 21, 21), 6) == 0.400000


def test_default_weights():
    """**Validates: Requirements 4.2**"""
    assert (
        DEFAULTS.PRIOR_ALPHA,
        DEFAULTS.W_POS_DEVICE,
        DEFAULTS.W_POS_REPEAT,
        DEFAULTS.PRIOR_BETA,
        DEFAULTS.W_NEG_DEVICE,
        DEFAULTS.W_NEG_REPEAT,
    ) == (1.0, 2.0, 0.25, 3.0, 1.5, 0.15)


def _grid(max_unique: int = 8, max_repeat: int = 5):
    for p in range(max_unique + 1):
        for o in range(p, p + max_repeat + 1):
            for n in range(max_unique + 1):
                for c in range(n, n + max_repeat + 1):
                    yield p, o, n, c


@pytest.mark.parametrize("p_max", [8, 30])
def test_property_11_confidence_bounds(p_max):
    """Property 11: confidence in (0, 1) for all non-negative P, O, N, C.

    **Validates: Requirements 4.3**
    """
    for p, o, n, c in _grid(p_max, 5):
        conf = compute_confidence(p, o, n, c)
        assert 0.0 < conf < 1.0, (p, o, n, c, conf)


def test_property_5_evidence_monotonicity():
    """Property 5: a clean crossing never raises confidence; an impact never lowers it.

    **Validates: Requirements 4.4, 4.5, 5.6**
    """
    for p, o, n, c in _grid():
        base = compute_confidence(p, o, n, c)
        # New-device and repeat-device impact
        assert compute_confidence(p + 1, o + 1, n, c) >= base
        assert compute_confidence(p, o + 1, n, c) >= base
        # New-device and repeat-device clean crossing
        assert compute_confidence(p, o, n + 1, c + 1) <= base
        assert compute_confidence(p, o, n, c + 1) <= base
        # Strict decrease from a clean crossing (used by Requirement 5.6)
        assert compute_confidence(p, o, n + 1, c + 1) < base
        assert compute_confidence(p, o, n, c + 1) < base


@pytest.mark.parametrize("k", range(2, 16))
def test_property_4_repeat_discount(k):
    """Property 4: k impacts from one device < k impacts from k devices,
    and one device never satisfies P ≥ 3.

    **Validates: Requirements 4.6, 5.4**
    """
    for n in range(0, 8):
        for c in range(n, n + 4):
            assert compute_confidence(1, k, n, c) < compute_confidence(k, k, n, c)
    conf = compute_confidence(1, k, 0, 0)
    assert next_state(SUSPECTED, 1, 0, conf) == SUSPECTED


@pytest.mark.parametrize("o", range(2, 40))
def test_property_3_two_devices_never_confirm(o):
    """Property 3: two distinct devices never confirm, however many impacts.

    **Validates: Requirements 5.9**
    """
    conf = compute_confidence(2, o, 0, 0)
    assert next_state(SUSPECTED, 2, 0, conf) == SUSPECTED


def test_property_3_three_devices_confirm():
    """**Validates: Requirements 5.8**"""
    conf = compute_confidence(3, 3, 0, 0)
    assert round(conf, 6) == 0.7
    assert next_state(SUSPECTED, 3, 0, conf) == CONFIRMED


# --- lifecycle --------------------------------------------------------------


@pytest.mark.parametrize(
    "state, p, n, conf, expected",
    [
        # SUSPECTED → CONFIRMED (criterion 4) and retained
        (SUSPECTED, 3, 0, 0.70, CONFIRMED),
        (SUSPECTED, 3, 0, 0.68, CONFIRMED),  # inclusive
        (SUSPECTED, 3, 0, 0.6799996, CONFIRMED),  # rounds to 0.68
        (SUSPECTED, 3, 0, 0.679999, SUSPECTED),
        (SUSPECTED, 2, 0, 0.95, SUSPECTED),  # P too low
        (SUSPECTED, 10, 10, 0.10, SUSPECTED),  # no repair edges from SUSPECTED
        # CONFIRMED → LIKELY_REPAIRED (criterion 3) and retained
        (CONFIRMED, 3, 3, 0.49, LIKELY_REPAIRED),
        (CONFIRMED, 3, 5, 0.30, LIKELY_REPAIRED),  # N < 6 so not RESOLVED
        (CONFIRMED, 3, 3, 0.50, CONFIRMED),  # strictly below 0.50
        (CONFIRMED, 3, 2, 0.30, CONFIRMED),  # N too low
        (CONFIRMED, 11, 13, 23 / 45.5, CONFIRMED),  # demo N = 13
        (CONFIRMED, 11, 14, 23 / 47, LIKELY_REPAIRED),  # demo N = 14
        (CONFIRMED, 3, 0, 0.90, CONFIRMED),
        # → RESOLVED (criterion 2, precedence over 3)
        (CONFIRMED, 3, 6, 0.39, RESOLVED),
        (LIKELY_REPAIRED, 3, 6, 0.39, RESOLVED),
        (LIKELY_REPAIRED, 3, 6, 0.3999994, RESOLVED),  # rounds to 0.399999
        (LIKELY_REPAIRED, 3, 6, 0.3999996, LIKELY_REPAIRED),  # rounds to 0.40
        (LIKELY_REPAIRED, 3, 6, 0.40, LIKELY_REPAIRED),
        (LIKELY_REPAIRED, 3, 5, 0.20, LIKELY_REPAIRED),  # N too low
        (LIKELY_REPAIRED, 11, 21, 23 / 57.5, LIKELY_REPAIRED),  # boundary 0.40
        (LIKELY_REPAIRED, 11, 22, 23 / 59, RESOLVED),
        # LIKELY_REPAIRED → CONFIRMED (re-evaluated confirm rule)
        (LIKELY_REPAIRED, 3, 3, 0.70, CONFIRMED),
        (LIKELY_REPAIRED, 3, 3, 0.60, LIKELY_REPAIRED),
        (LIKELY_REPAIRED, 2, 0, 0.90, LIKELY_REPAIRED),
        # RESOLVED is terminal
        (RESOLVED, 20, 0, 0.95, RESOLVED),
        (RESOLVED, 3, 3, 0.45, RESOLVED),
        (RESOLVED, 0, 10, 0.10, RESOLVED),
    ],
)
def test_next_state_table(state, p, n, conf, expected):
    """**Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5, 5.10, 22.3, 22.4**"""
    assert next_state(state, p, n, conf, DEFAULTS) == expected


@pytest.mark.parametrize("p", range(3, 16))
def test_property_6_repair_lifecycle_thresholds(p):
    """Property 6: after confirmation by P devices, N distinct clean devices give
    LIKELY_REPAIRED once N ≥ 3 and N > (4P − 4)/3, and RESOLVED once N ≥ max(6, 2P).

    **Validates: Requirements 5.2, 5.3, 5.5, 22.3, 22.4**
    """
    state = CONFIRMED
    likely_at = resolved_at = None
    for n in range(1, 4 * p + 10):
        new = next_state(state, p, n, compute_confidence(p, p, n, n))
        if new != state:
            if new == LIKELY_REPAIRED:
                likely_at = n
            elif new == RESOLVED:
                resolved_at = n
            state = new
        if state == RESOLVED:
            break
    expected_resolved = max(6, 2 * p)
    assert resolved_at == expected_resolved
    expected_likely = next(
        n for n in range(3, expected_resolved + 1) if n > (4 * p - 4) / 3
    )
    if expected_likely < expected_resolved:
        assert likely_at == expected_likely
    else:
        assert likely_at is None  # went straight to RESOLVED


# --- severity (Property 10) -------------------------------------------------


@pytest.mark.parametrize(
    "impacts, expected",
    [
        ([], 0.0),
        ([("a", 64.0)], 64.0),
        ([("a", 10.0), ("a", 20.0), ("a", 90.0)], 20.0),
        ([("a", 40.0), ("b", 60.0)], 50.0),  # even-sized outer median
        ([("a", 10.0), ("a", 30.0), ("b", 70.0)], 45.0),  # inner even median 20, outer (20+70)/2
        # Frequent reporter "a" contributes one value: medians a=10, b=90, c=80 → 80
        ([("a", 10.0)] * 9 + [("b", 90.0), ("c", 80.0)], 80.0),
        ([("a", 0.0), ("b", 0.0)], 0.0),
        ([("a", 100.0), ("b", 100.0), ("c", 100.0)], 100.0),
    ],
)
def test_aggregate_severity_table(impacts, expected):
    """**Validates: Requirements 6.1, 6.2, 6.3**"""
    assert aggregate_severity(impacts, DEFAULTS.SEVERITY_WINDOW) == pytest.approx(expected)


def test_severity_uses_only_newest_window():
    """Only the 20 newest impacts count; older ones are ignored.

    **Validates: Requirements 6.1, 6.5**
    """
    assert DEFAULTS.SEVERITY_WINDOW == 20
    newest = [(f"dev{i}", 50.0) for i in range(20)]
    oldest = [("old", 100.0)] * 15
    assert aggregate_severity(newest + oldest, 20) == 50.0
    # Shifting the window by one lets the newest "old" sample in, but it is one device
    # among 20 and does not move the median.
    assert aggregate_severity(newest[:19] + oldest, 20) == 50.0


@pytest.mark.parametrize("repeats", [1, 2, 5, 10, 17])
@pytest.mark.parametrize("score", [0.0, 30.0, 95.0])
def test_property_10_single_contribution_per_device(repeats, score):
    """Property 10: a device contributes exactly one value regardless of how many
    of the window's impacts it reports.

    **Validates: Requirements 6.2, 6.3, 6.4**
    """
    others = [("b", 40.0), ("c", 60.0)]
    spammer = [("a", score)] * repeats
    expected = sorted([score, 40.0, 60.0])[1]
    result = aggregate_severity(spammer + others, 20)
    assert result == expected
    assert 0.0 <= result <= 100.0


def test_property_10_bounds_over_score_grid():
    """**Validates: Requirements 6.3**"""
    scores = [0.0, 1.0, 33.3, 50.0, 99.9, 100.0]
    for combo in itertools.product(scores, repeat=3):
        impacts = [(f"d{i % 2}", s) for i, s in enumerate(combo)]
        assert 0.0 <= aggregate_severity(impacts, 20) <= 100.0
