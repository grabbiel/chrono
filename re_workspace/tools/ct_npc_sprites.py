#!/usr/bin/env python3
"""Chrono Trigger NPC sprites: the field's $E4:F000 records 7-255, as event opcode $82 loads them.

The field gives an object a sprite with one of three event opcodes (ChronoRET,
MIT; refs/ChronoRET, bank $C0):

  $81 record      Evt_Op81_InitSprite: RomE4_SprRec record `record`, its
                  graphics read from the ROM as they are (Field_E4Ptr0 pointer).
                  The event packs use it for records 0-6 only (the PCs).
  $82 n           Evt_Op82_InitWramSprite: record SprRec_FirstNpc (7) + n. The
                  graphics pack its $E4:2000 pointer names is unpacked
                  (Decomp_ToWramVec) to $7F:ObjQ_Unk71 (from $8000), once per
                  pack while objects share it (Evt_FindOrAddUnk0920).
  $83 n b         Evt_Op83_InitEnemySprite: the 10-byte $E4:F600 records (ct_sprites.py).

A record is the PCs' 5 bytes (graphics, frame set, palette, animation set,
size): the frame, animation and palette tables are the PCs' and the enemies'
(bank $E4: $2000, $2300, $2600, $2800, $0000 + 24p), read the same way. The
size class (bits 0-1) picks the field's frame builder and OBJ count:

  class 0  Obj_BuildFrame4  40 B records: 16 tile words (8 x 2) + 4 (x, y) pairs
  class 1  Obj_BuildFrame8  80 B records: 32 tile words (16 x 2) + 8 pairs

The builder copies the frame's cells (Spr_CopyTile, Spr_CopyTileFlipped: bits
0-10 a tile of the unpacked graphics, bit 14 mirrors it; tile 0 is copied as
it is) into a SprBuf chunk and queues it for VRAM at the object's OBJ tile T:
cells 0..w-1 to tiles T.., cells w.. to T+16.. (VramQ_DestB = DestA + $100
words). OBJ n is the 16x16 at T + 2n with the frame's pair n as its offset,
so it shows cells (0, 2n), (0, 2n+1), (1, 2n), (1, 2n+1): the enemies'
layouts 0 and 1. T comes from Obj_TileSlotAllocKind: class 0 the first free
slot from $19 down, class 1 the first free even/odd pair from $0C; slot n is
OBJ tile (n & $FE) x 16 + (n & 1) x 8. The palette goes to the first OBJ
palette of 0-4 that holds the same colours or is free (Obj_PalSlotAny).

Animations are the PCs' (Obj_AnimFrameLookup, Obj_AnimTickAndQueue): a step
lasts its duration in field frames; a zero duration restarts the row; a $FF
frame id shows the row's first frame for that entry's duration before the
restart; counted loops (mode 2, opcode $B7) take 2 off a count of 3 or more
per pass and hold the last frame at 1.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_npc_sprites.py decode <record> [--rom PATH]     one record as JSON (no tile bytes)
    ct_npc_sprites.py usage [--rom PATH]               the records each event pack and location loads
    ct_npc_sprites.py sharing [--rom PATH]             each NPC part and who else shows it
    ct_npc_sprites.py check [--rom PATH] [--run]       every evidence claim (exit 1 on a failure); --run
                                                       also runs the field's loader, frame builders,
                                                       frame lookup and animation tick
    ct_npc_sprites.py verify-import <project> [--rom PATH]
                                                       a Studio import (sprites/npc_NNN.*) against decode
    ct_npc_sprites.py vectors (--out | --check) P      synthetic vectors for the Swift twin
"""

import argparse
import collections
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_sprites as cs  # noqa: E402
from ct_sprites import (ANIM_BANK, ANIM_DURS, ANIM_FRAMES, BIT_REVERSE, END_MARKER, ENEMY_IDS, FRAMES_PTR,  # noqa: E402
                        HFLIP, PAL_BYTES, PAL_COLOURS, POINTERS, REF, ROM_PATH, SETS, SPR_REC, SPR_REC_BYTES,
                        TILE_BYTES, TILE_MASK, TILES_PTR, WS, pc, s8, snes, u8, u16, u24)

FAMILY = "ct-npc"
FIRST_NPC = 7                          # !SprRec_FirstNpc: record of Evt_Op82's operand 0
OP_RECORD, OP_NPC, OP_ENEMY = 0x81, 0x82, 0x83
SIZE_MASK = 0x03                       # !ObjSpr_SizeMask
# Field size classes as (columns, rows, record bytes, OBJs): Frame4_Bytes and Frame8_Bytes.
FIELD_LAYOUTS = {0: (8, 2, 40, 4), 1: (16, 2, 80, 8)}
SINGLE_TOP, PAIR_FIRST, PAIR_END = 0x19, 0x0C, 0x18   # !ObjTile_SingleTop / PairFirst / PairEnd
PAL_ANY_END = 5                        # !ObjPal_AnyEnd: kinds 3 and 4 use OBJ palettes 0-4
GFX_WRAM = 0x7F8000                    # $7F:ObjQ_Unk71Init: the first unpacked graphics
VRAM_ROW_WORDS = 0x100                 # !Vram_TileRowWords
PRIO_INIT = 0x20                       # !EvtSpr_PrioInit's byte: OAM priority 2
UPPER_OFS_Y = 0xE8                     # !Spr_UpperOfsY: class 0 OBJs with OfsY >= $E8 take Obj_PrioHigh


def slot_tile(n):
    """OBJ tile of tile slot n (Obj_TileSlotAllocKind)."""
    return (n & 0xFE) * 16 + (n & 1) * 8


SLOT_TILE = {0: slot_tile(SINGLE_TOP), 1: slot_tile(PAIR_FIRST)}     # the first slot an empty field gives


def npc_id(r):
    return f"npc_{r:03d}"


# --- Decode ---------------------------------------------------------------------------------

def record(rom, r):
    b = rom[pc(SPR_REC + SPR_REC_BYTES * r):pc(SPR_REC + SPR_REC_BYTES * (r + 1))]
    return {"gfx": b[0], "frames": b[1], "palette": b[2], "anim": b[3], "size": b[4] & SIZE_MASK, "sizeByte": b[4]}


_UNPACKED = {}


