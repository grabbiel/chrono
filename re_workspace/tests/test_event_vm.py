"""ct_event_vm.py: the differential check of CTEventVM against the ROM's
opcode handlers.

The helpers run on synthetic data: the random states stay inside the bounds
the handlers index by, the comparison names the first difference and leaves
the handlers' scratch bytes out. With the ROM, ChronoRET and a built
`chronoforge`, small samples of the party-control opcodes ($AF, $B0), of
the item, gold and party-membership opcodes, of the palette opcodes and of the
palette routines (PalAnim_TickAll, the slot claim and release) run both ways
and must agree.

Run: re_workspace/.venv/bin/python -m pytest re_workspace/tests/test_event_vm.py -q
"""

import json
import random
import re
import subprocess
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))

import ct_event_vm as vm  # noqa: E402


def test_scratch_ranges():
    assert vm.scratch(0x7E01C1)
    assert vm.scratch(0x7E01EA)
    assert not vm.scratch(0x7E01EB)
    assert vm.scratch(0x7F3800)
    assert not vm.scratch(0x7E0100)
    assert not vm.scratch(0x7F0000)


def test_states_stay_in_the_handlers_bounds():
    rng = random.Random(7)
    e4 = bytes(range(8))
    for _ in range(40):
        regions = dict(vm.state(rng, 3, 0xB0, e4))
        dp = regions[0x7E0100]
        assert len(dp) == 0xC0
        assert dp[0x6D] in (0, 2, 4) and dp[0x6E] == 0           # Obj_Cur: one of the 3 objects
        for p in (0, 2, 4):
            assert dp[0x97 + p] in (0, 2, 4, 0x80)
        assert dp[0xAF:0xB2] == bytes((0, 1, 0xE4))              # Field_E4Ptr0
        assert 0x8000 <= dp[0x71] | dp[0x72] << 8 < 0xE000
        assert all(k < 4 for k in regions[0x7E1100][0::2])       # party kinds 0-2 and one other
        assert all(k < 4 for k in regions[0x7E1600][0::2])       # facings
        assert all(k < 8 for k in regions[0x7E1C00][0::2])       # call levels
        assert all(at >> 16 in (0x7E, 0x7F) for at in regions)
        assert 0x7E7000 not in regions                           # tile attributes only for tile opcodes
    tiles = dict(vm.state(rng, 2, 0x8B, e4))
    assert len(tiles[0x7E7000]) == 0x1000
    assert all(t < 16 for t in tiles[0x7E1800][1::2])


def test_item_and_party_states_plant_the_operand():
    rng = random.Random(11)
    e4 = bytes(range(8))
    held = 0
    for _ in range(60):
        regions = dict(vm.state(rng, 4, 0xCA, e4, b"\x2a\x00"))
        inv = regions[0x7E2400]
        assert len(inv) == 0x200 and len(regions[0x7E2C53]) == 3   # ids, counts; the 24-bit gold
        held += 0x2A in inv[:0x100]
    assert held > 20                                             # the item is often held
    listed = 0
    for _ in range(60):
        regions = dict(vm.state(rng, 4, 0xD4, e4, b"\x03\x00"))
        order = regions[0x7E2980]
        assert len(order) == 0x30 and len(regions[0x7E21A0]) == 0x60   # Menu_PartyOrder .. $29AF; palette rows 5-7
        listed += 3 in order[:9]
    assert listed > 20
    assert 0x7E2400 not in dict(vm.state(rng, 4, 0xB0, e4))


def test_compare_names_the_first_difference():
    known = {0x7E0200: 5}
    rom = ("go", 0x23, True, {0x7E0200: 6, 0x7E01C1: 9}, known)
    same = {"kind": "go", "x": 0x23, "carry": True, "mem": {str(0x7E0200): 6}}
    assert vm.compare(rom, same, known) is None                  # $01C1 is scratch
    assert "X $0023" in vm.compare(rom, dict(same, x=0x24), known)
    assert "carry" in vm.compare(rom, dict(same, carry=False), known)
    assert "$7E0200" in vm.compare(rom, dict(same, mem={}), known)
    assert "unmodelled" in vm.compare(rom, {"kind": "unmodelled", "reason": "r"}, known)
    assert vm.compare(("halted",), {"kind": "halted"}, {}) is None
    assert "never returns" in vm.compare(("halted",), same, {})


