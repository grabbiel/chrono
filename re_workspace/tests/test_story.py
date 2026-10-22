"""Story flags and the world graph (tools/ct_story.py).

Synthetic packs check the access decoding, function attribution, flag guards
and era grouping without game data; the ROM tests reconcile the totals with a
re-decode, cite the evidence and execute the ROM's handlers."""

import json
import sys
from pathlib import Path

import pytest

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
import ct_story as story  # noqa: E402

BITSET = bytes([1, 2, 4, 8, 16, 32, 64, 128]) + bytes(8)


def table():
    """A decode table for the synthetic packs: fixed shapes for the opcodes used."""
    shapes = {0x00: (1, "e"), 0xB2: (1, "s"), 0x65: (3, "n"), 0x66: (3, "n"), 0x16: (5, "nj"), 0x18: (3, "nj"),
              0x56: (4, "n"), 0x53: (4, "n"), 0x4A: (5, "n"), 0xE0: (5, "n"), 0xE1: (5, "e"), 0xE2: (5, "n"),
              0x10: (2, "j"), 0x11: (2, "j"), 0x4E: None}
    jumps = {0x16: {"operand": 4, "sign": 1, "base": 4}, 0x18: {"operand": 2, "sign": 1, "base": 2},
             0x10: {"operand": 1, "sign": 1, "base": 1}, 0x11: {"operand": 1, "sign": -1, "base": 1}}
    out = []
    for op in range(256):
        if op == 0x4E:
            shape = {"counted": {"operand": 4, "add": 4}, "flow": "n"}
        elif op in shapes:
            shape = {"length": shapes[op][0], "flow": shapes[op][1]}
        else:
            shape = {"halt": True}
        out.append({"op": op, "shape": shape, "jump": jumps.get(op)})
    return out


def pack(*objects):
    """A pack of objects, each a list of functions, each a list of byte lists."""
    head = 1 + 32 * len(objects)
    body, funcs = bytearray(), []
    for obj in objects:
        offsets = []
        for code in obj:
            offsets.append(head - 1 + len(body))
            body += bytes(b for ins in code for b in ins)
        offsets += [offsets[-1]] * (16 - len(offsets))
        funcs.append(offsets)
    data = bytearray([len(objects)])
    for offsets in funcs:
        for o in offsets:
            data += o.to_bytes(2, "little")
    return bytes(data + body)


def test_bit_operands_page_and_mask():
    data = pack([[[0x65, 0x83, 0x10], [0x66, 0x02, 0x7F], [0x00]]])
    ops, _, funcs = story.packs.decode(table(), data)
    first = min(ops)
    (kind, addr, bit, width, detail), = story.decode_access(data, first, 0x65, BITSET)
    assert (kind, addr, bit, width, detail["mask"]) == ("set", 0x110, 3, 1, 8)   # bit 7: the $7F:0100 page
    (kind, addr, bit, *_), = story.decode_access(data, first + 3, 0x66, BITSET)
    assert (kind, addr, bit) == ("clear", 0x7F, 2)


def test_bit_numbers_past_bitset_are_flagged():
    data = pack([[[0x65, 0x09, 0x01], [0x00]]])
    ops, _, _ = story.packs.decode(table(), data)
    (_, _, bit, _, detail), = story.decode_access(data, min(ops), 0x65, BITSET)
    assert bit is None and detail["bitNumberPastBitSet"] == 9 and detail["mask"] == 0


def test_tests_reads_writes_and_ranges():
    data = pack([[[0x16, 0x05, 0x20, 0x86, 0x05], [0x56, 0x07, 0x34, 0x01], [0x56, 0x07, 0x00, 0x02],
                  [0x4A, 0x40, 0x00, 0x7F, 0x09], [0x4A, 0x40, 0x00, 0x7E, 0x09], [0x18, 0x10, 0x01],
                  [0x00]]])
    ops, _, _ = story.packs.decode(table(), data)
    y = sorted(ops)
    (kind, addr, bit, _, detail), = story.decode_access(data, y[0], 0x16, BITSET)
    assert (kind, addr, bit, detail["cmp"], detail["value"]) == ("test", 0x105, 5, "and", 0x20)
    assert story.decode_access(data, y[1], 0x56, BITSET)[0][:4] == ("write", 0x134, None, 1)
    assert story.decode_access(data, y[2], 0x56, BITSET) == []            # $7F:0200 is not story memory
    assert story.decode_access(data, y[3], 0x4A, BITSET)[0][:2] == ("write", 0x40)
    assert story.decode_access(data, y[4], 0x4A, BITSET) == []            # bank $7E
    assert story.decode_access(data, y[5], 0x18, BITSET)[0][:2] == ("test", 0)


