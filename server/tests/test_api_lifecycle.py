"""API-level tests through TestClient against a fresh temp SQLite file per test."""

from __future__ import annotations

import math
import sqlite3
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest

from app.fusion import EARTH_RADIUS_M

DEMO_LAT, DEMO_LON = 42.35500, -71.06500
M_PER_DEG_LAT = EARTH_RADIUS_M * math.pi / 180.0

# Fixed, whole-second base time safely in the past.
BASE_TIME = (datetime.now(timezone.utc) - timedelta(hours=1)).replace(microsecond=0)

DEFECT_FIELDS = {
    "id",
    "latitude",
    "longitude",
    "state",
    "confidence",
    "severity",
    "positive_observation_count",
    "positive_unique_device_count",
    "clean_crossing_count",
    "clean_unique_device_count",
    "first_seen",
    "last_seen",
    "created_at",
    "updated_at",
}


# --- helpers ----------------------------------------------------------------


def ts(offset_s: float = 0.0) -> str:
    return (BASE_TIME + timedelta(seconds=offset_s)).isoformat().replace("+00:00", "Z")


def offset(lat: float, lon: float, north_m: float = 0.0, east_m: float = 0.0) -> tuple[float, float]:
    return (
        lat + north_m / M_PER_DEG_LAT,
        lon + east_m / (M_PER_DEG_LAT * math.cos(math.radians(lat))),
    )


def impact(
    device_id: str | None = None,
    *,
    lat: float = DEMO_LAT,
    lon: float = DEMO_LON,
    t: float = 0.0,
    score: float = 60.0,
    **extra,
) -> dict:
    body = {
        "device_id": device_id or str(uuid.uuid4()),
        "type": "impact",
        "latitude": lat,
        "longitude": lon,
        "timestamp": ts(t),
        "speed_mps": 10.0,
        "gps_accuracy_m": 5.0,
        "impact_score": score,
        "peak_acceleration": 1.2,
        "peak_jerk": 30.0,
        "rotation_rate": 0.8,
        "is_simulated": False,
    }
    body.update(extra)
    return body


def crossing(
    defect_id: int,
    device_id: str | None = None,
    *,
    lat: float = DEMO_LAT,
    lon: float = DEMO_LON,
    t: float = 0.0,
    **extra,
) -> dict:
    body = {
        "device_id": device_id or str(uuid.uuid4()),
        "type": "clean_crossing",
        "road_defect_id": defect_id,
        "latitude": lat,
        "longitude": lon,
        "timestamp": ts(t),
        "speed_mps": 10.0,
        "gps_accuracy_m": 5.0,
        "is_simulated": False,
    }
    body.update(extra)
    return body


def post_ok(client, body: dict) -> dict:
    r = client.post("/evidence", json=body)
    assert r.status_code == 200, r.text
    return r.json()


def evidence_rows(client) -> list[sqlite3.Row]:
    conn = sqlite3.connect(client.db_path)
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute("SELECT * FROM evidence ORDER BY id").fetchall()
    finally:
        conn.close()


def all_defects(client) -> list[sqlite3.Row]:
    conn = sqlite3.connect(client.db_path)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute("SELECT * FROM road_defect ORDER BY id")]
    finally:
        conn.close()


def confirmed_defect(client, devices: int = 3) -> dict:
    """Create a defect at the demo coordinate confirmed by ``devices`` devices."""
    result = None
    for i in range(devices):
        result = post_ok(client, impact(f"pos-{i}", t=i))
    assert result["defect"]["state"] == "CONFIRMED"
    return result["defect"]


def resolve_defect(client, defect_id: int, p: int = 3) -> dict:
    """Post clean crossings from fresh devices until the defect is RESOLVED."""
    for i in range(2 * p):
        res = post_ok(client, crossing(defect_id, f"neg-{i}", t=100 + i))
    assert res["defect"]["state"] == "RESOLVED"
    return res["defect"]


# --- health and output shape -------------------------------------------------


