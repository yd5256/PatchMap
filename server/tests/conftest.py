"""Shared fixtures: a fresh temporary SQLite file and TestClient per test.

No uvicorn server or network is involved; requests go through Starlette's
in-process TestClient. The default database file is never touched.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from contextlib import ExitStack
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import load_config
from app.main import create_app


@pytest.fixture
def make_client(tmp_path: Path) -> Iterator[Callable[..., TestClient]]:
    """Factory for TestClients, each backed by its own temp SQLite file.

    Keyword arguments are forwarded as Config overrides
    (e.g. ``make_client(DEMO_RESET_ENABLED=False)``). The client exposes the
    DB file path as ``client.db_path``.
    """
    stack = ExitStack()
    counter = 0

    def factory(**overrides: object) -> TestClient:
        nonlocal counter
        counter += 1
        db_path = str(tmp_path / f"test_{counter}.db")
        cfg = load_config(DB_PATH=db_path, **overrides)
        client = stack.enter_context(TestClient(create_app(cfg)))
        client.db_path = db_path  # type: ignore[attr-defined]
        return client

    with stack:
        yield factory


@pytest.fixture
def client(make_client: Callable[..., TestClient]) -> TestClient:
    return make_client()
