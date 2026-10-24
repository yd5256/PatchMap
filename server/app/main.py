"""FastAPI app exposing the five Pothole Mesh endpoints.

Run from ``server/``: ``uvicorn app.main:app --host 0.0.0.0 --port 8000``.

Security note: the API is intentionally unauthenticated for the hackathon LAN
demo. Run it only on a trusted network; ``POTHOLE_MESH_DEMO_RESET_ENABLED=0``
disables ``POST /demo/reset``.
"""

from __future__ import annotations

import sqlite3
import threading
from collections.abc import Iterator
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException

from . import db
from .config import Config, load_config
from .ingest import INGEST_LOCK, IngestError, defect_out, ingest_evidence
from .schemas import DefectOut, EvidenceIn, IngestResult


def create_app(cfg: Optional[Config] = None) -> FastAPI:
    config = cfg if cfg is not None else load_config()
    schema_lock = threading.Lock()
    schema_ready = False

    def ensure_schema() -> None:
        nonlocal schema_ready
        with schema_lock:
            if not schema_ready:
                db.init_db(config.DB_PATH)
                schema_ready = True

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        ensure_schema()
        yield

    app = FastAPI(title="Pothole Mesh", version="0.1.0", lifespan=lifespan)
    app.state.config = config

    def get_conn() -> Iterator[sqlite3.Connection]:
        # Also covers clients that skip the lifespan (e.g. TestClient without `with`).
        ensure_schema()
        conn = db.connect(config.DB_PATH)
        try:
            yield conn
        finally:
            conn.close()

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/evidence", response_model=IngestResult)
    def post_evidence(
        evidence: EvidenceIn, conn: sqlite3.Connection = Depends(get_conn)
    ) -> IngestResult:
        try:
            return ingest_evidence(conn, evidence, config)
        except IngestError as exc:
            raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc

    @app.get("/defects", response_model=list[DefectOut])
    def list_defects(conn: sqlite3.Connection = Depends(get_conn)) -> list[DefectOut]:
        return [defect_out(row) for row in db.list_active_defects(conn)]

    @app.get("/defects/{defect_id}", response_model=DefectOut)
    def get_defect(defect_id: int, conn: sqlite3.Connection = Depends(get_conn)) -> DefectOut:
        row = db.get_defect(conn, defect_id)
        if row is None:
            raise HTTPException(status_code=404, detail=f"road defect {defect_id} not found")
        return defect_out(row)

    @app.post("/demo/reset")
    def demo_reset(conn: sqlite3.Connection = Depends(get_conn)) -> dict[str, str]:
        if not config.DEMO_RESET_ENABLED:
            raise HTTPException(status_code=403, detail="demo reset is disabled")
        with INGEST_LOCK:
            conn.execute("BEGIN IMMEDIATE")
            try:
                db.reset_all(conn)
            except BaseException:
                conn.execute("ROLLBACK")
                raise
            conn.execute("COMMIT")
        return {"status": "reset"}

    return app


app = create_app()
