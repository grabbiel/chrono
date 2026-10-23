#!/usr/bin/env python3
"""Chrono Trigger dialogue box: font, widths, window, layout and pacing, from the ROM's own routines.

Everything here is read by matched, commented ChronoRET routines (MIT;
refs/ChronoRET) and is checked against them: `check` holds the static claims
(source lines, the ROM's code operands, data shapes), `check --run` runs the
routines themselves in ChronoRET's 65816 interpreter.

Font (TextWin_DrawGlyph $C2:5DC4). Glyph g (16-bit: $A0-$FF, or $01xx/$02xx
after the prefix codes) is 12 x 12 pixels, 2bpp: 24 bytes at $FF:2060 + 24 g
give the left 8 pixels of each plane row (plane 0, plane 1, ... for rows
0-11), and 24 bytes at $FF:3860 + 24 (g >> 1) the right 4 (high nibble for
an even g, low for an odd one). The pen advance is entry (g low byte - $A0)
& $FF of TextWin_GlyphWidths ($C2:60E6, 96 bytes for $A0-$FF; the quirk lets
a wide glyph read past it). TextWin_Blit2bpp ORs a glyph into the 1 KB line
buffer $7E:F000 (store, not OR, at a pen on a tile boundary): rows 0-3 into
lines 4-7 of the upper tile row, rows 4-11 into the lower one, 2bpp tiles of
16 bytes, columns 0-15 from $000 and 16-31 from $200, the lower tile row
$100 on (TextWin_TileOfs2bpp).

Window (the field, bank $C0, and its HDMA builders, bank $FD). The text line
being written is sent to VRAM $5800 + line x $200 (Field_UploadUnk5800), BG3
characters $100-$1FF; the window is a band of 2n lines (n = Field_Unk27, 0-40,
opened and closed by 4 a frame) centred on line 48 (Field_Unk26 = 1) or 171
(2), with its own BG1SC/BG3SC ($1C: the tilemap at $1C00), scroll (BG1 V $37
/ -$44, BG3 V -$0F / -$8A), TM (BG1 on the a, BG1+BG3 on the b middle lines)
and colour math (EngFD_UnkD52D's add/subtract gradient on BG1). The tilemap
rows 0-7 are the text grid (Field_Unk2B78, high byte $29: BG3 palette 2) and
rows 8-17 the frame (Field_Unk29F7, BG1 tiles $F0-$FF and $3FC-$3FF, palette
0). Menu_Config01 bits 0-2 pick one of 8 frame graphics sets ($FF:9E10 + $280
k, Field_UploadUnk1F00) and colour sets (Pal_LoadUnkRow0: colours 1-15 of row
0 from $FF:B210 + 2 + 16 k; colours 9-11, the text, forced to three greys).

Layout and pacing (Field_Unk1F87 $C0:1F87 every frame, Field_MsgStep $C0:2126,
TextWin_Step $C2:5823 with one step per frame). The model below transcribes
those state machines and the line buffer byte for byte; control codes are
named only by what their handlers do: $05/$06 a new line (pen 8 / $14), $07/$08
the same after a key, $09/$0A a new page, $0B/$0C after a key, $03 n a wait of
15 n frames, $00 the end after a key, $04 and $10 a frame with nothing drawn,
the 4th line's new line turns the page without a key. Every other code keeps
its raw value.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_dialogue.py font [--rom PATH]                     the font and window as JSON (counts and digests)
    ct_dialogue.py layout <table:index> [--rom PATH]     one message's layout and pacing (numbers only)
    ct_dialogue.py check [--rom PATH] [--run]            every evidence claim, ct_helpline and ct_boxchoice included (exit 1 on a failure)
    ct_dialogue.py verify-cli <chronoforge> [--rom PATH] the Swift CLI's font and layouts against this decode
    ct_dialogue.py vectors (--out | --check) P           synthetic vectors for the Swift twin
"""

import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
REF = WS / "refs" / "ChronoRET"
ROM_PATH = WS / "ct_clean.sfc"
CORPUS = WS / "assets" / "text" / "message_corpus.json"
VECTORS = WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "dialogue" / "dialogue_vectors.json"
ROM_SIZE = 4 * 1024 * 1024
ROM_SHA256 = "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9"


def pc(long):
    """HiROM file offset of a 24-bit address."""
    return (long >> 16 & 0x3F) << 16 | long & 0xFFFF


def snes(long):
    return f"${long >> 16:02X}:{long & 0xFFFF:04X}"


# --- Addresses and constants (ChronoRET include/*.inc) ------------------------------------

FONT, FONT_RIGHT = 0xFF2060, 0xFF3860                   # !TextWinRom_Font / !TextWinRom_FontRight
WIDTHS = 0xC260E6                                       # TextWin_GlyphWidths
TILE_OFS = 0xC25FE6                                     # TextWin_TileOfs2bpp
CHAR_NAME_PTRS, STR_NADIA = 0xC25FD8, 0xC26146          # TextWin_CharNamePtrs, TextWin_StrNadia
DICT_PTRS = 0xDEFA00                                    # !TextWin_DictPtrs
TECH_NAMES, ENEMY_NAMES, ITEM_NAMES = 0xCC15C4, 0xCC6500, 0xCC0B5E
HEX_GLYPHS = 0xC25D03                                   # TextWin_HexGlyphs
CHAR_NAMES, PARTY, ITEM_ID = 0x7E2C23, 0x7E2980, 0x7F0200
ARGS, NUM_HEX = 0x7E0200, 0x7E02A1                      # TextWin_Unk3D's start ($00:0200), !TextWin_NumHex
FIRST_GLYPH, FIRST_DICT = 0xA0, 0x21
PEN_LEFT, PEN_INDENT = 8, 0x14                          # !TextWin_PenXLeft / !TextWin_PenXIndent
GLYPH_TOP_SKIP = 8
CHAR_NAME_MAX, CHAR_NAME_SIZE, ROM_NAME_SIZE, NAME_PAD, TECH_ICON = 5, 6, 11, 0xEF, 0x2F
DIGIT0 = 0xD4
STEP_DONE = 0x10
WAIT_UNIT, LAST_LINE, OPEN_SIZE, SWALLOW = 15, 3, 0x29, 0xFFFF   # !FieldMsg_WaitUnit ... !Field_Unk34Swallow
BUFFER, BUFFER_BYTES = 0x7EF000, 0x400                  # !Field_Unk7EF000, !Field_UploadUnk5800Bytes
TEXT_VRAM, LINE_WORDS = 0x5800, 0x200                   # !Field_UploadVram5800, Field_Unk31 x $200
FRAME_SRCS, FRAME_SET_BYTES = 0xC06EA0, 0x280           # Field_UploadUnk1F00Srcs ($FF offsets), $200 + $80
FRAME_VRAM, FRAME_ALT_VRAM = 0x1F00, 0x4FC0             # !Field_UploadVram1F00 / 4FC0
PAL_SETS, PAL_GREYS = 0xFFB210, (0x0C63, 0x18C6, 0x739C)   # !FieldRom_PalRow0Sets, !Pal_Grey9-11
STYLES = 8                                              # Menu_Config01 bits 0-2 (!Pal_Row0SetMask)
TILEMAP_TEXT, TILEMAP_FRAME = 0x1C00, 0x1D00            # !Field_UploadVram1C00 / 1D00
FRAME_TILE, FRAME_HI, FRAME_HI_ALT, TEXT_HI = 0xF0, 0x20, 0x23, 0x29
BAND_SC = 0x1C                                          # !Hdma_ScRecord2Unk: BG1SC = BG3SC = $1C in the band
BAND_SCROLL = {1: (0x0037, 0xFFF1), 2: (0xFFBC, 0xFF76)}  # (BG1 V, BG3 V): !Hdma_ScrollPair0-3
BAND_CENTRE = {1: 48, 2: 171}
TM_BAND, TM_EDGE, TM_CAP, TM_MIN = 5, 1, 10, 2          # $7F:1524 / $1528, !HdmaBand_TmCap / TmMin
GRAD_LINES, GRAD_STEPS, GRAD_ADD, GRAD_SUB = 40, 8, 0x01, 0x81
BGMODE, BG12NBA, BG34NBA, CGWSEL = 0x09, 0x11, 0x05, 0x02   # the field's (CTMapROM / Ppu_SetBgLayout)

# Field DP $0100 bytes (ram_engine.inc).
F29, F26, F27, F2A, F2B, F2D, F30, F31, F32, F33, F34, F36, F54, F62 = (
    0x7E0129, 0x7E0126, 0x7E0127, 0x7E012A, 0x7E012B, 0x7E012D, 0x7E0130, 0x7E0131, 0x7E0132, 0x7E0133,
    0x7E0134, 0x7E0136, 0x7E0154, 0x7E0162)
