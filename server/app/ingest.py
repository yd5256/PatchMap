"""Evidence ingestion: one function for real and simulated evidence alike.

``is_simulated`` is stored for transparency only and never affects fusion.
"""

from __future__ import annotations

import sqlite3
import threading

from . import db, fusion
from .config import Config
from .schemas import DefectOut, EvidenceIn, IngestResult, Transition

# Serializes every ingest (cluster lookup through commit) within the process.
INGEST_LOCK = threading.Lock()


class IngestError(Exception):
    status_code = 400

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail


class DefectNotFound(IngestError):
    status_code = 404


class DefectResolved(IngestError):
    status_code = 409


class CrossingTooFar(IngestError):
    status_code = 422


def _api_ts(db_ts: str) -> str:
    """ISO-8601 UTC string with second precision (``2026-01-01T12:00:00Z``)."""
    return db.from_db_ts(db_ts).strftime("%Y-%m-%dT%H:%M:%SZ")


def defect_out(row: sqlite3.Row) -> DefectOut:
    return DefectOut(
        id=row["id"],
        latitude=row["latitude"],
        longitude=row["longitude"],
        state=row["state"],
        confidence=row["confidence"],
        severity=row["severity"],
        positive_observation_count=row["positive_observation_count"],
        positive_unique_device_count=row["positive_unique_device_count"],
        clean_crossing_count=row["clean_crossing_count"],
        clean_unique_device_count=row["clean_unique_device_count"],
        first_seen=_api_ts(row["first_seen"]),
        last_seen=_api_ts(row["last_seen"]),
        created_at=_api_ts(row["created_at"]),
        updated_at=_api_ts(row["updated_at"]),
    )


def ingest_evidence(conn: sqlite3.Connection, evidence: EvidenceIn, cfg: Config) -> IngestResult:
    """Ingest one evidence item atomically. Raises ``IngestError`` subclasses
    for 404 / 409 / 422 outcomes; on any error nothing is written."""
    with INGEST_LOCK:
        conn.execute("BEGIN IMMEDIATE")
        try:
            result = _ingest(conn, evidence, cfg)
        except BaseException:
            conn.execute("ROLLBACK")
            raise
        conn.execute("COMMIT")
        return result


def _ingest(conn: sqlite3.Connection, ev: EvidenceIn, cfg: Config) -> IngestResult:
    now = db.to_db_ts(db.utcnow())
    ts = db.to_db_ts(ev.timestamp)
    is_impact = ev.type == "impact"

    # Clean-crossing target checks (part of request validation, before dedupe).
    if not is_impact:
        target = db.get_defect(conn, ev.road_defect_id)
        if target is None:
            raise DefectNotFound(f"road defect {ev.road_defect_id} not found")
        if target["state"] == fusion.RESOLVED:
            raise DefectResolved(f"road defect {ev.road_defect_id} is resolved")
        dist = fusion.haversine_m(ev.latitude, ev.longitude, target["latitude"], target["longitude"])
        if dist > cfg.CLEAN_CROSSING_MAX_DISTANCE_M:
            raise CrossingTooFar(
                f"clean crossing is {dist:.1f} m from road defect {ev.road_defect_id} "
                f"(max {cfg.CLEAN_CROSSING_MAX_DISTANCE_M:g} m)"
            )

    # Idempotent retries: return the matched row's defect unchanged.
    dup = db.find_duplicate(
        conn,
        device_id=ev.device_id,
        type=ev.type,
        timestamp=ev.timestamp,
        window_s=cfg.DEDUPE_WINDOW_S,
        latitude=ev.latitude,
        longitude=ev.longitude,
        radius_m=cfg.CLUSTER_RADIUS_M,
        road_defect_id=None if is_impact else ev.road_defect_id,
    )
    if dup is not None:
        dup_defect = db.get_defect(conn, dup["road_defect_id"])
        return IngestResult(
            evidence_id=dup["id"],
            duplicate=True,
            created=False,
            transition=None,
            defect=defect_out(dup_defect),
        )

    created = False
    if is_impact:
        active = [(r["id"], r["latitude"], r["longitude"]) for r in db.list_active_defects(conn)]
        defect_id = fusion.find_cluster(active, ev.latitude, ev.longitude, cfg.CLUSTER_RADIUS_M)
        if defect_id is None:
            defect_id = db.insert_defect(
                conn,
                latitude=ev.latitude,
                longitude=ev.longitude,
                state=fusion.SUSPECTED,
                confidence=fusion.compute_confidence(0, 0, 0, 0, cfg),
                severity=0.0,
                first_seen=ts,
                last_seen=ts,
                now=now,
            )
            created = True
    else:
        defect_id = ev.road_defect_id

    prev_state = db.get_defect(conn, defect_id)["state"]

    evidence_id = db.insert_evidence(
        conn,
        road_defect_id=defect_id,
        device_id=ev.device_id,
        type=ev.type,
        latitude=ev.latitude,
        longitude=ev.longitude,
        timestamp=ts,
        speed_mps=ev.speed_mps,
        gps_accuracy_m=ev.gps_accuracy_m,
        impact_score=ev.impact_score if is_impact else None,
        peak_acceleration=ev.peak_acceleration if is_impact else None,
        peak_jerk=ev.peak_jerk if is_impact else None,
        rotation_rate=ev.rotation_rate if is_impact else None,
        is_simulated=ev.is_simulated,
        now=now,
    )

    agg = db.defect_aggregates(conn, defect_id)
    confidence = fusion.compute_confidence(agg["P"], agg["O"], agg["N"], agg["C"], cfg)
    severity = fusion.aggregate_severity(agg["impacts_newest_first"], cfg.SEVERITY_WINDOW)
    new_state = fusion.next_state(prev_state, agg["P"], agg["N"], confidence, cfg)

    db.update_defect(
        conn,
        defect_id,
        latitude=agg["latitude"],
        longitude=agg["longitude"],
        state=new_state,
        confidence=confidence,
        severity=severity,
        positive_observation_count=agg["O"],
        positive_unique_device_count=agg["P"],
        clean_crossing_count=agg["C"],
        clean_unique_device_count=agg["N"],
        first_seen=agg["first_seen"],
        last_seen=agg["last_seen"],
        updated_at=now,
    )

    transition = (
        Transition(**{"from": prev_state, "to": new_state}) if new_state != prev_state else None
    )
    return IngestResult(
        evidence_id=evidence_id,
        duplicate=False,
        created=created,
        transition=transition,
        defect=defect_out(db.get_defect(conn, defect_id)),
    )