def pack(rom, gfx):
    """(tiles as 32-byte strings, mode, stream bytes) of graphics entry `gfx`, unpacked as Decomp_ToWram does."""
    at = u24(rom, TILES_PTR + 3 * gfx)
    key = (id(rom), at)
    if key not in _UNPACKED:
        import ct_tilesets
        data, mode, end = ct_tilesets.unpack_bytes(rom[pc(at):pc(at) + 0x10000])
        if len(data) % TILE_BYTES:
            raise ValueError(f"graphics {gfx} unpacks to {len(data)} bytes, not whole tiles")
        _UNPACKED[key] = ([bytes(data[TILE_BYTES * t:TILE_BYTES * (t + 1)]) for t in range(len(data) // TILE_BYTES)],
                          mode, end)
    return _UNPACKED[key]


def valid_frame(rom, at, record_bytes, columns, rows, ntiles):
    words = [u16(rom, at + 2 * k) for k in range(columns * rows)]
    return all(w & 0x3800 == 0 and w & TILE_MASK < ntiles for w in words)


def frame_count(rom, frame_set, record_bytes, columns, rows, ntiles):
    """Records up to the next frame block in the bank (at most 256), less
    trailing all-zero records. A bank's last block has no next pointer: it
    ends at its first record that is not a frame of the graphics (a cell past
    the tiles or with bits 11-13)."""
    start = u24(rom, FRAMES_PTR + 3 * frame_set)
    table = cs.table(rom, FRAMES_PTR, 3)
    end = cs.block_end(table, start)
    n = min(POINTERS, (end - start) // record_bytes)
    if not any(start < p < (start | 0xFFFF) + 1 for p in table):
        k = 0
        while k < n and valid_frame(rom, start + record_bytes * k, record_bytes, columns, rows, ntiles):
            k += 1
        n = k
    while n and not any(rom[pc(start + record_bytes * (n - 1)):pc(start + record_bytes * n)]):
        n -= 1
    return n


def decode_frame(rec, columns, rows, objs):
    return cs.decode_enemy_frame(rec, columns, rows, objs)


def anim_shape(rom, anim):
    """(stride, rows) of an animation set as the field reads it: the facing
    stride is (AnimFrames[a + 1] - AnimFrames[a]) / 4 entries (Evt_LoadSpriteRec's
    LSR LSR; 16 x rows for the PCs, 11 and 5 for sets 76 and 74), and a list
    may start in any of the ceil(stride / 4) rows."""
    stride = ((u16(rom, ANIM_FRAMES + 2 * anim + 2) - u16(rom, ANIM_FRAMES + 2 * anim)) & 0xFFFF) >> 2
    return stride, (stride + 3) // 4


def animation_lists(rom, anim):
    """Every non-empty (row, facing) list, as cs.decode_animations with the
    field's stride, and each list's end: "zero" (a zero duration), "marker"
    with the $FF entry's duration, or "end" (the facing's last entry)."""
    stride, rows = anim_shape(rom, anim)
    ids_at = ANIM_BANK + u16(rom, ANIM_FRAMES + 2 * anim)
    durs_at = ANIM_BANK + u16(rom, ANIM_DURS + 2 * anim)
    out = []
    for r in range(rows):
        for f in range(4):
            ids, durs = [], []
            for e in range(4 * r, stride):
                d, i = u8(rom, durs_at + e), u8(rom, ids_at + f * stride + e)
                if d == 0 or i == END_MARKER:
                    break
                ids.append(i)
                durs.append(d)
            if not ids:
                continue
            a = {"id": f"r{r:02d}.{cs.FACINGS[f]}", "row": r, "facing": f, "frames": ids, "durations": durs}
            e = 4 * r + len(ids)
            if e >= stride:
                a["end"] = "end"
            elif u8(rom, durs_at + e) == 0:
                a["end"] = "zero"
            else:
                a["end"] = "marker"
                a["markerDuration"] = u8(rom, durs_at + e)
            out.append(a)
    return out


def decode_npc(rom, r):
    """Record r's sprite as the field loads it with opcode $82 (no tile bytes)."""
    rec = record(rom, r)
    columns, rows, record_bytes, objs = FIELD_LAYOUTS[rec["size"]]
    tb, mode, packed_bytes = pack(rom, rec["gfx"])
    frames_at = u24(rom, FRAMES_PTR + 3 * rec["frames"])
    n = frame_count(rom, rec["frames"], record_bytes, columns, rows, len(tb))
    pal = ANIM_BANK + rec["palette"] * PAL_BYTES
    lists = animation_lists(rom, rec["anim"])
    return {
        "record": r, "fields": rec,
        "layout": {"index": rec["size"], "columns": columns, "rows": rows, "objs": objs, "recordBytes": record_bytes},
        "tiles": {"pointer": snes(u24(rom, TILES_PTR + 3 * rec["gfx"])), "count": len(tb), "mode": mode,
                  "packedBytes": packed_bytes},
        "frames": {"address": snes(frames_at), "count": n},
        "palette": {"address": snes(pal), "colours": [f"0x{u16(rom, pal + 2 * k):04X}" for k in range(PAL_COLOURS)]},
        "animations": {"frameIds": snes(ANIM_BANK + u16(rom, ANIM_FRAMES + 2 * rec["anim"])),
                       "durations": snes(ANIM_BANK + u16(rom, ANIM_DURS + 2 * rec["anim"])),
                       "rows": anim_shape(rom, rec["anim"])[1], "stride": anim_shape(rom, rec["anim"])[0]},
        "frameList": [decode_frame(rom[pc(frames_at + record_bytes * f):pc(frames_at + record_bytes * (f + 1))],
                                   columns, rows, objs) for f in range(n)],
        "animationList": [a for a in lists if all(i < n for i in a["frames"])],
        "slotTile": SLOT_TILE[rec["size"]],
    }


def palette(rom, r):
    at = ANIM_BANK + record(rom, r)["palette"] * PAL_BYTES
    return [u16(rom, at + 2 * k) for k in range(PAL_COLOURS)]


def nonzero_records(rom):
    return [r for r in range(FIRST_NPC, POINTERS)
            if any(rom[pc(SPR_REC + SPR_REC_BYTES * r):pc(SPR_REC + SPR_REC_BYTES * (r + 1))])]


# --- Which event packs and locations load each record ----------------------------------------

_USAGE = {}


def sprite_ops(rom):
    """{opcode: {record: [Evt_PackPtrs indices]}} for opcodes $81-$83 in every event pack."""
    key = id(rom)
    if key in _USAGE:
        return _USAGE[key]
    import ct_event_packs as ep
    table = json.loads(ep.TABLE.read_text())["opcodes"]
    packs, _ = ep.unpack_all(rom)
    out = {op: collections.defaultdict(set) for op in (OP_RECORD, OP_NPC, OP_ENEMY)}
    for p in packs:
        if not p["data"]:
            continue
        ops, _, _ = ep.decode(table, p["data"])
        for y, (op, _, _, _) in ops.items():
            if op in out:
                arg = p["data"][1 + y + 1]
                rec = arg + FIRST_NPC if op == OP_NPC else arg
                out[op][rec].update(p["pointerIndices"])
    _USAGE[key] = {op: {r: sorted(v) for r, v in d.items()} for op, d in out.items()}
    return _USAGE[key]


def locations_by_pack(rom):
    """{Evt_PackPtrs index: [locations whose LocRom .Events names it]}."""
    import ct_tilesets as ts
    out = collections.defaultdict(list)
    for i in range(ts.LOC_COUNT):
        out[u16(rom, ts.LOC_ROM + ts.LOC_BYTES * i + 8)].append(i)
    return out


def usage(rom):
    """{record: {"packs": [Evt_PackPtrs indices], "locations": [...]}} for every record opcode $82 loads."""
    by_pack = locations_by_pack(rom)
    out = {}
    for r, packs in sorted(sprite_ops(rom)[OP_NPC].items()):
        out[r] = {"packs": packs, "locations": sorted({loc for p in packs for loc in by_pack.get(p, [])})}
    return out


# --- Sharing: who else shows a record's parts ------------------------------------------------

PARTS = ("tiles", "frames", "palette", "animations")


def sharing(rom):
    """{record: {part: {"npc": [...], "enemy": [...], "pc": [...]}}}: for each
    nonzero NPC record, the other NPC records, the enemy records 0-254 and the
    playable sets (their tiles, frames and animations are entries 0-6, their
    palettes those records 0-6 name) that show the same part."""
    recs = {r: rom[pc(SPR_REC + SPR_REC_BYTES * r):pc(SPR_REC + SPR_REC_BYTES * r) + 4] for r in range(POINTERS)}
    enemies = [rom[pc(cs.ENEMY_SPR + cs.ENEMY_SPR_BYTES * i):pc(cs.ENEMY_SPR + cs.ENEMY_SPR_BYTES * i) + 4]
               for i in range(ENEMY_IDS)]
    pc_pal = {recs[c][2]: c for c in range(SETS)}
    out = {}
    npcs = nonzero_records(rom)
    for r in npcs:
        entry = {}
        for k, part in enumerate(PARTS):
            v = recs[r][k]
            pcs = sorted({v} if v < SETS and part != "palette" else ({pc_pal[v]} if part == "palette" and v in pc_pal else set()))
            entry[part] = {"value": v, "npc": [o for o in npcs if o != r and recs[o][k] == v],
                           "enemy": [i for i in range(ENEMY_IDS) if enemies[i][k] == v], "pc": pcs}
        out[r] = entry
    return out


# --- Evidence: ChronoRET's source ------------------------------------------------------------

ASM_CLAIMS = (
    # $82: record 7 + n, the PC tables, graphics unpacked to bank $7F (shared while unpacked).
    ("bankC0/bankC0.asm", "Evt_Op82_InitWramSprite",
     ("LDA.b #!Obj_Unk1100Kind4", "JSR Evt_InitWramSprite", "LDA.b #!SprRec_Bytes", "STA.w WRMPYB",
      "LDA.l !RomE4_NpcSprRec+!SprRec_Frames,X", "LDA.b [!Field_E4Ptr1],Y", "STA.w !Obj_FrameOfs,X",
      "STA.w !Obj_FrameBank,X", "LDA.l !RomE4_NpcSprRec+!SprRec_Pal,X", "LDA.b #!Pal_ObjColorBytes",
      "STA.w !Obj_PalSrc,X", "LDA.l !RomE4_NpcSprRec+!SprRec_Anim,X", "SBC.b [!Field_E4Ptr2],Y",
      "STA.w !Obj_AnimFacingStride,X", "STA.w !Obj_AnimFrameTbl,X", "LDA.b [!Field_E4Ptr3],Y",
      "STA.w !Obj_AnimTimeTbl,X", "LDA.l !RomE4_NpcSprRec+!SprRec_Size,X", "STA.w !Obj_SprSize,X",
      "LDA.l !RomE4_NpcSprRec+!SprRec_Gfx,X", "STA.b !Evt_Unk0920Key", "JSR Evt_FindOrAddUnk0920",
      "LDA.w !Obj_GfxOfs,X", "LDA.b [!Field_E4Ptr0],Y", "STA.w !Decomp_Src", "LDA.b !ObjQ_Unk71",
      "STA.w !Decomp_Dest", "LDA.b #!Bank7F", "STA.w !Decomp_DestBank", "JSL Decomp_ToWramVec",
      "LDA.w !Decomp_OutLen", "ADC.b !ObjQ_Unk71", "STA.b !ObjQ_Unk71")),
    # The common start: GfxOfs = ObjQ_Unk71 in bank $7F, priority, facing down, row 0.
    ("bankC0/bankC0.asm", "Evt_InitWramSprite",
     ("LDA.b !ObjQ_Unk71", "STA.w !Obj_GfxOfs,X", "LDA.w #!EvtSpr_PrioInit", "STA.w !Obj_PrioLow,X",
      "LDA.b #!Bank7F", "STA.w !Obj_GfxBank,X", "LDA.b #!Obj_FacingDown", "STA.w !Obj_Facing,X")),
    # $81: the same record layout, graphics read from the ROM.
    ("bankC0/bankC0.asm", "Evt_LoadSpriteRec",
     ("LDA.l !RomE4_SprRec+!SprRec_Gfx,X", "LDA.b [!Field_E4Ptr0],Y", "STA.w !Obj_GfxOfs,X",
      "STA.w !Obj_GfxBank,X")),
    # OBJ tile slots: class 0 from $19 down, classes 1-3 an even/odd pair from $0C.
    ("bankC0/bankC0.asm", "Obj_TileSlotAllocKind",
     ("LDA.w !Obj_SprSize,X", "AND.b #!ObjSpr_SizeMask", "LDX.b #!ObjTile_SingleTop", "AND.w #!ObjTile_PairMask",
      "AND.w #!ObjTile_OddBit", "STA.w !Obj_VramTile,X", "STA.w !Obj_TileRecOfs,X", "LDX.b #!ObjTile_PairFirst",
      "STA.w !Obj_TileSlot+1,X", "CPX.b #!ObjTile_PairEnd")),
    # The 8-OBJ builder: 80-byte records, 32 cells in two chunks, OBJ n at Obj_VramTile + 2n.
    ("bankC0/bankC0.asm", "Obj_BuildFrame8Pass0",
     ("JSR Obj_AnimFrameLookup", "JSR SprBuf_Alloc2", "LDA.b #!Frame8_Bytes", "STA.w WRMPYB",
      "LDA.w #!SprBuf_ChunkTiles", "JSR Spr_CopyTile", "JSR Spr_CopyTileFlipped")),
    ("bankC0/bankC0.asm", "Obj_BuildFrame8Pass1",
     ("ADC.w #!Gfx_8TilesBytes*2", "LDA.b #!Frame8_Bytes", "LDY.w #!Frame_TileWordBytes*16", "JSR Spr_CopyTile",
      "ADC.w #!Vram_TileRowWords", "STA.w !VramQ_DestB,X", "ADC.w #!Gfx_8TilesBytes*2", "STA.w !VramQ_SrcB,X",
      "LDY.w #!Frame_TileWordBytes*32", "STA.l SprTileSrc.OfsX,X", "STA.l SprTileSrc[7].OfsY,X",
      "LDA.w !Obj_VramTile,Y", "STA.l SprTileSrc.Tile,X", "STA.l SprTileSrc[7].Tile,X",
      "ORA.w !Obj_PrioLow,Y", "ORA.w !Obj_PrioHigh,Y")),
    # Builders by size class.
    ("bankC0/bankC0.asm", "Spr_PrepareTiles", ("JSR Spr_Load4", "JSR Spr_Load8")),
    # Palettes: kinds 3 and 4 share a slot of 0-4 with the same colours, else take a free one.
    ("bankC0/bankC0.asm", "Obj_PalSlotAny",
     ("LDA.w !Obj_PalSlot,X", "CPX.b #!ObjPal_AnyEnd", "AND.b #!ObjPal_AttrMask", "STA.w !Obj_OamAttr,X",
      "LDA.w #!ObjPal_CopyCount", "MVN !Bank7E,!BankE4", "LDA.w !Obj_PalSrc,X", "CMP.w !Obj_PalSrc,X")),
    # The tick: a zero duration restarts the row; mode 2 counts loops (two fewer from 3 up, hold at 1).
    ("bankC0/bankC0.asm", "Obj_AnimTickAndQueue",
     ("DEC.w !Obj_AnimTimer,X", "INC.w !Obj_AnimColumn,X", "ADC.w !Obj_AnimTimeTbl,X", "LDA.l !AnimRom,X",
      "STA.w !Obj_AnimTimer,X", "LDA.l !ObjX_AnimLoops,X", "STA.l !ObjX_AnimLoops,X", "STZ.w !Obj_AnimColumn,X",
      "DEC.w !Obj_AnimColumn,X")),
    # $FF: back to the row's first frame, column $FF (the next step is column 0).
    ("bankC0/bankC0.asm", "Obj_AnimFrameLookup",
     ("CMP.b #!Anim_EndMarker", "LDA.l !ObjX_AnimLoops,X", "SBC.b !Anim_Column", "LDA.b #!Anim_EndMarker",
      "STA.w !Obj_AnimColumn,X")),
)

CONSTANT_CLAIMS = (
    ("include/constants_engine.inc", "!SprRec_FirstNpc = 7"),
    ("include/constants_engine.inc", "!SprRec_Bytes = 5"),
    ("include/constants_engine.inc", "!Frame4_Bytes = $28"),
    ("include/constants_engine.inc", "!Frame8_Bytes = $50"),
    ("include/constants_engine.inc", "!ObjTile_SingleTop = $19"),
    ("include/constants_engine.inc", "!ObjTile_PairFirst = $0C"),
    ("include/constants_engine.inc", "!ObjTile_PairEnd = $18"),
    ("include/constants_engine.inc", "!ObjPal_AnyEnd = $05"),
    ("include/constants_engine.inc", "!ObjQ_Unk71Init = $8000"),
    ("include/constants_engine.inc", "!Spr_UpperOfsY = $E8"),
    ("include/constants_engine.inc", "!EvtSpr_PrioInit = $2020"),
)


# --- Evidence: the ROM's code bytes ---------------------------------------------------------

def code_claims(rom):
    out = []
    op82 = cs._body(rom, 0xC04590, 0xC046DE)
    out.append(("$C0:4590 multiplies the operand by 5 (LDA #$05; STA WRMPYB), reads $E4:F023-$E4:F027 (LDA.l "
                "$E4F0xx,X: record 7 + n) and calls Decomp_ToWramVec once (JSL $C30002)",
                b"\xa9\x05\x8d\x03\x42" in op82 and all(bytes([0xBF, 0x23 + k, 0xF0, 0xE4]) in op82 for k in range(5))
                and op82.count(b"\x22\x02\x00\xc3") == 1, ""))
    op81 = cs._body(rom, 0xC04476, 0xC04556)
    out.append(("$C0:4476 reads $E4:F000-$E4:F004 (LDA.l $E4F00x,X) and unpacks nothing (no JSL)",
                all(bytes([0xBF, k, 0xF0, 0xE4]) in op81 for k in range(5)) and b"\x22" not in op81, ""))
    alloc = cs._body(rom, 0xC06FBA, 0xC07055)
    out.append(("$C0:6FBA starts the single search at slot $19 (LDX #$19) and the pair search at $0C (LDX #$0C), "
                "ending before $18 (CPX #$18)", b"\xa2\x19" in alloc and b"\xa2\x0c" in alloc and b"\xe0\x18" in alloc, ""))
    build8 = cs._body(rom, 0xC0D28A, 0xC0D4F6)
    out.append(("$C0:D28A-$D4F6 multiply the frame by 80 (LDA #$50; STA WRMPYB) and read the pairs after 32 words "
                "(LDY #$0040)", build8.count(b"\xa9\x50\x8d\x03\x42") == 2 and b"\xa0\x40\x00" in build8, ""))
    pal = cs._body(rom, 0xC0721C, 0xC072B3)
    out.append(("$C0:721C searches palette slots below 5 (CPX #$05)", pal.count(b"\xe0\x05") >= 2, ""))
    return out


# --- Evidence: the ROM's data -----------------------------------------------------------------

def data_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    ops = sprite_ops(rom)
    claim("the event packs use opcode $81 for records 0-6 only (the playable characters)",
          sorted(ops[OP_RECORD]) == list(range(SETS)), str(sorted(ops[OP_RECORD])))
    used = sorted(ops[OP_NPC])
    loads = sum(len(v) for v in ops[OP_NPC].values())
    claim(f"opcode $82 loads {len(used)} records (7-{max(used)}) from {len({p for v in ops[OP_NPC].values() for p in v})} "
          f"event packs", used and min(used) >= FIRST_NPC and max(used) < POINTERS, f"{loads} (record, pack) pairs")
    recs = {r: record(rom, r) for r in used}
    sizes = collections.Counter(r["size"] for r in recs.values())
    claim(f"the records $82 loads are of size classes 0 and 1 only ({sizes[0]} and {sizes[1]}): the 4- and 8-OBJ builders",
          set(sizes) <= {0, 1}, str(dict(sizes)))
    odd = sorted(r for r, v in recs.items() if v["sizeByte"] & ~SIZE_MASK)
    claim("the size byte's bits 2-7 are clear except in records " + ", ".join(map(str, odd)) +
          " (no field reader tests them: Obj_SprSize is read AND #3)", True, str([recs[r]["sizeByte"] for r in odd]))
    gfx = sorted({v["gfx"] for v in recs.values()})
    bad, modes = [], collections.Counter()
    for g in gfx:
        try:
            _, mode, _ = pack(rom, g)
            modes[mode] += 1
        except ValueError as e:
            bad.append((g, str(e)))
    claim(f"the {len(gfx)} graphics packs they name unpack (Decomp_ToWram) to whole 4bpp tiles; none is a PC set",
          not bad and min(gfx) >= SETS, f"modes {dict(modes)}; {bad[:3]}")
    blank0 = [g for g in gfx if any(pack(rom, g)[0][0])]
    claim(f"tile 0 of {len(gfx) - len(blank0)} of the {len(gfx)} packs is blank (the field copies tile 0 as it is)", True,
          f"not blank: {blank0[:12]}")
    sizes_ok, past_tiles, past_frames, no_frames, ends = [], [], [], [], collections.Counter()
    for r in used:
        d = decode_npc(rom, r)
        words = [w for f in d["frameList"] for w in f["cells"]]
        if not d["frameList"]:
            no_frames.append(r)
        if any(w & 0x3800 or w & TILE_MASK >= d["tiles"]["count"] for w in words):
            past_tiles.append(r)
        lists = animation_lists(rom, d["fields"]["anim"])
        if len(lists) != len(d["animationList"]):
            past_frames.append(r)
        for a in d["animationList"]:
            ends[a["end"]] += 1
    claim(f"every record $82 loads has frames, and its cells name tiles of its graphics with bits 11-13 clear",
          not no_frames and not past_tiles, f"no frames {no_frames}; bad cells {past_tiles}")
    claim(f"animations naming frames past the frame set are left out ({len(past_frames)} records have some)",
          True, str(past_frames[:12]))
    claim(f"the imported lists end with a zero duration ({ends['zero']}), the $FF marker ({ends['marker']}) or the "
          f"facing's last entry ({ends['end']})", sum(ends.values()) > 0, str(dict(ends)))
    pals = {v["palette"] for v in recs.values()}
    claim(f"their {len(pals)} palettes are 12 BGR555 colours with bit 15 clear",
          all(u16(rom, ANIM_BANK + p * PAL_BYTES + 2 * k) < 0x8000 for p in pals for k in range(PAL_COLOURS)))
    claim("their animation sets index below 255 (AnimFrames[a + 1] exists)", all(v["anim"] < 255 for v in recs.values()))
    odd = {a: anim_shape(rom, a)[0] for a in range(255) if anim_shape(rom, a)[0] % 4}
    enemy_anims = {cs.enemy_record(rom, i)["anim"] for i in range(ENEMY_IDS)}
    claim("animation sets 74 and 76 have facing strides of 5 and 11 entries (AnimFrames gaps of 20 and 44 bytes, not "
          "16 x rows); only NPC records name them, and the field's stride (gap / 4) is used for every set",
          odd == {74: 5, 76: 11} and not set(odd) & enemy_anims and not any(a < SETS for a in odd), str(odd))
    loc = usage(rom)
    claim(f"{sum(1 for v in loc.values() if v['locations'])} of the {len(loc)} records are loaded by a location's event "
          "pack (LocRom .Events)", sum(1 for v in loc.values() if v["locations"]) > 0.9 * len(loc),
          str([r for r, v in loc.items() if not v["locations"]][:10]))
    others = [r for r in nonzero_records(rom) if r not in recs]
    undecodable = []
    for r in others:
        try:
            decode_npc(rom, r)
        except (ValueError, KeyError) as e:
            undecodable.append((r, str(e)[:40]))
    claim(f"the {len(others)} other nonzero records 7-255 (no pack loads them) decode the same way, except "
          f"{len(undecodable)}", True, str(undecodable[:6]))
    return out


# --- Evidence: the field's own code, run ------------------------------------------------------

DP = 0x7E0100
OBJ = 0x10                             # the object slot offset the runs use (object 8)
ADDR = {"Obj_Cur": DP + 0x6D, "ObjQ_Unk71": DP + 0x71, "ObjQ_Unk73": DP + 0x73, "ObjQ_Head": DP + 0x76,
        "ObjQ_Tail": DP + 0x77, "ObjQ_Unk78": DP + 0x78, "VramQ_Pos": DP + 0x79, "Field_E4Ptr0": DP + 0xAF,
        "Obj_Unk1100": 0x7E1100, "Obj_FrameOfs": 0x7E1380, "Obj_FrameBank": 0x7E1300, "Obj_PalSrc": 0x7E1400,
        "Obj_AnimFacingStride": 0x7E1480, "Obj_AnimFrameTbl": 0x7E1500, "Obj_AnimTimeTbl": 0x7E1580,
        "Obj_SprSize": 0x7E1201, "Obj_GfxOfs": 0x7E1280, "Obj_GfxBank": 0x7E1200, "Obj_PrioLow": 0x7E0C00,
        "Obj_PrioHigh": 0x7E0C01, "Obj_AnimRow": 0x7E1680, "Obj_AnimColumn": 0x7E1681, "Obj_Facing": 0x7E1600,
        "Obj_AnimTimer": 0x7E1601, "Obj_QueueNext": 0x7E1081, "Obj_AnimMode": 0x7E1780, "Obj_AnimRowAlt": 0x7E1781,
        "Obj_FixedFrame": 0x7E1301, "Obj_LastFrame": 0x7E0F01, "Obj_State": 0x7E1B00, "Obj_VramTile": 0x7E0D00,
        "Obj_TileRecOfs": 0x7E1700, "Obj_TileBuf": 0x7E0D80, "Obj_OamAttr": 0x7E0F81, "SprBuf_Owner": 0x7E0BC0,
        "Evt_Unk0920": 0x7E0920, "VramQ_SrcA": 0x7E0940, "VramQ_DestA": 0x7E0950, "VramQ_SrcB": 0x7E0960,
        "VramQ_DestB": 0x7E0970, "VramQ_SizeA": 0x7E0980, "VramQ_SizeB": 0x7E0990, "VramQ_Valid": 0x7E09A0,
        "ObjX_AnimLoops": 0x7F0B01, "SprTileSrc": 0x7F4800, "Evt_Data": 0x7F2001}
ENTRY = {"op82": 0xC04590, "build4": 0xC0CBDC, "build8": 0xC0CEF5, "lookup": 0xC0CB3A, "tick": 0xC0C98A}


class FieldRunner:
    """The field's sprite code run by ChronoRET's 65816 interpreter over the
    ROM (ct_tilesets.RomRunner: the multiplier and the WRAM port), with
    DP = $0100 and DB = $00 as the object pass has them."""

    def __init__(self, rom, ref=REF):
        import ct_tilesets
        self.rom = rom
        self.runner = ct_tilesets.RomRunner(rom, ref)
        self.absint = self.runner.absint

    def run(self, entry, known, x8=False, x=0, y=0):
        absint = self.absint
        s = absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, 0, 0, x, y
        s.d, s.db, s.m, s.xf, s.c = 0x0100, 0, True, x8, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        ends = self.runner.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != "rts" or self.runner.machine.opaque:
            raise RuntimeError(f"{[how for _, how in ends]} opaque {self.runner.machine.opaque}")
        return {**known, **ends[0][0].mem}

    @staticmethod
    def blank():
        known = {a: 0 for a in range(0x7E0000, 0x7E2000)}
        for i, base in enumerate((0x2000, 0x2300, 0x2600, 0x2800)):           # RomE4_PtrInit
            at = ADDR["Field_E4Ptr0"] + 3 * i
            known[at], known[at + 1], known[at + 2] = base & 0xFF, base >> 8, 0xE4
        put16(known, ADDR["Obj_Cur"], OBJ)
        put16(known, ADDR["ObjQ_Unk71"], GFX_WRAM & 0xFFFF)
        for k in range(16):
            known[ADDR["Evt_Unk0920"] + k] = 0xFF                             # Evt_Unk0920Free
        return known

    def load(self, r):
        """Evt_Op82_InitWramSprite for record r into object OBJ: the object's fields and the unpacked graphics."""
        known = self.blank()
        y = 0x40
        known[ADDR["Evt_Data"] + y] = OP_NPC
        known[ADDR["Evt_Data"] + y + 1] = r - FIRST_NPC
        mem = self.run(ENTRY["op82"], known, y=y)
        end = get16(mem, ADDR["ObjQ_Unk71"])
        tiles = bytes(mem.get(GFX_WRAM + i) or 0 for i in range(end - (GFX_WRAM & 0xFFFF)))
        fields = {k: get16(mem, ADDR[k] + OBJ) for k in ("Obj_FrameOfs", "Obj_PalSrc", "Obj_AnimFacingStride",
                                                         "Obj_AnimFrameTbl", "Obj_AnimTimeTbl", "Obj_GfxOfs")}
        fields.update({k: mem[ADDR[k] + OBJ] for k in ("Obj_FrameBank", "Obj_SprSize", "Obj_GfxBank", "Obj_PrioLow",
                                                       "Obj_PrioHigh", "Obj_Facing", "Obj_AnimRow", "Obj_AnimColumn")})
        fields["ObjQ_Unk71"] = end
        return fields, tiles, mem

    def build(self, mem, frame, size, vram_tile, rec_ofs, attr=0x04, mode=3, row=0, facing=0, column=0):
        """One frame build of object OBJ over `mem` (a load's result): mode 3
        builds `frame` (Obj_FixedFrame) in one pass; mode 0 builds the frame the
        animation state names (class 1: Pass0 then Pass1). Returns the chunk
        bytes, the VRAM queue entry and the SprTileSrc records."""
        known = {a: v for a, v in mem.items() if v is not None}
        for k in range(8):
            known[ADDR["SprBuf_Owner"] + k] = 0x80
        for a in range(0x7E0940, 0x7E09A4):
            known[a] = 0
        known[ADDR["VramQ_Pos"]] = 0
        known[ADDR["Obj_AnimMode"] + OBJ] = mode
        known[ADDR["Obj_FixedFrame"] + OBJ] = frame
        known[ADDR["Obj_LastFrame"] + OBJ] = 0xFF if frame != 0xFF else 0xFE
        known[ADDR["Obj_State"] + OBJ] = 0
        known[ADDR["Obj_AnimRow"] + OBJ], known[ADDR["Obj_AnimColumn"] + OBJ] = row, column
        known[ADDR["Obj_Facing"] + OBJ] = facing
        put16(known, ADDR["Obj_VramTile"] + OBJ, vram_tile)
        put16(known, ADDR["Obj_TileRecOfs"] + OBJ, rec_ofs)
        known[ADDR["Obj_OamAttr"] + OBJ] = attr
        entry = ENTRY["build4"] if size == 0 else ENTRY["build8"]
        mem = self.run(entry, known, x8=True, x=OBJ)
        if size == 1 and mode != 3:                                          # Pass1 on the next call
            mem = self.run(entry, {a: v for a, v in mem.items() if v is not None}, x8=True, x=OBJ)
        buf = get16(mem, ADDR["Obj_TileBuf"] + OBJ)
        chunks = 1 if size == 0 else 2
        chunk = bytes(mem.get(0x7F0000 + buf + i) or 0 for i in range(0x200 * chunks))
        queue = tuple(get16(mem, ADDR[k]) for k in ("VramQ_DestA", "VramQ_DestB", "VramQ_SrcA", "VramQ_SrcB",
                                                    "VramQ_SizeA", "VramQ_SizeB"))
        objs = FIELD_LAYOUTS[size][3]
        src = []
        for n in range(objs):
            at = ADDR["SprTileSrc"] + rec_ofs + 8 * n
            src.append((get16(mem, at + 2), mem.get(at + 4), mem.get(at + 6), mem.get(at + 7)))
        return chunk, queue, src, mem.get(ADDR["Obj_LastFrame"] + OBJ), buf

    def lookup(self, mem, row, facing, column):
        """Obj_AnimFrameLookup: (C, frame, column after)."""
        known = {a: v for a, v in mem.items() if v is not None}
        known[ADDR["Obj_AnimMode"] + OBJ] = 0
        known[ADDR["Obj_AnimRow"] + OBJ], known[ADDR["Obj_AnimColumn"] + OBJ] = row, column
        known[ADDR["Obj_Facing"] + OBJ] = facing
        known[DP + 0xD8] = 0xE4                                             # Anim_FramePtr's bank (the builders set it)
        return self.run_state(ENTRY["lookup"], known)

    def run_state(self, entry, known):
        absint = self.absint
        s = absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, 0, 0, OBJ, 0
        s.d, s.db, s.m, s.xf, s.c = 0x0100, 0, True, True, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        ends = self.runner.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != "rts" or self.runner.machine.opaque:
            raise RuntimeError(f"{[how for _, how in ends]} opaque {self.runner.machine.opaque}")
        st = ends[0][0]
        return {**known, **st.mem}, st.a, st.c

    def ticks(self, mem, row, n, mode=0, loops=0):
        """Obj_AnimTickAndQueue called n times from the load's state (timer 0,
        column 0; kind 4), the queue emptied between calls as
        Field_ProcessAnimQueue leaves it: [(column, timer)] after each."""
        known = {a: v for a, v in mem.items() if v is not None}
        known[ADDR["Obj_AnimMode"] + OBJ] = mode
        known[ADDR["Obj_AnimRow"] + OBJ] = row
        known[ADDR["Obj_AnimRowAlt"] + OBJ] = row
        known[ADDR["Obj_AnimColumn"] + OBJ] = 0
        known[ADDR["Obj_AnimTimer"] + OBJ] = 0
        known[ADDR["Obj_Unk1100"] + OBJ] = 4
        known[ADDR["ObjX_AnimLoops"] + OBJ] = loops
        out = []
        for _ in range(n):
            known[ADDR["ObjQ_Head"]] = known[ADDR["ObjQ_Tail"]] = 0x80
            known[ADDR["Obj_QueueNext"] + OBJ] = 0x80
            mem2, _, _ = self.run_state(ENTRY["tick"], known)
            known = {a: v for a, v in mem2.items() if v is not None}
            out.append((known[ADDR["Obj_AnimColumn"] + OBJ], known[ADDR["Obj_AnimTimer"] + OBJ],
                        known.get(ADDR["ObjX_AnimLoops"] + OBJ, 0)))
        return out


def put16(mem, at, v):
    mem[at], mem[at + 1] = v & 0xFF, v >> 8 & 0xFF


def get16(mem, at):
    lo, hi = mem.get(at), mem.get(at + 1)
    return None if lo is None or hi is None else lo | hi << 8


# --- The model the runs are compared with -----------------------------------------------------

def expected_load(rom, r):
    rec = record(rom, r)
    frames_at = u24(rom, FRAMES_PTR + 3 * rec["frames"])
    af, af2 = u16(rom, ANIM_FRAMES + 2 * rec["anim"]), u16(rom, ANIM_FRAMES + 2 * rec["anim"] + 2)
    tb, _, _ = pack(rom, rec["gfx"])
    fields = {"Obj_FrameOfs": frames_at & 0xFFFF, "Obj_FrameBank": frames_at >> 16, "Obj_PalSrc": rec["palette"] * PAL_BYTES,
              "Obj_AnimFacingStride": ((af2 - af) & 0xFFFF) >> 2, "Obj_AnimFrameTbl": af,
              "Obj_AnimTimeTbl": u16(rom, ANIM_DURS + 2 * rec["anim"]), "Obj_SprSize": rec["sizeByte"],
              "Obj_GfxOfs": GFX_WRAM & 0xFFFF, "Obj_GfxBank": GFX_WRAM >> 16, "Obj_PrioLow": PRIO_INIT,
              "Obj_PrioHigh": PRIO_INIT, "Obj_Facing": 1, "Obj_AnimRow": 0, "Obj_AnimColumn": 0,
              "ObjQ_Unk71": (GFX_WRAM & 0xFFFF) + TILE_BYTES * len(tb)}
    return fields, b"".join(tb)


def expected_build(frame, tile_bytes, size, vram_tile, attr=0x04):
    """The chunk (cells in record order, mirrored ones bit-reversed per byte,
    tile 0 copied as it is), the VRAM queue (row 0 to T, row 1 to T + 16) and
    the SprTileSrc records (offset, tile T + 2n, attribute)."""
    columns, rows, _, objs = FIELD_LAYOUTS[size]
    chunk = b""
    for w in frame["cells"]:
        raw = tile_bytes[w & TILE_MASK]
        chunk += bytes(BIT_REVERSE[b] for b in raw) if w & HFLIP else raw
    half = TILE_BYTES * columns
    queue = (vram_tile * 16, vram_tile * 16 + VRAM_ROW_WORDS, 0x3800, 0x3800 + half, half, half)
    src = []
    for n, (x, y) in enumerate(frame["pieces"]):
        high = (y & 0xFF) >= UPPER_OFS_Y if size == 0 else n >= 4
        src.append((x & 0xFFFF, y & 0xFF, (vram_tile + 2 * n) & 0xFF, attr | vram_tile >> 8 | PRIO_INIT))
        assert high in (True, False)
    return chunk, queue, src


class Clock:
    """Obj_AnimTickAndQueue and Obj_AnimFrameLookup for one object's list, as
    the field runs them once a frame (the Swift twin is CTNPCSprites.FieldClock).
    State after a load or a new row: column 0, timer 0."""

    def __init__(self, ids, durations, row_start=0, mode=0, loops=0):
        self.ids, self.durs = ids, durations                  # the facing's ids and the shared durations, by entry
        self.start, self.mode, self.loops = row_start, mode, loops
        self.column, self.timer = 0, 0

    def tick(self):
        if self.timer:
            self.timer -= 1
            if self.timer:
                return
        self.column = (self.column + 1) & 0xFF
        d = self.durs[(self.start + self.column) & 0xFFFF] if self.start + self.column < len(self.durs) else 0
        if d:
            self.timer = d
            return
        self.timer = self.durs[self.start]
        if self.mode == 2:
            if self.loops == 1:
                self.column = (self.column - 1) & 0xFF
                return
            if self.loops == 2:
                self.loops = 1
                self.column = (self.column - 1) & 0xFF
                return
            self.loops -= 2
        self.column = 0

    def frame(self):
        """The frame the builder shows now (a $FF entry: the row's first, column $FF)."""
        i = self.ids[self.start + self.column] if self.start + self.column < len(self.ids) else END_MARKER
        if i == END_MARKER:
            self.column = 0xFF
            return self.ids[self.start]
        return i


def run_claims(rom, ref=REF, records=None):
    runner = FieldRunner(rom, ref)
    out = []
    used = sorted(sprite_ops(rom)[OP_NPC]) if records is None else records
    load_bad, frames, frames_bad, steps, steps_bad, anim_runs, tick_bad, two_pass = [], 0, [], 0, [], 0, [], 0
    for r in used:
        d = decode_npc(rom, r)
        fields, tiles, mem = runner.load(r)
        want_fields, want_tiles = expected_load(rom, r)
        if fields != want_fields or tiles != want_tiles:
            load_bad.append((r, {k: (fields[k], want_fields[k]) for k in fields if fields[k] != want_fields[k]},
                             tiles == want_tiles))
            continue
        tb, _, _ = pack(rom, d["fields"]["gfx"])
        size = d["fields"]["size"]
        vram = SLOT_TILE[size]
        rec_ofs = (SINGLE_TOP if size == 0 else PAIR_FIRST) * 0x20
        for f, frame in enumerate(d["frameList"]):
            chunk, queue, src, last, buf = runner.build(mem, f, size, vram, rec_ofs)
            want = expected_build(frame, tb, size, vram)
            frames += 1
            if (chunk, queue, src) != want or last != f or buf != 0x3800:
                frames_bad.append((r, f))
        # Animations: the lookup at every step, the two-pass builder (class 1) at each list's first step,
        # and the tick against the Clock for two passes of the list.
        stride = d["animations"]["stride"]
        ids_at = ANIM_BANK + u16(rom, ANIM_FRAMES + 2 * d["fields"]["anim"])
        durs_at = ANIM_BANK + u16(rom, ANIM_DURS + 2 * d["fields"]["anim"])
        for a in d["animationList"]:
            for k, want in enumerate(a["frames"]):
                m2, frame_a, c = runner.lookup(mem, a["row"], a["facing"], k)
                steps += 1
                if not c or frame_a & 0xFF != want:
                    steps_bad.append((r, a["id"], k))
            if a.get("end") == "marker":
                m2, frame_a, c = runner.lookup(mem, a["row"], a["facing"], len(a["frames"]))
                steps += 1
                if not c or frame_a & 0xFF != a["frames"][0] or m2[ADDR["Obj_AnimColumn"] + OBJ] != 0xFF:
                    steps_bad.append((r, a["id"], "marker"))
            if size == 1 and a is d["animationList"][0]:
                chunk, queue, src, last, _ = runner.build(mem, 0, size, vram, rec_ofs, mode=0, row=a["row"],
                                                          facing=a["facing"])
                two_pass += 1
                if (chunk, queue, src) != expected_build(d["frameList"][a["frames"][0]], tb, size, vram):
                    frames_bad.append((r, a["id"], "two-pass"))
        for a in d["animationList"][:2]:
            ids = [u8(rom, ids_at + a["facing"] * stride + e) for e in range(stride)]
            durs = [u8(rom, durs_at + e) for e in range(stride)]
            cycle = sum(a["durations"]) + a.get("markerDuration", 0)
            n = min(2 * cycle + 2, 400)
            for mode, loops in ((0, 0), (2, 4)):
                got = runner.ticks(mem, a["row"], n, mode=mode, loops=loops)
                clock = Clock(ids, durs, 4 * a["row"], mode=mode, loops=loops)
                want = []
                for _ in range(n):
                    clock.tick()
                    want.append((clock.column, clock.timer, clock.loops if mode == 2 else 0))
                anim_runs += 1
                if [g[:2] + ((g[2],) if mode == 2 else (0,)) for g in got] != want:
                    tick_bad.append((r, a["id"], mode))
    out.append((f"Evt_Op82_InitWramSprite ($C0:4590, run) for the {len(used)} records the event packs load: the "
                "object's frame, palette, animation and size fields and the graphics unpacked to $7F:8000 = the decode",
                not load_bad, str(load_bad[:3])))
    out.append((f"Obj_BuildFrame4 / Obj_BuildFrame8 (run, fixed frame) for {frames} frames, and the two-pass build "
                f"of {two_pass} class-1 animations: the SprBuf chunk, the VRAM queue (rows at T and T + 16) and the "
                "OBJ records (offset, tile T + 2n, attribute) = the model", frames and not frames_bad, str(frames_bad[:5])))
    out.append((f"Obj_AnimFrameLookup (run) at {steps} steps of the imported lists ($FF: the row's first frame, "
                "column $FF) = the decode", steps and not steps_bad, str(steps_bad[:5])))
    out.append((f"Obj_AnimTickAndQueue (run, {anim_runs} lists over two passes, plain and counted loops from 4) = "
                "the Clock model", anim_runs and not tick_bad, str(tick_bad[:5])))
    return out


# --- Synthetic vectors for the Swift twin ----------------------------------------------------

VECTORS = cs.VECTORS.parent / "npc_sprite_vectors.json"


def synthetic_npc_rom():
    """The synthetic enemy image plus three synthetic NPC records (classes 0
    and 1 on packed graphics), as (regions, expected decodes, clock runs)."""
    regions, _ = cs.synthetic_enemy_rom()
    rng = cs.Lcg(0x4E9C)
    # Graphics 20 and 21 in bank $D6.
    gfx = {20: 26, 21: 40}
    gfx_at = {20: 0xD60000, 21: 0xD68000}
    for g, n in gfx.items():
        raw = bytes(rng.next(256) if rng.next(3) else 0 for _ in range(32 * n))
        regions[gfx_at[g]] = cs.pack_literals(raw)
    old = regions[TILES_PTR]
    table = [int.from_bytes(old[3 * i:3 * i + 3], "little") for i in range(len(old) // 3)]
    table += [0] * (22 - len(table))
    table[20], table[21] = gfx_at[20], gfx_at[21]
    regions[TILES_PTR] = b"".join(v.to_bytes(3, "little") for v in table)
    # Frame sets 20 (class 0, 5 frames) and 21 (class 1, 4 frames) in bank $DF; entry 22 ends set 21.
    sets = {20: (0, 5, gfx[20]), 21: (1, 4, gfx[21])}
    at, frame_ptrs = 0xDF0000, {}
    for fs, (size, n, ntiles) in sets.items():
        columns, rows, record_bytes, objs = FIELD_LAYOUTS[size]
        frame_ptrs[fs] = at
        recs = b""
        for f in range(n):
            words = [(rng.next(ntiles) if rng.next(4) else 0) | (HFLIP if rng.next(3) == 0 else 0)
                     for _ in range(columns * rows)]
            recs += b"".join(w.to_bytes(2, "little") for w in words) + bytes((rng.next(64) - 40) & 0xFF for _ in range(2 * objs))
        regions[at] = recs
        at += len(recs)
    frame_ptrs[22] = at
    old = regions[FRAMES_PTR]
    table = [int.from_bytes(old[3 * i:3 * i + 3], "little") for i in range(len(old) // 3)]
    table += [0] * (23 - len(table))
    for k, v in frame_ptrs.items():
        table[k] = v
    regions[FRAMES_PTR] = b"".join(v.to_bytes(3, "little") for v in table)
    # Records 7 (class 0), 8 (class 1, sharing animation set 4 with enemy 1) and 9 (class 0 on graphics 20 again).
    recs = {7: (20, 20, 4, 3, 0x00), 8: (21, 21, 5, 4, 0x01), 9: (20, 20, 6, 4, 0x04)}
    old = bytearray(regions[SPR_REC])
    old += bytes(5 * 10 - len(old))
    for r, b in recs.items():
        old[5 * r:5 * r + 5] = bytes(b)
    regions[SPR_REC] = bytes(old)
    pal = regions[ANIM_BANK]
    regions[ANIM_BANK] = pal + b"".join(rng.next(0x8000).to_bytes(2, "little") for _ in range(4 * PAL_COLOURS))
    image = bytearray(cs.ROM_SIZE)
    for long, data in regions.items():
        image[pc(long):pc(long) + len(data)] = data
    image = bytes(image)
    expect = []
    for r in recs:
        d = decode_npc(image, r)
        tb, _, _ = pack(image, d["fields"]["gfx"])
        d["tileIndices"] = bytes(v for t in tb for v in cs.tile_indices(t)).hex()
        expect.append(d)
    # Clock runs: synthetic lists, plain and counted.
    clocks = []
    for ids, durs, mode, loops in (([1, 2, 3, 0], [4, 2, 6, 0], 0, 0), ([5, 6, END_MARKER, 0], [3, 1, 7, 0], 0, 0),
                                   ([1, 2, 3, 0], [2, 3, 1, 0], 2, 5), ([4, END_MARKER, 0, 0], [2, 5, 0, 0], 2, 2),
                                   ([7, 8, 9, 0], [1, 1, 1, 0], 2, 1)):
        c = Clock(ids, durs, mode=mode, loops=loops)
        seq = []
        for _ in range(30):
            c.tick()
            seq.append([c.column, c.timer, c.frame()])
        clocks.append({"ids": ids, "durations": durs, "mode": mode, "loops": loops, "ticks": seq})
    return regions, expect, clocks


def vectors_text():
    regions, expect, clocks = synthetic_npc_rom()
    head = {"schema": "ct-npc-sprite-vectors/1",
            "note": "synthetic NPC records over the synthetic enemy and PC images (no ROM data); expected decode "
                    "and field clock by re_workspace/tools/ct_npc_sprites.py",
            "regions": [{"at": snes(k), "hex": v.hex()} for k, v in sorted(regions.items())]}
    text = "{\n" + ",\n".join(f' "{k}": {json.dumps(v, separators=(",", ":"))}' for k, v in head.items())
    text += ',\n "npcs": [\n' + ",\n".join("  " + json.dumps(d, separators=(",", ":")) for d in expect) + "]"
    return text + ',\n "clocks": [\n' + ",\n".join("  " + json.dumps(c, separators=(",", ":")) for c in clocks) + "]}\n"


# --- A Studio import against the decode ------------------------------------------------------

def verify_import(rom, project):
    from PIL import Image
    wanted = sorted(sprite_ops(rom)[OP_NPC])
    loc = usage(rom)
    bad = {k: [] for k in ("present", "frames", "animations", "palette", "stream", "sheet", "usage")}
    for r in wanted:
        path = Path(project) / "sprites" / f"{npc_id(r)}.sprite.json"
        if not path.exists():
            bad["present"].append(r)
            continue
        s = json.loads(path.read_text())
        d = decode_npc(rom, r)
        lay = d["layout"]
        ok = len(s["frames"]) == d["frames"]["count"] and s["rom"]["family"] == FAMILY and s["rom"]["set"] == r \
            and s["rom"]["layout"] == lay["index"] and s["rom"].get("packed") is True
        for f, g in zip(s["frames"], d["frameList"]):
            ok = ok and f["cells"] == g["cells"] and [[t["x"], t["y"]] for t in f["tiles"]] == g["pieces"] and \
                [t["tile"] for t in f["tiles"]] == [2 * n for n in range(lay["objs"])] and \
                all(t["size16"] and not t["hflip"] and not t["vflip"] for t in f["tiles"])
        if not ok:
            bad["frames"].append(r)
        keys = ("id", "row", "facing", "frames", "durations")
        got = [{k: a[k] for k in keys} | ({"markerDuration": a["markerDuration"]} if "markerDuration" in a else {})
               for a in s["animations"]]
        want = [{k: a[k] for k in keys} | ({"markerDuration": a["markerDuration"]} if "markerDuration" in a else {})
                for a in d["animationList"]]
        if got != want:
            bad["animations"].append(r)
        if [int(w, 16) for w in s["palettes"][0]] != [0] + palette(rom, r) + [0, 0, 0]:
            bad["palette"].append(r)
        stream = s.get("stream") or {}
        if (stream.get("columns"), stream.get("rows"), stream.get("baseTile")) != (lay["columns"], lay["rows"], d["slotTile"]):
            bad["stream"].append(r)
        field = s.get("field") or {}
        if field.get("packs") != loc[r]["packs"] or field.get("locations") != loc[r]["locations"] or \
                field.get("size") != d["fields"]["sizeByte"]:
            bad["usage"].append(r)
        sheet = Image.open(Path(project) / s["sheet"])
        tb, _, _ = pack(rom, d["fields"]["gfx"])
        cols = sheet.width // 8
        px = sheet.load()
        if not (sheet.mode == "P" and sheet.width == 128 and all(
                [px[(t % cols) * 8 + k % 8, (t // cols) * 8 + k // 8] for k in range(64)] == cs.tile_indices(tb[t])
                for t in range(len(tb)))):
            bad["sheet"].append(r)
    n = len(wanted)
    return [
        (f"npcs: the {n} records the event packs load imported as sprites/npc_NNN.*", not bad["present"],
         cs._first(bad["present"])),
        (f"npcs: frames, cells, OBJ offsets and OBJ tiles 2n as decoded ({n})", not bad["frames"], cs._first(bad["frames"])),
        (f"npcs: animations (and the $FF marker's duration) as decoded ({n})", not bad["animations"],
         cs._first(bad["animations"])),
        (f"npcs: palette = 0 + the 12 ROM colours + 3 zeros ({n})", not bad["palette"], cs._first(bad["palette"])),
        (f"npcs: streamed cells at the first tile slot ($188 or $C0) ({n})", not bad["stream"], cs._first(bad["stream"])),
        (f"npcs: the event packs and locations that load each record, and its size byte ({n})", not bad["usage"],
         cs._first(bad["usage"])),
        (f"npcs: sheet holds the record's unpacked tiles, 16 per row ({n})", not bad["sheet"], cs._first(bad["sheet"])),
    ]


# --- CLI --------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    d = sub.add_parser("decode")
    d.add_argument("record", type=int, choices=range(FIRST_NPC, POINTERS))
    d.add_argument("--rom", default=str(ROM_PATH))
    for name in ("usage", "sharing"):
        sub.add_parser(name).add_argument("--rom", default=str(ROM_PATH))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(ROM_PATH))
    k.add_argument("--run", action="store_true", help="also run the field's loader, frame builders, lookup and tick")
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
    rom = cs.read_rom(args.rom)
    if args.command == "decode":
        print(json.dumps(decode_npc(rom, args.record), indent=1))
        return 0
    if args.command == "usage":
        print(json.dumps({str(r): v for r, v in usage(rom).items()}, indent=1))
        return 0
    if args.command == "sharing":
        print(json.dumps({str(r): v for r, v in sharing(rom).items()}, indent=1))
        return 0
    if args.command == "verify-import":
        return cs.report(verify_import(rom, args.project))
    claims = cs.asm_claims(routines=ASM_CLAIMS, constants=CONSTANT_CLAIMS) + code_claims(rom) + data_claims(rom)
    if args.run:
        claims += run_claims(rom)
    return cs.report(claims)


if __name__ == "__main__":
    sys.exit(main())