TW_STATUS, TW_PENX, TW_CODE3, TW_STATE = 0x7E0215, 0x7E0234, 0x7E0216, 0x7E0230


# --- Memory: the ROM and the RAM a message reads -----------------------------------------

def canon(addr):
    """Low WRAM and its mirrors as $7E:0000-$1FFF; bank $7E/$7F as is."""
    addr &= 0xFFFFFF
    bank, low = addr >> 16, addr & 0xFFFF
    if (bank < 0x40 or 0x80 <= bank < 0xC0) and low < 0x2000:
        return 0x7E0000 | low
    return addr


class Memory:
    """The 24-bit space a message's routines read: the ROM (banks $C0-$FF, a
    4 MiB HiROM image or a sparse {address: byte} map) and RAM given as
    {address: byte} (names, party, item id, the argument block)."""

    def __init__(self, rom=None, regions=None, ram=None):
        self.rom = rom
        self.sparse = {}
        for long, data in (regions or {}).items():
            for i, b in enumerate(data):
                self.sparse[long + i] = b
        self.ram = {canon(k): v for k, v in (ram or {}).items()}

    def __call__(self, addr):
        addr = canon(addr)
        if addr in self.ram:
            return self.ram[addr]
        bank = addr >> 16
        if bank >= 0xC0 or (bank < 0x7E and addr & 0xFFFF >= 0x8000):
            if self.rom is not None:
                return self.rom[pc(addr)]
            return self.sparse.get(addr | 0xC00000, 0)
        return 0

    def word(self, addr):
        return self(addr) | self(addr + 1) << 8


# --- Font ----------------------------------------------------------------------------------

def font_addresses(g):
    """(left 24 bytes, right 24 bytes) addresses of glyph g, as TextWin_DrawGlyph
    computes them (16-bit sums in bank $FF)."""
    return (0xFF0000 | (g * 24 + (FONT & 0xFFFF)) & 0xFFFF,
            0xFF0000 | ((g >> 1) * 24 + (FONT_RIGHT & 0xFFFF)) & 0xFFFF)


def glyph_row_bytes(mem, g):
    """The 24 (plane row) 12-bit words of glyph g, bits 15-4 = pixels 0-11."""
    left, right = font_addresses(g)
    out = []
    for r in range(24):
        hi, nib = mem(left + r), mem(right + r)
        lo = (nib << 4) & 0xFF if g & 1 else nib & 0xF0
        out.append(hi << 8 | lo)
    return out


def glyph_pixels(mem, g):
    """12 rows x 12 columns of colour indices 0-3."""
    words = glyph_row_bytes(mem, g)
    return [[(words[2 * y] >> (15 - x) & 1) | (words[2 * y + 1] >> (15 - x) & 1) << 1 for x in range(12)]
            for y in range(12)]


def width(mem, g):
    return mem(WIDTHS + ((g & 0xFF) - FIRST_GLYPH & 0xFF))


def tile_offset(col):
    """TextWin_TileOfs2bpp entry `col` (0-63) as its layout documents it."""
    return (col & 15) * 16 + (col >> 4 & 1) * 0x200 + (col >> 5 & 1) * 0x100


def blit(buf, mem, g, pen):
    """TextWin_Blit2bpp of glyph g at pen X `pen` into the 1 KB buffer (bytearray)."""
    shift, tile = pen & 7, (pen & 0xF8) >> 3
    ofs = [tile_offset(tile), tile_offset(tile + 1), tile_offset(tile + 2)]
    words = glyph_row_bytes(mem, g)
    out = GLYPH_TOP_SKIP
    for r, w in enumerate(words):
        if r == 8:
            out += 0xF0
        if shift == 0:
            buf[(out + ofs[1]) & 0x3FF] = w & 0xFF
            buf[(out + ofs[0]) & 0x3FF] = w >> 8
        elif shift <= 4:
            v = w >> shift
            buf[(out + ofs[1]) & 0x3FF] = v & 0xFF
            buf[(out + ofs[0]) & 0x3FF] |= v >> 8
        else:
            k = 8 - shift
            v = (w << k) & 0xFFFF
            buf[(out + ofs[2]) & 0x3FF] = v & 0xFF
            buf[(out + ofs[1]) & 0x3FF] = v >> 8
            buf[(out + ofs[0]) & 0x3FF] |= w >> (16 - k)
        out += 1


def glyph_codes():
    """Every glyph the routine can be asked to draw from a message: $A0-$FF and $0100-$02FF."""
    return list(range(FIRST_GLYPH, 0x100)) + list(range(0x100, 0x300))


def font_digest(mem, codes=None):
    h = hashlib.sha256()
    for g in codes or glyph_codes():
        for row in glyph_pixels(mem, g):
            h.update(bytes(row))
        h.update(bytes([width(mem, g)]))
    return h.hexdigest()


# --- Window --------------------------------------------------------------------------------

def frame_set(mem, style):
    """(16 tiles $F0-$FF, 4 tiles $3FC-$3FF) of frame style 0-7: 4bpp tile bytes."""
    start = 0xFF0000 | mem.word(FRAME_SRCS + 2 * style)
    data = bytes(mem(start + i) for i in range(FRAME_SET_BYTES))
    return data[:0x200], data[0x200:]


def window_palette(mem, style):
    """Colours 1-15 of CGRAM row 0 for style 0-7 (Pal_LoadUnkRow0), colour 0 left None."""
    src = PAL_SETS + 2 + 16 * style
    out = [None] + [mem.word(src + 2 * i) for i in range(15)]
    out[9], out[10], out[11] = PAL_GREYS
    return out


def frame_tilemap():
    """Field_Unk29F7's 32 x 10 map (tilemap words)."""
    t, hi, alt = FRAME_TILE, FRAME_HI << 8, FRAME_HI_ALT << 8
    rows = [[t | hi] + [(t + 1 + (i & 1)) | hi for i in range(30)] + [(t + 3) | hi]]
    for band in range(2):
        for r in range(4):
            left, right = (t + 4, t + 5) if r in (0, 2) else (t + 6, t + 7)
            pair = (t + 12, t + 13) if r in (0, 2) else (t + 14, t + 15)
            first = (hi, alt) if r < 2 else (alt, hi)
            row = [left | hi]
            for block in range(15):
                h = first[block & 1]
                row += [pair[0] | h, pair[1] | h]
            rows.append(row + [right | hi])
    rows.append([(t + 8) | hi] + [(t + 9 + (i & 1)) | hi for i in range(30)] + [(t + 11) | hi])
    return rows


def text_tilemap():
    """Field_Unk2B78's 32 x 8 map: tiles $00-$FF in runs of 16, high byte $29."""
    runs = [0x00, 0x20, 0x10, 0x30, 0x40, 0x60, 0x50, 0x70, 0x80, 0xA0, 0x90, 0xB0, 0xC0, 0xE0, 0xD0, 0xF0]
    flat = [(t + i) | TEXT_HI << 8 for t in runs for i in range(16)]
    return [flat[32 * r:32 * r + 32] for r in range(8)]


def gradient():
    """EngFD_UnkD52D's (CGADSUB, COLDATA) pairs: 8 steps of 5 adding $E8-$E1, 5 subtracting $E0,
    9 steps of 5 subtracting $E1-$E9."""
    step = GRAD_LINES // GRAD_STEPS
    out = []
    for v in range(0xE8, 0xE0, -1):
        out += [(GRAD_ADD, v)] * step
    out += [(GRAD_SUB, 0xE0)] * (step + 2 * (GRAD_LINES % GRAD_STEPS))
    for v in range(0xE1, 0xEA):
        out += [(GRAD_SUB, v)] * step
    return out


def band(n, place):
    """The band's per-line registers at Field_Unk27 = n (1-40) and place 1/2:
    (first visible line, [(TM, CGADSUB, COLDATA)] per band line)."""
    first = BAND_CENTRE[place] - n
    a, b = (n - 1, TM_MIN) if n <= TM_CAP else (TM_CAP, 2 * n - 2 * TM_CAP)
    grad = gradient()
    lines = []
    for k in range(2 * n):
        tm = TM_BAND if a <= k < a + b else TM_EDGE
        math = grad[((GRAD_LINES - n) & 0x3F) + k] if k < 2 * n - 1 else (None, 0xE0)
        lines.append((tm, *math))
    return first, lines


# --- The model: TextWin + the field's message state machine ------------------------------