def test_health(client):
    """**Validates: Requirements 7.1**"""
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_defects_empty_initially(client):
    """**Validates: Requirements 7.2**"""
    r = client.get("/defects")
    assert r.status_code == 200
    assert r.json() == []


def test_defect_out_shape(client):
    """**Validates: Requirements 7.3, 7.7**"""
    res = post_ok(client, impact(t=0))
    assert set(res) == {"evidence_id", "duplicate", "created", "transition", "defect"}
    defect = client.get(f"/defects/{res['defect']['id']}").json()
    assert set(defect) == DEFECT_FIELDS
    for key in ("first_seen", "last_seen", "created_at", "updated_at"):
        datetime.strptime(defect[key], "%Y-%m-%dT%H:%M:%SZ")
    assert defect["first_seen"] == ts(0)


def test_get_unknown_defect_404(client):
    """**Validates: Requirements 7.4**"""
    assert client.get("/defects/999").status_code == 404


# --- validation (Requirement 1) ---------------------------------------------


def _future(seconds: float) -> str:
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()


@pytest.mark.parametrize(
    "mutate",
    [
        pytest.param(lambda b: b.pop("device_id"), id="device_id-missing"),
        pytest.param(lambda b: b.update(device_id=""), id="device_id-empty"),
        pytest.param(lambda b: b.update(device_id="x" * 65), id="device_id-too-long"),
        pytest.param(lambda b: b.pop("type"), id="type-missing"),
        pytest.param(lambda b: b.update(type="pothole"), id="type-invalid"),
        pytest.param(lambda b: b.pop("latitude"), id="lat-missing"),
        pytest.param(lambda b: b.update(latitude=90.0001), id="lat-high"),
        pytest.param(lambda b: b.update(latitude=-90.5), id="lat-low"),
        pytest.param(lambda b: b.pop("longitude"), id="lon-missing"),
        pytest.param(lambda b: b.update(longitude=180.01), id="lon-high"),
        pytest.param(lambda b: b.update(longitude=-181), id="lon-low"),
        pytest.param(lambda b: b.pop("timestamp"), id="ts-missing"),
        pytest.param(lambda b: b.update(timestamp="yesterday"), id="ts-garbage"),
        pytest.param(lambda b: b.update(timestamp="2026-01-01"), id="ts-date-only"),
        pytest.param(lambda b: b.update(timestamp=_future(400)), id="ts-future"),
        pytest.param(lambda b: b.update(speed_mps=-0.1), id="speed-negative"),
        pytest.param(lambda b: b.update(gps_accuracy_m=0), id="accuracy-zero"),
        pytest.param(lambda b: b.update(gps_accuracy_m=-3), id="accuracy-negative"),
        pytest.param(lambda b: b.update(gps_accuracy_m=30.5), id="accuracy-high"),
        pytest.param(lambda b: b.pop("impact_score"), id="score-missing"),
        pytest.param(lambda b: b.update(impact_score=None), id="score-null"),
        pytest.param(lambda b: b.update(impact_score=-1), id="score-low"),
        pytest.param(lambda b: b.update(impact_score=100.5), id="score-high"),
        pytest.param(lambda b: b.update(peak_acceleration=-0.1), id="peak-acc-negative"),
        pytest.param(lambda b: b.update(peak_jerk=-1), id="peak-jerk-negative"),
        pytest.param(lambda b: b.update(rotation_rate=-0.5), id="rotation-negative"),
    ],
)
def test_impact_validation_422(client, mutate):
    """**Validates: Requirements 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.15**"""
    body = impact(t=0)
    mutate(body)
    r = client.post("/evidence", json=body)
    assert r.status_code == 422, r.text
    assert evidence_rows(client) == []
    assert all_defects(client) == []


