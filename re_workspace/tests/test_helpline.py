"""The menu help line: item and tech descriptions as the menu draws them (tools/ct_helpline.py).

ROM-free: the tile words and their place in BG3's map, one upload of the glyph
buffer per glyph and of the map rows every step, the second line that is never
shown, the third that lands back on the first, a line past the row's column
31, the pen wrap that runs the tile loop away, and the Swift vectors file, all
on the synthetic font and invented strings of ct_dialogue.

Local (ROM, ChronoRET): every source, code and data claim of `check`, and the
routines run in ChronoRET's 65816 interpreter on a sample of real descriptions
and on the synthetic ones.
"""

import json
import os
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_dialogue as D  # noqa: E402
import ct_helpline as H  # noqa: E402


def g(text):
    return [0xA0 + ord(c) - 65 if c.isupper() else 0xBA + ord(c) - 97 if c.islower() else 0xEF for c in text]


def line(data, place="item"):
    regions = dict(D.synthetic_rom()[0])
    regions[D.TEXT_AT] = bytes(data)
    s = D.Settings(names=[[0xA0 + i] for i in range(8)])
    return H.HelpLine(D.Memory(regions=regions, ram=s.ram()), D.TEXT_AT, place).run()


# --- ROM-free ---------------------------------------------------------------------------

def test_tile_words_start_at_column_3_of_bg3_row_2():
    h = line(g("Ab") + [0])
    upper, lower = h.rows()
    assert upper[:3] == [0, 0, 0] and upper[3] == 0x3101 and lower[3] == 0x3111
    assert H.row_of("item") == 2 and H.row_of("tech") == 21
    assert H.screen_x(8) == 24


def test_one_glyph_a_frame_glyph_buffer_on_change_and_map_rows_always():
    h = line(g("Abc") + [3, 1] + [0])
    kinds = [u[1] for u in h.uploads]
    assert kinds == ["gfx", "map", "gfx", "map", "gfx", "map", "map", "map"]
    assert {u[2] for u in h.uploads if u[1] == "gfx"} == {0x7800}
    assert {u[2] for u in h.uploads if u[1] == "map"} == {0x6840}
    assert h.frame == 5 and h.summary()["fits"]


def test_tech_rows_go_to_6aa0():
    h = line(g("Ab") + [0], place="tech")
    assert {u[2] for u in h.uploads if u[1] == "map"} == {0x6AA0}


def test_a_second_line_is_drawn_but_never_sent():
    h = line(g("One") + [5] + g("Two") + [0])
    assert h.line == 1
    assert {u[2] for u in h.uploads if u[1] == "gfx"} == {0x7800, 0x7A00}
    two = [h.wram.get(0x4E84 + 0x80 + 2 * c, 0) | h.wram.get(0x4E85 + 0x80 + 2 * c, 0) << 8 for c in range(4)]
    assert two[1] == 0x3141                        # rows 4-5 in WRAM, column 3: tile word $41 on
    assert not h.summary()["fits"] and h.summary()["lines"] == 2
    assert all(w == 0 or (w & 0x3FF) < 0x140 for r in h.rows() for w in r)


def test_a_third_line_lands_back_on_the_first_rows():
    h = line(g("Aaaaaaa") + [5] + g("b") + [5] + g("C") + [0])
    assert h.line == 2
    assert h.rows()[0][3] == 0x3181                # Menu_TextCol $100 -> 0 (8-bit), tile word $81


def test_a_line_past_column_31_and_a_wrapping_pen():
    texts = H.synthetic_texts()
    regions = dict(D.synthetic_rom()[0])
    regions[D.TEXT_AT] = bytes(texts[3])
    regions[D.TEXT_AT + 0x100] = bytes(texts[5])
    mem = D.Memory(regions=regions)
    s = H.HelpLine(mem, D.TEXT_AT, "item").run().summary()
    assert s["pastRow"] and not s["fits"] and 240 < s["right"] <= 255
    with pytest.raises(H.HelpLineError, match="tile loop"):
        H.HelpLine(mem, D.TEXT_AT + 0x100, "item").run()


def test_pixels_follow_the_glyphs():
    h = line(g("A") + [0])
    pix = h.pixels()
    mem = D.Memory(regions=D.synthetic_rom()[0])
    glyph = D.glyph_pixels(mem, 0xA0)
    for y in range(12):
        assert pix[4 + y][24:36] == glyph[y]


def test_swift_vectors_file_is_current():
    assert H.VECTORS.exists(), "regenerate with ct_helpline.py vectors --out"
    assert H.VECTORS.read_text() == H.vectors_text()
    v = json.loads(H.VECTORS.read_text())
    assert v["schema"] == "ct-helpline-vectors/1"
    assert len(v["lines"]) == 2 * 2 * len(H.synthetic_texts())


# --- Local: the ROM and ChronoRET --------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return D.read_rom(rom_path)


def failed(claims):
    return [c for c in claims if not c[1]]


def test_helpline_source_claims(chronoret):
    claims = H.asm_claims(chronoret)
    assert len(claims) > 20 and not failed(claims)


def test_helpline_code_and_data_claims(rom):
    assert not failed(H.code_claims(rom) + H.data_claims(rom))


def test_helpline_runs_as_modelled(rom, chronoret):
    runner = H.patched_runner(rom, chronoret)
    s = D.default_settings()
    bad = []
    for place, index in (("item", 0x01), ("item", 0x40), ("item", 0xC0), ("tech", 0x05), ("tech", 0x40)):
        _, b = H.run_one(rom, runner, place, index, s)
        bad += b
    assert not bad
    assert not failed(H.run_synthetic(rom, chronoret))