class Settings:
    """What a message reads besides its bytes: names (8 x up to 6 glyph bytes,
    0-terminated), the party (3 ids), the treasure item id, the 12 argument
    bytes at $0200, TextWin_NumHex, the window place (1 top, 2 bottom) and
    how many frames after a key wait starts the key is pressed (>= 1)."""

    def __init__(self, names=None, party=(0, 1, 2), item=0, args=None, num_hex=False, place=1, press=1):
        self.names = [list(n) for n in (names or [[]] * 8)]
        self.party, self.item = list(party), item
        self.args = list(args or [0] * 12)
        self.num_hex, self.place, self.press = num_hex, place, max(1, press)

    def ram(self):
        out = {}
        for i in range(8):
            name = (self.names[i] + [0] * CHAR_NAME_SIZE)[:CHAR_NAME_SIZE]
            for k, b in enumerate(name):
                out[CHAR_NAMES + CHAR_NAME_SIZE * i + k] = b
        for i, p in enumerate(self.party):
            out[PARTY + i] = p
        out[ITEM_ID], out[ITEM_ID + 1] = self.item & 0xFF, self.item >> 8
        for i, b in enumerate(self.args):
            out[ARGS + i] = b
        out[NUM_HEX] = 1 if self.num_hex else 0
        return out


class DialogueError(ValueError):
    pass


class TextWin:
    """TextWin_Init / TextWin_Step (bank $C2) on a Memory, mode 0 (2bpp), one
    step per call (the field's TextWin_StepCount 1)."""

    def __init__(self, mem, text, buf, log):
        self.mem, self.ptr, self.buf, self.log = mem, text, buf, log
        self.state, self.status, self.pen, self.code3 = 0, 4, PEN_LEFT, 0
        self.sub, self.left, self.argp = 0, 0, ARGS
        self.digits = []

    def arg(self, n):
        if self.argp + n > ARGS + 12:
            raise DialogueError(f"an argument code reads past $020B (the TextWin block itself)")
        v = sum(self.mem(self.argp + i) << 8 * i for i in range(n))
        self.argp += n
        return v

    def draw(self, g):
        self.log("glyph", g, self.pen)
        blit(self.buf, self.mem, g, self.pen)
        self.pen = (self.pen + width(self.mem, g)) & 0xFF

    def step(self):
        if self.status == 0:
            return
        if self.status in (5, 7, 9, 11):
            self.pen = PEN_LEFT
        elif self.status in (6, 8, 10, 12):
            self.pen = PEN_INDENT
        [self.state0, self.state_sub, self.state_dec, self.state_sub][self.state]()

    def next_byte(self):
        b = self.mem(self.ptr)
        self.ptr = (self.ptr & 0xFF0000) | (self.ptr + 1) & 0xFFFF
        return b

    def start_sub(self, addr, count, state=1):
        self.sub, self.left, self.state = addr, count, state

    def state0(self):
        b = self.next_byte()
        if b >= FIRST_GLYPH:
            return self.glyph0(b)
        if b >= FIRST_DICT:
            at = 0xDE0000 | self.mem.word(DICT_PTRS + ((b - FIRST_DICT) * 2 & 0xFF))
            self.start_sub(at + 1, self.mem(at))
            return self.state_sub()
        self.log("code", b, self.pen)
        if b in (0, *range(4, 13)):
            self.status = b
        elif b == 3:
            self.code3, self.status = self.next_byte(), 3
        elif b in (1, 2):
            return self.glyph0(b << 8 | self.next_byte())
        elif b in (0x0D, 0x0E, 0x0F):
            return self.number(b)
        elif b == 0x10:
            return
        elif b == 0x11:
            return self.char_name(self.arg(1) * 2, doubled=True)      # a 16-bit ASL here
        elif b == 0x12:
            e = self.next_byte()
            if e >= 8:
                at = 0xDE0000 | self.mem.word(DICT_PTRS + (e - 8 + 0x1F) * 2)
                self.start_sub(at + 1, self.mem(at))
                return self.state_sub()
            if e > 1:
                raise DialogueError(f"code $12 ${e:02X} jumps past TextWin_ExtTable")
            base = TECH_NAMES if e == 0 else ENEMY_NAMES
            at = base + self.arg(1) * ROM_NAME_SIZE
            if e == 1:
                count = ROM_NAME_SIZE
            else:
                count = self.name_len(at, ROM_NAME_SIZE)
                if self.mem(at) == TECH_ICON:
                    at += 1
                    count = self.name_len(at, ROM_NAME_SIZE - 1)
            self.start_sub(at, count)
            return self.state_sub()
        elif 0x13 <= b <= 0x19:
            return self.char_name(b - 0x13)
        elif b == 0x1A:
            return self.ram_name(CHAR_NAMES)
        elif 0x1B <= b <= 0x1D:
            return self.char_name(self.mem(PARTY + b - 0x1B) * 2 & 0xFF, doubled=True)
        elif b == 0x1E:
            self.start_sub(STR_NADIA, 5)
            return self.state_sub()
        elif b == 0x1F:
            at = ITEM_NAMES + (self.mem(ITEM_ID)) * ROM_NAME_SIZE + 1
            self.start_sub(at, self.name_len(at, ROM_NAME_SIZE - 1))
            return self.state_sub()
        elif b == 0x20:
            return self.ram_name(CHAR_NAMES + 7 * CHAR_NAME_SIZE)

    def glyph0(self, g):
        self.draw(g)
        self.status = STEP_DONE

    def name_len(self, at, most):
        n = 0
        while self.mem(at + n) != NAME_PAD:
            n += 1
            if n >= most:
                break
        return n

    def char_name(self, index, doubled=False):
        x = index if doubled else index * 2 & 0xFF      # the 8-bit ASL of codes $13-$19
        return self.ram_name(0x7E0000 | self.mem.word(CHAR_NAME_PTRS + x))

    def ram_name(self, at):
        n = 0
        while self.mem(at + n) != 0:
            n += 1
            if n >= CHAR_NAME_MAX:
                break
        self.start_sub(at, n)
        return self.state_sub()

    def number(self, code):
        value = self.arg({0x0D: 1, 0x0E: 2, 0x0F: 3}[code])
        if code != 0x0F and self.mem(NUM_HEX):
            glyphs = []
            for byte in ([value] if code == 0x0D else [value >> 8, value & 0xFF]):
                for nib in (byte >> 4, byte & 15):
                    g = self.mem.word(HEX_GLYPHS + 2 * nib)
                    glyphs += [g >> 8, g & 0xFF] if g >= 0x100 else [g]
            self.digits = glyphs
            self.start_sub(None, len(glyphs), state=3)
            return self.state_sub()
        self.digits = [int(c) for c in str(value)]
        self.start_sub(None, len(self.digits), state=2)
        return self.state_dec()

    def sub_byte(self):
        if self.sub is None:
            b = self.digits[0]
            self.digits = self.digits[1:]
            return b
        b = self.mem(self.sub)
        self.sub = (self.sub & 0xFF0000) | (self.sub + 1) & 0xFFFF
        return b

    def state_sub(self):
        b = self.sub_byte()
        if b in (1, 2):
            b = b << 8 | self.sub_byte()
        self.draw(b)
        self.sub_end()

    def state_dec(self):
        self.draw(DIGIT0 + self.sub_byte() & 0xFF)
        self.sub_end()

    def sub_end(self):
        self.left = (self.left - 1) & 0xFF
        if self.left == 0:
            self.state = 0
        self.status = STEP_DONE


