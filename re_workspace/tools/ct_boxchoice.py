#!/usr/bin/env python3
"""Chrono Trigger dialogue box: where the field puts it, and the choice cursor.

The evidence for `CTDialogueChoice.swift`, read from matched ChronoRET
routines (MIT; refs/ChronoRET) and checked against them: `check` holds the
static claims (source lines, the ROM's code operands, data shapes), `check
--run` runs the routines themselves in ChronoRET's 65816 interpreter.

Place (Field_Unk1F87 $C0:1F87, state 5, the first frame: Field_Unk26 = 0).
The message opcodes set Field_Unk30: OpBB_Msg and OpC0_MsgChoice 0, OpC1 and
OpC3 1, OpC2 and OpC4 2. With 1 or 2 that is the place (1: the band centred on
line 48, the top; 2: on line 171, the bottom). Anything else reads the low byte
of Obj_ScreenY ($0A80 + X, 16-bit per object) for X = Field_Unk2E (the object
that ran the opcode, Obj_Cur): below $80 (BPL: the upper half of the screen)
the box goes to the bottom (2), from $80 on to the top (1).

Choice (OpC0 / OpC3 / OpC4, operand byte c; Evt_MsgChoiceStart $C0:3674):
Field_Unk65 = c & 3 (the last choice line), Field_Unk64 = c >> 2 & 3 (the
first), Field_Unk62 = 1. While Field_Unk62 = 1 the box waits as usual; when
the text has ended (TextWin_Status 0) state 7 sets the cursor Field_Unk63 =
Field_Unk64 and Field_Unk62 = 2. Then Sub_1ADF ($C0:1ADF, each frame from
Field_PauseAndMenuInput) moves it: Pad_Unk00F7 bit 2 (Down) one line on, past
Field_Unk65 back to Field_Unk64; else bit 3 (Up) one line back, from 0 or
below Field_Unk64 to Field_Unk65; else Pad_Unk00F8 bit 7 sets Field_Unk62 = 3
(made). For any other Field_Unk62 it keeps Field_Unk63 in Field_Unk66 and sets
Field_Unk63 = 4 (unless negative or 4). The opcode stores Field_Unk66 in the
object's ObjX_Unk7F0A80 (the choice made).

Cursor (Irq_DrawChoiceCursor $C0:F05E, from the IRQ while Field_Unk63 is not
negative): a 2 x 2 tile picture, words $28FC $28FD over $28FE $28FF (BG3
characters $0FC-$0FF, palette 2, priority) at columns 2-3 of map rows 2j and
2j + 1 of the text grid at VRAM $1C00 (j = Field_Unk63: the text line), the
grid's own words ($2902 + $40 j, + $10 below) put back at the other three
lines; Field_Unk63 4 or more clears all four and sets Field_Unk63 = $80. The
four characters are the 64 bytes Field_UploadUnk57E0 sends from $FF:9260 to
VRAM $57E0: BG3's characters start at $5000 (BG34NBA $05), so $57E0 is
character $0FC.

Over the map (EngFD_UnkC124's band records, Hdma_InitChannelsFD): in the band
the HDMA writes, besides the box's BG1SC/BG3SC ($1C), its VOFS and TM (5 or
1), HOFS 0 for BG1 and BG3 (each scroll pair's first word) and TS = TMW = TSW
= 0 (the 4-register TM record); the gradient's CGADSUB/COLDATA on every line
but the last, which keeps the map's CGADSUB with COLDATA black. Outside it the
records are the map's own (TM/TS from Ppu_Unk0BD7/0BD8, its tilemaps).

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_boxchoice.py place UNK30 SCREEN_Y                the place for Field_Unk30 and the speaker's Obj_ScreenY
    ct_boxchoice.py check [--rom PATH] [--run]          every evidence claim (exit 1 on a failure)
    ct_boxchoice.py vectors (--out | --check) P         synthetic vectors for the Swift twin
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_dialogue as D  # noqa: E402

VECTORS = D.WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "dialogue" / "choice_vectors.json"

# --- Addresses and constants (ChronoRET include/*.inc) ------------------------------------

MSG_STEP_ENTRY, MSG_START = 0xC01F87, 0xC020F2      # Field_Unk1F87, Field_MsgStart
SUB_1ADF, DRAW_CURSOR, UPLOAD_57E0 = 0xC01ADF, 0xC0F05E, 0xC06F5E
CURSOR_GFX, CURSOR_GFX_BYTES, CURSOR_VRAM = 0xFF9260, 0x40, 0x57E0   # !FieldRom_Unk9260, $40, $57E0
BG3_CHARS = 0x5000                                  # BG34NBA $05
OPCODE_UNK30 = {0xBB: 0, 0xC0: 0, 0xC1: 1, 0xC2: 2, 0xC3: 1, 0xC4: 2}
CHOICE_OPCODES = (0xC0, 0xC3, 0xC4)
PLACE_TOP, PLACE_BOTTOM = 1, 2                      # !FieldMsg_Place1 / 2
CHOICE_MASK = 3                                     # !Evt_ChoiceMask
CHOICE_START, CHOICE_ACTIVE, CHOICE_MADE = 1, 2, 3  # Field_Unk62
CURSOR_OFF, CURSOR_IDLE = 4, 0x80                   # Field_Unk63: forced / !Field_Unk63Idle
PAD_DOWN, PAD_UP, PAD_CONFIRM, PAD_F6_BIT7 = 0x04, 0x08, 0x80, 0x80
VRAM_ROW0, VRAM_ROW_STEP, VRAM_LINE = 0x1C02, 0x40, 0x20   # !ChoiceCursor_VramRow0 / RowStep / Line
TILE_TOP, TILE_BOTTOM = 0x28FC, 0x28FE
GRID_ROW0, GRID_ROW_STEP, GRID_LINE = 0x2902, 0x40, 0x10
OBJ_SCREEN_Y = 0x7E0A80
F2E, F2F = 0x7E012E, 0x7E012F
F34, F62, F63, F64, F65, F66 = 0x7E0134, 0x7E0162, 0x7E0163, 0x7E0164, 0x7E0165, 0x7E0166
PAD_F6, PAD_F7, PAD_F8 = 0x7E00F6, 0x7E00F7, 0x7E00F8


# --- The model ---------------------------------------------------------------------------

def box_place(unk30, screen_y):
    """Field_Unk26 for Field_Unk30 and the speaker's Obj_ScreenY (only its low byte counts)."""
    if unk30 in (PLACE_TOP, PLACE_BOTTOM):
        return unk30
    return PLACE_BOTTOM if screen_y & 0xFF < 0x80 else PLACE_TOP