@pytest.mark.parametrize(
    "mutate",
    [
        pytest.param(lambda b: b.update(latitude=90, longitude=180), id="max-bounds"),
        pytest.param(lambda b: b.update(latitude=-90, longitude=-180), id="min-bounds"),
        pytest.param(lambda b: b.update(gps_accuracy_m=30), id="accuracy-30"),
        pytest.param(lambda b: b.update(speed_mps=0), id="speed-zero"),
        pytest.param(lambda b: b.update(impact_score=0), id="score-0"),
        pytest.param(lambda b: b.update(impact_score=100), id="score-100"),
        pytest.param(lambda b: b.update(device_id="x" * 64), id="device-64"),
        pytest.param(lambda b: b.update(timestamp=_future(200)), id="ts-near-future"),
        pytest.param(
            lambda b: [b.pop(k) for k in ("speed_mps", "gps_accuracy_m", "peak_acceleration",
                                          "peak_jerk", "rotation_rate")],
            id="optional-absent",
        ),
    ],
)
def test_impact_validation_boundaries_accepted(client, mutate):
    """**Validates: Requirements 1.1, 1.3, 1.5, 1.6, 1.7, 1.8**"""
    body = impact(t=0)
    mutate(body)
    res = post_ok(client, body)
    assert res["duplicate"] is False
    assert len(evidence_rows(client)) == 1


def test_clean_crossing_missing_defect_id_422(client):
    """**Validates: Requirements 1.10, 1.15**"""
    defect = post_ok(client, impact(t=0))["defect"]
    body = crossing(defect["id"], t=5)
    body.pop("road_defect_id")
    assert client.post("/evidence", json=body).status_code == 422
    assert len(evidence_rows(client)) == 1
    assert client.get(f"/defects/{defect['id']}").json() == defect


def test_clean_crossing_unknown_defect_404(client):
    """**Validates: Requirements 1.11, 1.15**"""
    defect = post_ok(client, impact(t=0))["defect"]
    r = client.post("/evidence", json=crossing(999, t=5))
    assert r.status_code == 404
    assert len(evidence_rows(client)) == 1
    assert client.get(f"/defects/{defect['id']}").json() == defect


def test_clean_crossing_resolved_defect_409(client):
    """**Validates: Requirements 1.12, 1.15, 5.10**"""
    defect = confirmed_defect(client)
    resolved = resolve_defect(client, defect["id"])
    rows_before = len(evidence_rows(client))
    r = client.post("/evidence", json=crossing(defect["id"], t=500))
    assert r.status_code == 409
    assert len(evidence_rows(client)) == rows_before
    assert client.get(f"/defects/{defect['id']}").json() == resolved


@pytest.mark.parametrize("distance_m, status", [(30.0, 200), (39.5, 200), (41.0, 422), (100.0, 422)])
def test_clean_crossing_distance_limit(client, distance_m, status):
    """**Validates: Requirements 1.13, 1.14, 1.15**"""
    defect = post_ok(client, impact(t=0))["defect"]
    lat, lon = offset(defect["latitude"], defect["longitude"], north_m=distance_m)
    r = client.post("/evidence", json=crossing(defect["id"], lat=lat, lon=lon, t=5))
    assert r.status_code == status, r.text
    expected_rows = 2 if status == 200 else 1
    assert len(evidence_rows(client)) == expected_rows
    if status != 200:
        assert client.get(f"/defects/{defect['id']}").json() == defect


def test_clean_crossing_impact_fields_stored_null(client):
    """**Validates: Requirements 1.14**"""
    defect = post_ok(client, impact(t=0))["defect"]
    body = crossing(
        defect["id"], t=5, impact_score=99, peak_acceleration=2.0, peak_jerk=50, rotation_rate=1
    )
    res = post_ok(client, body)
    assert res["defect"]["id"] == defect["id"]
    row = evidence_rows(client)[-1]
    assert row["type"] == "clean_crossing"
    assert row["road_defect_id"] == defect["id"]
    for col in ("impact_score", "peak_acceleration", "peak_jerk", "rotation_rate"):
        assert row[col] is None


def test_impact_road_defect_id_is_ignored(client):
    """**Validates: Requirements 1.9**"""
    a = post_ok(client, impact(t=0))["defect"]
    far_lat, far_lon = offset(DEMO_LAT, DEMO_LON, north_m=200)
    b = post_ok(client, impact(lat=far_lat, lon=far_lon, t=1))["defect"]
    near_lat, near_lon = offset(DEMO_LAT, DEMO_LON, east_m=3)
    res = post_ok(client, impact(lat=near_lat, lon=near_lon, t=2, road_defect_id=b["id"]))
    assert res["defect"]["id"] == a["id"]
    assert res["created"] is False
    assert client.get(f"/defects/{b['id']}").json()["positive_observation_count"] == 1