class Dialogue:
    """Field_Unk1F87 (every frame) with Field_MsgStep and the NMI's line upload,
    from the message start (Field_Unk29 = 1) to the window closed (0)."""

    def __init__(self, mem, text, settings, log=None):
        self.mem, self.text, self.s = mem, text, settings
        self.buf = bytearray(BUFFER_BYTES)
        self.f = {"29": 1, "26": 0, "27": 0, "31": 0, "34": 0, "36": 0}
        self.tw = None
        self.frame = 0
        self.events = []            # (frame, kind, value, pen, line)
        self.uploads = []           # (frame, line, bytes)
        self.hold = None

    def log(self, kind, value, pen):
        self.events.append((self.frame, kind, value, pen, self.f["31"]))

    def clear(self):
        self.buf[:] = bytes(BUFFER_BYTES)

    def run(self, max_frames=20000):
        while self.f["29"]:
            if self.frame >= max_frames:
                raise DialogueError(f"no end within {max_frames} frames")
            self.step_frame()
        return self

    def press(self):
        """The key press, `press` frames after a key wait began (before Field_Unk1F87)."""
        f = self.f
        if f["29"] == 7 and f["34"] == SWALLOW:
            if self.hold is None:
                self.hold = self.frame
            if self.frame - self.hold >= self.s.press:
                f["34"], self.hold = 0, None
                self.events.append((self.frame, "key", 0, None, f["31"]))

    def step_frame(self):
        f = self.f
        self.press()
        st = f["29"]
        if st in (1, 8):
            self.clear()
            f["29"] += 1
            f["31"], f["36"] = 0, 1
        elif st in (2, 3, 4, 9, 10, 11):
            f["29"] += 1
            f["31"] += 1
        elif st == 5:
            if f["26"] == 0:
                f["26"], f["27"], f["31"], f["36"] = self.s.place, 0, 0, 0
                self.tw = TextWin(self.mem, self.text, self.buf, self.log)
            else:
                opened = f["27"] == OPEN_SIZE - 1
                for _ in range(4):
                    if opened:
                        break
                    f["27"] += 1
                    opened = f["27"] == OPEN_SIZE - 1
                if opened:
                    f["29"] = 6
                    self.msg_step()
        elif st == 6:
            self.msg_step()
        elif st == 7:
            self.wait()
        elif st == 12:
            f["29"] = 6
            self.msg_step()
        elif st == 13:
            # LDA; BEQ, then DEC / BEQ three times and a fourth DEC with no test
            closed = f["27"] == 0
            for i in range(4):
                if closed:
                    break
                f["27"] -= 1
                closed = i < 3 and f["27"] == 0
            if closed:
                f["29"], f["26"] = 0, 0
        if f["36"]:
            self.uploads.append((self.frame, f["31"], bytes(self.buf)))
            if f["36"] & 0x80:
                f["36"] = 0
        self.frame += 1

    def wait(self):
        f, tw = self.f, self.tw
        if f["34"] == SWALLOW:
            return
        if f["34"]:
            f["34"] -= 1
            return
        s = tw.status
        if 9 <= s <= 12:
            f["29"] = 8
        elif 5 <= s <= 8:
            f["29"] = 8 if f["31"] == LAST_LINE else 6
        elif s == 3 and tw.code3:
            f["29"] = 6
        else:
            f["29"] = 13

    def msg_step(self):
        f, tw = self.f, self.tw
        s = tw.status
        if s == 0:
            f["36"] = 0
            return
        if 9 <= s <= 12:
            f["31"] = 0
            self.clear()
        elif 5 <= s <= 8:
            f["31"] = 0 if f["31"] == LAST_LINE else f["31"] + 1
            self.clear()
        elif s == 3 and tw.code3 == 0:
            f["36"] = 0
            return
        tw.step()
        s = tw.status
        if s == 0 or s in (11, 12):
            f["34"] = SWALLOW
            self.page_wait()
        elif s in (9, 10):
            self.page_wait()
        elif s in (7, 8):
            f["34"], f["29"] = SWALLOW, 7
            self.line_end()
        elif s in (5, 6):
            self.line_end()
        elif s == 3:
            if tw.code3 == 0:
                self.page_wait()
            else:
                f["34"], f["29"], f["36"] = tw.code3 * WAIT_UNIT, 7, 1
        else:
            f["36"] = 1

    def line_end(self):
        if self.f["31"] != LAST_LINE:
            self.f["36"] = 1
        else:
            self.page_wait()

    def page_wait(self):
        self.f["29"], self.f["36"] = 7, 0x81


def layout_summary(d):
    """Numbers only: the frames, glyph count, pen and line of each glyph, the
    frames of the key waits and pages, and a digest of the uploaded lines."""
    glyphs = [(fr, v, pen, line) for fr, kind, v, pen, line in d.events if kind == "glyph"]
    keys = [fr for fr, kind, *_ in d.events if kind == "key"]
    h = hashlib.sha256()
    for fr, line, data in d.uploads:
        h.update(struct.pack("<IB", fr, line) + data)
    pages = [fr for fr, kind, v, *_ in d.events if kind == "code" and 9 <= v <= 12]
    return {"frames": d.frame, "glyphs": len(glyphs), "glyphFrames": [g[0] for g in glyphs],
            "pens": [g[2] for g in glyphs], "lines": [g[3] for g in glyphs], "keyFrames": keys,
            "pageCodes": pages, "uploads": len(d.uploads), "uploadDigest": h.hexdigest()}


# --- The corpus and the ROM's messages ------------------------------------------------------

def read_rom(path):
    data = Path(path).read_bytes()
    if len(data) == ROM_SIZE + 512:
        data = data[512:]
    if len(data) != ROM_SIZE:
        raise SystemExit("expected a 4 MiB Chrono Trigger ROM")
    return data


def message_address(rom, label):
    """`Messages_D8D000:12` or `D8D000:12` -> (table, index, the message's address)."""
    m = re.fullmatch(r"(?:Messages_)?([0-9A-Fa-f]{6}):(\d+)", label)
    if not m:
        raise SystemExit(f"bad message label {label!r} (want TABLE:INDEX, e.g. D8D000:12)")
    table, index = int(m.group(1), 16), int(m.group(2))
    return table, index, (table & 0xFF0000) | rom[pc(table + 2 * index)] | rom[pc(table + 2 * index + 1)] << 8


def corpus_labels():
    if not CORPUS.exists():
        return []
    labels = [c["label"] for c in json.loads(CORPUS.read_text())["cases"]]
    return [lab for lab in labels if re.fullmatch(r"Messages_[0-9A-F]{6}:\d+", lab)]   # not the unreferenced spans


def default_settings(press=1, place=1):
    """Placeholder names "A"-"H" ($A0+i), party 0-2, item 1, arguments 0x12, 0x34, ..."""
    return Settings(names=[[FIRST_GLYPH + i] for i in range(8)], item=1,
                    args=[(0x12 + 0x22 * i) & 0xFF for i in range(12)], place=place, press=press)


def layout(rom, label, settings=None):
    _, _, at = message_address(rom, label)
    s = settings or default_settings()
    return Dialogue(Memory(rom, ram=s.ram()), at, s).run()


# --- Evidence: the matched source --------------------------------------------------------------

ASM_CLAIMS = (
    ("bankC2/bankC2.asm", "TextWin_DrawGlyph", ("ADC.w #!TextWinRom_Font&$FFFF", "ADC.w #!TextWinRom_FontRight&$FFFF",
                                                "LDA.l TextWin_GlyphWidths,X", "ADC.b !TextWin_PenX")),
    ("bankC2/bankC2.asm", "TextWin_Blit2bppRow", ("LDA.b [!TextWin_FontPtr],Y", "AND.b #!TextWin_RightNibble")),
    ("bankC2/bankC2.asm", "TextWin_State0", ("CMP.b #!TextWin_FirstGlyph", "CMP.b #!TextWin_FirstDict",
                                             "JMP (TextWin_CodeTable,X)")),
    ("bankC2/bankC2.asm", "TextWin_StatusPenIndent", ("LDA.b #!TextWin_PenXIndent", "STA.b !TextWin_PenX")),
    ("bankC2/bankC2.asm", "TextWin_CodeStatusArg", ("STA.b !TextWin_Code3Arg",)),
    ("bankC2/bankC2.asm", "TextWin_CodeSetStatus", ("TYA", "STA.b !TextWin_Status")),
    ("bankC0/bankC0.asm", "Field_MsgStep", ("JSL BankC2_Entry0009", "LDA.b #!FieldMsg_WaitUnit",
                                           "LDX.w #!Field_Unk34Swallow", "CMP.b #!FieldMsg_LastLine")),
    ("bankC0/bankC0.asm", "Field_Unk1F87", ("JSR Field_MsgClearBuf", "LDA.b #!FieldMsg_OpenSize", "JSR Field_MsgStep")),
    ("bankC0/bankC0.asm", "Field_UploadUnk5800", ("ADC.w #!Field_UploadVram5800",)),
    ("bankC0/bankC0.asm", "Field_Unk29F7", ("LDA.b #!Field_Unk7EF000Tile", "LDA.b #!Field_Unk7EF000HiAlt")),
    ("bankC0/bankC0.asm", "Field_Unk2B78", ("LDY.b #!Field_Unk7EF000HiGrid",)),
    ("bankC0/bankC0.asm", "Field_UploadUnk1F00", ("LDA.l !Menu_Config01",)),
    ("bankC0/bankC0.asm", "Pal_LoadUnkRow0", ("ADC.w #!FieldRom_PalRow0Sets&$FFFF", "LDA.w #!Pal_Grey9")),
    ("bankFD/bankFD.asm", "EngFD_UnkC124", ("LDA.b #!Hdma_ScRecord2Unk", "LDA.w #!Hdma_ScrollPair0", "LDA.b #5")),
    ("bankFD/bankFD.asm", "EngFD_UnkD52D", ("LDA.b #!HdmaGrad_Lines", "LDA.b #!HdmaGrad_AddFirst")),
    ("bankFD/bankFD.asm", "FieldHdma_BuildTopBandA", ("LDX.w #!Hdma_Unk7F14F4&$FFFF", "LDX.w #(!Hdma_Unk7F14F8+4)&$FFFF",
                                                      "LDX.w #!Hdma_Unk7F1524&$FFFF")),
)
CONSTANT_CLAIMS = (
    ("include/constants_menu.inc", "!TextWinRom_Font = $FF2060"),
    ("include/constants_menu.inc", "!TextWinRom_FontRight = $FF3860"),
    ("include/constants_menu.inc", "!TextWin_PenXLeft = 8"),
    ("include/constants_menu.inc", "!TextWin_PenXIndent = $14"),
    ("include/constants_menu.inc", "!TextWin_GlyphTopSkip = 8"),
    ("include/constants_menu.inc", "!TextWin_DictPtrs = $DEFA00"),
    ("include/constants_engine.inc", "!FieldMsg_WaitUnit = 15"),
    ("include/constants_engine.inc", "!FieldMsg_LastLine = $03"),
    ("include/constants_engine.inc", "!FieldMsg_OpenSize = $29"),
    ("include/constants_engine.inc", "!Field_UploadVram5800 = $5800"),
    ("include/constants_engine.inc", "!Field_Unk7EF000HiGrid = $29"),
    ("include/constants_engine.inc", "!Hdma_ScrollPair1 = $FFF1"),
    ("include/constants_engine.inc", "!Hdma_ScrollPair3 = $FF76"),
    ("include/constants_engine.inc", "!HdmaBand_Half = $29"),
    ("include/constants_engine.inc", "!HdmaBand_TmCap = $0A"),
    ("include/ram_engine.inc", "!FieldRom_PalRow0Sets = $FFB210"),
)


