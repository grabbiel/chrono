"""ct_event_vm.py: the differential check of CTEventVM against the ROM's
opcode handlers.

The helpers run on synthetic data: the random states stay inside the bounds
the handlers index by, the comparison names the first difference and leaves
the handlers' scratch bytes out. With the ROM, ChronoRET and a built
`chronoforge`, a small sample of the party-control opcodes ($AF, $B0) runs both
ways and must agree.

Run: re_workspace/.venv/bin/python -m pytest re_workspace/tests/test_event_vm.py -q
"""

import json
import random
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