def choice_limits(operand):
    """(Field_Unk64, Field_Unk65): the first and last choice lines of a choice opcode's operand."""
    return operand >> 2 & CHOICE_MASK, operand & CHOICE_MASK


def sub_1adf(f62, f63, f64, f65, f66, f6, f7, f8, f34):
    """Sub_1ADF's writes: (f62, f63, f66, f34)."""
    if f62 == CHOICE_ACTIVE:
        if f7 & PAD_DOWN:
            n = (f63 + 1) & 0xFF
            return f62, n if n <= f65 else f64, f66, f34
        if f7 & PAD_UP:
            if f63 == 0:
                return f62, f65, f66, f34
            n = f63 - 1
            return f62, n if n >= f64 else f65, f66, f34
        return (CHOICE_MADE if f8 & PAD_CONFIRM else f62), f63, f66, f34
    if f62 != CHOICE_START and f63 < 0x80 and f63 != CURSOR_OFF:
        f66, f63 = f63, CURSOR_OFF
    if f6 & PAD_F6_BIT7:
        f34 = 0
    return f62, f63, f66, f34


def step_choice(cursor, operand, key):
    """The cursor after one key ('down', 'up' or None) on a choice operand."""
    low, high = choice_limits(operand)
    f7 = {"down": PAD_DOWN, "up": PAD_UP}.get(key, 0)
    return sub_1adf(CHOICE_ACTIVE, cursor, low, high, 0, 0, f7, 0, 0)[1]


def grid_word(row, below):
    return GRID_ROW0 + GRID_ROW_STEP * row + (GRID_LINE if below else 0)


