"""The dialogue box's place and the choice cursor (tools/ct_boxchoice.py).

ROM-free: the place by Field_Unk30 and the speaker's screen Y (only its low
byte), the choice operand's lines, Sub_1ADF's steps and wraps, the cursor's
VRAM writes against the text grid, and the Swift vectors file.

Local (ROM, ChronoRET): every source, code and data claim of `check`, and
Field_Unk1F87, Sub_1ADF and Irq_DrawChoiceCursor run in ChronoRET's 65816
interpreter against the model.
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
import ct_boxchoice as B  # noqa: E402


# --- ROM-free ---------------------------------------------------------------------------

def test_place_by_opcode_then_by_the_speakers_half_of_the_screen():
    assert B.box_place(1, 0x10) == B.box_place(1, 0xF0) == 1
    assert B.box_place(2, 0x10) == B.box_place(2, 0xF0) == 2
    assert B.box_place(0, 0x7F) == 2 and B.box_place(0, 0x80) == 1     # upper half: the box at the bottom
    assert B.box_place(3, 0x0140) == 2 and B.box_place(0xFF, 0x01C0) == 1   # the high byte does not count
    assert [B.OPCODE_UNK30[op] for op in (0xBB, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4)] == [0, 0, 1, 2, 1, 2]


def test_choice_operand_and_steps():
    assert B.choice_limits(0x06) == (1, 2)
    assert B.choice_limits(0x0F) == (3, 3)
    walk, cur = [], 1
    for key in ("down", "down", "down", "up", "up", "up"):
        cur = B.step_choice(cur, 0x07, key)            # lines 1-3
        walk.append(cur)
    assert walk == [2, 3, 1, 3, 2, 1]
    assert B.step_choice(0, 0x01, "up") == 1           # from 0 Up goes to the last line
    assert B.step_choice(2, 0x02, None) == 2


def test_sub_1adf_outside_a_choice_parks_the_cursor():
    assert B.sub_1adf(3, 2, 0, 3, 9, 0, 0, 0, 0x1234) == (3, 4, 2, 0x1234)   # made: Field_Unk66 = 2
    assert B.sub_1adf(3, 4, 0, 3, 9, 0x80, 0, 0, 0x1234) == (3, 4, 9, 0)     # already 4; F6 bit 7 clears F34
    assert B.sub_1adf(1, 2, 0, 3, 9, 0, B.PAD_DOWN, 0, 5) == (1, 2, 9, 5)    # 1: no move
    assert B.sub_1adf(2, 1, 0, 3, 9, 0, 0, B.PAD_CONFIRM, 5) == (3, 1, 9, 5)
    assert B.sub_1adf(2, 1, 0, 3, 9, 0, B.PAD_DOWN | B.PAD_UP, B.PAD_CONFIRM, 5) == (2, 2, 9, 5)  # Down first


def test_cursor_writes_and_the_grid_it_puts_back():
    writes, after = B.cursor_writes(1)
    assert after == 1 and len(writes) == 16
    assert writes[-4:] == [(0x1C42, 0x28FC), (0x1C43, 0x28FD), (0x1C62, 0x28FE), (0x1C63, 0x28FF)]
    grid = D.text_tilemap()
    for at, word in writes[:-4]:
        row, col = divmod(at - 0x1C00, 32)
        assert grid[row][col] == word
    writes, after = B.cursor_writes(4)
    assert after == B.CURSOR_IDLE and len(writes) == 16 and all(w >> 8 == 0x29 for _, w in writes)


def test_cursor_pixels_from_the_synthetic_rom():
    regions = dict(D.synthetic_rom()[0])
    regions[B.CURSOR_GFX] = bytes([0xFF, 0x00] * 8 + [0x00, 0xFF] * 8 + [0xFF] * 16 + [0] * 16)
    pix = B.cursor_tiles(D.Memory(regions=regions))
    assert pix[0][:8] == [1] * 8 and pix[0][8:] == [2] * 8 and pix[8][:8] == [3] * 8 and pix[8][8:] == [0] * 8


def test_swift_vectors_file_is_current():
    assert B.VECTORS.exists(), "regenerate with ct_boxchoice.py vectors --out"
    assert B.VECTORS.read_text() == B.vectors_text()
    v = json.loads(B.VECTORS.read_text())
    assert v["schema"] == "ct-choice-vectors/1" and len(v["cursors"]) == 6


# --- Local: the ROM and ChronoRET --------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return D.read_rom(rom_path)


def failed(claims):
    return [c for c in claims if not c[1]]


def test_boxchoice_source_claims(chronoret):
    claims = B.asm_claims(chronoret)
    assert len(claims) > 20 and not failed(claims)


def test_boxchoice_code_and_data_claims(rom):
    assert not failed(B.code_claims(rom) + B.data_claims(rom))


def test_boxchoice_routines_run_as_modelled(rom, chronoret):
    claims = B.run_claims(rom, chronoret)
    assert len(claims) == 3 and not failed(claims)
