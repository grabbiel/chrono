"""The builder's layout facts (free space, event pack streams, checksum rule)
re-derived from the ROM must equal the committed manifest and Swift twin."""
import json
import sys
from pathlib import Path

import pytest

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
import ct_event_packs as packs  # noqa: E402


@pytest.fixture(scope="module")
def layout(chronoret):
    import ct_rom_layout  # imports ChronoRET's c3pack at module level
    return ct_rom_layout


@pytest.fixture(scope="module")
def rom(rom_path):
    return packs.read_rom(rom_path)


def test_layout_matches_rom_and_swift(layout, rom, require):
    manifest = require(layout.MANIFEST, "manifest rom_layout.json")
    swift = require(layout.SWIFT, "Swift twin CTROMLayout.swift")
    derived = layout.derive(rom)
    assert json.dumps(derived, indent=1) + "\n" == manifest.read_text()
    assert layout.swift_source(derived) == swift.read_text()


def test_layout_numbers(manifest_path):
    doc = json.loads(manifest_path("rom_layout.json").read_text())
    assert len(doc["freeRegions"]) == 66 and doc["freeBytes"] == 62206
    assert doc["eventPacks"]["streams"] == 462 and doc["eventPacks"]["packEntries"] == 488
    assert {d["entry"] for d in doc["eventPacks"]["notPacks"]} >= {0, 75, 102, 231, 320}
    for r in doc["freeRegions"]:
        assert r["pc"] >> 16 == (r["pc"] + r["size"] - 1) >> 16


def test_checksum_rule_reproduces_header(layout, rom):
    assert layout.checksum(rom) == rom[0xFFDE] | rom[0xFFDF] << 8
    assert layout.checksum(rom) ^ (rom[0xFFDC] | rom[0xFFDD] << 8) == 0xFFFF
