"""The in-game dialogue box: font, window, layout and pacing (tools/ct_dialogue.py).

ROM-free: the 2bpp tile layout, the glyph blit at every pen shift class, the
width lookup's wrap past its table, the TextWin codes (line, page and key
breaks, waits, dictionary entries, names, numbers), the band's TM split and
gradient, and the Swift vectors file, all on a synthetic font and invented
strings.

Local (ROM, ChronoRET): every source, code and data claim of `check`, and a
subset of the `--run` claims (TextWin_DrawGlyph, the window tilemaps, the
synthetic messages and a few real ones in ChronoRET's 65816 interpreter).
"""

import json
import os
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_dialogue as ct  # noqa: E402


def g(text):
    """Invented strings in the synthetic font: A-Z $A0-$B9, a-z $BA-$D3, else space."""
    out = []
    for c in text:
        if c.isupper():
            out.append(0xA0 + ord(c) - 65)
        elif c.islower():
            out.append(0xBA + ord(c) - 97)
        else:
            out.append(0xEF)
    return out


@pytest.fixture(scope="module")
def synthetic():
    regions, messages = ct.synthetic_rom()
    return regions, messages


def run_text(regions, data, settings=None):
    s = settings or ct.Settings(names=[[0xA0 + i] for i in range(8)])
    mem_regions = dict(regions)
    mem_regions[ct.TEXT_AT] = bytes(data)
    return ct.Dialogue(ct.Memory(regions=mem_regions, ram=s.ram()), ct.TEXT_AT, s).run()


# --- ROM-free ---------------------------------------------------------------------------

def test_tile_offsets_follow_the_16_tile_layout():
    assert [ct.tile_offset(c) for c in (0, 1, 15, 16, 17, 32, 48, 63)] == \
        [0, 0x10, 0xF0, 0x200, 0x210, 0x100, 0x300, 0x3F0]
    assert len({ct.tile_offset(c) for c in range(64)}) == 64


def test_blit_stores_ors_and_spills_by_shift():
    # One glyph: row 0 plane 0 all twelve pixels set, nothing else.
    left = bytearray(24)
    left[0] = 0xFF
    right = bytearray(24)
    right[0] = 0xF0
    mem = ct.Memory(regions={ct.FONT + 24 * 0xA0: bytes(left), ct.FONT_RIGHT + 24 * 0x50: bytes(right)})
    assert ct.glyph_pixels(mem, 0xA0)[0] == [1] * 12
    for pen, cells in ((8, {(1, 0xFF), (2, 0xF0)}),            # shift 0: stores
                       (11, {(1, 0x1F), (2, 0xFE)}),           # shift 3: ORs the pen tile
                       (14, {(1, 0x03), (2, 0xFF), (3, 0xC0)})):  # shift 6: spills a third tile
        buf = bytearray(ct.BUFFER_BYTES)
        buf[ct.tile_offset(1) + ct.GLYPH_TOP_SKIP] = 0     # the OR target starts clear
        ct.blit(buf, mem, 0xA0, pen)
        got = {(c, buf[ct.tile_offset(c) + ct.GLYPH_TOP_SKIP]) for c in range(4)
               if buf[ct.tile_offset(c) + ct.GLYPH_TOP_SKIP]}
        assert got == cells, pen
        assert sum(1 for b in buf if b) == len(cells)


def test_blit_rows_8_to_11_go_to_the_next_tile_row():
    left = bytearray(24)
    left[16] = 0x80                     # plane row 16 = pixel row 8, plane 0
    mem = ct.Memory(regions={ct.FONT + 24 * 0xA0: bytes(left)})
    buf = bytearray(ct.BUFFER_BYTES)
    ct.blit(buf, mem, 0xA0, 0)
    assert [i for i, b in enumerate(buf) if b] == [ct.GLYPH_TOP_SKIP + 16 + 0xF0]


def test_width_lookup_wraps_for_wide_glyphs():
    table = bytes(range(1, 97)) + bytes((100 + i) & 0xFF for i in range(160))
    mem = ct.Memory(regions={ct.WIDTHS: table})
    assert ct.width(mem, 0xA0) == 1 and ct.width(mem, 0xFF) == 96
    assert ct.width(mem, 0x1A0) == 1                  # only the low byte counts
    assert ct.width(mem, 0x100) == table[0x60]        # $00 - $A0 wraps to $60: past the 96 entries


def test_line_page_and_key_breaks(synthetic):
    regions, _ = synthetic
    d = run_text(regions, g("ab") + [5] + g("c") + [0x0B] + g("d") + [0])
    glyphs = [(v, pen, line) for _, kind, v, pen, line in d.events if kind == "glyph"]
    assert [line for *_, line in glyphs] == [0, 0, 1, 0]
    assert glyphs[2][1] == ct.PEN_LEFT and glyphs[3][1] == ct.PEN_LEFT
    keys = [fr for fr, kind, *_ in d.events if kind == "key"]
    assert len(keys) == 2                              # the page key ($0B) and the end ($00)
    indent = run_text(regions, g("a") + [6] + g("b") + [0])
    assert [pen for _, kind, _, pen, _ in indent.events if kind == "glyph"][1] == ct.PEN_INDENT


