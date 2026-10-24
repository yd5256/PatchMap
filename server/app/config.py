"""Single source of every backend tunable.

No other backend module hard-codes these values. Tests (or the environment)
can override the database path and the demo-reset toggle:

- ``POTHOLE_MESH_DB_PATH``: SQLite file path (default ``server/data/pothole_mesh.db``)
- ``POTHOLE_MESH_DEMO_RESET_ENABLED``: ``0``/``false`` disables ``POST /demo/reset``
"""

from __future__ import annotations

import os
from dataclasses import dataclass, replace
from pathlib import Path

DEFAULT_DB_PATH = str(Path(__file__).resolve().parent.parent / "data" / "pothole_mesh.db")


@dataclass(frozen=True)
class Config:
    # Spatial clustering
    CLUSTER_RADIUS_M: float = 12.0

    # Confidence weights: alpha / (alpha + beta)
    PRIOR_ALPHA: float = 1.0
    W_POS_DEVICE: float = 2.0
    W_POS_REPEAT: float = 0.25
    PRIOR_BETA: float = 3.0
    W_NEG_DEVICE: float = 1.5
    W_NEG_REPEAT: float = 0.15

    # Lifecycle thresholds
    CONFIRM_MIN_POS_DEVICES: int = 3
    CONFIRM_MIN_CONFIDENCE: float = 0.68
    LIKELY_REPAIRED_MIN_NEG_DEVICES: int = 3
    LIKELY_REPAIRED_MAX_CONFIDENCE: float = 0.50  # strictly below
    RESOLVED_MIN_NEG_DEVICES: int = 6
    RESOLVED_MAX_CONFIDENCE: float = 0.40  # strictly below
    CONFIDENCE_ROUND_DECIMALS: int = 6

    # Severity
    SEVERITY_WINDOW: int = 20

    # Dedupe and validation limits
    DEDUPE_WINDOW_S: float = 2.0
    MAX_FUTURE_SKEW_S: float = 300.0
    MAX_GPS_ACCURACY_M: float = 30.0
    CLEAN_CROSSING_MAX_DISTANCE_M: float = 40.0
    MAX_DEVICE_ID_LEN: int = 64

    # Storage and demo
    DB_PATH: str = DEFAULT_DB_PATH
    DEMO_RESET_ENABLED: bool = True


# Defaults used by request validation (schemas) and pure fusion functions.
DEFAULTS = Config()


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off", ""}


def load_config(**overrides: object) -> Config:
    """Build a Config from defaults, environment, then explicit overrides."""
    cfg = replace(
        DEFAULTS,
        DB_PATH=os.environ.get("POTHOLE_MESH_DB_PATH", DEFAULTS.DB_PATH),
        DEMO_RESET_ENABLED=_env_bool("POTHOLE_MESH_DEMO_RESET_ENABLED", DEFAULTS.DEMO_RESET_ENABLED),
    )
    return replace(cfg, **overrides) if overrides else cfg
