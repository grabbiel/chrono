#!/usr/bin/env python3
"""Chrono Trigger menu help line: how the menu draws an item's or a tech's description.

The evidence for `CTHelpLine.swift`, read from matched ChronoRET routines (MIT;
refs/ChronoRET) and checked against them: `check` holds the static claims
(source lines, the ROM's code operands, data shapes), `check --run` runs the
routines themselves in ChronoRET's 65816 interpreter on every description.

Menu_DrawDescText ($C2:F2F3; items, string A of $CC:2EB1) and
Menu_TechDescText ($C2:BE33; techs, string Menu_TechId of $CC:3A09) set the
text up and call Menu_StartDescText ($C2:FA49). That runs the dialogue box's
own decoder, TextWin_Init / TextWin_Step (bank $C2, mode 0: the 2bpp VWF of
ct_dialogue.py), with one step a frame (Menu_TextSteps = 1) into the 1 KB
glyph buffer $7E:5E00, and clears the $80 map bytes (two rows) from the start
of Menu_TextDest's row. Menu_TextStepLoop ($C2:FAA8) steps the decoder each
frame and calls Menu_TextUpload ($C2:FAE9):

- when the glyph count (TextWin_Unk17) moved: the whole glyph buffer to VRAM
  $7800 (BG3 characters $100-$17F; BG3's characters start at $7000), then the
  tile words from the tile the last upload's pen was in up to the pen rounded
  up: tile word $3101 + tile - 1 (palette 4, priority), the lower row ($40
  bytes on) with bit 4 set, all at Menu_TextDest + 2 x tile;
- always: the two map rows (Menu_Unk0DD0 = $80 bytes from the row's start) to
  VRAM Menu_Unk0DCC: $6840 for items (BG3 map $6800, rows 2-3), $6AA0 for
  techs (rows 21-22).

Status 5 (code $05, a new line) moves the line two rows on and its glyphs to
VRAM $7A00, but only the first two rows are ever sent: a description is one
line. A code that resets the pen without a new line ($06-$0C) leaves the last
pen in Menu_TextPenStart, and the next tile count wraps: the routine would
write 65536 words. The window's frame (BG1/BG2) is not modelled here.

The menu's BG3 is mode 1's high-priority layer (Menu_InitPpuAndRam: BG3SC $6A,
BG34NBA $07); colours 16-19 (palette 4) are MenuRom_PalB ($FF:9C78,
Menu_LoadGraphics).

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_helpline.py show (item|tech) N [--rom PATH]   one description's help line (numbers only)
    ct_helpline.py check [--rom PATH] [--run]        every evidence claim (exit 1 on a failure)
    ct_helpline.py vectors (--out | --check) P       synthetic vectors for the Swift twin
"""

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_dialogue as D  # noqa: E402

VECTORS = D.WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "dialogue" / "helpline_vectors.json"

# --- Addresses and constants (ChronoRET include/*.inc) ------------------------------------