def test_fourth_line_turns_the_page_without_a_key(synthetic):
    regions, _ = synthetic
    d = run_text(regions, g("a") + [5] + g("b") + [5] + g("c") + [5] + g("d") + [5] + g("e") + [0])
    assert [line for _, kind, _, _, line in d.events if kind == "glyph"] == [0, 1, 2, 3, 0]
    assert len([e for e in d.events if e[1] == "key"]) == 1


def test_one_glyph_per_frame_and_waits_in_units_of_15(synthetic):
    regions, _ = synthetic
    plain = run_text(regions, g("abcd") + [0])
    frames = [fr for fr, kind, *_ in plain.events if kind == "glyph"]
    assert frames == list(range(frames[0], frames[0] + 4))
    waited = run_text(regions, g("ab") + [3, 2] + g("cd") + [0])
    wf = [fr for fr, kind, *_ in waited.events if kind == "glyph"]
    assert wf[2] - wf[1] > 2 * ct.WAIT_UNIT
    assert waited.frame - plain.frame >= 2 * ct.WAIT_UNIT


def test_dictionary_names_and_numbers(synthetic):
    regions, _ = synthetic
    mem = ct.Memory(regions=regions)
    entry = 0xDE0000 | mem.word(ct.DICT_PTRS)
    d = run_text(regions, [0x21, 0])
    assert [v for _, kind, v, *_ in d.events if kind == "glyph"] == \
        [mem(entry + 1 + i) for i in range(mem(entry))]
    names = [[0xA0 + i, 0xBA + i] for i in range(8)]
    s = ct.Settings(names=names, party=(4, 0, 1), args=[0xE9, 0x03, 0x05])
    d = run_text(regions, [0x14, 0x1B, 0x1A, 0x0E, 0x0D, 0], s)
    got = [v for _, kind, v, *_ in d.events if kind == "glyph"]
    assert got[:6] == names[1] + names[4] + names[0]
    assert got[6:] == [ct.DIGIT0 + int(c) for c in "10015"]          # $03E9 = 1001, then 5
    hexed = run_text(regions, [0x0D, 0], ct.Settings(args=[0x3C], num_hex=True))
    assert [v for _, kind, v, *_ in hexed.events if kind == "glyph"] == [0xD7, 0xA2]   # '3', 'C'


def test_unknown_codes_stay_codes(synthetic):
    regions, _ = synthetic
    d = run_text(regions, g("a") + [0x10, 0x04] + g("b") + [0])
    assert [v for _, kind, v, *_ in d.events if kind == "code"] == [0x10, 0x04, 0]


def test_band_tm_split_and_gradient():
    first, lines = ct.band(4, 1)
    assert first == 44 and [tm for tm, *_ in lines] == [1, 1, 1, 5, 5, 1, 1, 1]
    first, lines = ct.band(12, 2)
    assert first == 159 and [tm for tm, *_ in lines].count(5) == 4
    assert lines[-1][1:] == (None, 0xE0)
    grad = ct.gradient()
    assert len(grad) == 90 and grad[0] == (ct.GRAD_ADD, 0xE8) and grad[-1] == (ct.GRAD_SUB, 0xE9)


def test_frame_and_text_tilemaps():
    frame, text = ct.frame_tilemap(), ct.text_tilemap()
    assert len(frame) == 10 and all(len(r) == 32 for r in frame)
    assert frame[0][0] == 0x20F0 and frame[9][31] == 0x20FB
    assert sorted(w & 0x3FF for r in text for w in r) == list(range(0x100, 0x200))


def test_swift_vectors_file_is_current():
    path = ct.VECTORS
    assert path.exists(), "regenerate with ct_dialogue.py vectors --out"
    assert path.read_text() == ct.vectors_text()
    vectors = json.loads(path.read_text())
    assert vectors["schema"] == "ct-dialogue-vectors/1"
    assert len(vectors["layouts"]) == 2 * len(ct.synthetic_rom()[1])


# --- Local: the ROM and ChronoRET --------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return ct.read_rom(rom_path)


def failed(claims):
    return [c for c in claims if not c[1]]


def test_chronoret_source_claims(chronoret):
    claims = ct.asm_claims(chronoret)
    assert len(claims) > 20 and not failed(claims)


def test_code_claims(rom):
    assert not failed(ct.code_claims(rom))


def test_data_claims(rom):
    assert not failed(ct.data_claims(rom))


def test_rom_routines_run_as_modelled(rom, chronoret):
    runner = ct.RomRunner(rom, chronoret)
    claims = [ct.run_glyphs(rom, runner, codes=list(range(0xA0, 0x100, 5)) + [0x100, 0x1FF, 0x2FF])]
    claims += ct.run_tilemaps(rom, runner)
    claims += ct.run_synthetic_messages(rom, chronoret)
    assert not failed(claims)


def test_real_messages_run_as_modelled(rom, chronoret, require):
    require(ct.CORPUS, "message corpus")
    labels = ct.corpus_labels()[::400][:4]
    claims = ct.run_messages(rom, ct.RomRunner(rom, chronoret), labels, [ct.default_settings(press=2)])
    assert not failed(claims)