def test_recorded_evidence_matches_the_swift_families():
    src = (WS.parent / "macos_studio" / "Sources" / "ChronoForgeCore" / "CTEventVM.swift").read_text()
    table = src[src.index("public static let families"):src.index("public static let modelled")]
    families = {name: re.findall(r"0x[0-9A-F]{2}", body) for name, body in re.findall(r'"(\w+)": \[([^\]]*)\]', table)}
    assert set(families) == set(vm.EVIDENCE)
    for name, f in vm.EVIDENCE.items():
        assert f["opcodes"] == len(families[name]), name
        assert f["verified"] <= f["opcodes"]
        assert f["disagree"] == 0
        assert f["agree"] <= f["cases"]
    modelled = sum(f["opcodes"] for f in vm.EVIDENCE.values())
    assert modelled == len({op for ops in families.values() for op in ops}) == 197
    assert sum(f["verified"] for f in vm.EVIDENCE.values()) == 194
    assert sum(f["agree"] for f in vm.EVIDENCE.values()) == 9545
    assert sum(f["cases"] for f in vm.EVIDENCE.values()) == 9546
    assert vm.EVIDENCE_UNMODELLED["instructions"] < vm.EVIDENCE_UNMODELLED["instructionsInPacks"] // 10


def test_party_control_agrees_with_the_rom(rom_path, chronoret, require, tmp_path):
    cli = require(vm.CLI, "chronoforge build")
    out = tmp_path / "report.json"
    r = subprocess.run([sys.executable, str(WS / "tools" / "ct_event_vm.py"), "check", "--cli", str(cli),
                        "--ops", "AF,B0", "--per-op", "6", "--states", "2", "--json", str(out)],
                       capture_output=True, text=True, timeout=1200)
    assert r.returncode == 0, r.stdout + r.stderr
    party = json.loads(out.read_text())["families"]["party"]
    assert party["opcodes"] == 2
    assert party["opcodesVerified"] == 2
    assert party["disagree"] == 0
    assert party["agree"] >= 12


def test_items_and_membership_agree_with_the_rom(rom_path, chronoret, require, tmp_path):
    cli = require(vm.CLI, "chronoforge build")
    out = tmp_path / "report.json"
    r = subprocess.run([sys.executable, str(WS / "tools" / "ct_event_vm.py"), "check", "--cli", str(cli),
                        "--ops", "C9,CA,CB,CD,CE,D7,D2,D3,D4,D6", "--per-op", "3", "--states", "2", "--jobs", "2",
                        "--json", str(out)], capture_output=True, text=True, timeout=1200)
    assert r.returncode == 0, r.stdout + r.stderr
    families = json.loads(out.read_text())["families"]
    for name, verified in (("items", 6), ("membership", 4)):
        assert families[name]["opcodesVerified"] == verified, name
        assert families[name]["disagree"] == 0
        assert families[name]["agree"] == families[name]["cases"]


def test_routine_states_stay_in_the_routines_bounds():
    rng = random.Random(3)
    for _ in range(50):
        (at, recs), (pal_at, pal) = vm.tick_state(rng)
        assert (at, len(recs), pal_at, len(pal)) == (0x7E0520, 0x90, 0x7E2000, 0x400)
        for k in range(12):
            rec = recs[12 * k:12 * k + 12]
            assert 1 <= rec[2] <= 32                                  # no 64 KiB loops
            assert rec[0] == 0 or rec[0] >= 0x10
        regions = dict(vm.slot_state(rng))
        cur = regions[0x7E0100][0x6D]
        assert cur % 2 == 0 and cur < 0x20
        assert regions[0x7E1100][cur] < 12 or regions[0x7E1100][cur] >= 0x80   # a kind with a handler
    assert set(vm.EVIDENCE_ROUTINES) == set(vm.ROUTINES)
    assert all(agree == cases for cases, agree in vm.EVIDENCE_ROUTINES.values())


def test_palettes_and_their_routines_agree_with_the_rom(rom_path, chronoret, require, tmp_path):
    cli = require(vm.CLI, "chronoforge build")
    out = tmp_path / "report.json"
    r = subprocess.run([sys.executable, str(WS / "tools" / "ct_event_vm.py"), "check", "--cli", str(cli),
                        "--ops", "2E,33,88", "--per-op", "4", "--states", "2", "--jobs", "2", "--json", str(out)],
                       capture_output=True, text=True, timeout=1200)
    assert r.returncode == 0, r.stdout + r.stderr
    palettes = json.loads(out.read_text())["families"]["palettes"]
    assert palettes["opcodesVerified"] == 3 and palettes["agree"] == palettes["cases"]
    r = subprocess.run([sys.executable, str(WS / "tools" / "ct_event_vm.py"), "routines", "--cli", str(cli),
                        "--cases", "20", "--jobs", "2", "--json", str(out)], capture_output=True, text=True, timeout=1200)
    assert r.returncode == 0, r.stdout + r.stderr
    for name, row in json.loads(out.read_text()).items():
        assert row["agree"] == row["cases"] == 20, name