def cursor_writes(row):
    """Irq_DrawChoiceCursor's VRAM word writes, in order: [(address, word)], and Field_Unk63 after."""
    order = {0: (1, 2, 3), 1: (0, 2, 3), 2: (0, 1, 3), 3: (0, 1, 2)}.get(row, (0, 1, 2, 3))
    out = []
    for j in order:
        at = VRAM_ROW0 + VRAM_ROW_STEP * j
        out += [(at, grid_word(j, False)), (at + 1, grid_word(j, False) + 1),
                (at + VRAM_LINE, grid_word(j, True)), (at + VRAM_LINE + 1, grid_word(j, True) + 1)]
    if row < 4:
        at = VRAM_ROW0 + VRAM_ROW_STEP * row
        out += [(at, TILE_TOP), (at + 1, TILE_TOP + 1), (at + VRAM_LINE, TILE_BOTTOM),
                (at + VRAM_LINE + 1, TILE_BOTTOM + 1)]
        return out, row
    return out, CURSOR_IDLE


def cursor_tiles(mem):
    """The cursor's 16 x 16 pixels (colour indices 0-3) from the four 2bpp characters at $FF:9260."""
    data = [mem(CURSOR_GFX + i) for i in range(CURSOR_GFX_BYTES)]
    pix = [[0] * 16 for _ in range(16)]
    for t in range(4):
        tile = data[16 * t:16 * t + 16]
        ox, oy = 8 * (t & 1), 8 * (t >> 1)
        for y in range(8):
            p0, p1 = tile[2 * y], tile[2 * y + 1]
            for x in range(8):
                pix[oy + y][ox + x] = (p0 >> (7 - x) & 1) | (p1 >> (7 - x) & 1) << 1
    return pix


# --- Evidence: the source -------------------------------------------------------------------------

