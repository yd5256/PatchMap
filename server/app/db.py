"""SQLite data access with stdlib ``sqlite3`` (no ORM, bound parameters only)."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

from .fusion import RESOLVED, haversine_m

SCHEMA = """
CREATE TABLE IF NOT EXISTS road_defect (
  id                            INTEGER PRIMARY KEY AUTOINCREMENT,
  latitude                      REAL    NOT NULL,
  longitude                     REAL    NOT NULL,
  state                         TEXT    NOT NULL CHECK (state IN ('SUSPECTED','CONFIRMED','LIKELY_REPAIRED','RESOLVED')),
  confidence                    REAL    NOT NULL,
  severity                      REAL    NOT NULL,
  positive_observation_count    INTEGER NOT NULL DEFAULT 0,
  positive_unique_device_count  INTEGER NOT NULL DEFAULT 0,
  clean_crossing_count          INTEGER NOT NULL DEFAULT 0,
  clean_unique_device_count     INTEGER NOT NULL DEFAULT 0,
  first_seen                    TEXT    NOT NULL,
  last_seen                     TEXT    NOT NULL,
  created_at                    TEXT    NOT NULL,
  updated_at                    TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS evidence (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  road_defect_id     INTEGER NOT NULL REFERENCES road_defect(id) ON DELETE CASCADE,
  device_id          TEXT    NOT NULL,
  type               TEXT    NOT NULL CHECK (type IN ('impact','clean_crossing')),
  latitude           REAL    NOT NULL,
  longitude          REAL    NOT NULL,
  timestamp          TEXT    NOT NULL,
  speed_mps          REAL,
  gps_accuracy_m     REAL,
  impact_score       REAL,
  peak_acceleration  REAL,
  peak_jerk          REAL,
  rotation_rate      REAL,
  is_simulated       INTEGER NOT NULL DEFAULT 0,
  created_at         TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_evidence_defect ON evidence(road_defect_id);
CREATE INDEX IF NOT EXISTS idx_evidence_device ON evidence(device_id, type, timestamp);
"""

# --- timestamps -------------------------------------------------------------

def to_db_ts(dt: datetime) -> str:
    """Fixed-width UTC string with microseconds, so text order == time order."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def from_db_ts(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


# --- connection and schema --------------------------------------------------

def connect(db_path: str) -> sqlite3.Connection:
    """Open a connection in autocommit mode; callers manage transactions explicitly."""
    if db_path != ":memory:":
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, isolation_level=None, check_same_thread=False, timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db(db_path: str) -> None:
    conn = connect(db_path)
    try:
        conn.executescript(SCHEMA)
    finally:
        conn.close()


# --- repository -------------------------------------------------------------

def insert_defect(
    conn: sqlite3.Connection,
    *,
    latitude: float,
    longitude: float,
    state: str,
    confidence: float,
    severity: float,
    first_seen: str,
    last_seen: str,
    now: str,
) -> int:
    cur = conn.execute(
        """
        INSERT INTO road_defect (
          latitude, longitude, state, confidence, severity,
          positive_observation_count, positive_unique_device_count,
          clean_crossing_count, clean_unique_device_count,
          first_seen, last_seen, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, ?, ?, ?, ?)
        """,
        (latitude, longitude, state, confidence, severity, first_seen, last_seen, now, now),
    )
    return int(cur.lastrowid)


def insert_evidence(
    conn: sqlite3.Connection,
    *,
    road_defect_id: int,
    device_id: str,
    type: str,
    latitude: float,
    longitude: float,
    timestamp: str,
    speed_mps: Optional[float],
    gps_accuracy_m: Optional[float],
    impact_score: Optional[float],
    peak_acceleration: Optional[float],
    peak_jerk: Optional[float],
    rotation_rate: Optional[float],
    is_simulated: bool,
    now: str,
) -> int:
    cur = conn.execute(
        """
        INSERT INTO evidence (
          road_defect_id, device_id, type, latitude, longitude, timestamp,
          speed_mps, gps_accuracy_m, impact_score, peak_acceleration,
          peak_jerk, rotation_rate, is_simulated, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            road_defect_id,
            device_id,
            type,
            latitude,
            longitude,
            timestamp,
            speed_mps,
            gps_accuracy_m,
            impact_score,
            peak_acceleration,
            peak_jerk,
            rotation_rate,
            1 if is_simulated else 0,
            now,
        ),
    )
    return int(cur.lastrowid)


def find_duplicate(
    conn: sqlite3.Connection,
    *,
    device_id: str,
    type: str,
    timestamp: datetime,
    window_s: float,
    latitude: float,
    longitude: float,
    radius_m: float,
    road_defect_id: Optional[int] = None,
) -> Optional[sqlite3.Row]:
    """Find a stored row with the same device and type, timestamp within
    ``window_s`` either way, and the same target (same defect id for clean
    crossings, position within ``radius_m`` for impacts)."""
    lo = to_db_ts(timestamp - timedelta(seconds=window_s))
    hi = to_db_ts(timestamp + timedelta(seconds=window_s))
    rows = conn.execute(
        """
        SELECT * FROM evidence
        WHERE device_id = ? AND type = ? AND timestamp BETWEEN ? AND ?
        ORDER BY id
        """,
        (device_id, type, lo, hi),
    ).fetchall()
    for row in rows:
        if type == "clean_crossing":
            if row["road_defect_id"] == road_defect_id:
                return row
        elif haversine_m(latitude, longitude, row["latitude"], row["longitude"]) <= radius_m:
            return row
    return None


def list_active_defects(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT * FROM road_defect WHERE state != ? ORDER BY id", (RESOLVED,)
    ).fetchall()


def get_defect(conn: sqlite3.Connection, defect_id: int) -> Optional[sqlite3.Row]:
    return conn.execute("SELECT * FROM road_defect WHERE id = ?", (defect_id,)).fetchone()


def defect_aggregates(conn: sqlite3.Connection, defect_id: int) -> dict[str, Any]:
    """Recompute counts, centroid, first/last seen, and impact scores (newest first)."""
    imp = conn.execute(
        """
        SELECT COUNT(*) AS o, COUNT(DISTINCT device_id) AS p,
               AVG(latitude) AS lat, AVG(longitude) AS lon,
               MIN(timestamp) AS first_seen, MAX(timestamp) AS last_seen
        FROM evidence WHERE road_defect_id = ? AND type = 'impact'
        """,
        (defect_id,),
    ).fetchone()
    clean = conn.execute(
        """
        SELECT COUNT(*) AS c, COUNT(DISTINCT device_id) AS n
        FROM evidence WHERE road_defect_id = ? AND type = 'clean_crossing'
        """,
        (defect_id,),
    ).fetchone()
    scores = conn.execute(
        """
        SELECT device_id, impact_score FROM evidence
        WHERE road_defect_id = ? AND type = 'impact'
        ORDER BY timestamp DESC, id DESC
        """,
        (defect_id,),
    ).fetchall()
    return {
        "O": int(imp["o"]),
        "P": int(imp["p"]),
        "C": int(clean["c"]),
        "N": int(clean["n"]),
        "latitude": imp["lat"],
        "longitude": imp["lon"],
        "first_seen": imp["first_seen"],
        "last_seen": imp["last_seen"],
        "impacts_newest_first": [(r["device_id"], float(r["impact_score"])) for r in scores],
    }


def update_defect(
    conn: sqlite3.Connection,
    defect_id: int,
    *,
    latitude: float,
    longitude: float,
    state: str,
    confidence: float,
    severity: float,
    positive_observation_count: int,
    positive_unique_device_count: int,
    clean_crossing_count: int,
    clean_unique_device_count: int,
    first_seen: str,
    last_seen: str,
    updated_at: str,
) -> None:
    conn.execute(
        """
        UPDATE road_defect SET
          latitude = ?, longitude = ?, state = ?, confidence = ?, severity = ?,
          positive_observation_count = ?, positive_unique_device_count = ?,
          clean_crossing_count = ?, clean_unique_device_count = ?,
          first_seen = ?, last_seen = ?, updated_at = ?
        WHERE id = ?
        """,
        (
            latitude,
            longitude,
            state,
            confidence,
            severity,
            positive_observation_count,
            positive_unique_device_count,
            clean_crossing_count,
            clean_unique_device_count,
            first_seen,
            last_seen,
            updated_at,
            defect_id,
        ),
    )


def reset_all(conn: sqlite3.Connection) -> None:
    """Delete all evidence and defects and restart id sequences (demo determinism)."""
    conn.execute("DELETE FROM evidence")
    conn.execute("DELETE FROM road_defect")
    conn.execute(
        "DELETE FROM sqlite_sequence WHERE name IN (?, ?)", ("evidence", "road_defect")
    )
