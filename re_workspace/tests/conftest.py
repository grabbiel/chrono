"""Shared skip helpers for the research suites.

The ROM, refs/, manifests/, assets/ and reports/ are local-only: public CI
holds just tools/ and tests/. A test that reads one of them asks for it
through `require` or one of the fixtures below, and skips with
"local <what> not present (<path>)" when it is missing. Tests that need only
synthetic data, the codec dylib or the tools never touch these and always run.
"""
from pathlib import Path

import pytest

WS = Path(__file__).resolve().parents[1]          # re_workspace/


def _shown(path):
    try:
        return str(path.relative_to(WS.parent))
    except ValueError:
        return str(path)


def _require(path, what):
    path = Path(path)
    if not path.exists():
        pytest.skip(f"local {what} not present ({_shown(path)})")
    return path


@pytest.fixture(scope="session")
def require():
    """`require(path, what)` -> path, or skip the requesting test/fixture."""
    return _require


@pytest.fixture(scope="session")
def rom_path():
    """The ROM (re_workspace/ct_clean.sfc)."""
    return _require(WS / "ct_clean.sfc", "ROM")


@pytest.fixture(scope="session")
def chronoret():
    """The ChronoRET checkout (re_workspace/refs/ChronoRET)."""
    return _require(WS / "refs" / "ChronoRET", "ChronoRET checkout")


@pytest.fixture(scope="session")
def data_assets_csv(chronoret):
    """ChronoRET's packed-asset table (symbols/data_assets.csv)."""
    return _require(chronoret / "symbols" / "data_assets.csv", "ChronoRET data_assets.csv")


@pytest.fixture(scope="session")
def manifest_path():
    """`manifest_path(name)` -> re_workspace/manifests/<name>, or skip."""
    return lambda name: _require(WS / "manifests" / name, f"manifest {name}")