ASM_CLAIMS = (
    ("bankC0/bankC0.asm", "Field_Unk1F87", ("LDA.b !Field_Unk26", "BNE .opening", "LDA.b !Field_Unk30",
                                            "BEQ .by_object", "CMP.b #!FieldMsg_Place1", "BEQ .lower",
                                            "CMP.b #!FieldMsg_Place2", "BEQ .upper", "LDX.b !Field_Unk2E",
                                            "LDA.w !Obj_ScreenY,X", "BPL .upper", "LDA.b #!FieldMsg_Place1",
                                            "BRA .set_place", "LDA.b #!FieldMsg_Place2", "STA.b !Field_Unk26")),
    ("bankC0/bankC0.asm", "Field_Unk1F87", ("LDA.b !Field_Unk62", "BEQ .wait_count", "CMP.b #!FieldMsg_ChoiceStart",
                                            "BNE .choice_other", "LDA.w !TextWin_Dp+!TextWin_Status",
                                            "BNE .wait_count", "LDA.b !Field_Unk64", "STA.b !Field_Unk63",
                                            "LDA.b #!FieldMsg_ChoiceActive", "STA.b !Field_Unk62")),
    ("bankC0/bankC0.asm", "Evt_OpBB_Msg", ("LDA.b !Obj_Cur", "STA.b !Field_Unk2E", "STZ.b !Field_Unk30")),
    ("bankC0/bankC0.asm", "Evt_OpC1_MsgUnk30_1", ("LDA.b #$01", "STA.b !Field_Unk30")),
    ("bankC0/bankC0.asm", "Evt_OpC2_MsgUnk30_2", ("LDA.b #$02", "STA.b !Field_Unk30")),
    ("bankC0/bankC0.asm", "Evt_OpC0_MsgChoice", ("STZ.b !Field_Unk30", "BRA Evt_MsgChoiceStart",
                                                 "LDA.b !Field_Unk66", "STA.l !ObjX_Unk7F0A80,X")),
    ("bankC0/bankC0.asm", "Evt_OpC3_MsgChoiceUnk30_1", ("LDA.b #$01", "STA.b !Field_Unk30", "BRA Evt_MsgChoiceStart")),
    ("bankC0/bankC0.asm", "Evt_OpC4_MsgChoiceUnk30_2", ("LDA.b #$02", "STA.b !Field_Unk30", "BRL Evt_MsgChoiceStart")),
    ("bankC0/bankC0.asm", "Evt_MsgChoiceStart", ("AND.b #!Evt_ChoiceMask", "STA.b !Field_Unk65", "LSR A", "LSR A",
                                                 "AND.b #!Evt_ChoiceMask", "STA.b !Field_Unk64", "LDA.b #$01",
                                                 "STA.b !Field_Unk62", "LDA.b !Obj_Cur", "STA.b !Field_Unk2E")),
    ("bankC0/bankC0.asm", "Sub_1ADF", ("LDA.w !Pad_Unk00F7", "BIT.b #!Pad_HiDown", "BNE .step_up",
                                       "BIT.b #!Pad_HiUp", "BNE .step_down", "LDA.w !Pad_Unk00F8",
                                       "BIT.b #!Pad_Unk00F8Bit7", "LDA #$03", "STA.b !Field_Unk62")),
    ("bankC0/bankC0.asm", "Irq_DrawChoiceCursor", ("LDA.w !DP_Field+!Field_Unk63", "LDX.w #!ChoiceCursor_VramRow0",
                                                   "LDX.w #!ChoiceCursor_TileTop", "LDX.w #!ChoiceCursor_TileBottom")),
    ("bankFD/bankFD.asm", "EngFD_UnkC124", ("LDA.w #0", "STA.w !Hdma_Unk7F14F8", "LDA.w #!Hdma_ScrollPair0",
                                           "STA.w !Hdma_Unk7F14F8+2", "LDA.w #0", "STA.w !Hdma_Unk7F14F8+4",
                                           "LDA.w #!Hdma_ScrollPair1", "LDA.w #0", "STA.w !Hdma_Unk7F14F8+8",
                                           "LDA.w #!Hdma_ScrollPair2", "LDA.w #0", "STA.w !Hdma_Unk7F14F8+12",
                                           "LDA.w #!Hdma_ScrollPair3", "LDA.l !Ppu_Unk0BD7", "STA.w !Hdma_Unk7F1520",
                                           "LDA.b #5", "STA.w !Hdma_Unk7F1524", "LDA.b #0", "STA.w !Hdma_Unk7F1524+1",
                                           "LDA.b #0", "STA.w !Hdma_Unk7F1524+2", "STA.w !Hdma_Unk7F1524+3",
                                           "LDA.b #1", "STA.w !Hdma_Unk7F1528", "LDA.b #0", "STA.w !Hdma_Unk7F1528+1",
                                           "LDA.b #0", "STA.w !Hdma_Unk7F1528+2", "STA.w !Hdma_Unk7F1528+3")),
    ("bankFD/bankFD.asm", "Hdma_InitChannelsFD", ("LDA.b #!DMAP_HdmaIndirect|!DMAP_FourRegs", "STA.b DMAP4-!DP_DMA",
                                                  "LDA.b #!BBAD_BG1HOFS", "STA.b BBAD1-!DP_DMA",
                                                  "LDA.b #!BBAD_BG3HOFS", "STA.b BBAD3-!DP_DMA",
                                                  "LDA.b #!BBAD_TM", "STA.b BBAD4-!DP_DMA")),
    ("bankC0/bankC0.asm", "Field_UploadUnk57E0", ("LDX.w #!FieldRom_Unk9260&$FFFF", "LDX.w #!Field_UploadVram57E0",
                                                  "LDX.w #!Field_UploadUnk57E0Bytes")),
)
CONSTANT_CLAIMS = (
    ("include/constants_engine.inc", "!FieldMsg_Place1 = $01"),
    ("include/constants_engine.inc", "!FieldMsg_Place2 = $02"),
    ("include/constants_engine.inc", "!Evt_ChoiceMask = $03"),
    ("include/constants_engine.inc", "!FieldMsg_ChoiceActive = $02"),
    ("include/constants_engine.inc", "!Field_Unk63Idle = $80"),
    ("include/constants_engine.inc", "!Pad_HiDown = $04"),
    ("include/constants_engine.inc", "!Pad_HiUp = $08"),
    ("include/constants_engine.inc", "!ChoiceCursor_VramRowStep = $0040"),
    ("include/constants_engine.inc", "!ChoiceCursor_VramLine = $0020"),
    ("include/constants_engine.inc", "!ChoiceCursor_TileTop = $28FC"),
    ("include/constants_engine.inc", "!ChoiceCursor_TileBottom = $28FE"),
    ("include/constants_engine.inc", "!ChoiceCursor_GridRowStep = $0040"),
    ("include/constants_engine.inc", "!ChoiceCursor_GridLine = $0010"),
    ("include/constants_engine.inc", "!Field_UploadVram57E0 = $57E0"),
    ("include/constants_engine.inc", "!Field_UploadUnk57E0Bytes = $0040"),
    ("include/ram_engine.inc", "!FieldRom_Unk9260 = $FF9260"),
    ("include/ram_engine.inc", "!Obj_ScreenY = $0A80"),
)