# --- Property 1: single-impact suspicion ------------------------------------


def test_property_1_single_impact_suspicion(client):
    """**Validates: Requirements 1.1, 3.3, 3.6, 5.7**"""
    res = post_ok(client, impact("dev-a", t=0, score=64))
    assert res["created"] is True
    assert res["duplicate"] is False
    assert res["transition"] is None
    d = res["defect"]
    assert d["state"] == "SUSPECTED"
    assert (d["positive_observation_count"], d["positive_unique_device_count"]) == (1, 1)
    assert (d["clean_crossing_count"], d["clean_unique_device_count"]) == (0, 0)
    assert d["confidence"] == pytest.approx(0.5)
    assert d["severity"] == 64.0
    assert (d["latitude"], d["longitude"]) == (DEMO_LAT, DEMO_LON)
    assert client.get("/defects").json() == [d]
    assert len(evidence_rows(client)) == 1


# --- Property 2: spatial clustering and centroid ---------------------------


def test_property_2_clustering_and_centroid(client):
    """**Validates: Requirements 3.1, 3.2, 3.3, 3.5, 3.6**"""
    first = post_ok(client, impact("a", t=0))
    points = [offset(DEMO_LAT, DEMO_LON, north_m=6), offset(DEMO_LAT, DEMO_LON, east_m=-9)]
    for i, (lat, lon) in enumerate(points, start=1):
        res = post_ok(client, impact(f"d{i}", lat=lat, lon=lon, t=i))
        assert res["created"] is False
        assert res["defect"]["id"] == first["defect"]["id"]
    d = res["defect"]
    all_lats = [DEMO_LAT] + [p[0] for p in points]
    all_lons = [DEMO_LON] + [p[1] for p in points]
    assert d["latitude"] == pytest.approx(sum(all_lats) / 3, abs=1e-12)
    assert d["longitude"] == pytest.approx(sum(all_lons) / 3, abs=1e-12)
    assert d["positive_observation_count"] == 3

    # Farther than 12 m from every active defect → new defect
    far_lat, far_lon = offset(d["latitude"], d["longitude"], north_m=25)
    res = post_ok(client, impact("far", lat=far_lat, lon=far_lon, t=10))
    assert res["created"] is True
    assert res["defect"]["id"] != d["id"]
    assert len(client.get("/defects").json()) == 2


def test_property_2_attaches_to_nearest(client):
    """**Validates: Requirements 3.1, 3.2**"""
    a = post_ok(client, impact("a", t=0))["defect"]
    b_lat, b_lon = offset(DEMO_LAT, DEMO_LON, north_m=20)
    b = post_ok(client, impact("b", lat=b_lat, lon=b_lon, t=1))["defect"]
    assert a["id"] != b["id"]
    # 11 m north of A (9 m from B) → B is nearest
    lat, lon = offset(DEMO_LAT, DEMO_LON, north_m=11)
    res = post_ok(client, impact("c", lat=lat, lon=lon, t=2))
    assert res["defect"]["id"] == b["id"]


def test_first_and_last_seen_from_impact_timestamps(client):
    """**Validates: Requirements 3.7**"""
    post_ok(client, impact("a", t=10))
    post_ok(client, impact("b", t=0))
    d = post_ok(client, impact("c", t=5))["defect"]
    assert d["first_seen"] == ts(0)
    assert d["last_seen"] == ts(10)


# --- Property 3: independent confirmation -----------------------------------


def test_property_3_three_devices_confirm(client):
    """**Validates: Requirements 5.7, 5.8**"""
    states, transitions = [], []
    for i in range(3):
        res = post_ok(client, impact(f"dev-{i}", t=i))
        states.append(res["defect"]["state"])
        transitions.append(res["transition"])
    assert states == ["SUSPECTED", "SUSPECTED", "CONFIRMED"]
    assert transitions == [None, None, {"from": "SUSPECTED", "to": "CONFIRMED"}]
    assert round(res["defect"]["confidence"], 6) == 0.7


