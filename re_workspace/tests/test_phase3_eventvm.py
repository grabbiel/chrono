"""Phase 3 item 4 — Location Event VM ISA manifest verification.

Checks manifests/event_vm_isa.json against the ROM bytes and the
ChronoRET decompilation:
  * all 256 table words read from the ROM match the manifest handler addresses;
  * every documented handler points at real code (not $00/$FF fill) inside a
    documented bankC0.asm code span;
  * the halt opcodes are exactly the known 32;
  * the $7F:0000 story-flag memory region is documented;
  * >= 150 opcodes carry a non-empty description;
  * the coroutine/priority/step-budget architecture fields are present.

Run: cd <repo root> && re_workspace/.venv/bin/pytest re_workspace/tests/test_phase3_eventvm.py -q
"""

from __future__ import annotations

import json
import os
import sys

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REWORKSPACE = os.path.dirname(TESTS_DIR)
sys.path.insert(0, os.path.join(REWORKSPACE, "tools"))

from address_map import Rom, load as load_rom  # noqa: E402
import ct_event_isa as isa  # noqa: E402

MANIFEST_PATH = os.path.join(REWORKSPACE, "manifests", "event_vm_isa.json")
MD_PATH = os.path.join(REWORKSPACE, "manifests", "event_vm_isa.md")


@pytest.fixture(scope="module")
def manifest():
    assert os.path.exists(MANIFEST_PATH), "run tools/ct_event_isa.py first"
    with open(MANIFEST_PATH, encoding="utf-8") as f:
        return json.load(f)


@pytest.fixture(scope="module")
def rom():
    return load_rom(os.path.join(REWORKSPACE, "ct_clean.sfc"))


# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

def test_manifest_shape(manifest):
    assert manifest["coverage"]["total"] == 256
    assert len(manifest["opcodes"]) == 256
    for i, e in enumerate(manifest["opcodes"]):
        assert e["opcode"] == i
        assert e["status"] in ("documented", "halt", "undocumented")
    c = manifest["coverage"]
    assert c["documented"] + c["halt"] + c["undocumented"] == 256


# ---------------------------------------------------------------------------
# 1. Table read from the ROM matches the manifest exactly (all 256 words)
# ---------------------------------------------------------------------------

def test_table_matches_rom_bytes(manifest, rom):
    for e in manifest["opcodes"]:
        word = rom.u16(isa.TABLE_BANK, isa.TABLE_ADDR + 2 * e["opcode"])
        assert f"$C0:{word:04X}" == e["handler_snes"], (
            f"opcode {e['opcode_hex']}: ROM word ${word:04X} != manifest "
            f"{e['handler_snes']}")
        # handler_pc must be the correct HiROM file offset for the SNES word
        assert e["handler_pc"] == Rom.snes_to_pc(0xC0, word)


def test_dispatch_sites_are_jsr_absx(manifest, rom):
    for d in manifest["source"]["dispatch"]:
        bank, addr = 0xC0, int(d["site"].split(":")[1], 16)
        assert rom.read(bank, addr, 3).hex() == "fc6e5d", d["site"]
        assert d["verified"]


# ---------------------------------------------------------------------------
# 2. Documented handlers point to non-fill bytes inside code regions
# ---------------------------------------------------------------------------

def test_documented_handlers_are_real_code(manifest, rom):
    mos = isa.load_mos65816_table()
    asm = isa.parse_chronoret_labels()
    n = 0
    for e in manifest["opcodes"]:
        if e["status"] != "documented":
            continue
        n += 1
        bank, addr = 0xC0, int(e["handler_snes"].split(":")[1], 16)
        first8 = rom.read(bank, addr, 8)
        assert not all(b == 0x00 for b in first8), f"{e['opcode_hex']} all-$00 fill"
        assert not all(b == 0xFF for b in first8), f"{e['opcode_hex']} all-$FF fill"
        # first byte decodes to a real 65816 instruction (vendored MIT table)
        assert mos["OPCODES"][first8[0]][0] == e["verify"]["first_mnemonic"]
        # address lies inside a documented bankC0.asm routine span
        assert any(a <= addr < asm["span_end"][a] for a in asm["header_addrs"]
                   if a <= addr), f"{e['opcode_hex']} handler ${addr:04X} outside code spans"
    assert n == manifest["coverage"]["documented"]


# ---------------------------------------------------------------------------
# 3. The 32 halt opcodes match the known set
# ---------------------------------------------------------------------------

def test_halt_opcodes_exact(manifest, rom):
    halt = {e["opcode"] for e in manifest["opcodes"] if e["status"] == "halt"}
    assert halt == isa.KNOWN_HALT_OPCODES
    assert len(halt) == 32
    assert manifest["coverage"]["halt"] == 32
    # and in the ROM itself every one of those words is $5F6E
    for op in isa.KNOWN_HALT_OPCODES:
        assert rom.u16(isa.TABLE_BANK, isa.TABLE_ADDR + 2 * op) == isa.HALT_ADDR


# ---------------------------------------------------------------------------
# 4. Story-flag memory region $7F:0000 documented
# ---------------------------------------------------------------------------

def test_story_flag_region_documented(manifest):
    mm = manifest["architecture"]["memory_map"]
    assert "$7F:0000" in mm
    entry = mm["$7F:0000"]
    assert "!Evt_Mem7F" in entry["symbols"]
    assert "operand" in entry["comment"].lower()
    # treasure flags and the per-load window are mapped too
    assert "$7F:0001" in mm and "!Treasure_Flags" in mm["$7F:0001"]["symbols"]
    assert "$7F:0200" in mm
    # priority save tables: 8 levels, stride $80
    for i in range(8):
        key = f"$7F:{0x580 + 0x80 * i:04X}"
        assert key in mm, key
    assert "Evt_PrioStride" in manifest["architecture"]["priorities"]["save_tables"]


# ---------------------------------------------------------------------------
# 5. Description coverage >= 150
# ---------------------------------------------------------------------------

def test_description_coverage(manifest):
    with_desc = sum(1 for e in manifest["opcodes"] if e["description"].strip())
    assert with_desc >= 150, f"only {with_desc} opcodes have descriptions"
    # every documented opcode also has a label and a machine-readable name
    for e in manifest["opcodes"]:
        if e["status"] == "documented":
            assert e["label"] and e["name"]


# ---------------------------------------------------------------------------
# Architecture fields (objects / functions / priorities / coroutine semantics)
# ---------------------------------------------------------------------------

def test_architecture_fields(manifest):
    arch = manifest["architecture"]
    assert arch["objects"] == 16
    f = arch["functions"]
    assert "0" in f and "1" in f and "2" in f and "3+" in f
    assert "Evt_Data + slot*16" in f["table"]
    assert "Obj_Unk1C00" in arch["priorities"]["levels"]
    assert "7" in arch["priorities"]["levels"]  # level range 0-7 documented
    assert "Field_Unk68" in arch["step_budget"]["per_object_per_frame"]
    assert "Evt_StepsLeft" in arch["step_budget"]["counter"]
    sem = arch["coroutine_yield_semantics"]
    assert "C=1" in sem and "C=0" in sem  # continue / yield-to-next-frame
    assert "Obj_ScriptPos" in sem


def test_markdown_twin_exists(manifest):
    assert os.path.exists(MD_PATH)
    text = open(MD_PATH, encoding="utf-8").read()
    assert text.count("\n| $") >= 256