def asm_claims(ref=REF):
    out, sources = [], {}
    for path, label, lines in ASM_CLAIMS:
        text = sources.setdefault(path, (ref / "asm" / path).read_text().splitlines())
        try:
            start = next(i for i, line in enumerate(text) if line.split(";")[0].strip() == f"{label}:")
        except StopIteration:
            out.append((f"{path} {label}", False, "label not found"))
            continue
        end = next((i for i in range(start + 1, len(text)) if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", text[i])
                    and not text[i].startswith(label)), len(text))
        body = [line.split(";")[0].strip() for line in text[start + 1:end]]
        at, missing = 0, None
        for want in lines:
            found = next((i for i in range(at, len(body)) if body[i] == want), None)
            if found is None:
                missing = want
                break
            at = found + 1
        out.append((f"{path} {label}", missing is None, f"missing {missing!r}" if missing else f"line {start + 1}"))
    for path, prefix in CONSTANT_CLAIMS:
        text = sources.setdefault(path, (ref / "asm" / path).read_text().splitlines())
        out.append((f"{path} {prefix.split()[0]}", any(line.startswith(prefix) for line in text), prefix))
    return out


# --- Evidence: the ROM's code bytes and data ----------------------------------------------------

def _body(rom, start, end):
    return bytes(rom[pc(start):pc(end) + 1])


def code_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    draw = _body(rom, 0xC25DC4, 0xC25E35)
    claim("$C2:5DC4 adds $2060 and $3860 (ADC #$2060; ADC #$3860) and reads the widths (LDA.l $C260E6,X)",
          b"\x69\x60\x20" in draw and b"\x69\x60\x38" in draw and b"\xbf\xe6\x60\xc2" in draw)
    claim("$C2:5DC4 skips 8 buffer bytes (ADC #$0008)", b"\x69\x08\x00" in draw)
    blit2 = _body(rom, 0xC25E36, 0xC25E88)
    claim("$C2:5E36 draws 4 + 8 byte pairs and steps $F0 to the lower tile row (LDA #$04; LDA #$08; ADC #$00F0)",
          b"\xa9\x04" in blit2 and b"\xa9\x08" in blit2 and b"\x69\xf0\x00" in blit2)
    status = _body(rom, 0xC25895, 0xC258B1)
    claim("$C2:5895 resets the pen to 8 / $14 (LDA #$08; LDA #$14)", b"\xa9\x08" in status and b"\xa9\x14" in status)
    step = _body(rom, 0xC02126, 0xC021E0)
    claim("$C0:2126 runs one step a frame (LDA #$01; STA $0213; JSL $C20009)",
          b"\xa9\x01\x8d\x13\x02\x22\x09\x00\xc2" in step)
    claim("$C0:2126 waits 15 frames per $03 unit (LDA #$0F; STA $4203) and holds with $FFFF (LDX #$FFFF)",
          b"\xa9\x0f\x8d\x03\x42" in step and b"\xa2\xff\xff" in step)
    claim("$C0:2126 compares the line with 3 (CMP #$03 after LDA $31)", b"\xa5\x31\xc9\x03" in step)
    f1f87 = _body(rom, 0xC01F87, 0xC020B1)
    claim("$C0:1F87 opens to $29 - 1 (LDA #$29; DEC A)", b"\xa9\x29\x3a" in f1f87)
    up = _body(rom, 0xC06ECB, 0xC06EF0)
    claim("$C0:6ECB sends $400 bytes (LDX #$0400) to $5800 + line x $200 (ADC #$5800)",
          b"\xa2\x00\x04" in up and b"\x69\x00\x58" in up)
    pal = _body(rom, 0xC070E9, 0xC0712D)
    claim("$C0:70E9 reads $FF:B210 + 2 + 16 k (ADC #$B210) and forces three greys (LDA #$0C63/#$18C6/#$739C)",
          b"\x69\x10\xb2" in pal and all(struct.pack("<BH", 0xA9, g) in pal for g in PAL_GREYS))
    srcs = [struct.unpack_from("<H", rom, pc(FRAME_SRCS) + 2 * i)[0] for i in range(STYLES)]
    claim("$C0:6EA0 holds 8 frame-set offsets $280 apart",
          all(b - a == FRAME_SET_BYTES for a, b in zip(srcs, srcs[1:])), f"first ${srcs[0]:04X}")
    c124 = _body(rom, 0xFDC124, 0xFDC1ED)
    claim("$FD:C124 stores the band records (LDA #$1C; LDA #$0037/#$FFF1/#$FFBC/#$FF76; LDA #$05; LDA #$01)",
          b"\xa9\x1c" in c124 and all(struct.pack("<BH", 0xA9, v) in c124 for v in (0x37, 0xFFF1, 0xFFBC, 0xFF76))
          and b"\xa9\x05" in c124 and b"\xa9\x01" in c124)
    return out


def data_claims(rom):
    out = []
    mem = Memory(rom)

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    tab = [mem.word(TILE_OFS + 2 * c) for c in range(64)]
    claim("TextWin_TileOfs2bpp ($C2:5FE6) is the 16-tile, $100-row layout for all 64 columns",
          tab == [tile_offset(c) for c in range(64)])
    widths96 = [mem(WIDTHS + i) for i in range(96)]
    claim("TextWin_GlyphWidths: 96 advances of 0-11 pixels; $A0-$EF none 0; $F2 and $F4-$FE 0",
          max(widths96) <= 11 and all(widths96[:0x50])
          and [i + 0xA0 for i, w in enumerate(widths96) if w == 0] == [0xF2] + list(range(0xF4, 0xFF)),
          f"{len(set(widths96))} distinct")
    blank = glyph_pixels(mem, 0xEF)
    claim("glyph $EF (space) draws no pixel; every letter $A0-$D3 draws some", not any(map(any, blank))
          and all(any(map(any, glyph_pixels(mem, g))) for g in range(0xA0, 0xD4)))
    hexes = [mem.word(HEX_GLYPHS + 2 * i) for i in range(16)]
    claim("TextWin_HexGlyphs: '0'-'9' = $D4-$DD, 'A'-'F' = $A0-$A5",
          hexes == list(range(0xD4, 0xDE)) + list(range(0xA0, 0xA6)))
    frames = [frame_set(mem, k) for k in range(STYLES)]
    claim("8 frame styles: 20 4bpp tiles each, all different", len({a + b for a, b in frames}) == STYLES)
    pals = [window_palette(mem, k) for k in range(STYLES)]
    claim("8 window colour sets (colours 1-15), all different", len({tuple(p[1:]) for p in pals}) == STYLES)
    text_tiles = sorted(w & 0x3FF for row in text_tilemap() for w in row)
    claim("the text grid names BG3 characters $100-$1FF once each", text_tiles == list(range(0x100, 0x200)))
    g = gradient()
    claim("the gradient has 90 pairs: 40 adding 8-1, 5 subtracting 0, 45 subtracting 1-9", len(g) == 90
          and [v & 31 for _, v in g[:40:5]] == list(range(8, 0, -1)))
    return out