@pytest.mark.parametrize("impacts_per_device", [1, 3, 6])
def test_property_3_two_devices_never_confirm(client, impacts_per_device):
    """**Validates: Requirements 5.9**"""
    for k in range(impacts_per_device):
        for dev in ("a", "b"):
            res = post_ok(client, impact(dev, t=10 * k + (dev == "b")))
            assert res["duplicate"] is False
    d = res["defect"]
    assert d["state"] == "SUSPECTED"
    assert d["positive_unique_device_count"] == 2
    assert d["positive_observation_count"] == 2 * impacts_per_device


# --- Property 4: repeat-device discount -------------------------------------


@pytest.mark.parametrize("k", [2, 4, 8])
def test_property_4_repeat_device_discount(make_client, k):
    """**Validates: Requirements 3.6, 4.1, 4.6, 5.4**"""
    single = make_client()
    for i in range(k):
        res_single = post_ok(single, impact("same-device", t=10 * i))
    many = make_client()
    for i in range(k):
        res_many = post_ok(many, impact(f"device-{i}", t=10 * i))
    ds, dm = res_single["defect"], res_many["defect"]
    assert (ds["positive_unique_device_count"], ds["positive_observation_count"]) == (1, k)
    assert (dm["positive_unique_device_count"], dm["positive_observation_count"]) == (k, k)
    assert ds["confidence"] < dm["confidence"]
    assert ds["state"] == "SUSPECTED"


# --- Property 5: monotonicity -----------------------------------------------


def test_property_5_monotonicity_mixed_sequence(client):
    """**Validates: Requirements 4.4, 4.5**"""
    first = post_ok(client, impact("p0", t=0))["defect"]
    defect_id, prev = first["id"], first["confidence"]
    # (type, device) sequence mixing new and repeat devices
    seq = [
        ("impact", "p1"), ("clean", "n0"), ("clean", "n0"), ("impact", "p0"),
        ("impact", "p2"), ("clean", "n1"), ("impact", "p3"), ("clean", "n2"),
        ("clean", "n3"), ("clean", "n1"), ("impact", "p3"), ("clean", "n4"),
    ]
    for i, (kind, dev) in enumerate(seq, start=1):
        t = 10 * i
        body = impact(dev, t=t) if kind == "impact" else crossing(defect_id, dev, t=t)
        res = post_ok(client, body)
        assert res["duplicate"] is False
        conf = res["defect"]["confidence"]
        if kind == "impact":
            assert conf >= prev
        else:
            assert conf <= prev
        prev = conf


def test_suspected_with_clean_crossings_stays_suspected(client):
    """**Validates: Requirements 5.6**"""
    d = post_ok(client, impact("p0", t=0))["defect"]
    prev = d["confidence"]
    for i in range(8):
        res = post_ok(client, crossing(d["id"], f"n{i % 5}", t=10 + 10 * i))
        assert res["defect"]["state"] == "SUSPECTED"
        assert res["defect"]["confidence"] < prev
        assert res["transition"] is None
        prev = res["defect"]["confidence"]


# --- Property 6: repair lifecycle -------------------------------------------


@pytest.mark.parametrize("p", [3, 5, 8])
def test_property_6_repair_lifecycle(client, p):
    """**Validates: Requirements 5.1, 5.2, 5.3, 5.5, 5.7**"""
    defect = confirmed_defect(client, p)
    expected_resolved = max(6, 2 * p)
    expected_likely = next(n for n in range(3, expected_resolved + 1) if n > (4 * p - 4) / 3)
    transitions = {}
    for n in range(1, expected_resolved + 1):
        res = post_ok(client, crossing(defect["id"], f"neg-{n}", t=100 + n))
        assert res["defect"]["clean_unique_device_count"] == n
        if res["transition"] is not None:
            transitions[n] = res["transition"]
    assert transitions == {
        expected_likely: {"from": "CONFIRMED", "to": "LIKELY_REPAIRED"},
        expected_resolved: {"from": "LIKELY_REPAIRED", "to": "RESOLVED"},
    }


