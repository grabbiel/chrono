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
    ct_sprites.py decode-enemy <id> [--rom PATH]          an enemy record's sprite as JSON (no tile bytes)
    ct_sprites.py check [--rom PATH] [--run]              every evidence claim (exit 1 on a failure);
                                                          --run also executes the ROM's frame decoder
                                                          (and, for enemies, Decomp_ToWram)
    ct_sprites.py render <set> <frame> --out P [--rom]    a frame composed from its cells (PNG)
    ct_sprites.py verify-import <project> [--rom PATH] [--pc-only]
                                                    a Studio import (sprites/<name>.*, sprites/enemy_NNN.*) against decode
    ct_sprites.py vectors (--out | --check) P             synthetic vectors for the Swift twin
    ct_sprites.py enemy-vectors (--out | --check) P       the same for enemy sprites
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


def asm_claims(ref=REF, routines=None, constants=None):
    """Each ASM_CLAIMS routine holds its lines in order, and each constant is
    defined as stated: [(name, ok, detail)]."""
    out = []
    sources = {}
    for path, label, lines in ASM_CLAIMS if routines is None else routines:
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
    for path, prefix in CONSTANT_CLAIMS if constants is None else constants:
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

    def decode(self, slot, tiles_at, frames_at, frame, layout=0, extra_known=None):
        """(tile buffer rows as bytes, the OBJ offset words as bytes) after a
        decode; `extra_known` gives memory such as unpacked tiles in WRAM."""
        absint = self.absint
        known = {a: 0 for a in range(0x7E0000, 0x7E0100)}                  # direct page
        for addr, value in ((self.FRAME_SLOT, slot), (self.FRAME_ID, frame), (self.FRAMES_DECODED, 0)):
            known[addr] = value
        known[self.FRAME_SLOT + 1] = 0                                      # LDX.w reads the slot as a word
        known[self.FRAME_LAYOUT + slot] = layout
        known.update(extra_known or {})
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
        order = 5 if layout == 2 and slot != 3 else layout                 # Battle_FrameLayoutTallAlt
        columns, nrows = u8(self.rom, FRAME_LAYOUT + 14 * order + 12), u8(self.rom, FRAME_LAYOUT + 14 * order + 13)
        rows = []
        for r in range(nrows):
            at = dest + u16(self.rom, FRAME_LAYOUT + 14 * order + 2 * r)
            rows.append(_row(mem.get(at + i) for i in range(columns * TILE_BYTES)))
        objs = u8(self.rom, LAYOUT_SPRITES + 2 * layout)
        extra = bytes(mem[self.FRAME_EXTRA + 16 * slot + i] for i in range(4 * objs))
        if self.FRAMES_DECODED not in mem or mem[self.FRAMES_DECODED] != 1:
            raise RuntimeError("the decode was not counted")
        return rows, extra


BIT_REVERSE = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))


def _row(values):
    """Buffer bytes as `bytes`, or a tuple with None where a byte is unknown
    (a cell reading past the graphics the run was given)."""
    values = tuple(values)
    return tuple(values) if None in values else bytes(values)


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


# --- Enemy sprites ($E4:F600) ------------------------------------------------------------------
#
# RomE4_EnemySprRec $E4:F600 holds 10 bytes per record. The field's event
# opcode $83 (Evt_Op83_InitEnemySprite $C0:46DF) loads record n: +0 graphics,
# +1 frame set, +2 palette, +3 animation set (the first five bytes as a
# RomE4_SprRec record), +4 size class (bits 0-1, Obj_SprSize). Records below
# $F8 (EvtSpr_RomGfxMin) unpack their graphics (Decomp_ToWram) from the
# $E4:2000 pointer to bank $7F; records $F8 and up use the pointer itself.
# FieldBtl_SaveObj keeps the size class, palette and tile pointer in the
# battle's FieldBtlObj record. The battle (Battle_InitScene $CC:E000) takes
# the frame layout (= the size class) and the tiles from there, and reads the
# record of the enemy id for the frame set (+1), the animation set (+3), the
# flags (+4: bits 2, 3, 5, 7), screen offsets (+5, +6), half width (+7),
# height (+8) and move speed / delay (+9 bits 0-2 / 4-7).

ENEMY_SPR = 0xE4F600                  # !RomE4_EnemySprRec = BattleRom_EnemySpr
ENEMY_SPR_BYTES = 10                  # !EvtSpr_EnemyRecBytes
ENEMY_RECORDS = 256
ENEMY_IDS = 255                       # 0-254 ($FF is no enemy)
ROM_GFX_MIN = 0xF8                    # !EvtSpr_RomGfxMin: records from here use ROM graphics as they are
SIZE_MASK = 0x03                      # !ObjSpr_SizeMask: Obj_SprSize bits 0-1, the size class
LAYOUT_TALL, LAYOUT_TALL_ALT = 2, 5   # !Battle_FrameLayoutTall / TallAlt: slot 3 keeps layout 2's row order
ASSEMBLED = (0, 1, 2)                 # frame layouts whose OBJ assembly the battle's tables give
FIRST_ENEMY_SLOT = 3
SPR_IDX_BIAS = 12                     # !Battle_SprIdxBias: sprite index = slot + 12
SPR_TILE_LIST_PTR = 0xCCF84D          # BattleRom_SprTileListPtr: 2 B per sprite index
SPR_REC_RAM = 0x11B0                  # Battle_SprRec: records 4 * slot ... (the tile lists)
LAYOUT_SPR_BYTES = 0xCCF505           # BattleRom_LayoutSprBytes: 1 B per layout
ENEMY_SLOT_TILE = 0x40                # slot 3's first OBJ tile (FrameDmaVramA[3] = $400 words)
# Battle_InitSceneGfx's fixed DMA words for frame layout 2 (VRAM A, VRAM B, size A, size B, source A, source B).
TALL_DMA = {3: (0x0400, 0x0700, 0x0500, 0x0100, 0x6BAD, 0x71AD), "other": (0x0680, 0x0780, 0x0100, 0x0500, 0x70AD, 0x72AD)}