# --- Evidence: the routines, run ------------------------------------------------------------------

class RomRunner:
    """Routines run by ChronoRET's 65816 interpreter (refs/ChronoRET/tools/
    absint.py) over the ROM, concretely (one path; no state hashing). The
    interpreter has no hardware, so this gives it the multiplier (WRMPYB
    $4203), the divider (WRDIVB $4206) and the WRAM port (WMADD
    $2181-$2183, WMDATA $2180), from fullsnes."""

    def __init__(self, rom, ref=REF):
        if str(ref / "tools") not in sys.path:
            sys.path.insert(0, str(ref / "tools"))
        import absint
        self.absint = absint

        class Hardware(absint.Machine):
            def write8(self, s, addr, v):
                if addr is not None:
                    a = addr & 0xFFFFFF
                    bank, low = a >> 16, a & 0xFFFF
                    if bank < 0x40 or 0x80 <= bank < 0xC0:
                        if low == 0x2180:
                            port = [s.mem.get(0x1002181 + i) for i in range(3)]
                            w = port[0] | port[1] << 8 | (port[2] & 1) << 16
                            super().write8(s, 0x7E0000 + w, v)
                            w = (w + 1) & 0x1FFFF
                            for i, b in enumerate((w & 0xFF, w >> 8 & 0xFF, w >> 16)):
                                s.mem[0x1002181 + i] = b
                            return
                        if low in (0x2181, 0x2182, 0x2183):
                            s.mem[0x1000000 + low] = v
                            return
                        if low == 0x4203:
                            super().write8(s, addr, v)
                            p = s.mem[0x004202] * v
                            s.mem[0x004216], s.mem[0x004217] = p & 0xFF, p >> 8
                            return
                        if low == 0x4206:
                            super().write8(s, addr, v)
                            n = s.mem[0x004204] | s.mem[0x004205] << 8
                            q, r = (n // v, n % v) if v else (0xFFFF, n)
                            s.mem[0x004214], s.mem[0x004215] = q & 0xFF, q >> 8
                            s.mem[0x004216], s.mem[0x004217] = r & 0xFF, r >> 8
                            return
                super().write8(s, addr, v)

        self.machine = Hardware(bytearray(rom), bytearray(b"\x01") * len(rom), max_steps=10 ** 8,
                                callee_steps=10 ** 8)
        self.steps = 0

    def run(self, entry, memory, d=0, m=True, x=False, limit=2_000_000, strict=True, trace=None, a=0, db=0):
        """Run from `entry` to its return; `memory` ({address: byte}) is read and
        updated (`strict`: a byte written from unknown inputs is an error).
        `a` and `db` are the entry's A (low byte) and data bank."""
        absint, machine = self.absint, self.machine
        s = absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, a, 0, 0, 0
        s.d, s.db, s.m, s.xf, s.c = d, db, m, x, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        machine.known, machine.reads, machine.control, machine.opaque = memory, set(), set(), set()
        for n in range(1, limit):
            machine._steps = n
            if trace:
                trace(s)
            r = machine.step(s, 0)
            if r is None:
                continue
            if r[0] in ("rts", "rtl"):
                break
            raise RuntimeError(f"{snes(entry)}: {r[0]} at {snes(s.pc)}")
        else:
            raise RuntimeError(f"{snes(entry)}: no return in {limit} steps")
        self.steps += n
        for k, v in s.mem.items():
            if v is None:
                if strict:
                    raise RuntimeError(f"{snes(entry)}: unknown byte written at {k:06X}")
                memory.pop(k, None)
                continue
            memory[k] = v
        return memory


def run_glyphs(rom, runner, codes=None):
    """TextWin_DrawGlyph ($C2:5DC4) on every glyph code, the pen at 8 + code mod 8
    (all eight shifts) over a buffer of $5A bytes: the bytes written and the pen
    advance against blit() and width()."""
    mem = Memory(rom)
    bad = []
    codes = codes or glyph_codes()
    for g in codes:
        pen = 8 + 9 * (g & 7) + (g >> 3 & 1) * 0x60
        memory = {0x7E0235: g & 0xFF, 0x7E0236: g >> 8, 0x7E0234: pen, 0x7E0210: 0x00, 0x7E0211: 0xF0,
                  0x7E0212: 0x7E, 0x7E0214: 0, 0x7E0217: 0}
        for i in range(BUFFER_BYTES):
            memory[BUFFER + i] = 0x5A
        runner.run(0xC25DC4, memory, d=0x0200)
        got = bytes(memory[BUFFER + i] for i in range(BUFFER_BYTES))
        want = bytearray([0x5A] * BUFFER_BYTES)
        blit(want, mem, g, pen)
        if got != bytes(want) or memory[0x7E0234] != (pen + width(mem, g)) & 0xFF:
            bad.append(f"${g:03X}")
    return (f"TextWin_DrawGlyph ($C2:5DC4, run) = blit + width for {len(codes)} glyphs at all 8 pen shifts",
            not bad, ", ".join(bad[:6]))


def run_tilemaps(rom, runner):
    """Field_Unk29F7 and Field_Unk2B78 (WMDATA writes) against frame_tilemap() / text_tilemap()."""
    out = []
    for entry, want, name in ((0xC029F7, frame_tilemap(), "Field_Unk29F7 ($C0:29F7, run) = frame_tilemap, 32 x 10"),
                              (0xC02B78, text_tilemap(), "Field_Unk2B78 ($C0:2B78, run) = text_tilemap, 32 x 8")):
        memory = runner.run(entry, {}, d=0x0100)
        words = [w for row in want for w in row]
        got = [memory.get(BUFFER + 2 * i, -1) | memory.get(BUFFER + 2 * i + 1, -1) << 8 for i in range(len(words))]
        out.append((name, got == words, ""))
    return out


def run_band_data(rom, runner):
    """EngFD_UnkC124 (with EngFD_UnkD52D): the band's BGnSC, scroll, TM, window and gradient records."""
    # the map's tilemap bases ($1D7C-$1D86) and TM/TS ($0BD7/8): any values, the band records do not use them
    memory = {0x7E1D7C + i: 0x11 * i & 0xFF for i in range(11)}
    memory.update({0x7E0BD7: 0x17, 0x7E0BD8: 0x04})
    try:
        memory = runner.run(0xFDC124, memory, d=0x0100, strict=False)   # the MVN copies $100 bytes, $B4 built
    except RuntimeError as e:
        return [("EngFD_UnkC124 ($FD:C124, run): band records", False, str(e))]
    m = lambda a: memory.get(a)
    sc = [m(0x7F14F4), m(0x7F14F6)]
    pairs = [m(0x7F14F8 + i) | m(0x7F14F9 + i) << 8 for i in range(0, 16, 2)]
    tm = [m(0x7F1524 + i) for i in range(4)] + [m(0x7F1528 + i) for i in range(4)]
    grad = [(m(0x7F1538 + 2 * i), m(0x7F1539 + 2 * i)) for i in range(90)]
    return [("EngFD_UnkC124 ($FD:C124, run): BG1SC = BG3SC = $1C, scroll (0,$37) (0,-$0F) (0,-$44) (0,-$8A), "
             "TM 5 / 1 in the band", sc == [BAND_SC, BAND_SC]
             and pairs == [0, 0x37, 0, 0xFFF1, 0, 0xFFBC, 0, 0xFF76] and tm == [5, 0, 0, 0, 1, 0, 0, 0]),
            ("EngFD_UnkD52D ($FD:D52D, run) = gradient(), 90 pairs", grad == gradient())]


def message_sample(rom, labels, count):
    """`count` messages spread over the corpus, plus every message using a code
    the spread misses (numbers, names, waits, page codes, wide glyphs)."""
    if not labels:
        return []
    step = max(1, len(labels) // count)
    chosen = labels[::step][:count]
    seen = set()
    for lab in chosen:
        seen |= set(message_codes(rom, lab))
    for lab in labels:
        new = set(message_codes(rom, lab)) - seen
        if new:
            chosen.append(lab)
            seen |= new
    return chosen


def message_codes(rom, label):
    try:
        d = layout(rom, label)
    except DialogueError:
        return []
    return [v for _, kind, v, *_ in d.events if kind == "code"]


def run_message(rom, runner, label, settings):
    """Field_Unk1F87 ($C0:1F87) frame by frame, the NMI's upload and the key
    press emulated as in Dialogue: (frames, mismatches)."""
    table, index, at = message_address(rom, label)
    model = Dialogue(Memory(rom, ram=settings.ram()), at, settings)
    table, index = table + 2 * (index & ~0xFF), index & 0xFF     # Field_Unk2A is one byte: rebase the table
    memory = dict(settings.ram())
    memory.update({F29: 1, F26: 0, F27: 0, F2A: index, F2B: table & 0xFF, F2B + 1: table >> 8 & 0xFF,
                   F2D: table >> 16, F30: settings.place, F31: 0, F32: 0, F33: 0, F34: 0, F34 + 1: 0, F36: 0,
                   F54: 0, F62: 0})
    for i in range(BUFFER_BYTES):
        memory[BUFFER + i] = 0
    for i in range(0x40, 0x80):         # the decoder's work bytes: 16-bit loads of half-written words
        memory.setdefault(0x7E0200 + i, 0)
    hold, frame, bad = None, 0, []
    while model.f["29"] and frame < 20000:
        if memory[F29] == 7 and memory[F34] | memory[F34 + 1] << 8 == SWALLOW:
            hold = frame if hold is None else hold
            if frame - hold >= settings.press:
                memory[F34] = memory[F34 + 1] = 0
                hold = None
        runner.run(0xC01F87, memory, d=0x0100)
        upload = memory[F36] != 0
        line = memory[F31]
        if memory[F36] & 0x80:
            memory[F36] = 0
        model.step_frame()
        mine = model.f
        got = (memory[F29], memory[F27], line, memory[F34] | memory[F34 + 1] << 8, memory.get(TW_STATUS),
               memory.get(TW_PENX))
        want = (mine["29"], mine["27"], model.uploads[-1][1] if upload and model.uploads else mine["31"],
                mine["34"], model.tw.status if model.tw else memory.get(TW_STATUS),
                model.tw.pen if model.tw else memory.get(TW_PENX))
        if got != want:
            bad.append((frame, got, want))
        if upload:
            buf = bytes(memory[BUFFER + i] for i in range(BUFFER_BYTES))
            if not model.uploads or model.uploads[-1][0] != frame or model.uploads[-1][2] != buf:
                bad.append((frame, "upload"))
        elif model.uploads and model.uploads[-1][0] == frame:
            bad.append((frame, "extra upload"))
        if bad:
            break
        frame += 1
    if model.f["29"] or memory[F29]:
        bad.append((frame, "not ended"))
    return model, bad


def run_messages(rom, runner, labels, settings_list):
    out, frames, glyphs, failed = [], 0, 0, []
    for lab in labels:
        for s in settings_list:
            try:
                model, bad = run_message(rom, runner, lab, s)
            except DialogueError as e:
                failed.append(f"{lab}: {e}")
                continue
            frames += model.frame
            glyphs += sum(1 for e in model.events if e[1] == "glyph")
            if bad:
                failed.append(f"{lab} place {s.place} press {s.press}: frame {bad[0]}")
    n = len(labels) * len(settings_list)
    out.append((f"Field_Unk1F87 ($C0:1F87, run) = Dialogue for {n - len(failed)} of {n} message runs "
                f"({frames} frames, {glyphs} glyphs: pens, lines, pages, waits, uploads)", not failed,
                "; ".join(failed[:3])))
    return out


def run_claims(rom, ref=REF, messages=24, labels=None):
    runner = RomRunner(rom, ref)
    out = [run_glyphs(rom, runner)]
    out += run_tilemaps(rom, runner)
    out += run_band_data(rom, runner)
    chosen = message_sample(rom, corpus_labels() if labels is None else labels, messages)
    settings = [default_settings(press=1, place=1), default_settings(press=7, place=2)]
    out += run_messages(rom, runner, chosen, settings)
    out += run_synthetic_messages(rom, ref)
    return out


def run_synthetic_messages(rom, ref=REF):
    """The synthetic messages (every modelled code, the ones no real message
    uses among them: $04 $07 $08 $0F $10 $11 $12) placed in a copy of the ROM
    in memory, run in the interpreter under both synthetic settings."""
    patched = bytearray(rom)
    table = TEXT_AT + 0xF00
    labels = []
    for i, m in enumerate(synthetic_rom()[1]):
        at = TEXT_AT + 0x100 * i
        patched[pc(at):pc(at) + len(m)] = bytes(m)
        patched[pc(table + 2 * i):pc(table + 2 * i) + 2] = struct.pack("<H", at & 0xFFFF)
        labels.append(f"Messages_{table:06X}:{i}")
    patched = bytes(patched)
    out = run_messages(patched, RomRunner(patched, ref), labels, synthetic_settings())
    return [(name.replace("message runs", "synthetic message runs"), ok, *rest) for name, ok, *rest in out]


# --- Synthetic vectors for the Swift twin -------------------------------------------------------

class Lcg:
    """Deterministic numbers (no ROM data)."""

    def __init__(self, seed):
        self.v = seed

    def next(self, n):
        self.v = (self.v * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.v >> 8) % n


TEXT_AT = 0xC80000                       # where the synthetic messages sit (any ROM address)


def synthetic_rom():
    """Synthetic font, widths, dictionary, names and window in the real tables'
    places, and messages exercising every modelled code: (regions, messages)."""
    rng = Lcg(7)
    regions = {}

    def put(long, data):
        regions[long] = bytes(data)

    put(FONT + 24 * FIRST_GLYPH, [rng.next(256) for _ in range(24 * 96)])
    put(FONT + 24 * 0x100, [rng.next(256) for _ in range(24 * 32)])
    put(FONT_RIGHT + 24 * (FIRST_GLYPH >> 1), [rng.next(256) for _ in range(24 * 48)])
    put(FONT_RIGHT + 24 * 0x80, [rng.next(256) for _ in range(24 * 16)])
    put(WIDTHS, [3 + rng.next(9) for _ in range(80)] + [0] * 15 + [4] + [rng.next(12) for _ in range(160)])
    put(TILE_OFS, b"".join(struct.pack("<H", tile_offset(c)) for c in range(64)))
    put(CHAR_NAME_PTRS, b"".join(struct.pack("<H", (CHAR_NAMES + CHAR_NAME_SIZE * i) & 0xFFFF) for i in range(7)))
    put(STR_NADIA, [0xA0, 0xA1, 0xA2, 0xA3, 0xA4])
    put(HEX_GLYPHS, b"".join(struct.pack("<H", g) for g in list(range(0xD4, 0xDE)) + list(range(0xA0, 0xA6))))
    entries, at = [], 0xDEFB00
    ptrs = []
    for i in range(160):
        e = [0xA0 + rng.next(0x4F) for _ in range(1 + rng.next(5))]
        ptrs.append(at & 0xFFFF)
        entries += [len(e)] + e
        at += 1 + len(e)
    put(DICT_PTRS, b"".join(struct.pack("<H", p) for p in ptrs))
    put(0xDEFB00, entries)
    for base in (TECH_NAMES, ENEMY_NAMES, ITEM_NAMES):
        names = []
        for i in range(4):
            n = [TECH_ICON if base == TECH_NAMES and i == 2 else 0x20] + [0xA0 + rng.next(0x34) for _ in range(5)]
            names += (n + [NAME_PAD] * ROM_NAME_SIZE)[:ROM_NAME_SIZE]
        put(base, names)
    put(FRAME_SRCS, b"".join(struct.pack("<H", 0x9E10 + FRAME_SET_BYTES * k) for k in range(STYLES)))
    put(0xFF9E10, [rng.next(256) for _ in range(FRAME_SET_BYTES * STYLES)])
    put(PAL_SETS, b"".join(struct.pack("<H", rng.next(0x8000)) for _ in range(8 * STYLES + 8)))
    g = lambda s: [0xA0 + (ord(c) - 65 if c.isupper() else ord(c) - 97 + 26) if c.isalpha() else 0xEF for c in s]
    messages = [
        g("Hello there") + [5] + g("Second line") + [0],
        [0x21, 0x22, 0xEF, 0x13, 0xEF, 0x1B, 0x1C, 6] + g("indent") + [0x0B] + g("after key") + [0],
        g("Wait") + [3, 2] + g("ok") + [3, 0] + g("zero") + [0],
        [0x0D, 0x0E, 0x0F, 0xEF, 0x11, 0x1A, 0x20, 0x1E, 0x1F] + [0],
        [0x12, 0, 0x12, 1, 0x12, 0x30, 0x12, 9, 1, 0x05, 2, 0x10] + g("wide") + [0],
        g("a") + [5] + g("b") + [5] + g("c") + [5] + g("d") + [5] + g("e") + [7] + g("f") + [9] + g("g") + [0],
        g("x") + [0x10, 0x04, 0x10] + g("y") + [8] + g("z") + [0x0C] + g("w") + [0x0A] + g("v") + [0],
        g("Long") + [0xA0 + rng.next(0x34) for _ in range(60)] + [0],
    ]
    return regions, messages


def synthetic_settings():
    return [Settings(names=[[0xA0 + i, 0xB0, 0xC0][:1 + i % 3] for i in range(8)], party=(2, 0x80, 5), item=3,
                     args=[7, 0x39, 0x30, 0x40, 0x42, 0x0F, 2, 1, 0, 3, 0, 0], place=1, press=1),
            Settings(names=[[0xA0 + i] * 6 for i in range(8)], party=(1, 2, 3), item=2,
                     args=[255, 0xFF, 0xFF, 0x7F, 0x96, 0x98, 3, 0, 0, 1, 0, 0], num_hex=True, place=2, press=5)]


def vectors_text():
    regions, messages = synthetic_rom()
    mem_regions = dict(regions)
    for i, m in enumerate(messages):
        mem_regions[TEXT_AT + 0x100 * i] = bytes(m)
    expect = []
    for i in range(len(messages)):
        for k, s in enumerate(synthetic_settings()):
            d = Dialogue(Memory(regions=mem_regions, ram=s.ram()), TEXT_AT + 0x100 * i, s).run()
            summ = layout_summary(d)
            expect.append({"message": i, "settings": k, **summ})
    mem = Memory(regions=mem_regions)
    fonts = {"digest": font_digest(mem, list(range(0xA0, 0x100)) + list(range(0x100, 0x120))),
             "glyphA0": [v for row in glyph_pixels(mem, 0xA0) for v in row],
             "glyph101": [v for row in glyph_pixels(mem, 0x101) for v in row],
             "widths": [width(mem, g) for g in range(0xA0, 0x100)]}
    window = {"palette3": window_palette(mem, 3)[1:], "frame5": hashlib.sha256(b"".join(frame_set(mem, 5))).hexdigest(),
              "frameTilemap": hashlib.sha256(b"".join(struct.pack("<H", w) for r in frame_tilemap() for w in r)).hexdigest(),
              "textTilemap": hashlib.sha256(b"".join(struct.pack("<H", w) for r in text_tilemap() for w in r)).hexdigest(),
              "gradient": [list(p) for p in gradient()],
              "band": {f"{n},{p}": [band(n, p)[0], [list(l) for l in band(n, p)[1]]] for n, p in ((4, 1), (12, 2), (40, 1))}}
    settings = [{"names": s.names, "party": s.party, "item": s.item, "args": s.args, "numHex": s.num_hex,
                 "place": s.place, "press": s.press} for s in synthetic_settings()]
    head = {"schema": "ct-dialogue-vectors/1",
            "note": "synthetic font, widths, dictionary, names, window and messages in the real tables' places "
                    "(no ROM data); expected results by re_workspace/tools/ct_dialogue.py",
            "textAt": snes(TEXT_AT), "messageStride": 256,
            "regions": [{"at": snes(k), "hex": v.hex()} for k, v in sorted(mem_regions.items())],
            "settings": settings, "font": fonts, "window": window}
    lines = ["{"]
    lines += [f' "{k}": {json.dumps(v, separators=(",", ":"))},' for k, v in head.items()]
    body = ",\n".join("  " + json.dumps(d, separators=(",", ":")) for d in expect)
    return "\n".join(lines) + f'\n "layouts": [\n{body}]}}\n'


# --- The Swift CLI against this decode ---------------------------------------------------------

def verify_cli(rom_path, binary, labels=None, count=40):
    """`text font --json` and `text preview --layout-json` on the ROM against
    this decode (font digest, widths, window, and each sample message's layout)."""
    rom = read_rom(rom_path)
    mem = Memory(rom)
    out = []
    font = json.loads(subprocess.run([binary, "text", "font", str(rom_path), "--json"], check=True,
                                     capture_output=True, text=True).stdout)
    out.append(("text font --json: glyph digest = ct_dialogue font_digest (608 glyphs)",
                font.get("glyphDigest") == font_digest(mem)))
    out.append(("text font --json: widths $A0-$FF", font.get("widths") == [width(mem, g) for g in range(0xA0, 0x100)]))
    frame_digests = [hashlib.sha256(b"".join(frame_set(mem, k))).hexdigest() for k in range(STYLES)]
    out.append(("text font --json: 8 frame styles and colour sets",
                font.get("frameDigests") == frame_digests
                and font.get("palettes") == [window_palette(mem, k)[1:] for k in range(STYLES)]))
    chosen = message_sample(rom, corpus_labels() if labels is None else labels, count)
    bad = []
    for lab in chosen:
        for s in (default_settings(press=1, place=1), default_settings(press=4, place=2)):
            try:
                want = layout_summary(layout(rom, lab, s))
            except DialogueError:
                continue
            table, index, _ = message_address(rom, lab)
            args = [binary, "text", "preview", str(rom_path), f"{table:06X}:{index}", "--layout-json",
                    "--press", str(s.press), "--place", str(s.place)]
            got = json.loads(subprocess.run(args, check=True, capture_output=True, text=True).stdout)
            if any(got.get(k) != v for k, v in want.items()):
                bad.append(lab)
    out.append((f"text preview --layout-json = Dialogue for {2 * len(chosen) - len(bad)} of {2 * len(chosen)} "
                f"message layouts", not bad, ", ".join(bad[:4])))
    return out


# --- CLI ---------------------------------------------------------------------------------------

def report(claims):
    bad = [c for c in claims if not c[1]]
    for name, ok, *detail in claims:
        extra = f"  ({detail[0]})" if detail and detail[0] else ""
        print(f"{'ok  ' if ok else 'FAIL'} {name}{extra}")
    print(f"{len(claims) - len(bad)} of {len(claims)} claims hold")
    return 1 if bad else 0


def font_summary(rom):
    mem = Memory(rom)
    return {"schema": "ct-dialogue-font/1", "font": snes(FONT), "fontRight": snes(FONT_RIGHT), "glyphs": 608,
            "glyphPixels": "12x12 2bpp", "widthsAt": snes(WIDTHS), "glyphDigest": font_digest(mem),
            "widths": [width(mem, g) for g in range(0xA0, 0x100)],
            "frameDigests": [hashlib.sha256(b"".join(frame_set(mem, k))).hexdigest() for k in range(STYLES)],
            "palettes": [window_palette(mem, k)[1:] for k in range(STYLES)],
            "box": {"lines": 4, "lineHeight": 16, "penLeft": PEN_LEFT, "penIndent": PEN_INDENT, "innerRight": 248,
                    "bandLines": 80, "framesPerGlyph": 1, "waitUnitFrames": WAIT_UNIT}}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    f = sub.add_parser("font")
    f.add_argument("--rom", default=str(ROM_PATH))
    lay = sub.add_parser("layout")
    lay.add_argument("message")
    lay.add_argument("--rom", default=str(ROM_PATH))
    lay.add_argument("--press", type=int, default=1)
    lay.add_argument("--place", type=int, default=1, choices=(1, 2))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(ROM_PATH))
    k.add_argument("--run", action="store_true", help="also run the ROM's own routines in ChronoRET's interpreter")
    k.add_argument("--messages", type=int, default=24)
    v = sub.add_parser("verify-cli")
    v.add_argument("binary")
    v.add_argument("--rom", default=str(ROM_PATH))
    g = sub.add_parser("vectors")
    m = g.add_mutually_exclusive_group(required=True)
    m.add_argument("--out")
    m.add_argument("--check")
    args = parser.parse_args()

    if args.command == "vectors":
        text = vectors_text()
        if args.out:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(text)
            print(f"wrote {args.out}")
            return 0
        same = Path(args.check).read_text() == text
        print("vectors match" if same else "vectors differ: regenerate with --out")
        return 0 if same else 1
    if args.command == "verify-cli":
        return report(verify_cli(args.rom, args.binary))
    rom = read_rom(args.rom)
    if args.command == "font":
        print(json.dumps(font_summary(rom), indent=1))
        return 0
    if args.command == "layout":
        d = layout(rom, args.message, default_settings(press=args.press, place=args.place))
        print(json.dumps(layout_summary(d), indent=1))
        return 0
    claims = asm_claims() + code_claims(rom) + data_claims(rom)
    if args.run:
        claims += run_claims(rom, messages=args.messages)
    claims += traced_claims(rom, args.run)
    return report(claims)


def traced_claims(rom, run):
    """The traces built on this decoder: the menu help line (ct_helpline.py)
    and the box's place and choice cursor (ct_boxchoice.py)."""
    import ct_boxchoice
    import ct_helpline
    out = []
    for m in (ct_helpline, ct_boxchoice):
        out += m.asm_claims() + m.code_claims(rom) + m.data_claims(rom)
        if run:
            out += m.run_claims(rom)
    return out


if __name__ == "__main__":
    sys.exit(main())