def test_likely_repaired_returns_to_confirmed_on_new_impacts(client):
    """**Validates: Requirements 5.4**"""
    defect = confirmed_defect(client, 3)
    for n in range(3):
        res = post_ok(client, crossing(defect["id"], f"neg-{n}", t=100 + n))
    assert res["defect"]["state"] == "LIKELY_REPAIRED"
    # alpha must exceed 0.68/0.32 * beta (beta = 7.5) → P ≥ 8
    for i in range(3, 20):
        res = post_ok(client, impact(f"pos-{i}", t=200 + i))
        if res["transition"]:
            assert res["transition"] == {"from": "LIKELY_REPAIRED", "to": "CONFIRMED"}
            break
    assert res["defect"]["state"] == "CONFIRMED"


# --- Property 7: resolved is terminal ---------------------------------------


def test_property_7_resolved_is_terminal(client):
    """**Validates: Requirements 1.12, 3.4, 5.10, 7.2, 7.3**"""
    defect = confirmed_defect(client)
    resolved = resolve_defect(client, defect["id"])
    assert client.get("/defects").json() == []
    assert client.get(f"/defects/{defect['id']}").json()["state"] == "RESOLVED"
    assert client.post("/evidence", json=crossing(defect["id"], t=900)).status_code == 409

    res = post_ok(client, impact("new-dev", t=1000))
    assert res["created"] is True
    assert res["defect"]["id"] != defect["id"]
    assert res["defect"]["state"] == "SUSPECTED"
    assert client.get(f"/defects/{defect['id']}").json() == resolved
    assert [d["id"] for d in client.get("/defects").json()] == [res["defect"]["id"]]


# --- Property 8: idempotent retry and dedupe --------------------------------


def test_property_8_identical_impact_retry(client):
    """**Validates: Requirements 2.1, 2.2, 2.3**"""
    body = impact("dev-a", t=0)
    first = post_ok(client, body)
    second = post_ok(client, body)
    assert second["duplicate"] is True
    assert second["created"] is False
    assert second["transition"] is None
    assert second["evidence_id"] == first["evidence_id"]
    assert second["defect"] == first["defect"]
    assert len(evidence_rows(client)) == 1


def test_property_8_identical_crossing_retry(client):
    """**Validates: Requirements 2.1, 2.2, 2.3**"""
    defect = confirmed_defect(client)
    body = crossing(defect["id"], "neg", t=50)
    first = post_ok(client, body)
    for _ in range(3):
        again = post_ok(client, body)
        assert again["duplicate"] is True
        assert again["defect"] == first["defect"]
    assert first["defect"]["clean_crossing_count"] == 1


@pytest.mark.parametrize(
    "dt, move_m, is_dup",
    [
        (0.0, 0.0, True),
        (1.5, 5.0, True),
        (-2.0, 11.0, True),
        (2.0, 0.0, True),
        (2.5, 0.0, False),  # outside time window
        (-3.0, 0.0, False),
        (1.0, 14.0, False),  # outside cluster radius
    ],
)
def test_property_8_impact_dedupe_window(client, dt, move_m, is_dup):
    """**Validates: Requirements 2.1, 2.2**"""
    first = post_ok(client, impact("dev-a", t=100))
    lat, lon = offset(DEMO_LAT, DEMO_LON, north_m=move_m)
    res = post_ok(client, impact("dev-a", lat=lat, lon=lon, t=100 + dt, score=90))
    assert res["duplicate"] is is_dup
    if is_dup:
        assert res["defect"] == first["defect"]
        assert len(evidence_rows(client)) == 1
    else:
        assert len(evidence_rows(client)) == 2