# Frame layouts 0-3 as (columns, rows, record bytes, OBJs): enemy_data_claims
# reads them from BattleRom_FrameLayout / FrameBytes / LayoutSprites.
LAYOUTS = {0: (8, 2, 40, 4), 1: (16, 2, 80, 8), 2: (8, 6, 120, 12), 3: (96, 1, 240, 24)}


def layout_shape(rom, layout):
    """(columns, rows, row offsets, record bytes, OBJs) of a frame layout, from the battle's tables."""
    at = FRAME_LAYOUT + 14 * layout
    offsets = [u16(rom, at + 2 * i) for i in range(6)]
    return (u8(rom, at + 12), u8(rom, at + 13), offsets, u16(rom, FRAME_BYTES_TBL + 2 * layout),
            u8(rom, LAYOUT_SPRITES + 2 * layout))


def enemy_record(rom, i):
    b = rom[pc(ENEMY_SPR + ENEMY_SPR_BYTES * i):pc(ENEMY_SPR + ENEMY_SPR_BYTES * (i + 1))]
    return {"gfx": b[0], "frames": b[1], "palette": b[2], "anim": b[3], "size": b[4] & SIZE_MASK,
            "flags": b[4] & ~SIZE_MASK & 0xFF, "screenOffsetX": b[5], "screenOffsetY": b[6], "halfWidth": b[7],
            "height": b[8], "moveSpeed": b[9] & 7, "moveDelay": b[9] >> 4}


