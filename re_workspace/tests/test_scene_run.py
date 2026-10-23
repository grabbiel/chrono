"""ct_scene_run.py: the Scene Director's VM timeline against the runtime trace,
its durations against the ROM's handlers and its formations against the
ROM's battle hand-off.

The parsing, the bar derivation and the random states run on synthetic data.
With the ROM, ChronoRET and a built `chronoforge`, two locations' timelines,
a sample of move/animation/wait durations and of formations must agree.

Run: re_workspace/.venv/bin/python -m pytest re_workspace/tests/test_scene_run.py -q
"""

import random
import subprocess
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))

import ct_scene_run as sr  # noqa: E402

TRACE = """\
location 1 (loc_001): 3 frames
load   obj  0 $0040 AD -> $0040 (yield)
load   obj  1 $0050 8B -> $0053
f0     obj  0 $0040 AD -> $0040 (yield)  [$7F0010] 00->01
f0     obj  1 $0053 18 -> $0060
f2     obj  0 $0040 AD -> $0042
f2     obj  0 $0042 12 -> $0047
f2     obj  1 $0060 E7 -> $0060 (yield)
f3     obj  1 $0070 BB unmodelled: opcode $BB at $0070 has no model yet
"""


def test_trace_lines_parse():
    steps = sr.trace_steps(TRACE)
    assert len(steps) == 8
    assert steps[0] == (-1, 0, 0x40, 0xAD, 0x40, False, None)
    assert steps[2] == (0, 0, 0x40, 0xAD, 0x40, False, None)
    assert steps[3][4:6] == (0x60, True)
    assert steps[-1][4] is None and steps[-1][6].startswith("unmodelled")


def test_bars_run_from_first_run_to_the_run_that_moves_on():
    lanes = sr.bars_from_steps(sr.trace_steps(TRACE))
    assert lanes[0] == [(0x40, -1, 2, 3), (0x42, 2, 2, 1)]
    # $E7 left unfinished when the object is moved elsewhere ends there; a stop ends at once.
    assert lanes[1] == [(0x50, -1, -1, 1), (0x53, 0, 0, 1), (0x60, 2, 3, 1), (0x70, 3, 3, 1)]


def test_formation_states_list_objects_near_the_screen():
    rng = random.Random(3)
    for _ in range(20):
        regions = dict(sr.formation_state(rng))
        n = regions[0x7F2000][0]
        assert 1 <= n <= 16
        kinds = regions[0x7E1100]
        assert all(kinds[s] in (4, 5, 6, 7, 0x80) for s in range(0, 0x80, 2))
        assert len(regions[0x7E0D00]) == 0x80


def test_duration_states_start_a_fresh_instruction():
    rng = random.Random(5)
    e4 = sr.E4(bytes(8))
    regions, slot = sr.duration_state(rng, 4, 0x96, e4, 2)
    fixed = {at: b[0] for at, b in regions if len(b) == 1}
    assert fixed[sr.UNK1001 + slot] == 0 and fixed[sr.UNK1000 + slot] == 2
    assert fixed[sr.KIND + slot] == 4 and fixed[sr.ARC + slot] == 0
    assert fixed[sr.MOVEFRAMES + slot] == 0 and fixed[sr.LOOPS + slot] == 0


def run_tool(*args):
    r = subprocess.run([sys.executable, str(WS / "tools" / "ct_scene_run.py"), *args],
                       capture_output=True, text=True, timeout=1800)
    return r.returncode, r.stdout + r.stderr


def test_timelines_equal_the_runtime_trace(rom_path, require):
    cli = require(sr.CLI, "chronoforge build")
    code, out = run_tool("trace-check", "--cli", str(cli), "--locations", "29,7", "--frames", "300")
    assert code == 0, out
    assert "2 of 2 locations" in out


def test_durations_agree_with_the_rom(rom_path, chronoret, require):
    cli = require(sr.CLI, "chronoforge build")
    code, out = run_tool("durations", "--cli", str(cli), "--per-op", "2", "--states", "1", "--frames", "120")
    assert code == 0, out
    assert " 0 disagree" in out


def test_formations_agree_with_the_rom(rom_path, chronoret, require):
    cli = require(sr.CLI, "chronoforge build")
    code, out = run_tool("formations", "--cli", str(cli), "--cases", "60")
    assert code == 0, out
    assert "60 of 60 formation cases agree" in out