def test_dedupe_requires_same_device_type_and_target(client):
    """**Validates: Requirements 2.1**"""
    d1 = post_ok(client, impact("dev-a", t=0))["defect"]
    # Different device, same time and place: not a duplicate
    assert post_ok(client, impact("dev-b", t=0))["duplicate"] is False
    # Same device, different type: not a duplicate
    assert post_ok(client, crossing(d1["id"], "dev-a", t=0))["duplicate"] is False
    # Clean crossing on a different defect from the same device at the same time
    lat2, lon2 = offset(DEMO_LAT, DEMO_LON, north_m=100)
    d2 = post_ok(client, impact("dev-c", lat=lat2, lon=lon2, t=0))["defect"]
    res = post_ok(client, crossing(d2["id"], "dev-a", lat=lat2, lon=lon2, t=0))
    assert res["duplicate"] is False
    # Same device, same defect, within window → duplicate
    assert post_ok(client, crossing(d2["id"], "dev-a", lat=lat2, lon=lon2, t=1))["duplicate"] is True


# --- Property 9: real/simulated equivalence ---------------------------------


def _sequence(sim: bool) -> list[tuple[str, dict]]:
    seq: list[tuple[str, dict]] = []
    for i in range(5):
        lat, lon = offset(DEMO_LAT, DEMO_LON, north_m=i, east_m=-i)
        seq.append(("impact", impact(f"p{i}", lat=lat, lon=lon, t=i, score=50 + 7 * i,
                                     is_simulated=sim)))
    seq.append(("impact", impact("p0", t=20, score=90, is_simulated=sim)))
    for j in range(9):
        seq.append(("clean", crossing(1, f"n{j % 7}", t=100 + 10 * j, is_simulated=sim)))
    return seq


def test_property_9_simulated_equivalence(make_client):
    """**Validates: Requirements 1.2**"""
    real, sim = make_client(), make_client()
    strip = lambda r: {**r, "defect": {k: v for k, v in r["defect"].items()
                                        if k not in ("created_at", "updated_at")}}
    for (_, body_r), (_, body_s) in zip(_sequence(False), _sequence(True)):
        res_r = strip(post_ok(real, body_r))
        res_s = strip(post_ok(sim, body_s))
        assert res_r == res_s
    assert [r["is_simulated"] for r in evidence_rows(real)] == [0] * 15
    assert [r["is_simulated"] for r in evidence_rows(sim)] == [1] * 15
    final = sim.get("/defects/1").json()
    assert final["state"] in ("LIKELY_REPAIRED", "RESOLVED")


# --- concurrency (Requirement 8.5) ------------------------------------------


def test_concurrent_impacts_produce_one_defect(client):
    """**Validates: Requirements 8.4, 8.5**"""
    workers = 8
    barrier = threading.Barrier(workers)

    def send(i: int) -> int:
        lat, lon = offset(DEMO_LAT, DEMO_LON, north_m=(i % 3), east_m=-(i % 4))
        barrier.wait()
        return client.post("/evidence", json=impact(f"c{i}", lat=lat, lon=lon, t=i)).status_code

    with ThreadPoolExecutor(max_workers=workers) as pool:
        codes = list(pool.map(send, range(workers)))
    assert codes == [200] * workers
    defects = client.get("/defects").json()
    assert len(defects) == 1
    assert defects[0]["positive_observation_count"] == workers
    assert defects[0]["positive_unique_device_count"] == workers
    assert defects[0]["state"] == "CONFIRMED"


# --- demo reset (Requirements 7.5, 7.6) -------------------------------------


def test_demo_reset_enabled(client):
    """**Validates: Requirements 7.5**"""
    defect = confirmed_defect(client)
    post_ok(client, crossing(defect["id"], t=50))
    r = client.post("/demo/reset")
    assert r.status_code == 200
    assert r.json() == {"status": "reset"}
    assert client.get("/defects").json() == []
    assert client.get(f"/defects/{defect['id']}").status_code == 404
    assert evidence_rows(client) == []
    # Ids restart, so a fresh demo is deterministic
    assert post_ok(client, impact(t=0))["defect"]["id"] == 1


