"""Event packs: the handler-derived decode table against every ROM pack, the
documented opcode sizes, and refusals. Derivation itself is
`tools/ct_event_packs.py derive` (slow); these checks use its committed output."""

import json
import sys
from pathlib import Path

import pytest

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
import ct_event_packs as packs  # noqa: E402


@pytest.fixture(scope="module")
def rom(rom_path):
    return packs.read_rom(rom_path)


@pytest.fixture(scope="module")
def table(require):
    return json.loads(require(packs.TABLE, "manifest event_decode_table.json").read_text())


@pytest.fixture(scope="module")
def opcodes(table):
    return table["opcodes"]


@pytest.fixture(scope="module")
def pack_records(require):
    return json.loads(require(packs.PACKS, "manifest event_pack_verification.json").read_text())


@pytest.fixture(scope="module")
def isa_doc(manifest_path):
    return json.loads(manifest_path("event_vm_isa.json").read_text())


@pytest.fixture(scope="module")
def swift_twin(require):
    return require(packs.SWIFT, "Swift twin CTEventISA.swift")


def test_every_pack_decodes_from_the_table_to_its_record(rom, table, pack_records, swift_twin, data_assets_csv):
    assert packs.check(rom) == 462


def test_record_totals_and_pointer_coverage(pack_records):
    records = pack_records["packs"]
    assert len(records) == 462
    assert sum(1 for r in records if r.get("objects")) == 461           # EvtPack_075 unpacks to 0 bytes
    indices = sorted(i for r in records for i in r["pointerIndices"]) + pack_records["nonEventPointerIndices"]
    assert sorted(indices) == list(range(513))
    assert all(r["dataBytes"] >= 0 and r["innerInstructions"] >= 0 for r in records if r.get("objects"))


def test_fixed_lengths_agree_with_the_documented_isa(opcodes, isa_doc):
    """Handler traces vs the byte counts in the handlers' headers (event_vm_isa.json)."""
    isa = {o["opcode"]: o for o in isa_doc["opcodes"]}
    compared = 0
    for entry in opcodes:
        doc = isa[entry["op"]]
        if doc["status"] == "halt":
            assert entry["shape"] == {"halt": True}
            continue
        shape = entry["shape"]
        lengths = {c.get("length") for c in shape["cases"]} if "cases" in shape else {shape.get("length")}
        if len(lengths) == 1 and None not in lengths and doc["args"]["total_bytes"] is not None:
            assert lengths == {doc["args"]["total_bytes"]}, entry["name"]
            compared += 1
    assert compared >= 215


def test_variable_shapes_match_the_handler_headers(opcodes):
    by = {e["op"]: e["shape"] for e in opcodes}
    assert by[0x4E] == {"counted": {"operand": 4, "add": 4}, "flow": "n"}       # dst, bank, len, len-2 bytes
    pal = by[0x2E]["cases"]                                                     # $40/$50: 6; $8x: 3 + n; else 2
    assert all(pal[k]["length"] == 6 for k in range(0x40, 0x60))
    assert all(pal[k]["counted"] == {"operand": 3, "add": 3} for k in range(0x80, 0x90))
    assert all(pal[k]["length"] == 2 for k in list(range(0x40)) + list(range(0x60, 0x80)) + list(range(0x90, 0x100)))
    obj = by[0x88]["cases"]                                                     # 0: 2; $20/$30: 4; $4x/$5x: 5; $8x: 2 + n
    assert obj[0]["length"] == 2 and obj[0x20]["length"] == 4 and obj[0x30]["length"] == 4
    assert all(obj[k]["length"] == 5 for k in range(0x40, 0x60))
    assert all(obj[k]["counted"] == {"operand": 2, "add": 2} for k in range(0x80, 0x90))
    fade = by[0xF1]["cases"]                                                    # colour 0: 2 bytes, else 3
    assert fade[0]["length"] == 2 and all(fade[k]["length"] == 3 for k in range(1, 256))


def test_jump_encodings(opcodes):
    jumps = {e["op"]: e["jump"] for e in opcodes if e["jump"]}
    assert jumps[0x10] == {"operand": 1, "sign": 1, "base": 1}
    assert jumps[0x11] == {"operand": 1, "sign": -1, "base": 1}
    assert jumps[0x16] == {"operand": 4, "sign": 1, "base": 4}
    assert jumps[0x13] == {"operand": 5, "sign": 1, "base": 5}
    assert all("j" in packs.shape_flows(opcodes[op]["shape"]) for op in jumps)
    assert opcodes[0x10]["shape"]["flow"] == "j" and opcodes[0x00]["shape"]["flow"] == "se"   # stays at init level (handler header)


def test_swift_twin_is_generated_from_the_table(table, swift_twin):
    assert swift_twin.read_text() == packs.swift_source(table)


def test_refusals(opcodes):
    with pytest.raises(packs.PackError, match="empty"):
        packs.decode(opcodes, b"")
    with pytest.raises(packs.PackError, match="header"):
        packs.decode(opcodes, bytes([2, 0, 0]))
    head = bytes([1]) + (32).to_bytes(2, "little") * 16
    with pytest.raises(packs.PackError, match="cannot be decoded"):
        packs.decode(opcodes, head + bytes([0x01]))                        # unused opcode reached
    with pytest.raises(packs.PackError, match="past the pack"):
        packs.decode(opcodes, head + bytes([0x65, 0x00]))                  # truncated operand
    with pytest.raises(packs.PackError, match="outside"):
        packs.decode(opcodes, head + bytes([0x10, 0xF0]))                  # jump past the end


def test_mutated_jump_changes_the_recorded_digest(rom, opcodes, pack_records, data_assets_csv):
    record = next(r for r in pack_records["packs"] if r["label"] == "EvtPack_027")
    packs_list, _ = packs.unpack_all(rom)
    data = bytearray(next(p["data"] for p in packs_list if p["label"] == "EvtPack_027"))
    ops, _, _ = packs.decode(opcodes, bytes(data))
    assert packs.pack_record(opcodes, bytes(data))["instructionDigest"] == record["instructionDigest"]
    # a conditional whose target moved by one byte lands where no opcode was
    y = next(y for y, o in sorted(ops.items()) if o[0] == 0x16 and o[3] + 1 not in ops and data[1 + y + 4] < 255)
    data[1 + y + 4] += 1
    try:
        changed = packs.pack_record(opcodes, bytes(data))["instructionDigest"]
    except packs.PackError:
        changed = None
    assert changed != record["instructionDigest"]
