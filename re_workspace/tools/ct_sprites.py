#!/usr/bin/env python3
"""Chrono Trigger playable-character sprites: frames, tiles, animations, palettes, evidence.

The family decoded here is the sprite sets of the seven playable characters
(sets 0-6, by character id). Both engines draw them from the same bank-$E4
tables, and ChronoRET (MIT; refs/ChronoRET) has every reader matched and
commented: the battle's set-up (Battle_InitScene $CC:E000), frame decoder
(Battle_DrawBattlerFrameAnyLayout $C1:1C55), OAM placer (BattleCF_DrawBattler
$CF:EAC5) and animation ticker (Battle_TickPcSlots $C1:2D9F); and, for the
field, the sprite-record loader (Evt_LoadSpriteRec), the frame builder
(Obj_BuildFrame4 $C0:CBDC), the animation lookup (Obj_AnimFrameLookup
$C0:CB3A) and the palette copy (Obj_PalSlotFixed $C0:719B). Two independent
readers of each table agree, so every field below has two witnesses.

Tables (bank $E4; RomE4_PtrInit $E4:FFE0 gives the field the same four bases):

  SprTilesPtr  $E4:2000  3 B per set: long pointer to its raw 4bpp tiles (32 B each)
  SprFramesPtr $E4:2300  3 B per set: long pointer to its frame records (40 B each)
  AnimFrames   $E4:2600  2 B per set: bank-$E4 offset of its frame-id rows
  AnimDurs     $E4:2800  2 B per set: bank-$E4 offset of its duration rows
  SprRec       $E4:F000  5 B per record: gfx, frames, palette, anim, size class;
                         records 0-6 are (c, c, c, c, 0)
  palette      $E4:0000 + palette * $18: 12 BGR555 colours, copied to colours 1-12

A frame record is 16 tile words (8 columns x 2 rows) and 4 (x, y) signed byte
pairs. A word's bits 0-10 are a tile of the set (0 = blank), bit 14 mirrors
the 8x8 tile left to right (each byte bit-reversed); the decoders test no
other bit. Row 0 goes to VRAM tiles T..T+7 and row 1 to T+16..T+23, and the
four OBJs (16x16, OBSEL 0) use tiles T + 2n, so OBJ n shows cells (0, 2n),
(0, 2n+1), (1, 2n), (1, 2n+1) at the origin plus pair n. T is 8 for battle
slot 0 and for the field's leader.

An animation row is 4 entries; set c has `rows` = (AnimFrames[c+1] -
AnimFrames[c]) / 16 of them per facing (up, down, left, right: Obj_Facing
0-3). Entry k of row r, facing f: frame id at AnimFrames + f * stride + r * 4
+ k (stride = rows * 4), duration at AnimDurs + r * 4 + k. A zero duration
ends the animation; until then it may run into the next row. A duration is
field frames (the object pass runs once a frame); the battle waits duration
/ 5 (at least 1) of its two-frame upkeep passes.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_sprites.py decode <set> [--rom PATH]               one set as JSON (no tile bytes)
    ct_sprites.py check [--rom PATH] [--run]              every evidence claim (exit 1 on a failure);
                                                          --run also executes the ROM's frame decoder
    ct_sprites.py render <set> <frame> --out P [--rom]    a frame composed from its cells (PNG)
    ct_sprites.py verify-import <project> [--rom PATH]    a Studio import (sprites/<name>.*) against decode
    ct_sprites.py vectors (--out | --check) P             synthetic vectors for the Swift twin
"""

import argparse
import json
import re
import struct
import sys
import zlib
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
REF = WS / "refs" / "ChronoRET"
ROM_PATH = WS / "ct_clean.sfc"
ROM_SIZE = 4 * 1024 * 1024


def pc(long):
    """HiROM file offset of a 24-bit address."""
    return (long >> 16 & 0x3F) << 16 | long & 0xFFFF


def snes(long):
    return f"${long >> 16:02X}:{long & 0xFFFF:04X}"


# --- Tables --------------------------------------------------------------------------

SETS = 7                              # sets 0-6: the playable characters, by id
NAMES = ("crono", "marle", "lucca", "robo", "frog", "ayla", "magus")
TILES_PTR = 0xE42000                  # BattleRom_SprTilesPtr = the field's Field_E4Ptr0 base
FRAMES_PTR = 0xE42300                 # BattleRom_SprFramesPtr = Field_E4Ptr1
ANIM_FRAMES = 0xE42600                # BattleRom_SprAnimFrames = Field_E4Ptr2
ANIM_DURS = 0xE42800                  # BattleRom_SprAnimDurs = Field_E4Ptr3
POINTERS = 256                        # entries of each pointer table ($E4:2000-$28FF)
PTR_INIT = 0xE4FFE0                   # RomE4_PtrInit: the field's four bases
SPR_REC = 0xE4F000                    # RomE4_SprRec
SPR_REC_BYTES = 5                     # gfx, frames, palette, anim, size
ANIM_BANK = 0xE40000                  # !AnimRom / !BattleRom_AnimData
PAL_BYTES, PAL_COLOURS = 0x18, 12     # Pal_ObjColorBytes; colours 1-12 of the OBJ palette

TILE_BYTES = 32
FRAME_BYTES = 40                      # BattleRom_FrameBytes[0] = Frame4_Bytes
COLUMNS, ROWS = 8, 2                  # BattleRom_FrameLayout[0]: width 8, height 2
CELLS = COLUMNS * ROWS
PIECES = 4                            # BattleRom_LayoutSprites[0]; size class 0 = 4 OBJs
TILE_MASK, HFLIP = 0x07FF, 0x4000     # !Battle_FrameTileMask / !SprFrame_TileMask, !Battle_FrameHFlip
SLOT_TILE = 8                         # battle slot 0 (SprRecInit $2A08) = the field leader (EvtChar_VramTile0)
VRAM_ROW = 16                         # tiles per VRAM row: a 16x16 OBJ's lower half is +16
PRIORITY = 2                          # EvtSpr_PrioInit $2020 and SprRecInit attribute $2A: OAM priority 2
FACINGS = ("up", "down", "left", "right")
END_MARKER = 0xFF                     # !Anim_EndMarker: a frame id that ends the row (field)
DUR_DIVISOR = 5                       # !Battle_AnimTicksDivisor

# Battle tables in bank $CC (ROM data the claims read; not used by the decoder).
FRAME_LAYOUT = 0xCCF3B6               # 14 B per layout: 6 row-offset words, width, height
FRAME_BYTES_TBL = 0xCCF40A
FRAME_EXTRA_COUNT = 0xCCF4FC
LAYOUT_SPRITES = 0xCCF50A             # read at layout * 2
SPR_REC_INIT = 0xCCFAF3               # 2 B per Battle_SprRec record: tile, attribute
FRAME_DEST_BASE = 0xCCF941
DMA_SRC_A, DMA_SRC_B, DMA_VRAM_A, DMA_VRAM_B = 0xCCF987, 0xCCF99D, 0xCCF9B3, 0xCCF9C9
DMA_SIZE_A, DMA_SIZE_B = 0xCCF9DF, 0xCCF9E9
PC_SLOTS = 3