def asm_claims(ref=D.REF):
    saved = D.ASM_CLAIMS, D.CONSTANT_CLAIMS
    try:
        D.ASM_CLAIMS, D.CONSTANT_CLAIMS = ASM_CLAIMS, CONSTANT_CLAIMS
        return [(f"box and choice: {n}", ok, *rest) for n, ok, *rest in D.asm_claims(ref)]
    finally:
        D.ASM_CLAIMS, D.CONSTANT_CLAIMS = saved


# --- Evidence: the ROM's code bytes and data ----------------------------------------------------

def code_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    body = lambda a, b: bytes(rom[D.pc(a):D.pc(b) + 1])
    step = body(0xC01F87, 0xC020B1)
    claim("$C0:1F87 places the box by Field_Unk30 1 / 2, else Obj_ScreenY's sign (LDA $30; BEQ; CMP #$01; BEQ; "
          "CMP #$02; BEQ; LDX $2E; LDA $0A80,X; BPL)",
          any(step[i:i + 2] == b"\xa5\x30" and step[i + 2] == 0xF0 and step[i + 4:i + 6] == b"\xc9\x01"
              and step[i + 8:i + 10] == b"\xc9\x02" and step[i + 12:i + 17] == b"\xa6\x2e\xbd\x80\x0a"
              and step[i + 17] == 0x10 for i in range(len(step) - 18)))
    start = body(0xC03674, 0xC036A9)
    claim("$C0:3674 splits the operand (AND #$03; STA $65; LSR; LSR; AND #$03; STA $64; LDA #$01; STA $62)",
          b"\x29\x03\x85\x65" in start and b"\x4a\x4a\x29\x03\x85\x64\xa9\x01\x85\x62" in start)
    sub = body(SUB_1ADF, 0xC01B35)
    claim("$C0:1ADF tests Down, Up and the press (LDA $00F7; BIT #$04; BNE; BIT #$08; BNE; LDA $00F8; BIT #$80)",
          any(sub[i:i + 5] == b"\xad\xf7\x00\x89\x04" and sub[i + 5] == 0xD0 and sub[i + 7:i + 9] == b"\x89\x08"
              and sub[i + 11:i + 16] == b"\xad\xf8\x00\x89\x80" for i in range(len(sub) - 16)))
    cur = body(DRAW_CURSOR, 0xC0F10F)
    claim("$C0:F05E writes $1C02, $28FC and $28FE (LDX #$1C02; LDX #$28FC; LDX #$28FE) after VMAIN $80",
          b"\xa2\x02\x1c" in cur and b"\xa2\xfc\x28" in cur and b"\xa2\xfe\x28" in cur and b"\xa9\x80" in cur)
    clear = body(0xC0F159, 0xC0F16F)
    claim("$C0:F159 puts back $2902 at $1C02 (LDX #$1C02; LDX #$2902)", b"\xa2\x02\x1c" in clear and b"\xa2\x02\x29" in clear)
    up = body(UPLOAD_57E0, 0xC06F78)
    claim("$C0:6F5E sends $40 bytes of $FF:9260 to $57E0 (LDX #$9260; LDX #$57E0; LDX #$0040; LDA #$FF)",
          all(p in up for p in (b"\xa2\x60\x92", b"\xa2\xe0\x57", b"\xa2\x40\x00", b"\xa9\xff")))
    return out


def data_claims(rom):
    out = []
    mem = D.Memory(rom)

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    claim("VRAM $57E0 is BG3 character $0FC (characters at $5000, 8 words each)",
          BG3_CHARS + 8 * (TILE_TOP & 0x3FF) == CURSOR_VRAM and D.BG34NBA & 0x0F == BG3_CHARS >> 12)
    grid = D.text_tilemap()
    claim("the cursor puts back the text grid's own words (Field_Unk2B78, columns 2-3 of rows 0-7)",
          all(grid[2 * j + b][2 + c] == grid_word(j, b) + c for j in range(4) for b in (0, 1) for c in (0, 1)))
    pix = cursor_tiles(mem)
    lit = sum(1 for row in pix for v in row if v)
    claim("the cursor's characters ($FF:9260) draw pixels in more than one colour, in both halves",
          lit > 16 and len({v for row in pix for v in row}) > 2 and any(any(r[:8]) for r in pix) and any(any(r[8:]) for r in pix),
          f"{lit} pixels")
    return out


# --- Evidence: the routines, run --------------------------------------------------------------------