DESC_TABLE, TECH_TABLE = 0xCC2EB1, 0xCC3A09        # !MenuRom_DescStrTable, !MenuRom_TechTextTable
ITEM_DESCS, TECH_DESCS = 242, 0x76                 # item ids 0-$F1; tech ids 0-$75 ($76-$78: page titles)
DRAW_DESC, TECH_DESC, START_DESC = 0xC2F2F3, 0xC2BE33, 0xC2FA49
STEP_LOOP, UPLOAD, YIELD, QUEUE_WRAM = 0xC2FAA8, 0xC2FAE9, 0xC2821E, 0xC2838E
GFX, GFX_BYTES = 0x7E5E00, 0x400                   # !Menu_TextGfxA, !Menu_TextGfxBytes
TILE_DEST, TILE_WORD, PEN_FIRST = 0x7800, 0x3101, 8   # !Menu_TextTileDestA, !Menu_TextTileWordA, !Menu_TextPenFirst
MAP_BYTES, ROW_BYTES, LOWER = 0x80, 0x40, 0x10     # !Menu_DescUnk0DD0, !Menu_MapRowBytes, !Menu_TextLowerTile
LINE_BREAK = 5                                     # !Menu_TextLineBreak
PLACES = {"item": (0x4E84, 0x6840), "tech": (0x5344, 0x6AA0)}   # (Menu_TextDest, Menu_Unk0DCC)
TABLES = {"item": (DESC_TABLE, ITEM_DESCS), "tech": (TECH_TABLE, TECH_DESCS)}
BG3_MAP, BG3_CHARS = 0x6800, 0x7000                # BG3SC $6A (32 x 64), BG34NBA $07
BG3SC, BG34NBA, BGMODE = 0x6A, 0x07, 0x09          # mode 1, BG3 on top
PAL_B, PAL_A = 0xFF9C78, 0xFF9C68                  # colours 16-19; colours 0-3
MENU_WRAM_MAP = 0x3E00                             # WRAM of VRAM $6000 (BG2's map; BG3's follows at $4E00)
RIGHT_LIMIT = 240                                  # pen past this: tile words past column 31 of the row
D78, D77, TECH_ID, QUEUE_END = 0x7E0D78, 0x7E0D77, 0x7E0F4C, 0x7E0D11


def screen_x(pen):
    """The screen x of a pen: buffer tile k is map column 2 + k."""
    return pen + 16


def row_of(place):
    dest, vmap = PLACES[place]
    return (vmap - BG3_MAP) // 32


# --- The model -----------------------------------------------------------------------------------

class HelpLineError(ValueError):
    pass


class MenuTextWin(D.TextWin):
    """TextWin with TextWin_Unk17: +1 a glyph, zeroed with each pen reset (statuses 5-12)."""

    def __init__(self, *a):
        super().__init__(*a)
        self.unk17 = 0

    def draw(self, g):
        super().draw(g)
        self.unk17 = (self.unk17 + 1) & 0xFF

    def step(self):
        if 5 <= self.status <= 12:
            self.unk17 = 0
        super().step()


