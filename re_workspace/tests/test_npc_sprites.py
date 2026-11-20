"""Field NPC sprites: records 7-255 as opcode $82 loads them (tools/ct_npc_sprites.py).

ROM-free: OBJ tile slots, the field's animation clock (plain, $FF marker,
counted loops), the frame-count end rule and the Swift vectors file, all on
synthetic bytes.

Local (ROM, ChronoRET): the source, code and data claims of `check`, and the
field's loader, frame builders, frame lookup and tick run in ChronoRET's
65816 interpreter for a few records (`check --run` covers all of them).
"""

import json
import os
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_npc_sprites as ns  # noqa: E402
import ct_sprites as cs  # noqa: E402


# --- ROM-free ---------------------------------------------------------------------------

def test_tile_slots_give_the_first_obj_tiles():
    assert ns.slot_tile(0x19) == 0x188 and ns.slot_tile(0x0C) == 0xC0
    assert ns.SLOT_TILE == {0: 0x188, 1: 0xC0}
    assert ns.npc_id(7) == "npc_007"


def run_clock(ids, durs, n, mode=0, loops=0):
    c = ns.Clock(ids, durs, mode=mode, loops=loops)
    out = []
    for _ in range(n):
        c.tick()
        out.append(c.frame())
    return out


def test_clock_steps_on_at_the_first_tick_and_restarts_at_a_zero_duration():
    # Frames 5, 6 for 3 and 2 ticks; the zero duration restarts the row.
    assert run_clock([5, 6, 0], [3, 2, 0], 9) == [6, 6, 5, 5, 5, 6, 6, 5, 5]


def test_clock_marker_shows_the_first_frame_for_its_duration():
    shown = run_clock([5, 6, ns.END_MARKER, 0], [3, 1, 4, 0], 12)
    assert shown == [6, 5, 5, 5, 5, 5, 5, 5, 6, 5, 5, 5]


def test_clock_counted_loops_take_two_off_from_three():
    c = ns.Clock([1, 2, 0], [1, 1, 0], mode=2, loops=5)
    loops = []
    for _ in range(8):
        c.tick()
        loops.append(c.loops)
    assert loops == [5, 3, 3, 1, 1, 1, 1, 1]
    assert c.column == 1           # held on the last frame


def test_synthetic_records_decode_by_class():
    _, expect, clocks = ns.synthetic_npc_rom()
    assert [d["record"] for d in expect] == [7, 8, 9]
    assert [d["layout"]["index"] for d in expect] == [0, 1, 0]
    assert expect[2]["fields"]["sizeByte"] == 4 and expect[2]["fields"]["size"] == 0   # bit 2 unread
    for d in expect:
        cols, rows, rec_bytes, objs = ns.FIELD_LAYOUTS[d["fields"]["size"]]
        assert all(len(f["cells"]) == cols * rows and len(f["pieces"]) == objs for f in d["frameList"])
        assert all(max(a["frames"]) < d["frames"]["count"] for a in d["animationList"])
    assert len(clocks) == 5


def test_swift_vectors_file_is_current():
    path = ns.VECTORS
    assert path.exists(), "regenerate with ct_npc_sprites.py vectors --out"
    assert path.read_text() == ns.vectors_text()
    vectors = json.loads(path.read_text())
    assert vectors["schema"] == "ct-npc-sprite-vectors/1" and len(vectors["npcs"]) == 3
    for d in vectors["npcs"]:
        assert len(d["tileIndices"]) == 2 * 64 * d["tiles"]["count"]


# --- Local: the ROM and ChronoRET --------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return cs.read_rom(rom_path)


def failed(claims):
    return [(name, *detail) for name, ok, *detail in claims if not ok]


def test_chronoret_source_claims(rom, chronoret):
    claims = cs.asm_claims(chronoret, routines=ns.ASM_CLAIMS, constants=ns.CONSTANT_CLAIMS)
    assert len(claims) == len(ns.ASM_CLAIMS) + len(ns.CONSTANT_CLAIMS)
    assert not failed(claims)


def test_code_and_data_claims(rom):
    assert not failed(ns.code_claims(rom) + ns.data_claims(rom))


def test_usage_counts(rom):
    used = ns.usage(rom)
    assert len(used) == 191
    assert sum(len(u["packs"]) for u in used.values()) == 1190
    assert all(u["locations"] for u in used.values())


def test_field_routines_run_as_modelled_for_some_records(rom, chronoret):
    # 67: sets 74/76's left and right facings; 95: class 1; 218: a bank's last frame block.
    claims = ns.run_claims(rom, ref=chronoret, records=[67, 95, 218])
    assert len(claims) == 4 and not failed(claims)