def patched_runner(rom, ref=D.REF):
    patched = bytearray(rom)
    patched[D.pc(MSG_START)] = 0x60          # RTS: Field_MsgStart (the decoder's start) is not part of the place
    return D.RomRunner(bytes(patched), ref)


def place_cases():
    out = []
    for unk30 in (0, 1, 2, 3, 0x80, 0xFF):
        for y in (0x00, 0x01, 0x7F, 0x80, 0x81, 0xFF):
            for hi in (0x00, 0x01, 0xFF):
                for obj in (0x00, 0x02, 0x3E):
                    out.append((unk30, y | hi << 8, obj))
    return out


def run_place(rom, ref=D.REF):
    runner = patched_runner(rom, ref)
    failed = []
    cases = place_cases()
    for unk30, y, obj in cases:
        memory = {D.F29: 5, D.F26: 0, D.F27: 7, D.F30: unk30, D.F31: 3, D.F33: 5, D.F36: 1, F2E: obj, F2F: 0}
        for k in range(0x80):           # every object's Obj_ScreenY: the others hold the opposite half
            memory[OBJ_SCREEN_Y + k] = 0xC0 if y & 0x80 == 0 else 0x10
        memory[OBJ_SCREEN_Y + obj], memory[OBJ_SCREEN_Y + obj + 1] = y & 0xFF, y >> 8
        try:
            runner.run(MSG_STEP_ENTRY, memory, d=0x0100)
        except Exception as e:          # the interpreter's Unresolved and RuntimeError
            failed.append(f"{unk30} {y:04X} {obj}: {e}")
            continue
        got = (memory[D.F26], memory[D.F27], memory[D.F31], memory[D.F33], memory[D.F36], memory[D.F29])
        if got != (box_place(unk30, y), 0, 0, 0, 0, 5):
            failed.append(f"Field_Unk30 {unk30} Obj_ScreenY ${y:04X} object {obj}: {got}")
    return [(f"Field_Unk1F87 (run) = box_place for {len(cases) - len(failed)} of {len(cases)} "
             f"(Field_Unk30, Obj_ScreenY, object) cases", not failed, "; ".join(failed[:3]))]


def sub_cases():
    out = []
    for f62 in (0, 1, 2, 3, 0x80):
        for low in range(4):
            for high in range(4):
                for cur in (0, 1, 2, 3, 4, 0x7F, 0x80):
                    for f7, f8 in ((0, 0), (PAD_DOWN, 0), (PAD_UP, 0), (PAD_DOWN | PAD_UP, 0), (0, PAD_CONFIRM),
                                   (PAD_UP, PAD_CONFIRM)):
                        f6 = 0x80 if (cur + f7) & 1 else 0
                        out.append((f62, cur, low, high, 9, f6, f7, f8, 0x1234))
    return out


def run_sub(rom, ref=D.REF):
    runner = D.RomRunner(rom, ref)
    failed = []
    cases = sub_cases()
    for f62, f63, f64, f65, f66, f6, f7, f8, f34 in cases:
        memory = {F62: f62, F63: f63, F64: f64, F65: f65, F66: f66, PAD_F6: f6, PAD_F7: f7, PAD_F8: f8,
                  F34: f34 & 0xFF, F34 + 1: f34 >> 8}
        try:
            runner.run(SUB_1ADF, memory, d=0x0100, a=f62)
        except Exception as e:
            failed.append(f"{f62} {f63}: {e}")
            continue
        got = (memory[F62], memory[F63], memory[F66], memory[F34] | memory[F34 + 1] << 8)
        want = sub_1adf(f62, f63, f64, f65, f66, f6, f7, f8, f34)
        if got != want:
            failed.append(f"Field_Unk62 {f62} cursor {f63} lines {f64}-{f65} pads {f6:02X}/{f7:02X}/{f8:02X}: "
                          f"{got} != {want}")
    return [(f"Sub_1ADF (run) = sub_1adf for {len(cases) - len(failed)} of {len(cases)} cases", not failed,
             "; ".join(failed[:3]))]