def u8(rom, long):
    return rom[pc(long)]


def u16(rom, long):
    return rom[pc(long)] | rom[pc(long + 1)] << 8


def u24(rom, long):
    return u16(rom, long) | rom[pc(long + 2)] << 16


def s8(v):
    return v - 256 if v & 0x80 else v


def table(rom, base, size, count=POINTERS):
    read = u24 if size == 3 else u16
    return [read(rom, base + size * i) for i in range(count)]


def block_end(pointers, start):
    """Where the block at `start` ends: the next higher pointer of the table
    in the same bank, else the bank's end."""
    end = (start | 0xFFFF) + 1
    return min([p for p in pointers if start < p < end] + [end])


def tile_count(rom, c):
    start = u24(rom, TILES_PTR + 3 * c)
    return (block_end(table(rom, TILES_PTR, 3), start) - start) // TILE_BYTES


def frame_count(rom, c):
    """Records up to the next frame block (at most 256: a frame id is a byte),
    less trailing all-zero records (Robo's block runs to the bank's end and
    is zero-filled after its last record)."""
    start = u24(rom, FRAMES_PTR + 3 * c)
    n = min(POINTERS, (block_end(table(rom, FRAMES_PTR, 3), start) - start) // FRAME_BYTES)
    while n and not any(rom[pc(start + FRAME_BYTES * (n - 1)):pc(start + FRAME_BYTES * n)]):
        n -= 1
    return n


def anim_rows(rom, c):
    """Animation rows per facing: (AnimFrames[c+1] - AnimFrames[c]) / 16."""
    return (u16(rom, ANIM_FRAMES + 2 * c + 2) - u16(rom, ANIM_FRAMES + 2 * c)) // 16


def palette_offset(rom, c):
    return u8(rom, SPR_REC + SPR_REC_BYTES * c + 2) * PAL_BYTES


# --- Codec ---------------------------------------------------------------------------

def decode_frame(rec):
    """A 40-byte record: {"cells": 16 tile words, "pieces": 4 (x, y)}."""
    assert len(rec) == FRAME_BYTES
    cells = [rec[2 * k] | rec[2 * k + 1] << 8 for k in range(CELLS)]
    pieces = [[s8(rec[32 + 2 * n]), s8(rec[33 + 2 * n])] for n in range(PIECES)]
    return {"cells": cells, "pieces": pieces}


def piece_cells(n):
    """Cell indices of OBJ n in VRAM order: top-left, top-right, bottom-left, bottom-right."""
    return [2 * n, 2 * n + 1, COLUMNS + 2 * n, COLUMNS + 2 * n + 1]


def tile_indices(raw):
    """One 4bpp tile (32 B, SNES planar: planes 0/1 interleaved per row in
    bytes 0-15, planes 2/3 in bytes 16-31; bit 7 is the leftmost pixel) as
    64 row-major palette indices."""
    out = []
    for r in range(8):
        planes = (raw[2 * r], raw[2 * r + 1], raw[16 + 2 * r], raw[17 + 2 * r])
        for x in range(8):
            out.append(sum((planes[p] >> (7 - x) & 1) << p for p in range(4)))
    return out


def tiles(rom, c):
    """The set's tiles as raw 32-byte strings."""
    start = pc(u24(rom, TILES_PTR + 3 * c))
    return [bytes(rom[start + TILE_BYTES * t:start + TILE_BYTES * (t + 1)]) for t in range(tile_count(rom, c))]


def encode_tile(indices):
    """64 row-major palette indices as one SNES planar 4bpp tile (the inverse of tile_indices)."""
    out = bytearray(TILE_BYTES)
    for r in range(8):
        for x in range(8):
            v = indices[8 * r + x]
            for p in range(4):
                if v >> p & 1:
                    out[(16 if p >= 2 else 0) + 2 * r + (p & 1)] |= 0x80 >> x
    return bytes(out)


def set_spans(rom, c):
    """The PC ranges set c's write-back may change: its tiles, frame records,
    frame-id rows, duration rows and colours 1-12 (docs/sprites.md)."""
    t, f = pc(u24(rom, TILES_PTR + 3 * c)), pc(u24(rom, FRAMES_PTR + 3 * c))
    ids, durs = pc(ANIM_BANK + u16(rom, ANIM_FRAMES + 2 * c)), pc(ANIM_BANK + u16(rom, ANIM_DURS + 2 * c))
    pal, rows = pc(ANIM_BANK + palette_offset(rom, c)), anim_rows(rom, c)
    return {"tiles": range(t, t + TILE_BYTES * tile_count(rom, c)), "frames": range(f, f + FRAME_BYTES * frame_count(rom, c)),
            "frameIds": range(ids, ids + 16 * rows), "durations": range(durs, durs + 4 * rows),
            "palette": range(pal, pal + 2 * PAL_COLOURS)}


def cell_pixels(word, tile_bytes):
    """64 indices of a cell: tile word & $7FF of the set (0 blank), mirrored with bit 14."""
    t = word & TILE_MASK
    if t == 0 or t >= len(tile_bytes):
        return [0] * 64
    px = tile_indices(tile_bytes[t])
    if word & HFLIP:
        px = [px[r * 8 + 7 - x] for r in range(8) for x in range(8)]
    return px


def compose(frame, tile_bytes):
    """{(x, y): index} of a frame's opaque pixels about its origin; the lower
    OBJ number is in front (OAM order: BattleCF_CopySprTiles copies record k
    to OAM entry k)."""
    img = {}
    for n in range(PIECES):
        x0, y0 = frame["pieces"][n]
        for q, k in enumerate(piece_cells(n)):
            px = cell_pixels(frame["cells"][k], tile_bytes)
            ox, oy = x0 + 8 * (q % 2), y0 + 8 * (q // 2)
            for i, v in enumerate(px):
                if v:
                    img.setdefault((ox + i % 8, oy + i // 8), v)
    return img


def decode_animations(rom, c):
    """Every non-empty (row, facing) animation: frame ids and durations up to
    a zero duration (both engines: Battle_TickPcSlots goes back to entry 0,
    Obj_AnimTickAndQueue to the row's first) or a $FF frame id (the field's
    Anim_EndMarker, Obj_AnimFrameLookup). Until then a list runs on into the
    next row, never past the set's last."""
    rows = anim_rows(rom, c)
    frames_at = ANIM_BANK + u16(rom, ANIM_FRAMES + 2 * c)
    durs_at = ANIM_BANK + u16(rom, ANIM_DURS + 2 * c)
    stride = rows * 4
    out = []
    for r in range(rows):
        for f in range(4):
            ids, durs = [], []
            for e in range(r * 4, stride):
                d, i = u8(rom, durs_at + e), u8(rom, frames_at + f * stride + e)
                if d == 0 or i == END_MARKER:
                    break
                ids.append(i)
                durs.append(d)
            if ids:
                out.append({"id": f"r{r:02d}.{FACINGS[f]}", "row": r, "facing": f, "frames": ids, "durations": durs})
    return out


def palette(rom, c):
    at = ANIM_BANK + palette_offset(rom, c)
    return [u16(rom, at + 2 * i) for i in range(PAL_COLOURS)]


def decode_set(rom, c):
    frames_at = u24(rom, FRAMES_PTR + 3 * c)
    nframes = frame_count(rom, c)
    return {
        "set": c, "name": NAMES[c],
        "tiles": {"address": snes(u24(rom, TILES_PTR + 3 * c)), "count": tile_count(rom, c)},
        "frames": {"address": snes(frames_at), "count": nframes},
        "palette": {"address": snes(ANIM_BANK + palette_offset(rom, c)),
                    "colours": [f"0x{w:04X}" for w in palette(rom, c)]},
        "animations": {"frameIds": snes(ANIM_BANK + u16(rom, ANIM_FRAMES + 2 * c)),
                       "durations": snes(ANIM_BANK + u16(rom, ANIM_DURS + 2 * c)), "rows": anim_rows(rom, c)},
        "frameList": [decode_frame(rom[pc(frames_at + FRAME_BYTES * i):pc(frames_at + FRAME_BYTES * (i + 1))])
                      for i in range(nframes)],
        "animationList": decode_animations(rom, c),
    }


# --- Evidence: ChronoRET's source -----------------------------------------------------

# (file under asm/, routine label, lines that must appear in its body, in order).
ASM_CLAIMS = (
    # Battle: the PC set-up, by character id.
    ("bankCC/bankCC.asm", "Battle_InitScene",
     ("LDA.b #!Battler_SprBytesPc", "STA.w !Battler_SprBytes,Y",
      "LDA.l !BattleRom_SprTilesPtr,X", "STA.w !Battler_TileGfxPtr,Y",
      "LDA.l !BattleRom_SprFramesPtr,X", "STA.w !Battler_FramesPtr,Y",
      "LDA.l !BattleRom_SprAnimFrames,X", "STA.w !Battler_AnimFrameBase,Y",
      "LDA.l !BattleRom_SprAnimDurs,X", "STA.w !Battler_AnimDurBase,Y",
      "SBC.b !BattleTmp_82", "STA.w !Battler_FacingStrideLo,X")),
    # Battle: OAM records with their tile and attribute, and the high table.
    ("bankCC/bankCC.asm", "Battle_InitSceneGfx",
     ("LDA.l !BattleRom_SprRecInit,X", "STA.w Battle_SprRec.X,Y", "LDA.b #!Battle_HiTableLarge4",
      "STA.w !Battle_Unk0B24,X")),
    # Battle: the frame decoder.
    ("bankC1/bankC1.asm", "Battle_DrawBattlerFrameAnyLayout",
     ("LDA.l !BattleRom_FrameBytes,X", "JSR Battle_Mul8x16", "LDA.w !Battler_FramesPtr,X",
      "ADC.b !Battle_MulProduct", "LDA.w !Battler_TileGfxPtr,X", "LDA.l BattleRom_FrameLayout.Width,X",
      "LDA.l BattleRom_FrameLayout.Height,X", "LDA.l !BattleRom_FrameDestBase,X", "ADC.b [!BattleFrame_RowPtr]",
      "LDA.b [!BattleFrame_MapPtr]", "AND.w #!Battle_FrameTileMask", "AND.w #!Battle_FrameHFlip",
      "LDA.l BitReverseTable,X", "LDA.l !BattleRom_FrameExtraCount,X", "LDA.b [!BattleFrame_MapPtr],Y",
      "STA.w !Battler_FrameExtra,X", "LDA.b #!Battle_SignExtendNeg", "STA.w !Battler_FrameExtra+1,X")),
    # Battle: positions = base + the frame's (x, y) words; palette and priority from the battler.
    ("bankCF/bankCF.asm", "BattleCF_DrawBattler",
     ("LDA.w !Battler_Palette-!Battle_SprIdxBias,X", "ORA.w !Battler_ActAttr-!Battle_SprIdxBias,X",
      "LDA.l !BattleRom_LayoutSprites,X", "LDA.w !Battler_FrameExtra,Y", "ADC.b !BattleSpr_BaseX-!BattleSpr_Page",
      "LDA.w !Battler_FrameExtra+2,Y", "ADC.b !BattleSpr_BaseY-!BattleSpr_Page", "LDA.w BattleOam.Tile,X",
      "AND.w #!Battle_OamKeepTileFlip", "ORA.b !BattleSpr_AttrWord-!BattleSpr_Page", "STA.w BattleOam.Tile,X")),
    # Battle: record k's tile/attribute word to OAM entry k.
    ("bankCF/bankCF.asm", "BattleCF_CopySprTiles",
     ("LDA.w BattleSprRec[0].Tile,X", "STA.w BattleSprRec[0].Tile,Y", "LDA.w BattleSprRec[1].Tile,X",
      "STA.w BattleSprRec[1].Tile,Y", "LDA.w BattleSprRec[2].Tile,X", "STA.w BattleSprRec[2].Tile,Y",
      "LDA.w BattleSprRec[3].Tile,X", "STA.w BattleSprRec[3].Tile,Y")),
    # Battle: the animation lists.
    ("bankC1/bankC1.asm", "Battle_TickPcSlots",
     ("LDA.w !Battler_AnimFrameBase,X", "LDA.w !Battler_AnimDurBase,X", "STA.b !Battle_TickFacingOffset",
      "LDA.w !Battler_Facing,X", "LDA.w !Battler_FacingStrideLo,X", "JSR Battle_Mul8x16",
      "LDA.l !BattleRom_AnimData,X", "LDA.b #!Battle_AnimTicksDivisor", "JSR Battle_Divide",
      "STA.w !Pc_AnimTimer,X", "LDA.l !BattleRom_AnimData,X", "STA.w !Battle_FrameId",
      "JSR Battle_DrawBattlerFrame")),
    # Field: the four bank-$E4 bases.
    ("bankC0/bankC0.asm", "Field_InitLoadState",
     ("LDA.l !RomE4_PtrInit", "STA.b !Field_E4Ptr0", "LDA.l !RomE4_PtrInit+2", "STA.b !Field_E4Ptr1",
      "LDA.l !RomE4_PtrInit+4", "STA.b !Field_E4Ptr2", "LDA.l !RomE4_PtrInit+6", "STA.b !Field_E4Ptr3")),
    # Field: a sprite record's five indexes.
    ("bankC0/bankC0.asm", "Evt_LoadSpriteRec",
     ("LDA.l !RomE4_SprRec+!SprRec_Frames,X", "LDA.b [!Field_E4Ptr1],Y", "STA.w !Obj_FrameOfs,X",
      "LDA.l !RomE4_SprRec+!SprRec_Pal,X", "LDA.b #!Pal_ObjColorBytes", "STA.w !Obj_PalSrc,X",
      "LDA.l !RomE4_SprRec+!SprRec_Anim,X", "LDA.b [!Field_E4Ptr2],Y", "SBC.b [!Field_E4Ptr2],Y",
      "STA.w !Obj_AnimFacingStride,X", "LDA.b [!Field_E4Ptr3],Y", "STA.w !Obj_AnimTimeTbl,X",
      "LDA.l !RomE4_SprRec+!SprRec_Size,X", "LDA.l !RomE4_SprRec+!SprRec_Gfx,X", "LDA.b [!Field_E4Ptr0],Y",
      "STA.w !Obj_GfxOfs,X")),
    # Field: the 4-OBJ frame builder.
    ("bankC0/bankC0.asm", "Obj_BuildFrame4",
     ("LDA.b #!Frame4_Bytes", "ADC.w !Obj_FrameOfs,X", "BIT.w #!SprFrame_HFlip", "JSR Spr_CopyTile",
      "JSR Spr_CopyTileFlipped", "ADC.w #!Vram_TileRowWords", "STA.w !VramQ_DestB,X",
      "ADC.w #!Gfx_8TilesBytes", "STA.w !VramQ_SrcB,X", "LDY.w #!Frame_TileWordBytes*16",
      "LDA.b [!Spr_FramePtr],Y", "STA.l SprTileSrc.OfsX,X", "STA.l SprTileSrc.OfsY,X",
      "LDA.w !Obj_VramTile,Y", "STA.l SprTileSrc.Tile,X", "STA.l SprTileSrc[1].Tile,X",
      "STA.l SprTileSrc[2].Tile,X", "STA.l SprTileSrc[3].Tile,X")),
    ("bankC0/bankC0.asm", "Spr_CopyTile", ("AND.w #!SprFrame_TileMask",)),
    ("bankC0/bankC0.asm", "Spr_CopyTileFlipped", ("AND.w #!SprFrame_TileMask", "LDA.w BitReverseTable,X")),
    # Field: frame id = table + facing * stride + row * 4 + column.
    ("bankC0/bankC0.asm", "Obj_AnimFrameLookup",
     ("LDA.w !Obj_AnimFacingStride,X", "ADC.w !Obj_AnimFrameTbl,X", "LDA.w !Obj_AnimColumn,X",
      "LDA.w !Obj_AnimRow,X", "ADC.b !Anim_Column", "ADC.b !Anim_FramePtr", "LDA.b [!Anim_FramePtr]")),
    ("bankC0/bankC0.asm", "Obj_AnimTickAndQueue", ("ADC.w !Obj_AnimTimeTbl,X",)),
    # Field: 12 colours from bank $E4 at Obj_PalSrc into colours 1-12 of the palette row.
    ("bankC0/bankC0.asm", "Obj_PalSlotFixed",
     ("LDA.w !Obj_PalSrc,X", "LDA.w #!ObjPal_CopyCount", "MVN !Bank7E,!BankE4")),
    # Field: OBSEL 0 (8x8 and 16x16 OBJs, tiles at VRAM word 0) on a location load.
    ("bankFD/bankFD.asm", "Ppu_SetBgLayout", ("LDA.b #$00", "STA.b OBSEL-!DP_PPU")),
)

# Constants the claims above rely on: (file under asm/, exact definition prefix).
CONSTANT_CLAIMS = (
    ("include/constants_battle.inc", "!Battle_FrameTileMask    = $07FF"),
    ("include/constants_battle.inc", "!Battle_FrameHFlip       = $4000"),
    ("include/constants_battle.inc", "!Battle_AnimTicksDivisor = 5"),
    ("include/constants_battle.inc", "!Battle_HiTableLarge4     = $AA"),
    ("include/constants_battle.inc", "!Battle_OamKeepTileFlip   = $C1FF"),
    ("include/constants_battle.inc", "!Battler_SprBytesPc       = $0F"),
    ("include/constants_engine.inc", "!SprFrame_TileMask = $07FF"),
    ("include/constants_engine.inc", "!SprFrame_HFlip = $4000"),
    ("include/constants_engine.inc", "!Frame4_Bytes = $28"),
    ("include/constants_engine.inc", "!Vram_TileRowWords = $0100"),
    ("include/constants_engine.inc", "!RomE4_SprRec = $E4F000"),
    ("include/constants_engine.inc", "!Pal_ObjColorBytes = $18"),
    ("include/constants_engine.inc", "!EvtChar_VramTile0 = $0008"),
    ("include/constants_engine.inc", "!Obj_FacingUp = $00"),
    ("include/constants_engine.inc", "!Obj_FacingRight = $03"),
)


def asm_claims(ref=REF):
    """Each ASM_CLAIMS routine holds its lines in order, and each constant is
    defined as stated: [(name, ok, detail)]."""
    out = []
    sources = {}
    for path, label, lines in ASM_CLAIMS:
        text = sources.setdefault(path, (ref / "asm" / path).read_text().splitlines())
        try:
            start = next(i for i, line in enumerate(text) if line.split(";")[0].strip() == f"{label}:")
        except StopIteration:
            out.append((f"{path} {label}", False, "label not found"))
            continue
        end = next((i for i in range(start + 1, len(text))
                    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", text[i])), len(text))
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


# --- Evidence: the ROM's code bytes ----------------------------------------------------

def _body(rom, start, end):
    return bytes(rom[pc(start):pc(end) + 1])


def code_claims(rom):
    """Operands of the readers, from the ROM's own code bytes."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    decoder = _body(rom, 0xC11C55, 0xC11F78)
    claim("$C1:1C55 reads BattleRom_FrameBytes, FrameLayout, FrameDestBase, FrameExtraCount (LDA.l $CCxxxx,X)",
          all(p in decoder for p in (b"\xbf\x0a\xf4\xcc", b"\xbf\xc2\xf3\xcc", b"\xbf\xc3\xf3\xcc",
                                     b"\xbf\x41\xf9\xcc", b"\xbf\xfc\xf4\xcc")))
    claim("$C1:1C55 masks the tile word with AND #$07FF and tests AND #$4000",
          b"\x29\xff\x07" in decoder and b"\x29\x00\x40" in decoder)
    claim("$C1:1C55 mirrors through BitReverseTable (LDA.l $C0FD00,X)", b"\xbf\x00\xfd\xc0" in decoder)
    claim("$C1:1C55 sign-extends with $FF", b"\xa9\xff" in decoder)
    placer = _body(rom, 0xCFEAC5, 0xCFEB93)
    claim("$CF:EAC5 keeps flips, name bit and tile (AND #$C1FF) and reads LayoutSprites (LDA.l $CCF50A,X)",
          b"\x29\xff\xc1" in placer and b"\xbf\x0a\xf5\xcc" in placer)
    setup = _body(rom, 0xCCE000, 0xCCED86)
    claim("$CC:E000 reads $E4:2000, $E4:2300, $E4:2600 and $E4:2800 (LDA.l $E4xxxx,X)",
          all(p in setup for p in (b"\xbf\x00\x20\xe4", b"\xbf\x00\x23\xe4", b"\xbf\x00\x26\xe4", b"\xbf\x00\x28\xe4")))
    claim("$CC:E000 gives a PC $0F sprite bytes (LDA #$0F; STA $1D7F,Y)", b"\xa9\x0f\x99\x7f\x1d" in setup)
    ticker = _body(rom, 0xC12D9F, 0xC12F1E)
    claim("$C1:2D9F reads bank $E4 lists (LDA.l $E40000,X) and divides durations by 5 (LDA #$05)",
          ticker.count(b"\xbf\x00\x00\xe4") == 2 and b"\xa9\x05" in ticker)
    build4 = _body(rom, 0xC0CBDC, 0xC0CDC7)
    claim("$C0:CBDC multiplies the frame by 40 (LDA #$28; STA WRMPYB) and tests BIT #$4000",
          b"\xa9\x28\x8d\x03\x42" in build4 and b"\x89\x00\x40" in build4)
    claim("$C0:CBDC queues the second row at +$100 VRAM words (ADC #$0100)", b"\x69\x00\x01" in build4)
    for start, end, name in ((0xC0E687, 0xC0E6C0, "Spr_CopyTile"), (0xC0E534, 0xC0E560, "Spr_CopyTileFlipped")):
        claim(f"${start >> 16:02X}:{start & 0xFFFF:04X} {name} masks with AND #$07FF", b"\x29\xff\x07" in _body(rom, start, end))
    layout = _body(rom, 0xFDC0D7, 0xFDC123)
    claim("$FD:C0D7 writes OBSEL 0 (LDA #$00; STA $01 with D = $2100)", b"\xa9\x00\x85\x01" in layout)
    return out


# --- Evidence: the ROM's data ------------------------------------------------------------

def coherence(tile_bytes, interleaved):
    """Share of vertically adjacent pixel pairs (not both 0) with the same index."""
    same = total = 0
    for raw in tile_bytes:
        if interleaved:
            px = tile_indices(raw)
        else:
            px = [sum((raw[8 * p + r] >> (7 - x) & 1) << p for p in range(4)) for r in range(8) for x in range(8)]
        for i in range(56):
            a, b = px[i], px[i + 8]
            if a or b:
                total += 1
                same += a == b
    return same / max(total, 1)


def mirror_pairs(rom, c, decoded=None, tile_bytes=None):
    """(about x = 0, up to a shift, compared): the first column of every
    row's left and right facings whose composed frames are mirror images, with
    the axis at x = 0 (pixel x <-> -1 - x) and with any vertical axis."""
    decoded = decoded or decode_set(rom, c)
    tile_bytes = tile_bytes or tiles(rom, c)
    frames = decoded["frameList"]
    rows = decoded["animations"]["rows"]
    at = ANIM_BANK + u16(rom, ANIM_FRAMES + 2 * c)
    exact = good = total = 0
    for r in range(rows):
        left, right = u8(rom, at + 2 * rows * 4 + r * 4), u8(rom, at + 3 * rows * 4 + r * 4)
        if left == right or max(left, right) >= len(frames):
            continue
        a, b = compose(frames[left], tile_bytes), compose(frames[right], tile_bytes)
        if not a or not b:
            continue
        total += 1
        exact += {(-1 - x, y): v for (x, y), v in a.items()} == b
        axis = min(x for x, _ in b) + max(x for x, _ in a)
        good += {(axis - x, y): v for (x, y), v in a.items()} == b
    return exact, good, total


def data_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    init = [u16(rom, PTR_INIT + 2 * i) for i in range(4)]
    claim("RomE4_PtrInit gives the field the battle's four tables ($2000, $2300, $2600, $2800)",
          init == [0x2000, 0x2300, 0x2600, 0x2800], str([hex(v) for v in init]))
    recs = [list(rom[pc(SPR_REC + SPR_REC_BYTES * c):pc(SPR_REC + SPR_REC_BYTES * (c + 1))]) for c in range(SETS)]
    claim("RomE4_SprRec records 0-6 are (c, c, c, c, 0): the field loads set c with size class 0 (4 OBJs)",
          recs == [[c, c, c, c, 0] for c in range(SETS)], str(recs))
    lay = [u16(rom, FRAME_LAYOUT + 2 * i) for i in range(6)] + [u8(rom, FRAME_LAYOUT + 12), u8(rom, FRAME_LAYOUT + 13)]
    claim("BattleRom_FrameLayout[0]: 8 x 2 cells, rows at buffer offsets 0 and $200",
          lay[6:] == [COLUMNS, ROWS] and lay[:2] == [0, 0x200], str(lay))
    claim("BattleRom_FrameBytes[0] = 40 = 16 words + 8 bytes; FrameExtraCount[0] = 8",
          u16(rom, FRAME_BYTES_TBL) == FRAME_BYTES and u8(rom, FRAME_EXTRA_COUNT) == 2 * PIECES)
    claim("BattleRom_LayoutSprites[0] = 4 OBJs", u8(rom, LAYOUT_SPRITES) == PIECES)
    slots_ok, detail = True, []
    for s in range(PC_SLOTS):
        words = [u16(rom, SPR_REC_INIT + 2 * (4 * s + n)) for n in range(PIECES)]
        base = words[0] & 0xFF
        attr = words[0] >> 8
        vram_a, vram_b = u16(rom, DMA_VRAM_A + 2 * s), u16(rom, DMA_VRAM_B + 2 * s)
        dest = u16(rom, FRAME_DEST_BASE + 2 * s)
        ok = (all(w & 0xFF == base + 2 * n and w >> 8 == attr for n, w in enumerate(words))
              and vram_a == base * 16 and vram_b == (base + VRAM_ROW) * 16
              and u16(rom, DMA_SRC_A + 2 * s) == dest and u16(rom, DMA_SRC_B + 2 * s) == dest + 0x200
              and attr == 0x20 | (5 + s) << 1)
        slots_ok &= ok
        detail.append(f"slot {s}: tiles {base}+2n, attr ${attr:02X}, VRAM ${vram_a:04X}/${vram_b:04X}")
    claim("PC slots 0-2: OBJ n has tile T+2n (T = 8, 32, 40), palette 5-7, priority 2; row 0 is DMAed to "
          "tile T and row 1 to T+16 (the lower halves of 16x16 OBJs)", slots_ok, "; ".join(detail))
    claim("the PC slots' DMA moves 8 tiles per row (FrameDmaSizeA/B[0] = $100)",
          u16(rom, DMA_SIZE_A) == 0x100 and u16(rom, DMA_SIZE_B) == 0x100)
    claim("PC slot 0's first OBJ tile is the field leader's (8)", u16(rom, SPR_REC_INIT) & 0xFF == SLOT_TILE)

    tile_tbl, frame_tbl = table(rom, TILES_PTR, 3), table(rom, FRAMES_PTR, 3)
    af = [u16(rom, ANIM_FRAMES + 2 * i) for i in range(SETS + 1)]
    ad = [u16(rom, ANIM_DURS + 2 * i) for i in range(SETS + 1)]
    for c in range(SETS):
        d = decode_set(rom, c)
        frames, anims = d["frameList"], d["animationList"]
        tb = tiles(rom, c)
        words = [w for f in frames for w in f["cells"]]
        top = max(w & TILE_MASK for w in words)
        rows = d["animations"]["rows"]
        used = {i for a in anims for i in a["frames"]}
        name = f"set {c} ({NAMES[c]})"
        claim(f"{name}: its tile block ends at the highest tile its frames use (+1): "
              f"{d['tiles']['count']} tiles", top + 1 == d["tiles"]["count"], f"highest {top}")
        claim(f"{name}: tile 0 is blank (the battle's blank-cell rule = the field's plain copy)", not any(tb[0]))
        claim(f"{name}: tile words use only bits 0-10, 14 and 15 (bits 11-13 never set)",
              all(w & 0x3800 == 0 for w in words), f"bit 15 in {sum(1 for w in words if w & 0x8000)} cells")
        span = (block_end(frame_tbl, u24(rom, FRAMES_PTR + 3 * c)) - u24(rom, FRAMES_PTR + 3 * c)) // FRAME_BYTES
        empty = rows * 4 - len(anims)
        claim(f"{name}: {len(frames)} frames; the {len(anims)} non-empty animations use ids below that",
              used and max(used) < len(frames), f"highest {max(used)}, block {span} records")
        marker = [r for r in range(rows) if all(u8(rom, ANIM_BANK + af[c] + f * 4 * rows + 4 * r) == END_MARKER
                                                 and u8(rom, ANIM_BANK + ad[c] + 4 * r) for f in range(4))]
        zero = [r for r in range(rows) if u8(rom, ANIM_BANK + ad[c] + 4 * r) == 0]
        claim(f"{name}: the {empty} empty (row, facing) lists are rows starting with duration 0 or the $FF "
              "marker in all four facings", empty == 4 * (len(zero) + len(marker)),
              f"duration 0: rows {zero}; $FF: rows {marker}")
        claim(f"{name}: frame-id block = 4 facings x {rows} rows of 4 (AnimFrames[c+1] - AnimFrames[c] = 16 x rows)",
              af[c + 1] - af[c] == 16 * rows)
        claim(f"{name}: its {rows} duration rows end at or before the next set's",
              ad[c] + 4 * rows <= ad[c + 1], f"${ad[c]:04X} + {4 * rows} <= ${ad[c + 1]:04X}")
        pal = palette(rom, c)
        claim(f"{name}: palette {u8(rom, SPR_REC + SPR_REC_BYTES * c + 2)} at "
              f"{d['palette']['address']}: 12 BGR555 colours (bit 15 clear)", all(w < 0x8000 for w in pal))
        exact, good, total = mirror_pairs(rom, c, d, tb)
        claim(f"{name}: the left and right facings' first frames are mirror images in {good} of {total} rows "
              "(at least 80%)", total and good >= 0.8 * total,
              f"{exact} about x = 0; composed as 4 16x16 OBJs of cells (0,2n) (0,2n+1) (1,2n) (1,2n+1)")
    crono = tiles(rom, 0)[1:]
    a, b = coherence(crono, True), coherence(crono, False)
    claim("SNES planar layout (planes 0/1 interleaved per row): set 0's tiles are coherent "
          f"({a:.3f} vertical same-colour rate) where the plane-after-plane reading is not ({b:.3f})",
          a > 2 * b, "fullsnes; PPUFrame.storeTiles; ct_gfx.py")
    claim("the frame pointer table has no pointer inside a PC frame block other than its start",
          all(not any(u24(rom, FRAMES_PTR + 3 * c) < p < u24(rom, FRAMES_PTR + 3 * c) + FRAME_BYTES * frame_count(rom, c)
                      for p in frame_tbl) for c in range(SETS)))
    claim("the tile pointer table has no pointer inside a PC tile block other than its start",
          all(not any(u24(rom, TILES_PTR + 3 * c) < p < u24(rom, TILES_PTR + 3 * c) + TILE_BYTES * tile_count(rom, c)
                      for p in tile_tbl) for c in range(SETS)))
    return out


# --- Evidence: the ROM's frame decoder, run ---------------------------------------------------

class RomFrameDecoder:
    """Battle_DrawBattlerFrameAnyLayout ($C1:1C55) run by ChronoRET's 65816
    interpreter (refs/ChronoRET/tools/absint.py) over the ROM, for one PC slot
    with frame layout 0. The interpreter has no hardware multiplier, so this
    subclass gives it one (fullsnes: writing WRMPYB $4203 multiplies it by
    WRMPYA $4202, unsigned, into RDMPYL/H $4216/$4217; the routine reads the
    product after the documented 8 cycles)."""

    ENTRY = 0xC11C55
    FRAME_SLOT, FRAME_ID = 0x7E9679, 0x7E967B
    FRAME_LAYOUT, FRAME_SHOWN, FRAMES_DECODED, FRAME_DEFERRED = 0x7E967C, 0x7E9907, 0x7E9912, 0x7E9922
    TILE_PTR, FRAMES_PTR_RAM, FRAME_EXTRA = 0x7E1C57, 0x7E1C78, 0x7E9F47

    def __init__(self, rom, ref=REF):
        if str(ref / "tools") not in sys.path:
            sys.path.insert(0, str(ref / "tools"))
        import absint
        self.absint = absint

        class Multiplier(absint.Machine):
            def write8(self, s, addr, v):
                super().write8(s, addr, v)
                if addr is not None and addr & 0xFFFFFF == 0x004203:
                    a = s.mem.get(0x004202)
                    p = None if a is None or v is None else a * v
                    s.mem[0x004216] = None if p is None else p & 0xFF
                    s.mem[0x004217] = None if p is None else p >> 8

        self.rom = rom
        self.machine = Multiplier(bytes(rom), bytearray(b"\x01") * len(rom), max_steps=10 ** 6, callee_steps=10 ** 5)
        self.machine.widen_after = 10 ** 9

    def decode(self, slot, tiles_at, frames_at, frame):
        """(tile buffer rows as bytes, the 8 extra words as bytes) after a decode."""
        absint = self.absint
        known = {a: 0 for a in range(0x7E0000, 0x7E0100)}                  # direct page
        for addr, value in ((self.FRAME_SLOT, slot), (self.FRAME_ID, frame), (self.FRAMES_DECODED, 0)):
            known[addr] = value
        known[self.FRAME_SLOT + 1] = 0                                      # LDX.w reads the slot as a word
        known[self.FRAME_LAYOUT + slot] = 0
        known[self.FRAME_SHOWN + slot] = (frame + 1) & 0xFF
        known[self.FRAME_DEFERRED + slot] = 1
        for i in range(3):
            known[self.TILE_PTR + 3 * slot + i] = tiles_at >> 8 * i & 0xFF
            known[self.FRAMES_PTR_RAM + 3 * slot + i] = frames_at >> 8 * i & 0xFF
        s = absint.State()
        s.pc, s.a, s.b, s.x, s.y = self.ENTRY, 0, 0, 0, 0
        s.d, s.db, s.m, s.xf, s.c = 0, 0x7E, True, False, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != "rts" or self.machine.opaque:
            raise RuntimeError(f"{[how for _, how in ends]} opaque {self.machine.opaque}")
        mem = {**known, **ends[0][0].mem}
        dest = 0x7E0000 | u16(self.rom, FRAME_DEST_BASE + 2 * slot)
        rows = []
        for r in range(ROWS):
            at = dest + u16(self.rom, FRAME_LAYOUT + 2 * r)
            rows.append(bytes(mem.get(at + i) if mem.get(at + i) is not None else 0x100 for i in range(COLUMNS * TILE_BYTES)))
        extra = bytes(mem[self.FRAME_EXTRA + 16 * slot + i] for i in range(4 * PIECES))
        if self.FRAMES_DECODED not in mem or mem[self.FRAMES_DECODED] != 1:
            raise RuntimeError("the decode was not counted")
        return rows, extra


BIT_REVERSE = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))


def expected_buffer(frame, tile_bytes):
    """What the decoder should leave: per row the cells' 32 bytes (zeros for
    tile 0, bytes bit-reversed for bit 14), and the pairs sign-extended."""
    rows = []
    for r in range(ROWS):
        row = b""
        for c in range(COLUMNS):
            w = frame["cells"][r * COLUMNS + c]
            t = w & TILE_MASK
            raw = bytes(TILE_BYTES) if t == 0 else tile_bytes[t]
            row += bytes(BIT_REVERSE[b] for b in raw) if w & HFLIP else raw
        rows.append(row)
    extra = b"".join(struct.pack("<hh", x, y) for x, y in frame["pieces"])
    return rows, extra


def run_claims(rom, sets=range(SETS), ref=REF):
    """The ROM's decoder against `decode_frame` + the tile bytes, for every
    frame of each set (in PC slot 0; Crono's frame 0 also in slot 1)."""
    runner = RomFrameDecoder(rom, ref)
    out = []
    for c in sets:
        d = decode_set(rom, c)
        tb = tiles(rom, c)
        frames = d["frameList"]
        bad = [i for i in range(len(frames))
               if runner.decode(0, u24(rom, TILES_PTR + 3 * c), u24(rom, FRAMES_PTR + 3 * c), i)
               != expected_buffer(frames[i], tb)]
        if c == 0 and runner.decode(1, u24(rom, TILES_PTR), u24(rom, FRAMES_PTR), 0) != expected_buffer(frames[0], tb):
            bad.append("slot 1")
        mirrored = sum(1 for f in frames if any(w & HFLIP for w in f["cells"]))
        out.append((f"set {c} ({NAMES[c]}): the ROM's frame decoder ($C1:1C55, run) = decode_frame + tiles "
                    f"for all {len(frames)} frames ({mirrored} with mirrored cells)", not bad,
                    f"differs at {bad[:5]}" if bad else ""))
    return out


# --- Synthetic vectors for the Swift twin ------------------------------------------------

class Lcg:
    """Deterministic numbers (no ROM data)."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self, n):
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.state >> 8) % n


VECTORS = WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "sprites" / "sprite_vectors.json"


def synthetic_rom():
    """Sparse ROM regions (address -> bytes) holding two synthetic sets in the
    real tables' places, and the expected decode of each. No ROM data."""
    rng = Lcg(0x5C7E)
    regions = {}

    def put(long, data):
        regions[long] = bytes(data)

    tiles_at = (0xD20000, 0xD20000 + 32 * 40)        # set 0: 40 tiles, set 1 right after: 24 tiles
    ntiles = (40, 24)
    frames_at = (0xDC0000, 0xDC0000 + 40 * 12)       # set 0: 12 frames, set 1: 9 frames then a zero record
    nframes = (12, 9)
    rows = (5, 3)
    af = (0x3000, 0x3000 + 16 * rows[0], 0x3000 + 16 * (rows[0] + rows[1]))
    ad = (0xA800, 0xA800 + 4 * rows[0], 0xA800 + 4 * (rows[0] + rows[1]) + 8)
    tile_ptrs = list(tiles_at) + [tiles_at[1] + 32 * ntiles[1]]
    frame_ptrs = list(frames_at) + [frames_at[1] + 40 * (nframes[1] + 1)]
    put(TILES_PTR, b"".join(p.to_bytes(3, "little") for p in tile_ptrs))
    put(FRAMES_PTR, b"".join(p.to_bytes(3, "little") for p in frame_ptrs))
    put(ANIM_FRAMES, b"".join(v.to_bytes(2, "little") for v in af))
    put(ANIM_DURS, b"".join(v.to_bytes(2, "little") for v in ad))
    put(SPR_REC, bytes([0, 0, 0, 0, 0, 1, 1, 2, 1, 0]))   # set 1 uses palette 2
    pal = [rng.next(0x8000) for _ in range(3 * PAL_COLOURS)]
    put(ANIM_BANK, b"".join(w.to_bytes(2, "little") for w in pal))
    expect = []
    for c in range(2):
        tile_data = bytes(32) + bytes(rng.next(256) if rng.next(3) else 0 for _ in range(32 * (ntiles[c] - 1)))
        put(tiles_at[c], tile_data)
        recs = b""
        for f in range(nframes[c]):
            words = []
            for k in range(CELLS):
                t = rng.next(ntiles[c]) if rng.next(5) else 0
                words.append(t | (HFLIP if rng.next(3) == 0 else 0) | (0x8000 if rng.next(9) == 0 else 0))
            if f == nframes[c] - 1:
                words[0] = ntiles[c] - 1                     # the highest tile is used
            pairs = [(rng.next(48) - 32) & 0xFF for _ in range(2 * PIECES)]
            recs += b"".join(w.to_bytes(2, "little") for w in words) + bytes(pairs)
        if c == 1:
            recs += bytes(FRAME_BYTES)                       # trailing zero record: trimmed
        put(frames_at[c], recs)
        ids, durs = [], []
        for f in range(4):
            ids += [rng.next(nframes[c]) for _ in range(4 * rows[c])]
        for r in range(rows[c]):
            n = 1 + rng.next(5)                              # 1-4 entries, 5 = runs into the next row
            durs += [1 + rng.next(30) if k < n else 0 for k in range(4)]
        durs[-1] = 0
        if c == 0:
            for f in range(4):
                ids[f * 4 * rows[c] + 4] = END_MARKER          # row 1: the $FF marker in every facing
            ids[2 * 4 * rows[c] + 8 + 1] = END_MARKER          # row 2, left: ends after one frame
        else:
            durs[8] = 0                                        # row 2 starts with duration 0: empty
        put(ANIM_BANK + af[c], ids)
        put(ANIM_BANK + ad[c], durs)
    image = bytearray(ROM_SIZE)
    for long, data in regions.items():
        image[pc(long):pc(long) + len(data)] = data
    for c in range(2):
        d = decode_set(bytes(image), c)
        tb = tiles(bytes(image), c)
        composed = []
        for f in (0, len(d["frameList"]) - 1):
            img = compose(d["frameList"][f], tb)
            xs, ys = [x for x, _ in img], [y for _, y in img]
            left, top = min(xs), min(ys)
            w, h = max(xs) - left + 1, max(ys) - top + 1
            px = bytes(img.get((left + i % w, top + i // w), 0) for i in range(w * h))
            composed.append({"frame": f, "left": left, "top": top, "width": w, "height": h, "indices": px.hex()})
        d.pop("name")
        d["composed"] = composed
        d["tileIndices"] = bytes(i for t in tb for i in tile_indices(t)).hex()
        expect.append(d)
    return regions, expect


def vectors_text():
    regions, expect = synthetic_rom()
    head = {"schema": "ct-sprite-vectors/1",
            "note": "synthetic sets in the real tables' places (no ROM data); expected decode by "
                    "re_workspace/tools/ct_sprites.py",
            "regions": [{"at": snes(k), "hex": v.hex()} for k, v in sorted(regions.items())]}
    sets = []
    for d in expect:
        frames = ",\n".join("    " + json.dumps(f, separators=(",", ":")) for f in d.pop("frameList"))
        anims = ",\n".join("    " + json.dumps(a, separators=(",", ":")) for a in d.pop("animationList"))
        body = ",\n".join(f'   "{k}": {json.dumps(v, separators=(",", ":"))}' for k, v in d.items())
        sets.append(f'  {{\n{body},\n   "frameList": [\n{frames}],\n   "animationList": [\n{anims}]}}')
    text = "{\n" + ",\n".join(f' "{k}": {json.dumps(v, separators=(",", ":"))}' for k, v in head.items())
    return text + ',\n "sets": [\n' + ",\n".join(sets) + "]}\n"


# --- Output helpers ----------------------------------------------------------------------

def bgr555_rgb(w):
    return tuple(((w >> s & 31) << 3) | ((w >> s & 31) >> 2) for s in (0, 5, 10))


def write_png_rgba(path, width, height, rgba):
    raw = b"".join(b"\x00" + bytes(rgba[4 * width * y:4 * width * (y + 1)]) for y in range(height))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def render(rom, c, frame, out, scale=4):
    d = decode_set(rom, c)
    img = compose(d["frameList"][frame], tiles(rom, c))
    colours = [0] + palette(rom, c) + [0, 0, 0]
    xs, ys = [x for x, _ in img] or [0], [y for _, y in img] or [0]
    left, top = min(xs + [0]), min(ys + [0])
    w, h = max(xs + [0]) - left + 1, max(ys + [0]) - top + 1
    rgba = bytearray(4 * w * h * scale * scale)
    for y in range(h * scale):
        for x in range(w * scale):
            v = img.get((left + x // scale, top + y // scale), 0)
            if v:
                rgba[4 * (y * w * scale + x):4 * (y * w * scale + x) + 4] = bytes(bgr555_rgb(colours[v])) + b"\xff"
    write_png_rgba(out, w * scale, h * scale, rgba)
    return w, h, left, top


def verify_import(rom, project, sets=range(SETS)):
    """A Studio import (sprites/<name>.sprite.json and its sheet) against the
    decode: [(name, ok, detail)]."""
    from PIL import Image
    out = []
    for c in sets:
        name = NAMES[c]
        path = Path(project) / "sprites" / f"{name}.sprite.json"
        if not path.exists():
            out.append((f"{name}: imported", False, f"{path} missing"))
            continue
        s = json.loads(path.read_text())
        d = decode_set(rom, c)
        frames_ok = (len(s["frames"]) == d["frames"]["count"]
                     and all(f["cells"] == g["cells"]
                             and [[t["x"], t["y"]] for t in f["tiles"]] == g["pieces"]
                             and [t["tile"] for t in f["tiles"]] == [2 * n for n in range(PIECES)]
                             and all(t["size16"] and not t["hflip"] and not t["vflip"] for t in f["tiles"])
                             for f, g in zip(s["frames"], d["frameList"])))
        out.append((f"{name}: {d['frames']['count']} frames, cells and OBJ offsets as decoded", frames_ok))
        anims_ok = [{k: a[k] for k in ("id", "row", "facing", "frames", "durations")} for a in s["animations"]] == \
            d["animationList"]
        out.append((f"{name}: {len(d['animationList'])} animations as decoded", anims_ok))
        pal = [int(w, 16) for w in s["palettes"][0]]
        out.append((f"{name}: palette = 0 + the 12 ROM colours + 3 zeros",
                    pal == [0] + palette(rom, c) + [0, 0, 0], str(s["palettes"][0][:3])))
        stream = s.get("stream") or {}
        out.append((f"{name}: streamed 8 x 2 cells at VRAM tile 8",
                    (stream.get("columns"), stream.get("rows"), stream.get("baseTile")) == (COLUMNS, ROWS, SLOT_TILE)))
        sheet = Image.open(Path(project) / s["sheet"])
        tb = tiles(rom, c)
        cols = sheet.width // 8
        px = sheet.load()
        sheet_ok = sheet.mode == "P" and sheet.width == 128 and all(
            [px[(t % cols) * 8 + i % 8, (t // cols) * 8 + i // 8] for i in range(64)] == tile_indices(tb[t])
            for t in range(len(tb)))
        out.append((f"{name}: sheet holds the {len(tb)} tiles, 16 per row", sheet_ok, f"{sheet.mode} {sheet.size}"))
    return out


# --- CLI ------------------------------------------------------------------------------------------

def read_rom(path):
    data = Path(path).read_bytes()
    if len(data) == ROM_SIZE + 512:
        data = data[512:]
    if len(data) != ROM_SIZE:
        raise SystemExit("expected a 4 MiB Chrono Trigger ROM")
    return data


def report(claims):
    bad = [c for c in claims if not c[1]]
    for name, ok, *detail in claims:
        extra = f"  ({detail[0]})" if detail and detail[0] else ""
        print(f"{'ok  ' if ok else 'FAIL'} {name}{extra}")
    print(f"{len(claims) - len(bad)} of {len(claims)} claims hold")
    return 1 if bad else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    d = sub.add_parser("decode")
    d.add_argument("set", type=int, choices=range(SETS))
    d.add_argument("--rom", default=str(ROM_PATH))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(ROM_PATH))
    k.add_argument("--run", action="store_true", help="also run the ROM's frame decoder on every frame")
    r = sub.add_parser("render")
    r.add_argument("set", type=int, choices=range(SETS))
    r.add_argument("frame", type=int)
    r.add_argument("--out", required=True)
    r.add_argument("--rom", default=str(ROM_PATH))
    v = sub.add_parser("verify-import")
    v.add_argument("project")
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
    rom = read_rom(args.rom)
    if args.command == "decode":
        print(json.dumps(decode_set(rom, args.set), indent=1))
        return 0
    if args.command == "render":
        w, h, left, top = render(rom, args.set, args.frame, args.out)
        print(f"wrote {args.out}: {w} x {h} pixels, origin at ({-left}, {-top})")
        return 0
    if args.command == "verify-import":
        return report(verify_import(rom, args.project))
    claims = asm_claims() + code_claims(rom) + data_claims(rom)
    if args.run:
        claims += run_claims(rom)
    return report(claims)


if __name__ == "__main__":
    sys.exit(main())