def test_copy_data_into_story_memory():
    data = pack([[[0x4E, 0x10, 0x00, 0x7F, 0x05, 0x00, 1, 2, 3], [0x00]]])
    ops, _, _ = story.packs.decode(table(), data)
    (kind, addr, _, width, detail), = story.decode_access(data, min(ops), 0x4E, BITSET)
    assert (kind, addr, width, detail["copy"]) == ("write", 0x10, 3, True)
    counts = story.flag_table([{"kind": kind, "addr": addr, "bit": None, "width": width, "copy": True}])
    assert sorted(a for a, _ in counts) == [0x10, 0x11, 0x12]


def test_functions_reaching_each_instruction():
    # Object 0: init sets a bit then $00, and goes on past it (Evt_RunObjInit);
    # function 1 jumps into the shared tail.
    # function 1 jumps into the tail; a second $00 stops function 0.
    init = [[0x65, 0x00, 0x01], [0x00], [0x66, 0x00, 0x01], [0x00], [0x65, 0x01, 0x01], [0xB2]]
    data = pack([init, [[0x11, 9]]])                                    # back to the $66
    ops, _, funcs = story.packs.decode(table(), data)
    reach = story.function_reach(data, ops, funcs)
    start = funcs[0][0]
    assert reach[start] == [(0, 0)]
    assert reach[start + 4][:2] == [(0, 0), (0, 1)]                       # after the $00: function 0's, and the jump's
    assert start + 8 not in reach                                         # past the second $00: nobody
    assert reach[funcs[0][1]][0] == (0, 1)


def test_guards_must_hold_on_every_path():
    # if 7F:0005 & $01 { warp A } ; warp B (always)
    code = [[0x16, 0x05, 0x01, 0x06, 0x06], [0xE0, 0x10, 0x00, 3, 4], [0xE0, 0x20, 0x00, 5, 6], [0x00]]
    data = pack([[[0x00]], [[0x00]], [[0x00]], code])
    ops, _, funcs = story.packs.decode(table(), data)
    guards = story.guard_sets(data, ops, funcs)
    start = funcs[0][3]
    a, b = start + 5, start + 10
    assert [(g["addr"], g["bit"], g["holds"]) for g in guards[a]] == [(5, 0, True)]
    assert guards[b] == []                                                # reached both ways


def test_warp_operands():
    data = pack([[[0xE0, 0xF4, 0x13, 7, 9], [0xE2, 1, 2, 3, 4], [0x00]]])
    ops, _, _ = story.packs.decode(table(), data)
    y = sorted(ops)
    w = story.warp_operands(data, y[0], 0xE0)
    assert (w["dest"], w["x"], w["y"], w["facing"]) == (0x1F4, 7, 9, 9)
    assert story.warp_operands(data, y[1], 0xE2) == {"kind": "warpVars", "dest": None, "vars": [1, 2, 3, 4]}


def test_world_graph_groups_by_nearest_c2_location():
    def warp(src, dest, kind="warp"):
        return {"kind": kind, "dest": dest, "locations": [src], "pack": "P", "offset": 0, "x": 0, "y": 0,
                "guards": []}
    warps = [warp(1, 0x1F0), warp(2, 1), warp(3, 0x1F1), warp(4, 3), warp(2, 4), warp(5, 5),
             warp(6, 0x1F0), warp(6, 0x1F1), warp(7, 6), warp(8, 9, "setPrevLoc")]
    g = story.world_graph(warps)
    groups = {int(k): v for k, v in g["groups"].items()}
    assert groups[1] == 0x1F0 and groups[3] == 0x1F1
    assert groups[2] == 0x1F0                       # one step from 1, two from 3
    assert groups[4] == 0x1F1
    assert groups[6] is None and groups[7] is None  # tie: ungrouped
    assert groups[5] is None                        # no path to a seed
    assert not any(e["from"] == 8 for e in g["edges"])
    assert any(e["crossGroup"] for e in g["edges"] if (e["from"], e["to"]) == (2, 4))