class HelpLine:
    """Menu_StartDescText then Menu_TextStepLoop (one step a frame) with
    Menu_TextUpload, from the string at `text` to the decoder's status 0.
    `gfx` is the glyph buffer's 1 KB before the run (the routine never clears
    it) and `wram` the bank-$7E bytes {address: byte} of the map before it."""

    def __init__(self, mem, text, place="item", gfx=None, wram=None):
        self.mem, self.text, self.place = mem, text, place
        self.dest, self.vmap = PLACES[place]
        self.buf = bytearray(gfx if gfx is not None else bytes(GFX_BYTES))
        self.wram = dict(wram or {})
        self.uploads = []           # (frame, kind, VRAM word address, source, bytes)
        self.glyph_log = []         # (frame, glyph, pen, width, line)
        self.frame = 0
        self.line = 0
        self.right = PEN_FIRST      # the first line's last pen
        self.wraps = False
        self.past_row = False

    def put(self, addr, word):
        self.wram[addr & 0xFFFF] = word & 0xFF
        self.wram[(addr + 1) & 0xFFFF] = word >> 8

    def map_bytes(self, start, n):
        return bytes(self.wram.get((start + i) & 0xFFFF, 0) for i in range(n))

    def run(self, max_frames=4000):
        row = self.dest & 0xFFC0
        for i in range(MAP_BYTES):
            self.wram[row + i] = 0
        glyphs, col, pen_start, tile_word, tile_dest = 0, 0, PEN_FIRST, TILE_WORD, TILE_DEST

        def log(kind, value, pen):
            if kind == "glyph":
                w = D.width(self.mem, value)
                self.glyph_log.append((self.frame, value, pen, w, self.line))
                if pen + w > 0xFF:
                    self.wraps = True

        tw = MenuTextWin(self.mem, self.text, self.buf, log)
        while True:
            if self.frame >= max_frames:
                raise HelpLineError(f"no end within {max_frames} frames")
            tw.step()
            # Menu_TextUpload
            if tw.unk17 != glyphs:
                glyphs = tw.unk17
                self.uploads.append((self.frame, "gfx", tile_dest, GFX & 0xFFFF, bytes(self.buf)))
                p = tw.pen
                for _ in range(3):
                    p = (p >> 1) + (p & 1)
                first = (pen_start & 0xF8) >> 2
                x = (first + col + self.dest) & 0xFFFF
                tmp02 = first >> 1
                count = (p - tmp02) & 0xFFFF
                if count == 0 or count > 0x40:
                    raise HelpLineError(f"frame {self.frame}: the tile loop would write {count or 0x10000} words "
                                        f"(pen {tw.pen}, last tile pen {pen_start})")
                a = (tmp02 - 1) & 0xFFFF
                a += tile_word
                carry = a >> 16
                a = (a + LOWER + carry) & 0xFFFF
                for _ in range(count):
                    a &= 0xFFEF
                    self.put(x, a)
                    a |= LOWER
                    self.put(x + ROW_BYTES, a)
                    a = (a + 1) & 0xFFFF
                    if self.line == 0 and (x - row) // 2 >= 32:
                        self.past_row = True
                    x += 2
                pen_start = tw.pen
                if self.line == 0:
                    self.right = tw.pen
            self.uploads.append((self.frame, "map", self.vmap, row, self.map_bytes(row, MAP_BYTES)))
            if tw.status == 0:
                break
            if tw.status == LINE_BREAK:
                col = (col & 0xFF00) | ((col & 0xE0) + 0x80) & 0xFF
                tile_word = (tile_word & 0xFF00) | ((tile_word & 0xC0) + 0x41) & 0xFF
                glyphs = 0
                tile_dest = (tile_dest + 0x200) & 0xFFFF
                pen_start = PEN_FIRST
                self.line += 1
            self.frame += 1
        self.frame += 1
        return self

    # --- what the screen shows ---

    def vram(self):
        """{VRAM word: word} after every upload (the NMI sends them in order)."""
        out = {}
        for _, kind, dest, _, data in self.uploads:
            for i in range(len(data) // 2):
                out[(dest + i) & 0x7FFF] = data[2 * i] | data[2 * i + 1] << 8
        return out

    def rows(self):
        """The two BG3 map rows the help line shows: 2 x 32 tile words."""
        v = self.vram()
        return [[v.get(self.vmap + 32 * r + c, 0) for c in range(32)] for r in range(2)]

    def pixels(self):
        """16 lines x 256 columns of BG3 colour indices 0-3 (palette 4 when not 0),
        from the rows and the uploaded characters; tiles below $100 are the
        menu font's, not modelled, and read as 0 (the cleared map's tile 0 is
        blank: the first 16 BG3 tiles are cleared RAM)."""
        v = self.vram()
        out = [[0] * 256 for _ in range(16)]
        for r, row in enumerate(self.rows()):
            for c, w in enumerate(row):
                tile = w & 0x3FF
                if tile < 0x100:
                    continue
                base = BG3_CHARS + tile * 8
                hf, vf = w & 0x4000, w & 0x8000
                for y in range(8):
                    word = v.get(base + (7 - y if vf else y), 0)
                    for xx in range(8):
                        bit = xx if hf else 7 - xx
                        out[8 * r + y][8 * c + xx] = (word >> bit & 1) | (word >> (8 + bit) & 1) << 1
        return out

    def summary(self):
        lines = self.line + 1
        return {"frames": self.frame, "glyphs": len(self.glyph_log),
                "pens": [g[2] for g in self.glyph_log], "lines": lines, "right": self.right,
                "rightX": screen_x(self.right), "wraps": self.wraps, "pastRow": self.past_row,
                "fits": lines == 1 and not self.wraps and not self.past_row and self.right <= RIGHT_LIMIT,
                "uploads": len(self.uploads),
                "uploadDigest": digest(self.uploads),
                "rows": hashlib.sha256(b"".join(struct.pack("<H", w) for r in self.rows() for w in r)).hexdigest(),
                "pixels": hashlib.sha256(bytes(v for r in self.pixels() for v in r)).hexdigest()}


def digest(uploads):
    h = hashlib.sha256()
    for fr, kind, dest, src, data in uploads:
        h.update(struct.pack("<IHH", fr, dest, src) + data)
    return h.hexdigest()


def string_address(mem, place, index):
    table, _ = TABLES[place]
    return (table & 0xFF0000) | mem.word(table + 2 * (index & 0xFF))


def help_line(rom, place, index, settings=None, gfx=None, wram=None):
    s = settings or D.default_settings()
    mem = D.Memory(rom, ram=s.ram())
    return HelpLine(mem, string_address(mem, place, index), place, gfx, wram).run()


# --- Evidence: the matched source -----------------------------------------------------------------

ASM_CLAIMS = (
    ("bankC2/bankC2.asm", "Menu_DrawDescText", ("LDX.w #!Menu_DescTextDest", "LDX.w #!Menu_DescUnk0DCC",
                                                "LDX.w #!MenuRom_DescStrTable&$FFFF", "LDA.b #1",
                                                "LDX.w #!Menu_DescUnk0DD0", "JSR Menu_StartDescText")),
    ("bankC2/bankC2.asm", "Menu_TechDescText", ("LDX.w #!Menu_TechDescDest", "LDA.b #1", "LDA.w !Menu_TechId")),
    ("bankC2/bankC2.asm", "Menu_TechTextSetup", ("LDX.w #!Menu_TechUnk0DCC", "LDX.w #!MenuRom_TechTextTable&$FFFF",
                                                 "LDX.w #!Menu_DescUnk0DD0", "JSR Menu_StartDescText")),
    ("bankC2/bankC2.asm", "Menu_StartDescText", ("STZ.w !TextWin_Dp+!TextWin_Mode", "AND.w #!Menu_TextRowMask",
                                                 "LDA.w #!Menu_TextGfxA", "LDA.w #!Menu_TextTileWordA",
                                                 "LDA.w #!Menu_TextPenFirst", "LDA.w #!Menu_TextTileDestA",
                                                 "JSL BankC2_Entry0003")),
    ("bankC2/bankC2.asm", "Menu_TextStepLoop", ("LDA.w !Menu_TextSteps", "JSL BankC2_Entry0009",
                                                "JSR Menu_TextUpload", "CMP.b #!Menu_TextLineBreak",
                                                "AND.b #!Menu_TextLineMask", "ADC.b #!Menu_TextLineBytes",
                                                "ADC.b #!Menu_TextTileLineFirst", "INC.w !Menu_TextTileDest+1")),
    ("bankC2/bankC2.asm", "Menu_TextUpload", ("LDA.w !TextWin_Dp+!TextWin_Unk17", "LDA.w #!Menu_TextGfxBytes",
                                              "ADC.w #!Menu_TextLowerTile", "AND.w #!Menu_TextUpperMask",
                                              "STA.w !Eng_PtrBase+!Menu_MapRowBytes,X", "LDA.w !Menu_Unk0DD0")),
    ("bankC2/bankC2.asm", "Menu_InitPpuAndRam", ("LDA.b #BG_MODE_1|BG3_HIGH_PRIO", "LDA.b #!BG3SC_6800_32x64",
                                                 "LDA.b #!BG34NBA_Bg3At7000")),
    ("bankC2/bankC2.asm", "Menu_LoadGraphics", ("LDX.w #!MenuRom_PalB&$FFFF", "LDY.w #!Menu_PalBuf+(16*!Menu_ColorBytes)")),
    ("bankC2/bankC2.asm", "TextWin_StatusPenIndent", ("STZ.b !TextWin_Unk17",)),
)
CONSTANT_CLAIMS = (
    ("include/constants_menu.inc", "!MenuRom_DescStrTable = $CC2EB1"),
    ("include/constants_menu.inc", "!MenuRom_TechTextTable = $CC3A09"),
    ("include/constants_menu.inc", "!Menu_DescTextDest = $4E84"),
    ("include/constants_menu.inc", "!Menu_DescUnk0DCC = $6840"),
    ("include/constants_menu.inc", "!Menu_DescUnk0DD0 = $0080"),
    ("include/constants_menu.inc", "!Menu_TechDescDest = $5344"),
    ("include/constants_menu.inc", "!Menu_TechUnk0DCC = $6AA0"),
    ("include/constants_menu.inc", "!Menu_TextGfxA = $5E00"),
    ("include/constants_menu.inc", "!Menu_TextTileDestA = $7800"),
    ("include/constants_menu.inc", "!Menu_TextTileWordA = $3101"),
    ("include/constants_menu.inc", "!Menu_TextLineBreak = 5"),
    ("include/constants_menu.inc", "!MenuRom_PalB = $FF9C78"),
    ("hardware.inc", "!BG3SC_6800_32x64      = $6A"),
    ("hardware.inc", "!BG34NBA_Bg3At7000     = $07"),
)


def asm_claims(ref=D.REF):
    saved = D.ASM_CLAIMS, D.CONSTANT_CLAIMS
    try:
        D.ASM_CLAIMS, D.CONSTANT_CLAIMS = ASM_CLAIMS, CONSTANT_CLAIMS
        return [(f"help line: {n}", ok, *rest) for n, ok, *rest in D.asm_claims(ref)]
    finally:
        D.ASM_CLAIMS, D.CONSTANT_CLAIMS = saved


# --- Evidence: the ROM's code bytes and data ----------------------------------------------------

def code_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    body = lambda a, b: bytes(rom[D.pc(a):D.pc(b) + 1])
    draw = body(0xC2F2F3, 0xC2F331)
    claim("$C2:F2F3 sets $4E84, $6840, table $CC:2EB1, 1 step and $80 map bytes "
          "(LDX #$4E84; LDX #$6840; LDX #$2EB1; LDA #$CC; LDA #$01; LDX #$0080)",
          all(p in draw for p in (b"\xa2\x84\x4e", b"\xa2\x40\x68", b"\xa2\xb1\x2e", b"\xa9\xcc", b"\xa9\x01",
                                  b"\xa2\x80\x00")))
    tech = body(0xC2BE33, 0xC2BE78)
    claim("$C2:BE33 sets $5344, $6AA0 and table $CC:3A09 (LDX #$5344; LDX #$6AA0; LDX #$3A09; LDA #$CC)",
          all(p in tech for p in (b"\xa2\x44\x53", b"\xa2\xa0\x6a", b"\xa2\x09\x3a", b"\xa9\xcc")))
    start = body(0xC2FA49, 0xC2FA9E)
    claim("$C2:FA49 sets buffer $5E00, tile word $3101, pen 8 and VRAM $7800 (LDA #$5E00/#$3101/#$0008/#$7800)",
          all(p in start for p in (b"\xa9\x00\x5e", b"\xa9\x01\x31", b"\xa9\x08\x00", b"\xa9\x00\x78")))
    loop = body(0xC2FAA5, 0xC2FAE8)
    claim("$C2:FAA5 breaks lines on status 5 (CMP #$05), two rows on (AND #$E0; CLC; ADC #$80) and tile word "
          "+$41 (AND #$C0; CLC; ADC #$41)",
          b"\xc9\x05" in loop and b"\x29\xe0\x18\x69\x80" in loop and b"\x29\xc0\x18\x69\x41" in loop)
    up = body(0xC2FAE9, 0xC2FB96)
    claim("$C2:FAE9 sends $400 bytes (LDA #$0400) and writes upper / lower tile words (AND #$FFEF; ORA #$0010; "
          "STA $0040,X)",
          b"\xa9\x00\x04" in up and b"\x29\xef\xff" in up and b"\x09\x10\x00" in up and b"\x9d\x40\x00" in up)
    init = body(0xC2940D, 0xC2950F)
    claim("$C2:940D sets mode 1 + BG3 on top, BG3SC $6A and BG34NBA $07 (LDA #$09; LDA #$6A; LDA #$07)",
          b"\xa9\x09" in init and b"\xa9\x6a" in init and b"\xa9\x07" in init)
    return out


def data_claims(rom):
    out = []
    mem = D.Memory(rom)

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    first = mem.word(DESC_TABLE)
    claim(f"the item description table has {ITEM_DESCS} pointers (the first string follows them)",
          first == (DESC_TABLE & 0xFFFF) + 2 * ITEM_DESCS, f"${first:04X}")
    ends = []
    for place, (table, n) in TABLES.items():
        for i in range(n):
            at = string_address(mem, place, i)
            k = next((k for k in range(200) if mem(at + k) == 0), None)
            ends.append(k is not None)
    claim(f"every description ({ITEM_DESCS} items, {TECH_DESCS} techs) ends with $00 within 200 bytes", all(ends))
    claim("MenuRom_PalB ($FF:9C78): colours 17-19 of palette 4 are not all equal",
          len({mem.word(PAL_B + 2 * i) for i in (1, 2, 3)}) > 1)
    return out


# --- Evidence: the routines, run --------------------------------------------------------------------

GFX_FILL, MAP_FILL = 0x5A, 0xA5


def run_one(rom, runner, place, index, settings):
    """Menu_DrawDescText (items) or Menu_TechDescText (techs), then
    Menu_TextStepLoop with Menu_Yield returning at once (a copy of the ROM in
    memory): each queued upload (Menu_QueueVramWram's record and its bytes),
    the frames, the glyph buffer and the map rows against HelpLine."""
    dest, _ = PLACES[place]
    row = dest & 0xFFC0
    memory = dict(settings.ram())
    for i in range(GFX_BYTES):
        memory[GFX + i] = GFX_FILL
    for i in range(4 * ROW_BYTES):
        memory[0x7E0000 + row + i] = MAP_FILL
    for i in range(0x40, 0x80):
        memory.setdefault(0x7E0200 + i, 0)
    memory.update({D78: 0x80, D77: 0, QUEUE_END: 0, TECH_ID: index & 0xFF})
    entry = DRAW_DESC if place == "item" else TECH_DESC
    runner.run(entry, memory, d=0, db=0x7E, a=index & 0xFF)
    queued, yields = [], [0]
    machine = runner.machine

    def trace(s):
        if s.pc == QUEUE_WRAM:
            rec = [machine.read8(s, 0x7E0000 | (s.x + k) & 0xFFFF) for k in range(7)]
            dst, src, size = rec[0] | rec[1] << 8, rec[2] | rec[3] << 8, rec[5] | rec[6] << 8
            data = bytes(machine.read8(s, (rec[4] << 16) | (src + i) & 0xFFFF) or 0 for i in range(size))
            queued.append((yields[0], dst, src, data))
        elif s.pc == YIELD:
            yields[0] += 1

    runner.run(STEP_LOOP, memory, d=0, db=0x7E, trace=trace)
    gfx = bytes([GFX_FILL] * GFX_BYTES)
    wram = {row + i: MAP_FILL for i in range(4 * ROW_BYTES)}
    model = help_line(rom, place, index, settings, gfx, wram)
    want = [(fr, dst, src, data) for fr, _, dst, src, data in model.uploads]
    bad = []
    if queued != want:
        k = next((i for i, (a, b) in enumerate(zip(queued, want)) if a != b), min(len(queued), len(want)))
        bad.append(f"upload {k} of {len(want)} (run {len(queued)})")
    if yields[0] + 1 != model.frame:
        bad.append(f"frames {yields[0] + 1} != {model.frame}")
    if bytes(memory[GFX + i] for i in range(GFX_BYTES)) != bytes(model.buf):
        bad.append("glyph buffer")
    if any(memory.get(0x7E0000 + row + i) != model.wram.get(row + i, MAP_FILL) for i in range(4 * ROW_BYTES)):
        bad.append("map rows")
    return model, bad


def patched_runner(rom, ref=D.REF):
    patched = bytearray(rom)
    patched[D.pc(YIELD)] = 0x60            # RTS: Menu_Yield returns at once (one frame per pass)
    return D.RomRunner(bytes(patched), ref)


def run_claims(rom, ref=D.REF, settings=None):
    runner = patched_runner(rom, ref)
    out = []
    s = settings or D.default_settings()
    for place, (_, n) in TABLES.items():
        failed, frames, glyphs, skipped = [], 0, 0, []
        for i in range(n):
            try:
                model, bad = run_one(rom, runner, place, i, s)
            except HelpLineError as e:
                skipped.append(f"{i}: {e}")
                continue
            except Exception as e:          # the interpreter's Unresolved and RuntimeError
                failed.append(f"{place} {i}: {e}")
                continue
            frames += model.frame
            glyphs += len(model.glyph_log)
            if bad:
                failed.append(f"{place} {i}: {bad[0]}")
        routine = "Menu_DrawDescText" if place == "item" else "Menu_TechDescText"
        out.append((f"{routine} + Menu_TextStepLoop (run) = HelpLine for {n - len(failed) - len(skipped)} of {n} "
                    f"{place} descriptions ({frames} frames, {glyphs} glyphs: every upload, the glyph buffer, "
                    f"the map rows)", not failed and not skipped, "; ".join((failed + skipped)[:3])))
    out += run_synthetic(rom, ref)
    return out


def run_synthetic(rom, ref=D.REF):
    """Synthetic descriptions (a second line, a wait, numbers and names, a line
    past the row) in a copy of the ROM in memory, under the item and tech
    settings, run in the interpreter."""
    patched = bytearray(rom)
    texts = synthetic_texts()
    for place, (table, _) in TABLES.items():
        for i, t in enumerate(texts):
            at = (table & 0xFF0000) | 0xF800 + 0x40 * i if place == "item" else (table & 0xFF0000) | 0xFC00 + 0x40 * i
            patched[D.pc(at):D.pc(at) + len(t)] = bytes(t)
            patched[D.pc(table + 2 * i):D.pc(table + 2 * i) + 2] = struct.pack("<H", at & 0xFFFF)
    patched = bytes(patched)
    runner = patched_runner(patched, ref)
    failed, n, runaway = [], 0, 0
    for place in TABLES:
        for i in range(len(texts)):
            for s in D.synthetic_settings():
                try:
                    help_line(patched, place, i, s)
                except HelpLineError:
                    runaway += 1                # the ROM's tile loop wraps too: not run
                    continue
                n += 1
                try:
                    _, bad = run_one(patched, runner, place, i, s)
                except Exception as e:      # HelpLineError, the interpreter's Unresolved and RuntimeError
                    bad = [str(e)]
                if bad:
                    failed.append(f"{place} {i}: {bad[0]}")
    return [(f"Menu_TextStepLoop (run) = HelpLine for {n - len(failed)} of {n} synthetic description runs "
             f"({runaway} more the model stops as a runaway tile loop)", not failed and runaway > 0, "; ".join(failed[:3]))]


# --- Synthetic vectors for the Swift twin -------------------------------------------------------

def synthetic_texts():
    """Invented descriptions in the synthetic font (no ROM text): one line, two
    lines, codes (dictionary, names, a number, a wait), a line that ends past
    the row's column 31 (pen 241-255), three lines, and one whose pen wraps
    (the tile loop runs away: HelpLineError, and the ROM itself does not
    return)."""
    g = lambda s: [0xA0 + (ord(c) - 65 if c.isupper() else ord(c) - 97 + 26) if c.isalpha() else 0xEF for c in s]
    mem = D.Memory(regions=D.synthetic_rom()[0])
    rng = D.Lcg(11)
    past, pen = g("Wide"), 8
    pen += sum(D.width(mem, c) for c in past)
    while pen <= 240:
        c = 0xA0 + rng.next(0x34)
        if pen + D.width(mem, c) <= 255:
            past.append(c)
            pen += D.width(mem, c)
    wrap = g("Wrap") + [0xA0 + rng.next(0x34) for _ in range(60)]
    return [
        g("Restores some health") + [0],
        g("Two") + [5] + g("lines here") + [0],
        [0x21, 0xEF, 0x13, 0xEF, 0x1B] + g(" and ") + [0x0D, 0xEF, 3, 2] + g("ok") + [0],
        past + [0],
        [0x1E, 0xEF, 0x1F, 0x10, 0x04] + g("x") + [5] + g("y") + [5] + g("z") + [0],
        wrap + [0],
    ]


SYN_TABLE = 0xC8F000                     # synthetic string table (any ROM address)


def vectors_text():
    regions, _ = D.synthetic_rom()
    mem_regions = dict(regions)
    texts = synthetic_texts()
    ptrs = []
    for i, t in enumerate(texts):
        at = SYN_TABLE + 0x100 + 0x40 * i
        mem_regions[at] = bytes(t)
        ptrs.append(at & 0xFFFF)
    mem_regions[SYN_TABLE] = b"".join(struct.pack("<H", p) for p in ptrs)
    expect = []
    for place in PLACES:
        for i in range(len(texts)):
            for k, s in enumerate(D.synthetic_settings()):
                mem = D.Memory(regions=mem_regions, ram=s.ram())
                text = (SYN_TABLE & 0xFF0000) | mem.word(SYN_TABLE + 2 * i)
                try:
                    h = HelpLine(mem, text, place).run()
                    expect.append({"place": place, "text": i, "settings": k, **h.summary()})
                except HelpLineError as e:
                    expect.append({"place": place, "text": i, "settings": k, "error": str(e)})
    settings = [{"names": s.names, "party": s.party, "item": s.item, "args": s.args, "numHex": s.num_hex,
                 "place": s.place, "press": s.press} for s in D.synthetic_settings()]
    head = {"schema": "ct-helpline-vectors/1",
            "note": "synthetic font, dictionary, names and descriptions in the real tables' places (no ROM data); "
                    "expected results by re_workspace/tools/ct_helpline.py",
            "table": D.snes(SYN_TABLE), "regions": [{"at": D.snes(k), "hex": v.hex()} for k, v in sorted(mem_regions.items())],
            "settings": settings}
    lines = ["{"]
    lines += [f' "{k}": {json.dumps(v, separators=(",", ":"))},' for k, v in head.items()]
    body = ",\n".join("  " + json.dumps(d, separators=(",", ":")) for d in expect)
    return "\n".join(lines) + f'\n "lines": [\n{body}]}}\n'


# --- CLI ---------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sh = sub.add_parser("show")
    sh.add_argument("place", choices=tuple(PLACES))
    sh.add_argument("index", type=lambda v: int(v, 0))
    sh.add_argument("--rom", default=str(D.ROM_PATH))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(D.ROM_PATH))
    k.add_argument("--run", action="store_true")
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
    rom = D.read_rom(args.rom)
    if args.command == "show":
        print(json.dumps(help_line(rom, args.place, args.index).summary(), indent=1))
        return 0
    claims = asm_claims() + code_claims(rom) + data_claims(rom)
    if args.run:
        claims += run_claims(rom)
    return D.report(claims)


if __name__ == "__main__":
    sys.exit(main())