def test_demo_reset_disabled(make_client):
    """**Validates: Requirements 7.6**"""
    client = make_client(DEMO_RESET_ENABLED=False)
    defect = confirmed_defect(client)
    rows_before = evidence_rows(client)
    r = client.post("/demo/reset")
    assert 400 <= r.status_code < 500
    assert r.json() != {"status": "reset"}
    assert client.get(f"/defects/{defect['id']}").json() == defect
    assert len(evidence_rows(client)) == len(rows_before)


# --- full demo sequence (Requirement 22.1–22.4) -----------------------------

SCORES = [58, 72, 64, 69, 55, 76, 61, 67]


def spiral_position(k: int) -> tuple[float, float]:
    theta = math.radians(k * 137.508)
    r = 6.0 * math.sqrt(((k - 1) % 16 + 1) / 16)
    dlat = r * math.cos(theta) / 111_320
    dlon = r * math.sin(theta) / (111_320 * math.cos(math.radians(DEMO_LAT)))
    return DEMO_LAT + dlat, DEMO_LON + dlon


def demo_trip(k: int, kind: str, defect_id: int | None = None) -> dict:
    lat, lon = spiral_position(k)
    body = {
        "device_id": str(uuid.uuid4()),
        "type": kind,
        "latitude": lat,
        "longitude": lon,
        "timestamp": ts(k),
        "speed_mps": 8 + (3 * k) % 7,
        "gps_accuracy_m": 3 + k % 6,
        "is_simulated": True,
    }
    if kind == "impact":
        score = SCORES[(k - 1) % 8]
        body.update(
            impact_score=score,
            peak_acceleration=0.4 + score / 50,
            peak_jerk=10 + score / 2,
            rotation_rate=0.6 + 0.1 * (k % 5),
        )
    else:
        body["road_defect_id"] = defect_id
    return body


def test_full_demo_sequence(client):
    """**Validates: Requirements 22.1, 22.2, 22.3, 22.4, 5.7**"""
    assert client.post("/demo/reset").json() == {"status": "reset"}

    # Phase 1: 11 impact trips (Low @ 1x for 3, then Medium for 8)
    defect_id = None
    for k in range(1, 12):
        res = post_ok(client, demo_trip(k, "impact"))
        d = res["defect"]
        assert res["created"] is (k == 1)
        if k == 1:
            defect_id = d["id"]
        assert d["id"] == defect_id
        assert d["positive_unique_device_count"] == k
        if k < 3:
            assert d["state"] == "SUSPECTED" and res["transition"] is None
            assert [x["state"] for x in client.get("/defects").json()] == ["SUSPECTED"]
        elif k == 3:
            assert res["transition"] == {"from": "SUSPECTED", "to": "CONFIRMED"}
            assert round(d["confidence"], 6) == 0.7
        else:
            assert d["state"] == "CONFIRMED" and res["transition"] is None
    assert d["confidence"] == pytest.approx(23 / 26)
    assert round(d["confidence"], 2) == 0.88
    assert d["clean_unique_device_count"] == 0
    assert 55 <= d["severity"] <= 76

    # Phase 2: repaired, clean-crossing trips with fresh devices
    for n in range(1, 23):
        k = 11 + n
        res = post_ok(client, demo_trip(k, "clean_crossing", defect_id))
        d = res["defect"]
        assert d["clean_unique_device_count"] == n
        assert d["positive_unique_device_count"] == 11
        if n == 14:
            assert res["transition"] == {"from": "CONFIRMED", "to": "LIKELY_REPAIRED"}
            assert d["confidence"] == pytest.approx(23 / 47)
        elif n == 22:
            assert res["transition"] == {"from": "LIKELY_REPAIRED", "to": "RESOLVED"}
            assert d["confidence"] == pytest.approx(23 / 59)
        else:
            assert res["transition"] is None
            assert d["state"] == ("CONFIRMED" if n < 14 else "LIKELY_REPAIRED")
        if n == 21:
            assert round(d["confidence"], 6) == 0.4

    assert client.get("/defects").json() == []
    assert client.get(f"/defects/{defect_id}").json()["state"] == "RESOLVED"
    # The simulator would see 409 on a further crossing
    r = client.post("/evidence", json=demo_trip(34, "clean_crossing", defect_id))
    assert r.status_code == 409
