"""Location maps: header, tile planes, tile properties, exits, treasure (tools/ct_maps.py).

ROM-free: the layer-size, wrap-mask, own-step and screen formulas, the plane
and triple parser (runs, a count of 0, a run cut at the plane's end, a map
that ends before its triples do), the exit tiles as Map_LoadExitTiles writes
them (a row wraps its column, a column wraps its row), the treasure
redirect, the packer's round trip and the Swift vectors file, all on
synthetic bytes.

Local (ROM, ChronoRET): every source, code and data claim of `check`, the
`--run` claims on a few locations (LocLoad_UnkA33B and Map_LoadTreasureTiles
in ChronoRET's 65816 interpreter) and location 1 against the Phase 3
manifest's real-map decode.
"""

import json
import os
import struct
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_maps as cm  # noqa: E402
import ct_tilesets as ts  # noqa: E402


@pytest.fixture(scope="module")
def synthetic():
    regions, expect = cm.synthetic_rom()
    image = bytearray(ts.ROM_SIZE)
    for long, data in regions.items():
        image[ts.pc(long):ts.pc(long) + len(data)] = data
    return bytes(image), expect


# --- ROM-free ---------------------------------------------------------------------------

def test_layer_sizes_follow_the_immediates():
    # Size1 bits 0-1 / 2-3 (layer 1), 4-5 / 6-7 (layer 2); Size3 bits 0-1 / 2-3 (layer 3).
    assert cm.layer_sizes(0x00, 0x00) == {1: (16, 16), 2: (16, 16), 3: (16, 16)}
    assert cm.layer_sizes(0xFF, 0x0F) == {1: (64, 64), 2: (64, 64), 3: (64, 64)}
    assert cm.layer_sizes(0x01 | 0x08 | 0x30 | 0x40, 0x06) == {1: (32, 48), 2: (64, 32), 3: (48, 32)}


def test_wrap_masks_and_own_steps():
    assert [cm.wrap_mask(n) for n in (0x10, 0x20, 0x30, 0x40)] == [0x0F, 0x1F, 0x3F, 0x3F]
    assert cm.own_step(0x00) == (0, 0)
    assert cm.own_step(0x01) == (1, 0)
    assert cm.own_step(0x0A | 0x90) == (-2, -1)
    assert cm.own_step(0x73) == (4, 64)


def test_screens_keep_bg12_obj_without_layer3():
    p = {"screens": 0xFF, "colorMath": 0x82}
    assert cm.screens(p, 0) == (0x17, 0x17, 0x82)
    assert cm.screens(p, cm.NONE) == (0x13, 0x13, 0x82)
    assert cm.screens({"screens": 0x4B, "colorMath": 3}, 0) == (0x13, 0x04, 3)


def header_bytes(size1=0, size3=0, screens=0x13, math=0):
    return bytes([size1, size3, 0, 0, screens, math])


def test_parse_reads_planes_then_triples_and_runs():
    planes = bytes(range(256)) + bytes(255 - k for k in range(256))
    # 2 single triples, a run of 254, then exactly the plane.
    tail = bytes([0x01, 0xAA, 0xBB]) + bytes([0x02, 0x10, 0x20]) + bytes([0x80 | 0x7C, 0x0C, 0x83, 254])
    p = cm.parse_props(header_bytes() + planes + tail)
    assert (p["used"], p["length"], p["staleTiles"], p["entries"], p["runs"]) == (len(planes) + 6 + 10,) * 2 + (0, 3, 1)
    assert p["planes"][1][:2] == [0 | 1 << 8, 1]                  # HiBits bit 0 is the layer-1 bit 8
    assert p["planes"][2][1] == 254 | 1 << 8                      # HiBits bit 1 the layer-2 bit 8
    assert p["hiBits"][2:] == [0x7C] * 254 and p["attrB"][-1] == 0x83
    assert 3 not in p["planes"]


def test_parse_counts_0_as_256_and_stops_mid_run():
    planes = bytes(512)
    p = cm.parse_props(header_bytes() + planes + bytes([0x80, 1, 2, 0]))
    assert p["attrA"] == [1] * 256 and p["staleTiles"] == 0
    # A run longer than what is left: the routine returns at the plane's end.
    p = cm.parse_props(header_bytes() + planes + bytes([0x05, 0, 0]) + bytes([0x81, 3, 4, 0]))
    assert p["hiBits"][:2] == [5, 1] and len(p["hiBits"]) == 256 and p["used"] == p["length"]


def test_parse_reads_layer3_only_with_size3_bit7():
    planes = bytes(256 * 3)
    p = cm.parse_props(header_bytes(size3=0x80) + planes + bytes([0x80, 0, 0, 0]))
    assert set(p["planes"]) == {1, 2, 3} and p["layer3Plane"]