def run_cursor(rom, ref=D.REF):
    """Irq_DrawChoiceCursor with the VRAM port (VMAIN $2115, VMADD $2116-7, VMDATA $2118-9) recorded."""
    runner = D.RomRunner(rom, ref)
    machine = runner.machine
    base = machine.write8
    port = {"addr": 0, "vmain": None, "lo": 0, "writes": []}

    def write8(s, addr, v):
        low = None if addr is None else addr & 0xFFFF
        if addr is not None and addr >> 16 & 0xFF in (0x00, 0x80) and low in (0x2115, 0x2116, 0x2117, 0x2118, 0x2119):
            if low == 0x2115:
                port["vmain"] = v
            elif low == 0x2116:
                port["addr"] = port["addr"] & 0xFF00 | v
            elif low == 0x2117:
                port["addr"] = port["addr"] & 0x00FF | v << 8
            elif low == 0x2118:
                port["lo"] = v
            else:
                port["writes"].append((port["addr"], port["lo"] | v << 8))
                port["addr"] = (port["addr"] + 1) & 0x7FFF
            return
        base(s, addr, v)

    machine.write8 = write8
    failed, rows = [], (0, 1, 2, 3, 4, 5, 0x7F)
    for row in rows:
        port.update(addr=0, vmain=None, writes=[])
        memory = {F63: row}
        try:
            runner.run(DRAW_CURSOR, memory, d=0x0100)
        except Exception as e:
            failed.append(f"row {row}: {e}")
            continue
        want, after = cursor_writes(row)
        if port["writes"] != want or memory[F63] != after or port["vmain"] != 0x80:
            failed.append(f"row {row}: {len(port['writes'])} writes, Field_Unk63 {memory[F63]}")
    return [(f"Irq_DrawChoiceCursor (run) = cursor_writes for {len(rows) - len(failed)} of {len(rows)} cursor values "
             "(the VRAM port recorded)", not failed, "; ".join(failed[:3]))]


def run_claims(rom, ref=D.REF):
    return run_place(rom, ref) + run_sub(rom, ref) + run_cursor(rom, ref)


# --- Synthetic vectors for the Swift twin -------------------------------------------------------

def vectors_text():
    places = [[u, y, box_place(u, y)] for u, y, _ in place_cases()[::3]]
    subs = [[*c, *sub_1adf(*c)] for c in sub_cases()[::7]]
    walks = []
    for operand in (0x01, 0x02, 0x03, 0x06, 0x07, 0x0B, 0x0D, 0x0F, 0x00, 0x09):
        low, _ = choice_limits(operand)
        cur, trail = low, [low]
        for key in ("down", "down", "down", "down", "up", "up", "up", "up", "up", None):
            cur = step_choice(cur, operand, key)
            trail.append(cur)
        walks.append([operand, trail])
    cursors = []
    for row in (0, 1, 2, 3, 4, 0x7F):
        writes, after = cursor_writes(row)
        cursors.append({"row": row, "after": after, "writes": [[a, w] for a, w in writes]})
    head = {"schema": "ct-choice-vectors/1",
            "note": "box place, Sub_1ADF and the choice cursor's VRAM writes as modelled (no ROM data); "
                    "expected results by re_workspace/tools/ct_boxchoice.py",
            "opcodes": {f"{k:02X}": v for k, v in OPCODE_UNK30.items()}}
    lines = ["{"]
    lines += [f' "{k}": {json.dumps(v, separators=(",", ":"))},' for k, v in head.items()]
    lines.append(f' "places": {json.dumps(places, separators=(",", ":"))},')
    lines.append(f' "walks": {json.dumps(walks, separators=(",", ":"))},')
    lines.append(' "subs": [\n' + ",\n".join("  " + json.dumps(s, separators=(",", ":")) for s in subs) + "],")
    lines.append(' "cursors": [\n' + ",\n".join("  " + json.dumps(c, separators=(",", ":")) for c in cursors) + "]}")
    return "\n".join(lines) + "\n"


# --- CLI ---------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("place")
    p.add_argument("unk30", type=lambda v: int(v, 0))
    p.add_argument("screen_y", type=lambda v: int(v, 0))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(D.ROM_PATH))
    k.add_argument("--run", action="store_true")
    g = sub.add_parser("vectors")
    m = g.add_mutually_exclusive_group(required=True)
    m.add_argument("--out")
    m.add_argument("--check")
    args = parser.parse_args()
    if args.command == "place":
        print(box_place(args.unk30, args.screen_y))
        return 0
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
    claims = asm_claims() + code_claims(rom) + data_claims(rom)
    if args.run:
        claims += run_claims(rom)
    return D.report(claims)


if __name__ == "__main__":
    sys.exit(main())