def test_chronoret_parsing_on_a_synthetic_tree(tmp_path):
    inc = tmp_path / "asm" / "include"
    inc.mkdir(parents=True)
    (inc / "ram.inc").write_text("!Story_A = $7F0010 ; a byte\n!Other = $7F0300\n")
    bank = tmp_path / "asm" / "bankC0"
    bank.mkdir()
    (bank / "bankC0.asm").write_text(
        "; $C0:1000 — Demo_Routine (8 bytes, $1000–$1007)\n"
        "Demo_Routine:\n"
        "    LDA.l !Story_A\n"
        "    STA.l !Story_A+1,X\n"
        "    STA.l !Other\n"
        "    RTL\n")
    uses, routines = story.chronoret_uses(tmp_path)
    assert [(u["mnemonic"], u["addr"], u["access"], u["indexed"], u["line"]) for u in uses] == [
        ("LDA", 0x10, "read", False, 3), ("STA", 0x11, "write", True, 4)]
    assert routines == [{"name": "Demo_Routine", "start": 0xC01000, "end": 0xC01008,
                         "file": "asm/bankC0/bankC0.asm", "line": 1}]
    rom = bytearray(0x10000)
    rom[0x1000:0x1004] = bytes([0xAF, 0x10, 0x00, 0x7F])      # LDA $7F0010: in the routine, in its source
    rom[0x1004:0x1008] = bytes([0x8F, 0x55, 0x00, 0x7F])      # STA $7F0055: in the routine, not in source
    rom[0x2000:0x2004] = bytes([0x9F, 0x00, 0x01, 0x7F])      # elsewhere
    rom[0x3000:0x3004] = bytes([0xAF, 0x00, 0x02, 0x7F])      # $7F:0200: not story memory
    code = story.code_refs(bytes(rom), tmp_path)
    assert [(h["pc"], h["status"]) for h in code["romPatterns"]] == [
        (0x1000, "code-proven"), (0x1004, "in-routine"), (0x2000, "pattern-matched")]


# ── ROM ─────────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def rom(rom_path, chronoret, manifest_path):
    manifest_path("event_decode_table.json")
    manifest_path("event_pack_verification.json")
    manifest_path("event_vm_isa.json")
    return story.packs.read_rom(rom_path)


@pytest.fixture(scope="module")
def result(rom):
    return story.check(rom, run=False, log=lambda *_: None)


def test_totals_reconcile_with_the_decoder(result):
    t = result["totals"]
    assert t["instructions"] == 142702
    assert t["refs"] == 7055 and t["warps"] == 663
    assert (t["op65"], t["op66"], t["op16"], t["op18"]) == (1136, 432, 4085, 745)


def test_flag_summary(result):
    s = story.summary(result["refs"], result["warps"], result["totals"])
    assert (s["bitFlags"], s["bytesTouched"], s["bytesUnused"]) == (852, 219, 293)


def test_citations_name_isa_rows_and_chronoret_lines(result):
    cites = result["cites"]
    assert cites[0x65]["isa"].endswith("$65 Evt_Op65_SetMemBit")
    assert cites[0x65]["chronoret"].startswith("asm/bankC0/bankC0.asm:")
    assert all(c["chronoret"] for c in cites.values())


def test_code_outside_the_event_vm(result):
    code = result["code"]
    assert len(code["source"]) == 699
    statuses = {h["status"] for h in code["romPatterns"]}
    assert statuses <= {"code-proven", "in-routine", "pattern-matched"}
    assert sum(1 for h in code["romPatterns"] if h["status"] == "code-proven") == 83


def test_world_graph_from_the_rom(result):
    g = story.world_graph(result["warps"])
    assert g["seeds"] == list(range(0x1F0, 0x1F8))
    assert len(g["edges"]) == 718


def test_handlers_change_the_recorded_bytes(rom, result):
    assert story.run_handlers(rom, result["refs"]) == 1101