def enemy_piece_cells(n, columns):
    """Cells of OBJ n (16x16) in a frame `columns` wide: OBJs run along row
    pairs, columns / 2 per pair: top-left, top-right, bottom-left, bottom-right."""
    p, q = divmod(n, columns // 2)
    return [2 * p * columns + 2 * q, 2 * p * columns + 2 * q + 1, (2 * p + 1) * columns + 2 * q, (2 * p + 1) * columns + 2 * q + 1]


def decode_enemy_frame(rec, columns, rows, objs):
    cells = [rec[2 * k] | rec[2 * k + 1] << 8 for k in range(columns * rows)]
    at = 2 * columns * rows
    return {"cells": cells, "pieces": [[s8(rec[at + 2 * n]), s8(rec[at + 2 * n + 1])] for n in range(objs)]}


def enemy_frame_count(rom, frame_set, record_bytes):
    """Records up to the next frame block (the PC rule with the layout's record size)."""
    start = u24(rom, FRAMES_PTR + 3 * frame_set)
    n = min(POINTERS, (block_end(table(rom, FRAMES_PTR, 3), start) - start) // record_bytes)
    while n and not any(rom[pc(start + record_bytes * (n - 1)):pc(start + record_bytes * n)]):
        n -= 1
    return n


_UNPACKED = {}


def enemy_tile_bytes(rom, i):
    """(the record's tiles as 32-byte strings, "packed" | "rom"): unpacked from
    the $E4:2000 pointer below $F8 (ct_tilesets.unpack_bytes, ChronoRET's
    Decomp_ToWram format), the block itself from $F8 up."""
    r = enemy_record(rom, i)
    if i >= ROM_GFX_MIN:
        return tiles(rom, r["gfx"]), "rom"
    at = u24(rom, TILES_PTR + 3 * r["gfx"])
    key = (id(rom), at)
    if key not in _UNPACKED:
        import ct_tilesets
        data, _, _ = ct_tilesets.unpack_bytes(rom[pc(at):pc(at) + 0x10000])
        _UNPACKED[key] = [bytes(data[TILE_BYTES * t:TILE_BYTES * (t + 1)]) for t in range(len(data) // TILE_BYTES)]
    return _UNPACKED[key], "packed"


def decode_enemy(rom, i):
    """Enemy record i's sprite: record, layout, graphics, frames, palette and animations (no tile bytes)."""
    r = enemy_record(rom, i)
    columns, rows, record_bytes, objs = LAYOUTS[r["size"]]
    frames_at = u24(rom, FRAMES_PTR + 3 * r["frames"])
    n = enemy_frame_count(rom, r["frames"], record_bytes)
    tb, source = enemy_tile_bytes(rom, i)
    pal = ANIM_BANK + r["palette"] * PAL_BYTES
    return {
        "id": i, "record": r, "layout": {"index": r["size"], "columns": columns, "rows": rows, "objs": objs,
                                        "recordBytes": record_bytes},
        "tiles": {"pointer": snes(u24(rom, TILES_PTR + 3 * r["gfx"])), "source": source, "count": len(tb)},
        "frames": {"address": snes(frames_at), "count": n},
        "palette": {"address": snes(pal), "colours": [f"0x{u16(rom, pal + 2 * k):04X}" for k in range(PAL_COLOURS)]},
        "animations": {"frameIds": snes(ANIM_BANK + u16(rom, ANIM_FRAMES + 2 * r["anim"])),
                       "durations": snes(ANIM_BANK + u16(rom, ANIM_DURS + 2 * r["anim"])), "rows": anim_rows(rom, r["anim"])},
        "frameList": [decode_enemy_frame(rom[pc(frames_at + record_bytes * f):pc(frames_at + record_bytes * (f + 1))],
                                         columns, rows, objs) for f in range(n)],
        "animationList": decode_animations(rom, r["anim"]),
    }


def enemy_palette(rom, i):
    at = ANIM_BANK + enemy_record(rom, i)["palette"] * PAL_BYTES
    return [u16(rom, at + 2 * k) for k in range(PAL_COLOURS)]


ENEMY_ASM_CLAIMS = (
    # Field: event opcode $83 loads a record of the 10-byte table like a RomE4_SprRec record.
    ("bankC0/bankC0.asm", "Evt_Op83_InitEnemySprite",
     ("LDA.b #!EvtSpr_EnemyRecBytes", "STA.w WRMPYB", "LDA.l !RomE4_EnemySprRec+!SprRec_Frames,X",
      "LDA.b [!Field_E4Ptr1],Y", "STA.w !Obj_FrameOfs,X", "LDA.l !RomE4_EnemySprRec+!SprRec_Pal,X",
      "LDA.b #!Pal_ObjColorBytes", "STA.w !Obj_PalSrc,X", "LDA.l !RomE4_EnemySprRec+!SprRec_Anim,X",
      "SBC.b [!Field_E4Ptr2],Y", "STA.w !Obj_AnimFacingStride,X", "LDA.b [!Field_E4Ptr3],Y",
      "STA.w !Obj_AnimTimeTbl,X", "LDA.l !RomE4_EnemySprRec+!SprRec_Size,X", "STA.w !Obj_SprSize,X",
      "LDA.l !RomE4_EnemySprRec+!SprRec_Gfx,X", "CMP.b #!EvtSpr_RomGfxMin", "LDA.b [!Field_E4Ptr0],Y",
      "STA.w !Decomp_Src", "JSL Decomp_ToWramVec", "LDA.b [!Field_E4Ptr0],Y", "STA.w !Obj_GfxOfs,X")),
    # Field: the battle's object record keeps the size class, palette and tile pointer.
    ("bankC0/bankC0.asm", "FieldBtl_SaveObj",
     ("LDA.w !Obj_SprSize,Y", "AND.b #!ObjSpr_SizeMask", "STA.l FieldBtlObj.Flags,X", "LDA.w !Obj_OamAttr,Y",
      "STA.l FieldBtlObj.Attr,X", "LDA.w !Obj_GfxBank,Y", "STA.l FieldBtlObj.GfxBank,X", "LDA.w !Obj_GfxOfs,Y",
      "STA.l FieldBtlObj.GfxOfs,X")),
    # Battle: layout, palette and tiles from the object record; frames, animations and the rest by enemy id.
    ("bankCC/bankCC.asm", "Battle_InitScene",
     ("LDA.w FieldBtlObj.Flags,X", "AND.b #$07", "STA.w !Battler_FrameLayout,Y", "LDA.l !BattleRom_LayoutSprBytes,X",
      "STA.w !Battler_SprBytes,Y", "LDA.w FieldBtlObj.Attr,X", "STA.w !Battler_Palette,Y",
      "LDA.w FieldBtlObj.GfxBank,X", "LDA.w FieldBtlObj.GfxOfs,X", "LDA.w BattleEnemyInit.Id,X",
      "LDA.l BattleRom_EnemySpr.AnimSet,X", "LDA.l BattleRom_EnemySpr.FrameSet,X", "LDA.l !BattleRom_SprFramesPtr,X",
      "LDA.l !BattleRom_SprAnimFrames,X", "LDA.l !BattleRom_SprAnimDurs,X", "LDA.l BattleRom_EnemySpr.Flags,X",
      "LDA.l BattleRom_EnemySpr.OffsetX,X", "LDA.l BattleRom_EnemySpr.OffsetY,X", "LDA.l BattleRom_EnemySpr.HalfWidth,X",
      "LDA.l BattleRom_EnemySpr.Height,X", "LDA.l BattleRom_EnemySpr.Move,X", "AND.b #$07",
      "STA.w !Battler_DefMoveSpeed+!Battle_FirstEnemySlot,Y")),
    # Battle: OBJ high table by layout, and the frame DMA: two fixed sets for layout 2, else by slot and layout.
    ("bankCC/bankCC.asm", "Battle_InitSceneGfx",
     ("LDA.l !BattleRom_SprRecInit,X", "LDA.b #!Battle_HiTableLarge4", "LDA.w !Battler_FrameLayout,X",
      "CMP.b #$02", "LDA.b #!Battler_FrameDmaVramASlot3&$FF", "LDA.b #!Battler_FrameDmaSrcBSlot3&$FF",
      "LDA.b #!Battler_FrameDmaVramAOther&$FF", "LDA.b #!Battler_FrameDmaSrcBOther&$FF",
      "LDA.l !BattleRom_FrameDmaSizeA,X", "LDA.l !BattleRom_FrameDmaVramA,X", "LDA.l !BattleRom_FrameDmaSrcB,X")),
    # Battle: the frame decoder's row order for layout 2 outside slot 3.
    ("bankC1/bankC1.asm", "Battle_DrawBattlerFrameAnyLayout",
     ("LDA.w !Battler_FrameLayout,X", "CMP.b #!Battle_FrameLayoutTall", "CMP.b #!Battle_FirstEnemySlot",
      "LDA.b #!Battle_FrameLayoutTallAlt")),
    # Battle: a battler's tile list and OBJ count.
    ("bankCF/bankCF.asm", "BattleCF_BuildSprites",
     ("LDA.l !BattleRom_SprTileListPtr,X", "JSR BattleCF_CopySprTiles", "JSR BattleCF_DrawBattler")),
)

ENEMY_CONSTANT_CLAIMS = (
    ("include/constants_engine.inc", "!RomE4_EnemySprRec = $E4F600"),
    ("include/constants_engine.inc", "!EvtSpr_EnemyRecBytes = $0A"),
    ("include/constants_engine.inc", "!EvtSpr_RomGfxMin = $F8"),
    ("include/constants_engine.inc", "!ObjSpr_SizeMask = $03"),
    ("include/constants_battle.inc", "!Battle_FrameLayoutTall  = 2"),
    ("include/constants_battle.inc", "!Battle_FrameLayoutTallAlt = 5"),
    ("include/constants_battle.inc", "!Battle_FirstEnemySlot   = 3"),
    ("include/constants_battle.inc", "!Battle_SprIdxBias        = $0C"),
) + tuple(("include/constants_battle.inc", f"!Battler_FrameDma{k}{w} = ${v:04X}")
          for w, vals in (("Slot3", TALL_DMA[3]), ("Other", TALL_DMA["other"]))
          for k, v in zip(("VramA", "VramB", "SizeA", "SizeB", "SrcA", "SrcB"), vals))


def enemy_code_claims(rom):
    out = []
    op83 = _body(rom, 0xC046DF, 0xC04866)
    out.append(("$C0:46DF multiplies the operand by 10 (LDA #$0A; STA WRMPYB) and reads $E4:F600-$E4:F604 "
                "(LDA.l $E4F6xx,X), and tests the operand against $F8 (CMP #$F8)",
                b"\xa9\x0a\x8d\x03\x42" in op83 and all(bytes([0xBF, k, 0xF6, 0xE4]) in op83 for k in range(5))
                and b"\xc9\xf8" in op83, ""))
    setup = _body(rom, 0xCCE000, 0xCCED86)
    out.append(("$CC:E000 reads $E4:F601 and $E4:F603-$E4:F609 by enemy id (LDA.l $E4F6xx,X)",
                all(bytes([0xBF, k, 0xF6, 0xE4]) in setup for k in (1, 3, 4, 5, 6, 7, 8, 9))
                and bytes([0xBF, 0, 0xF6, 0xE4]) not in setup and bytes([0xBF, 2, 0xF6, 0xE4]) not in setup, ""))
    gfx = _body(rom, 0xCCED87, 0xCCF062)
    want = [bytes([0xA9, v & 0xFF]) for v in TALL_DMA[3] + TALL_DMA["other"]]
    out.append(("$CC:ED87 loads the layout-2 DMA words (LDA #imm) and the per-slot tables (LDA.l $CCF9xx,X)",
                all(w in gfx for w in want) and all(bytes([0xBF, a & 0xFF, a >> 8 & 0xFF, 0xCC]) in gfx
                                                     for a in (DMA_SRC_A, DMA_VRAM_A, DMA_SIZE_A)), ""))
    return out


def vram_tiles(rom, slot, layout):
    """{OBJ tile: buffer cell} after the frame DMA of `slot` with `layout`:
    the decoder's buffer rows (layout 5's order for layout 2 outside slot 3)
    moved by DMA A then B to VRAM (32 B a tile)."""
    columns, rows, offsets, _, _ = layout_shape(rom, LAYOUT_TALL_ALT if layout == LAYOUT_TALL and slot != FIRST_ENEMY_SLOT
                                                else layout)
    dest = u16(rom, FRAME_DEST_BASE + 2 * slot)
    if layout == LAYOUT_TALL:
        va, vb, sa, sb, ra, rb = TALL_DMA[3] if slot == FIRST_ENEMY_SLOT else TALL_DMA["other"]
    else:
        va, vb = u16(rom, DMA_VRAM_A + 2 * slot), u16(rom, DMA_VRAM_B + 2 * slot)
        sa, sb = u16(rom, DMA_SIZE_A + 2 * layout), u16(rom, DMA_SIZE_B + 2 * layout)
        ra, rb = u16(rom, DMA_SRC_A + 2 * slot), u16(rom, DMA_SRC_B + 2 * slot)
    cell_at = {offsets[r] + TILE_BYTES * c: r * columns + c for r in range(rows) for c in range(columns)}
    vram = {}
    for v, size, src in ((va, sa, ra), (vb, sb, rb)):
        for k in range(size // TILE_BYTES):
            off = src - dest + TILE_BYTES * k
            vram[v // 16 + k] = cell_at.get(off)
    return vram


def assembly_holds(rom, slot, layout):
    """Each of the layout's OBJs (tile from Battle_SprRec record 4 * slot + n,
    16x16) shows enemy_piece_cells(n): (ok, detail)."""
    columns, rows, _, _, objs = layout_shape(rom, layout)
    vram = vram_tiles(rom, slot, layout)
    base = u16(rom, SPR_TILE_LIST_PTR + 2 * (slot + SPR_IDX_BIAS))
    first = (base - SPR_REC_RAM) // 4
    for n in range(objs):
        t = u16(rom, SPR_REC_INIT + 2 * (first + n)) & 0x1FF
        got = [vram.get(t + d) for d in (0, 1, 16, 17)]
        if got != enemy_piece_cells(n, columns):
            return False, f"OBJ {n} at tile ${t:03X} shows {got}"
    return True, ""


def enemy_data_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    shapes = [layout_shape(rom, L) for L in range(4)]
    claim("frame layouts 0-3: 8 x 2, 16 x 2, 8 x 6 and 96 x 1 cells; a record is 2 B a cell + 2 B an OBJ (40, 80, 120, "
          "240 B for 4, 8, 12, 24 OBJs); each OBJ count is cells / 4",
          [(c, r, b, o) for c, r, _, b, o in shapes] == [LAYOUTS[L] for L in range(4)]
          and all(u8(rom, FRAME_EXTRA_COUNT + L) == 2 * shapes[L][4] for L in range(4)),
          str([(c, r, b, o) for c, r, _, b, o in shapes]))
    claim("BattleRom_LayoutSprBytes: 16 x (1, 2, 3, 6) - 1 for layouts 0-3 (1, 2, 3 or 6 groups of four OBJ records)",
          [u8(rom, LAYOUT_SPR_BYTES + L) for L in range(4)] == [0x0F, 0x1F, 0x2F, 0x5F])
    lists = [u16(rom, SPR_TILE_LIST_PTR + 2 * (s + SPR_IDX_BIAS)) for s in range(11)]
    claim("BattleRom_SprTileListPtr: slot s's OBJ records start at Battle_SprRec record 4s",
          lists == [SPR_REC_RAM + 16 * s for s in range(11)])
    holds = {L: [s for s in range(FIRST_ENEMY_SLOT, 11) if assembly_holds(rom, s, L)[0]] for L in range(4)}
    claim("OBJ assembly, from the battle's DMA tables and OBJ records: OBJ n of a frame w cells wide shows cells "
          "(2p, 2q), (2p, 2q+1), (2p+1, 2q), (2p+1, 2q+1) with p, q = divmod(n, w / 2); for layout 0 in all 8 enemy "
          "slots, layout 1 in slots 3, 5, 7, 9 and layout 2 in slots 3 and 6; layout 3 in none",
          holds == {0: list(range(3, 11)), 1: [3, 5, 7, 9], 2: [3, 6], 3: []}, str(holds))
    recs = [enemy_record(rom, i) for i in range(ENEMY_RECORDS)]
    sizes = [sum(1 for r in recs[:ENEMY_IDS] if r["size"] == L) for L in range(4)]
    claim(f"enemy records 0-254: size classes 0-3 used {sizes[0]}, {sizes[1]}, {sizes[2]} and {sizes[3]} times",
          sum(sizes) == ENEMY_IDS, str([i for i in range(ENEMY_IDS) if recs[i]["size"] == 3]))
    packed = sorted({recs[i]["gfx"] for i in range(ROM_GFX_MIN)})
    bad = []
    for g in packed:
        try:
            enemy_tile_bytes(rom, next(i for i in range(ROM_GFX_MIN) if recs[i]["gfx"] == g))
        except ValueError as e:
            bad.append((g, str(e)))
    claim(f"the {len(packed)} graphics records 0-247 name unpack as Decomp_ToWram streams to whole 4bpp tiles",
          not bad, str(bad[:3]))
    claim("records $F8-$FF name only the playable characters' raw tile blocks (or 0)",
          all(recs[i]["gfx"] < SETS for i in range(ROM_GFX_MIN, ENEMY_RECORDS)), str([recs[i]["gfx"] for i in range(ROM_GFX_MIN, 256)]))
    empty, past_tiles, past_frames = [], [], []
    for i in range(ENEMY_IDS):
        d = decode_enemy(rom, i)
        n, count = d["frames"]["count"], d["tiles"]["count"]
        words = [w for f in d["frameList"] for w in f["cells"]]
        used = {k for a in d["animationList"] for k in a["frames"]}
        if not n:
            empty.append(i)
        if words and max(w & TILE_MASK for w in words) >= count:
            past_tiles.append(i)
        if used and max(used) >= n:
            past_frames.append(i)
    claim("every enemy record 0-254 has frames; cells name tiles below the graphics' count except in records 117 and "
          "253; animations name frames below the frame count except in records 26, 27 and 254 (253 and 254 pair "
          "Crono's tiles with other frame sets)", not empty and past_tiles == [117, 253] and past_frames == [26, 27, 254],
          f"no frames {empty}; tiles past {past_tiles}; frames past {past_frames}")
    claim("enemy palettes: 12 BGR555 colours with bit 15 clear",
          all(w < 0x8000 for i in range(ENEMY_IDS) for w in enemy_palette(rom, i)))
    claim("enemy animation sets index below 255 (AnimFrames[a + 1] exists)", all(r["anim"] < 255 for r in recs[:ENEMY_IDS]))
    return out


def enemy_run_claims(rom, ref=REF, ids=range(ENEMY_IDS)):
    """The ROM's own Decomp_ToWram for every packed graphics record, and its
    frame decoder for every frame of every enemy (graphics, frame set and
    layout distinct), in slot 3 (layout 2 also in slot 6: the TallAlt order)."""
    import ct_tilesets
    runner, decomp = RomFrameDecoder(rom, ref), ct_tilesets.RomRunner(rom, ref)
    out, bad, packs = [], [], {}
    for i in ids:
        r = enemy_record(rom, i)
        if i < ROM_GFX_MIN and r["gfx"] not in packs:
            at = u24(rom, TILES_PTR + 3 * r["gfx"])
            got, _ = decomp.decomp(at, 0x7F2000)
            packs[r["gfx"]] = got == b"".join(enemy_tile_bytes(rom, i)[0])
    out.append((f"Decomp_ToWram ($C3:0557, run) = the decode's unpacked tiles for the {len(packs)} enemy graphics packs",
                packs and all(packs.values()), str([g for g, ok in packs.items() if not ok][:5])))
    seen, frames = set(), 0
    for i in ids:
        r = enemy_record(rom, i)
        key = (r["gfx"] if i < ROM_GFX_MIN else ("rom", r["gfx"]), r["frames"], r["size"])
        if key in seen or r["size"] not in ASSEMBLED:
            continue
        seen.add(key)
        tb, _ = enemy_tile_bytes(rom, i)
        d = decode_enemy(rom, i)
        tiles_at = 0x7F2000 if i < ROM_GFX_MIN else u24(rom, TILES_PTR + 3 * r["gfx"])
        if i >= ROM_GFX_MIN:                     # past the block the decoder reads on in the bank (16-bit addresses)
            tb = tb + [bytes(rom[pc(tiles_at & 0xFF0000 | (tiles_at + TILE_BYTES * t + k) & 0xFFFF)] for k in range(TILE_BYTES))
                       for t in range(len(tb), TILE_MASK + 1)]
        wram = {0x7F2000 + k: v for k, v in enumerate(b"".join(tb))} if i < ROM_GFX_MIN else {}
        slots = (FIRST_ENEMY_SLOT, 6) if r["size"] == LAYOUT_TALL else (FIRST_ENEMY_SLOT,)
        for slot in slots:
            for f in range(d["frames"]["count"]):
                got = runner.decode(slot, tiles_at, u24(rom, FRAMES_PTR + 3 * r["frames"]), f, layout=r["size"], extra_known=wram)
                frames += 1
                if got != expected_enemy_buffer(rom, d["frameList"][f], tb, r["size"], slot):
                    bad.append((i, slot, f))
    out.append((f"the ROM's frame decoder ($C1:1C55, run) = the enemy decode for {frames} frames of {len(seen)} "
                "distinct enemy sprites in layouts 0-2", frames and not bad, f"differs at {bad[:5]}" if bad else ""))
    return out


def expected_enemy_buffer(rom, frame, tile_bytes, layout, slot):
    """The decoder's buffer rows (by the slot's row order) and the sign-extended OBJ offsets."""
    columns, rows, _, _ = LAYOUTS[layout]
    rows_out = []
    for r in range(rows):
        row = ()
        for c in range(columns):
            w = frame["cells"][r * columns + c]
            t = w & TILE_MASK
            if t >= len(tile_bytes):
                row += (None,) * TILE_BYTES                                # past the graphics: unknown
                continue
            raw = bytes(TILE_BYTES) if t == 0 else tile_bytes[t]
            row += tuple(BIT_REVERSE[b] for b in raw) if w & HFLIP else tuple(raw)
        rows_out.append(_row(row))
    return rows_out, b"".join(struct.pack("<hh", x, y) for x, y in frame["pieces"])


def compose_enemy(frame, tile_bytes, columns):
    """{(x, y): index} of an enemy frame about its origin, the lower OBJ in front."""
    img = {}
    for n, (x0, y0) in enumerate(frame["pieces"]):
        for q, k in enumerate(enemy_piece_cells(n, columns)):
            px = cell_pixels(frame["cells"][k], tile_bytes)
            ox, oy = x0 + 8 * (q % 2), y0 + 8 * (q // 2)
            for j, v in enumerate(px):
                if v:
                    img.setdefault((ox + j % 8, oy + j // 8), v)
    return img


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


ENEMY_VECTORS = VECTORS.parent / "enemy_sprite_vectors.json"


def pack_literals(data):
    """A Decomp_ToWram stream of `data` in 8-literal groups only (no back-references),
    the last group padded with zeros."""
    body = b"".join(b"\x00" + data[8 * i:8 * i + 8].ljust(8, b"\x00") for i in range((len(data) + 7) // 8))
    return len(body).to_bytes(2, "little") + body + b"\x00"


def synthetic_enemy_rom():
    """The synthetic PC image plus four synthetic enemy records (layouts 0, 1
    and 2 with packed graphics, and a $F8 record on PC set 0's raw tiles), as
    (regions, expected decodes). No ROM data."""
    regions, _ = synthetic_rom()
    rng = Lcg(0xE5E7)

    def ptrs(base, size, values):
        old = regions[base]
        table = [int.from_bytes(old[size * i:size * (i + 1)], "little") for i in range(len(old) // size)]
        for k, v in values.items():
            table += [0] * (k + 1 - len(table))
            table[k] = v
        regions[base] = b"".join(v.to_bytes(size, "little") for v in table)
        return table

    gfx = {10: 30, 11: 50}                               # graphics entry -> tiles
    gfx_at = {10: 0xD50000, 11: 0xD58000}
    for g, n in gfx.items():
        raw = bytes(32) + bytes(rng.next(256) if rng.next(3) else 0 for _ in range(32 * (n - 1)))
        regions[gfx_at[g]] = pack_literals(raw)
    ptrs(TILES_PTR, 3, gfx_at)
    # Frame sets 10-12 in bank $DD: (layout, frames, graphics tiles); entry 13 ends set 12.
    sets = {10: (0, 6, gfx[10]), 11: (1, 5, gfx[11]), 12: (2, 4, gfx[10])}
    at, frame_ptrs = 0xDD0000, {}
    for fs, (layout, n, ntiles) in sets.items():
        columns, rows, record_bytes, objs = LAYOUTS[layout]
        frame_ptrs[fs] = at
        recs = b""
        for f in range(n):
            words = [(rng.next(ntiles) if rng.next(4) else 0) | (HFLIP if rng.next(3) == 0 else 0)
                     for _ in range(columns * rows)]
            if f == n - 1:
                words[1] = ntiles - 1
            recs += b"".join(w.to_bytes(2, "little") for w in words) + bytes((rng.next(64) - 40) & 0xFF for _ in range(2 * objs))
        regions[at] = recs
        at += len(recs)
    frame_ptrs[13] = at
    ptrs(FRAMES_PTR, 3, frame_ptrs)
    # Animation sets 3 and 4 after the PC sets' (2 and 3 rows).
    af = ptrs(ANIM_FRAMES, 2, {})
    ad = ptrs(ANIM_DURS, 2, {})
    rows = {3: 2, 4: 3}
    af3, ad3 = af[2], ad[2]
    ptrs(ANIM_FRAMES, 2, {3: af3, 4: af3 + 16 * rows[3], 5: af3 + 16 * (rows[3] + rows[4])})
    ptrs(ANIM_DURS, 2, {3: ad3, 4: ad3 + 4 * rows[3], 5: ad3 + 4 * (rows[3] + rows[4])})
    for a, frames in ((3, 4), (4, 5)):
        ids = [rng.next(frames) for _ in range(16 * rows[a])]
        durs = [1 + rng.next(40) if k < 1 + rng.next(4) else 0 for _ in range(rows[a]) for k in range(4)]
        durs[-1] = 0
        regions[ANIM_BANK + (af3 if a == 3 else af3 + 16 * rows[3])] = bytes(ids)
        regions[ANIM_BANK + (ad3 if a == 3 else ad3 + 4 * rows[3])] = bytes(durs)
    # Records: id -> (gfx, frame set, palette, animation set, size | flags, five more bytes).
    recs = {0: (10, 10, 1, 3, 0x40), 1: (11, 11, 2, 4, 0x81), 2: (10, 12, 0, 3, 0x22), 0xF8: (0, 0, 0, 0, 0x00)}
    for i, (g, fs, pal, anim, b4) in recs.items():
        regions[ENEMY_SPR + ENEMY_SPR_BYTES * i] = bytes([g, fs, pal, anim, b4] + [rng.next(256) for _ in range(5)])
    image = bytearray(ROM_SIZE)
    for long, data in regions.items():
        image[pc(long):pc(long) + len(data)] = data
    image = bytes(image)
    expect = []
    for i in recs:
        d = decode_enemy(image, i)
        tb, _ = enemy_tile_bytes(image, i)
        img = compose_enemy(d["frameList"][-1], tb, d["layout"]["columns"])
        xs, ys = [x for x, _ in img], [y for _, y in img]
        left, top = min(xs), min(ys)
        w, h = max(xs) - left + 1, max(ys) - top + 1
        d["composed"] = {"frame": len(d["frameList"]) - 1, "left": left, "top": top, "width": w, "height": h,
                         "indices": bytes(img.get((left + k % w, top + k // w), 0) for k in range(w * h)).hex()}
        d["tileIndices"] = bytes(v for t in tb for v in tile_indices(t)).hex()
        expect.append(d)
    return regions, expect


def enemy_vectors_text():
    regions, expect = synthetic_enemy_rom()
    head = {"schema": "ct-enemy-sprite-vectors/1",
            "note": "synthetic enemy records and the synthetic PC sets in the real tables' places (no ROM data); "
                    "expected decode by re_workspace/tools/ct_sprites.py",
            "regions": [{"at": snes(k), "hex": v.hex()} for k, v in sorted(regions.items())]}
    text = "{\n" + ",\n".join(f' "{k}": {json.dumps(v, separators=(",", ":"))}' for k, v in head.items())
    return text + ',\n "enemies": [\n' + ",\n".join("  " + json.dumps(d, separators=(",", ":")) for d in expect) + "]}\n"


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


def _first(ids):
    return " ".join(map(str, ids[:8])) + (" ..." if len(ids) > 8 else "")


def verify_enemy_import(rom, project):
    """The enemies' sprites of a Studio import (sprites/enemy_NNN.*) against
    decode_enemy: one claim per check over every record 0-254 of layouts 0-2,
    and none imported for layout 3. [(name, ok, detail)]."""
    from PIL import Image
    wanted = [i for i in range(ENEMY_IDS) if enemy_record(rom, i)["size"] in ASSEMBLED]
    bad = {k: [] for k in ("present", "frames", "animations", "palette", "stream", "sheet")}
    for i in wanted:
        path = Path(project) / "sprites" / f"enemy_{i:03d}.sprite.json"
        if not path.exists():
            bad["present"].append(i)
            continue
        s = json.loads(path.read_text())
        d = decode_enemy(rom, i)
        lay = d["layout"]
        half = lay["columns"] // 2
        frames_ok = len(s["frames"]) == d["frames"]["count"] and s["rom"]["family"] == "ct-enemy" and \
            s["rom"]["set"] == i and s["rom"]["layout"] == lay["index"]
        for f, g in zip(s["frames"], d["frameList"]):
            frames_ok = frames_ok and f["cells"] == g["cells"] and \
                [[t["x"], t["y"]] for t in f["tiles"]] == g["pieces"] and \
                [t["tile"] for t in f["tiles"]] == [32 * (n // half) + 2 * (n % half) for n in range(lay["objs"])] and \
                all(t["size16"] and not t["hflip"] and not t["vflip"] for t in f["tiles"])
        if not frames_ok:
            bad["frames"].append(i)
        count = d["frames"]["count"]
        kept = [a for a in d["animationList"] if all(x < count for x in a["frames"])]
        if [{k: a[k] for k in ("id", "row", "facing", "frames", "durations")} for a in s["animations"]] != kept:
            bad["animations"].append(i)
        if [int(w, 16) for w in s["palettes"][0]] != [0] + enemy_palette(rom, i) + [0, 0, 0]:
            bad["palette"].append(i)
        stream = s.get("stream") or {}
        if (stream.get("columns"), stream.get("rows"), stream.get("baseTile")) != \
                (lay["columns"], lay["rows"], ENEMY_SLOT_TILE):
            bad["stream"].append(i)
        sheet = Image.open(Path(project) / s["sheet"])
        tb, _ = enemy_tile_bytes(rom, i)
        cols = sheet.width // 8
        px = sheet.load()
        if not (sheet.mode == "P" and sheet.width == 128 and all(
                [px[(t % cols) * 8 + k % 8, (t // cols) * 8 + k // 8] for k in range(64)] == tile_indices(tb[t])
                for t in range(len(tb)))):
            bad["sheet"].append(i)
    others = sorted(i for i in range(ENEMY_IDS) if i not in wanted and
                    (Path(project) / "sprites" / f"enemy_{i:03d}.sprite.json").exists())
    n = len(wanted)
    return [
        (f"enemies: {n} records of frame layouts 0-2 imported as sprites/enemy_NNN.*", not bad["present"],
         _first(bad["present"])),
        (f"enemies: frames, cells, OBJ offsets and OBJ tiles 32p + 2q as decoded ({n})", not bad["frames"],
         _first(bad["frames"])),
        (f"enemies: animations as decoded, less those naming frames past the block ({n})", not bad["animations"],
         _first(bad["animations"])),
        (f"enemies: palette = 0 + the 12 ROM colours + 3 zeros ({n})", not bad["palette"], _first(bad["palette"])),
        (f"enemies: streamed columns x rows cells at OBJ tile $40 ({n})", not bad["stream"], _first(bad["stream"])),
        (f"enemies: sheet holds the record's tiles, 16 per row ({n})", not bad["sheet"], _first(bad["sheet"])),
        ("enemies: layout 3 records are not imported", not others, _first(others)),
    ]


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
    e = sub.add_parser("decode-enemy")
    e.add_argument("id", type=int, choices=range(ENEMY_IDS))
    e.add_argument("--rom", default=str(ROM_PATH))
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
    v.add_argument("--pc-only", action="store_true",
                   help="only the playable characters' sets (an enemy import is a snapshot of the clean ROM)")
    for name in ("vectors", "enemy-vectors"):
        g = sub.add_parser(name)
        m = g.add_mutually_exclusive_group(required=True)
        m.add_argument("--out")
        m.add_argument("--check")
    args = parser.parse_args()

    if args.command in ("vectors", "enemy-vectors"):
        text = vectors_text() if args.command == "vectors" else enemy_vectors_text()
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
    if args.command == "decode-enemy":
        print(json.dumps(decode_enemy(rom, args.id), indent=1))
        return 0
    if args.command == "render":
        w, h, left, top = render(rom, args.set, args.frame, args.out)
        print(f"wrote {args.out}: {w} x {h} pixels, origin at ({-left}, {-top})")
        return 0
    if args.command == "verify-import":
        claims = verify_import(rom, args.project)
        return report(claims if args.pc_only else claims + verify_enemy_import(rom, args.project))
    claims = asm_claims() + code_claims(rom) + data_claims(rom)
    claims += asm_claims(routines=ENEMY_ASM_CLAIMS, constants=ENEMY_CONSTANT_CLAIMS)
    claims += enemy_code_claims(rom) + enemy_data_claims(rom)
    if args.run:
        claims += run_claims(rom) + enemy_run_claims(rom)
    return report(claims)


if __name__ == "__main__":
    sys.exit(main())