def test_short_map_takes_zeros_past_the_end():
    planes = bytes(512)
    p = cm.parse_props(header_bytes() + planes + bytes([0x80, 9, 9, 250]))
    assert p["staleTiles"] == 6 and p["attrA"][-6:] == [0] * 6 and p["attrA"][249] == 9


def test_exit_tiles_wrap_as_the_routine_does():
    row = {"x": 14, "y": 3, "span": 3, "vertical": False}
    col = {"x": 2, "y": 14, "span": 3, "vertical": True}
    tiles = cm.exit_tiles([row, col], 0x0F, 0x0F)
    assert {k for k, v in tiles.items() if v == 0} == {3 << 8 | 14, 3 << 8 | 15, 3 << 8 | 0, 3 << 8 | 1}
    assert {k for k, v in tiles.items() if v == 1} == {14 << 8 | 2, 15 << 8 | 2, 0 << 8 | 2, 1 << 8 | 2}


def test_decode_exit_and_treasure_fields():
    e = cm.decode_exit([3, 4, 0x82, 0x34, 0x80 | 0x05 << 1 | 1, 7, 8])
    assert (e["dest"], e["facing"], e["destFlag"], e["span"], e["vertical"]) == (0x134, 5, True, 2, True)
    assert cm.decode_treasure(5 << 8 | 6, 0x8000 | 25)["amount"] == 50
    assert cm.decode_treasure(0, 0x4000)["kind"] == "empty"
    assert cm.decode_treasure(0, 0x01C5)["item"] == 0x1C5


def test_pack_props_round_trips():
    rng = ts.Lcg(77)
    planes = bytes(rng.next(256) for _ in range(512 + 1024))
    hi = [rng.next(4) if rng.next(3) else 0 for _ in range(256)]
    p = {"size1": 0x00, "size3": 0x80, "move2": 0, "move3": 0, "screens": 0x13, "colorMath": 0,
         "planes": {1: list(planes[:256]), 2: list(planes[256:512]), 3: list(planes[512:768])},
         "hiBits": hi, "attrA": [rng.next(2) for _ in range(256)], "attrB": [rng.next(2) for _ in range(256)]}
    q = cm.parse_props(cm.pack_props(p))
    assert q["used"] == q["length"]
    for k in (1, 2, 3):
        assert [v & 0xFF for v in q["planes"][k]] == p["planes"][k]
    assert (q["hiBits"], q["attrA"], q["attrB"]) == (hi, p["attrA"], p["attrB"])


def test_synthetic_locations(synthetic):
    rom, expect = synthetic
    d0, d1, d2, d3 = expect
    assert d1["treasure"]["list"] == 0 and d1["treasure"]["records"] == d0["treasure"]["records"]
    assert d1["ppu"]["TM"] & 0x04 == 0 and d1["props"]["halfRate2"] and d1["steps"]["2"] == [-2, -1]
    assert d1["limits"] == {"left": 0, "top": 0, "right": 31, "bottom": 47}
    assert d2["props"]["staleTiles"] == 9
    assert d3["props"]["entry"] == d0["props"]["entry"] and d3["header"]["music"] == 0x81
    assert [15, 1] in d0["exitTiles"] and [271, 1] in d0["exitTiles"]


def test_vectors_file_matches_the_decoder():
    assert cm.VECTORS.read_text() == cm.vectors_text(), "regenerate with ct_maps.py vectors --out"


# --- Local ROM and ChronoRET ---------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return cm.read_rom(rom_path)


def test_source_claims(chronoret):
    bad = [c for c in cm.asm_claims(chronoret) if not c[1]]
    assert not bad, bad


def test_code_claims(rom):
    bad = [c for c in cm.code_claims(rom) if not c[1]]
    assert not bad, bad


def test_data_claims(rom, data_assets_csv):
    bad = [c for c in cm.data_claims(rom, data_assets_csv) if not c[1]]
    assert not bad, bad


def test_run_claims_on_a_few_locations(rom, chronoret):
    bad = [c for c in cm.run_claims(rom, chronoret, locations=[1, 47, 109, 386]) if not c[1]]
    assert not bad, bad


def test_location_1_matches_the_manifest(rom, manifest_path):
    real = json.loads(manifest_path("maps_schema.json").read_text())["real_map_decode"]
    d = cm.decode(rom, 1)
    p = d["props"]
    assert (p["entry"], p["at"], p["length"], p["used"]) == (
        real["map_props_entry"], real["packed_addr"], real["unpacked_len"], real["bytes_consumed"])
    assert (p["entries"], p["runs"]) == (real["attr_entries"], real["attr_runs"])
    assert (p["screens"], p["colorMath"]) == (int(real["screens_byte"], 16), int(real["color_math_byte"], 16))
    row0 = bytes(v & 0xFF for v in d["planes"]["1"][:16]).hex(" ").upper()
    assert row0 == real["plane1_row0_first16"]
