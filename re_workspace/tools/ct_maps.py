#!/usr/bin/env python3
"""Chrono Trigger location maps: header, the three tile planes, the tile-property planes, exits, treasure, evidence.

A location's LocRom record ($F6:0000, 14 B) is read by the location load. The
fields that draw or bound the map are read by matched, commented ChronoRET
routines (MIT; refs/ChronoRET):

  .Music       (+0)   LocLoad_AudioSetup sends it with Audio_CmdPlayMusic; bit 7 = keep
  .Tileset12   (+1)   layers 1/2 graphics and metatiles (ct_tilesets.py)
  .Tileset3    (+2)   layer 3 graphics and metatiles; $FF = none, and then
                      LocLoad_UnkA33B keeps only BG1/BG2/OBJ on both screens
  .Palette     (+3)   LocPal_Rom entry (ct_tilesets.py)
  .MapProps    (+4)   16-bit Map_PropsPtrs entry ($F6:1E00): the packed map
  .Unk06       (+6)   not read by a matched routine (0 in every record)
  .Events      (+8)   Evt_PackPtrs entry: the location's event data
  .Limit*      (+A-D) the camera limits (Map_InitMasksAndLimits); LimitLeft
                      bit 7 = the edges of layer 1 instead

MapProps (LocLoad_UnkA33B $C0:A33B unpacks it with Decomp_ToWram to $7E:B500):

  +0 Size1      layer 1 width ((n & 3) + 1) x 16, height ((n & $C) + 4) x 4;
                layer 2 width (n & $30) + 16, height (n & $C0) / 4 + 16 (metatiles)
  +1 Size3      layer 3 size as layer 1's; bit 4/5 layer 2/3 moves by its own
                step only (no camera step), bit 6 layer 2 at half rate, bit 7 a
                layer-3 plane follows
  +2 Move2      layer 2's own step per frame: bits 0-2 n: X 1 << (n - 1), bit 3
                negative; bits 4-6 / 7 the same for Y
  +3 Move3      the same for layer 3
  +4 Screens    bits 0-2 BG1-3 and bit 3 OBJ on the main screen (TM), bits 4-7
                the same for the sub screen (TS)
  +5 ColorMath  CGADSUB (Ppu_ApplyMapScreens writes TM, TS, CGADSUB)
  +6 ...        Map_UnpackTilePlanes: layer 1, layer 2 and (Size3 bit 7) layer 3
                metatile bytes row by row, then over layer 1's size the
                triples (HiBits, AttrA, AttrB), a HiBits byte with bit 7 a run:
                (HiBits & $7F, AttrA, AttrB) for a count (0 = 256) of tiles

Tile properties, as the field code reads them:

  HiBits  bit 0 / 1: bit 8 of the layer-1 / layer-2 metatile (Map_WriteRow1/2);
          bits 2-7: the shape (Map_ProbeTileLevel): 0 half A, 1 half B, 2-$17
          a sloped line splits A and B, $18-$1D B in a half or quarter, $1E
          half A and the Y step is cut to +-1 (Map_ProbeShape1E), $1F-$3F half A
  AttrA   bits 0-1 push direction (0 up, 1 down, 2 left, 3 right), bits 2-3
          push speed (0 none, then $08/$10/$20), bit 4 starts a tile
          animation, bit 6 the leader's low-half OAM priority (2 or 3)
  AttrB   bits 0-1 / 3-4 the level of half A / B, bit 2 / 5 their no-level
          bits, bit 6 the high-half OAM priority, bit 7 blocks objects moved
          by event scripts (Obj_SetVelocityChecked, Evt_PushTarget).
          Map_ProbeLevelBlocked: level 0 blocks; level 3 lets anyone
          through; level 1 or 2 lets through a leader on that level or on 3;
          stepping on a half with a level puts the leader on it. A no-level
          half blocks only a leader on level 3 and keeps the leader's level.
  AttrA bits 5 and 7 are read by nothing traced; they are kept raw.
  A treasure tile blocks the leader (Map_ProbeTileAttrs).

Exits: ExitRom ($E5:0000) records of 7 B from ExitRom_LocOfs[location] up to
the next location's (Map_LoadExitTiles $C0:A66B): tile X, tile Y, span
(bits 0-6 tiles after the first, bit 7 down the column), destination
location (9 bits), facing (bits 1-4 of byte 4), destination X/Y.
Treasure: TreasureRom ($F5:0000) records of 4 B (Map_LoadTreasureTiles
$C0:A712): tile (row << 8 | column), contents (bit 15 gold x 2, bit 14
nothing, else an item). Save points and encounters are not map data: they
are event objects (the location's Events entry).

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_maps.py decode <location> [--rom PATH]           one location as JSON (planes summarized)
    ct_maps.py check [--rom PATH] [--run]               every evidence claim (exit 1 on a failure);
                                                        --run also runs LocLoad_UnkA33B, Map_LoadTreasureTiles
                                                        and Ppu_SetBgLayout in ChronoRET's interpreter
    ct_maps.py verify-import <project> [--rom PATH] [--content]
                                                        a Studio import (maps/*) against decode; --content
                                                        skips the rom provenance (a ROM built from it)
    ct_maps.py vectors (--out | --check) P              synthetic vectors for the Swift twin
"""

import argparse
import json
import re
import struct
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_tilesets as ts  # noqa: E402
from ct_tilesets import REF, ROM_PATH, pc, snes, u8, u16, u24, unpack, unpack_bytes, read_rom, report  # noqa: E402

WS = ts.WS

# --- Tables ----------------------------------------------------------------------------

LOC_ROM, LOC_COUNT, LOC_BYTES = ts.LOC_ROM, ts.LOC_COUNT, ts.LOC_BYTES
NONE = ts.NONE
MAP_PROPS_PTRS, MAP_PROPS_COUNT = ts.MAP_PROPS_PTRS, ts.MAP_PROPS_COUNT
EXIT_OFS, EXIT_BANK, EXIT_BYTES = 0xE50000, 0xE50000, 7              # !ExitRom_LocOfs, struct ExitRom
TREASURE_OFS, TREASURE_BANK, TREASURE_BYTES = 0xF5F000, 0xF50000, 4  # !TreasureRom_LocOfs, struct TreasureRom
LIMITS_NONE = 0x80                                                   # LocRom.LimitLeft bit 7
SPAN_COLUMN, SPAN_LEN = 0x80, 0x7F                                   # !Exit_SpanLenMask
RUN_FLAG, RUN_MASK = 0x80, 0x7F                                      # !Map_RunFlagMask
EXIT_NONE = TREASURE_NONE = 0x80                                     # !Map_ExitNone / !Map_TreasureNone
DEST_WORLD = 0x1F0                                                   # destinations from here on: no LocRom map

# The field's BG layout (Ppu_SetBgLayout, LocLoad_DrawMap): mode 1, BG3 high
# priority, BG1/2 characters at $1000, BG3's at $5000, CGWSEL adds the sub
# screen, COLDATA black; the tilemaps the map is drawn into.
BGMODE, BG12NBA, BG34NBA, CGWSEL, COLDATA = 0x09, 0x11, 0x05, 0x02, 0xE0
TILEMAP_VRAM = {1: 0x6000, 2: 0x6800, 3: 0x7000}                     # !Map_VramTilemap1/2/3

SHAPES = {0: "half-a", 1: "half-b", 0x18: "left-b", 0x19: "top-b", 0x1A: "bottom-left-b",
          0x1B: "bottom-right-b", 0x1C: "top-right-b", 0x1D: "top-left-b", 0x1E: "stair"}


def shape_name(n):
    if n in SHAPES:
        return SHAPES[n]
    return "slope" if 2 <= n <= 0x17 else "half-a"


# --- Header ------------------------------------------------------------------------------

def header(rom, i):
    """The LocRom record of location i."""
    at = LOC_ROM + LOC_BYTES * i
    b = [u8(rom, at + k) for k in range(LOC_BYTES)]
    return {"at": snes(at), "music": b[0], "tileset12": b[1], "tileset3": b[2], "palette": b[3],
            "mapProps": b[4] | b[5] << 8, "unk06": b[6] | b[7] << 8, "events": b[8] | b[9] << 8,
            "limits": {"left": b[10], "top": b[11], "right": b[12], "bottom": b[13]}}


def layer_sizes(size1, size3):
    """{layer: (width, height)} in metatiles (LocLoad_UnkA33B)."""
    return {1: (((size1 & 3) + 1) * 16, ((size1 & 0x0C) + 4) * 4),
            2: ((size1 & 0x30) + 0x10, ((size1 & 0xC0) >> 2) + 0x10),
            3: (((size3 & 3) + 1) * 16, ((size3 & 0x0C) + 4) * 4)}


def wrap_mask(n):
    """Map_InitMasksAndLimits: $40 and $30 wrap at 64, $20 at 32, else 16."""
    return 0x3F if n in (0x30, 0x40) else 0x1F if n == 0x20 else 0x0F


def own_step(byte):
    """(X, Y) per-frame steps of a Move2/Move3 byte (signed)."""
    def one(n, neg):
        if not n:
            return 0
        v = 1 << (n - 1)
        return -v if neg else v
    return one(byte & 7, byte & 8), one(byte >> 4 & 7, byte & 0x80)


def screens(props, tileset3):
    """TM, TS and CGADSUB as LocLoad_UnkA33B makes them."""
    s = props["screens"]
    tm = (s & 7) | (s & 8) << 1
    ts_ = (s >> 4 & 7) | (s & 0x80) >> 3
    if tileset3 == NONE:                                  # Field_UnkBB: no layer 3 loaded
        tm &= 0x13
        ts_ &= 0x13
    return tm, ts_, props["colorMath"]


# --- Map props ---------------------------------------------------------------------------

def parse_props(data):
    """A MapProps image: the header fields, planes and tile-property triples
    (Map_UnpackTilePlanes), and how many bytes the parse used. When the data
    ends before the triples cover layer 1, the routine reads on into WRAM
    past the map; those `staleTiles` (the last ones) are decoded from zeros."""
    if len(data) < 6:
        raise ValueError("MapProps shorter than its header")
    s1, s3 = data[0], data[1]
    sizes = layer_sizes(s1, s3)
    out = {"size1": s1, "size3": s3, "move2": data[2], "move3": data[3], "screens": data[4], "colorMath": data[5],
           "sizes": sizes, "layer3Plane": bool(s3 & 0x80), "halfRate2": bool(s3 & 0x40),
           "ownStep2": bool(s3 & 0x10), "ownStep3": bool(s3 & 0x20)}
    at = 6
    planes = {}
    for layer in (1, 2, 3):
        if layer == 3 and not s3 & 0x80:
            continue
        w, h = sizes[layer]
        if at + w * h > len(data):
            raise ValueError(f"layer {layer} plane runs past the data")
        planes[layer] = list(data[at:at + w * h])
        at += w * h
    w1, h1 = sizes[1]
    n = w1 * h1
    hi, a, b = [], [], []
    entries = runs = 0
    end = len(data)
    data = bytes(data) + bytes(4 * n)                     # past the end: what WRAM holds there, taken as 0
    stale = None
    while len(hi) < n:
        if at >= end and stale is None:
            stale = len(hi)
        first = data[at]
        if first & RUN_FLAG:
            if at + 4 > end and stale is None:
                stale = len(hi)
            count = data[at + 3] or 256
            take = min(count, n - len(hi))               # the routine returns mid-run at the plane's end
            hi += [first & RUN_MASK] * take
            a += [data[at + 1]] * take
            b += [data[at + 2]] * take
            at += 4
            runs += 1
        else:
            if at + 3 > end and stale is None:
                stale = len(hi)
            hi.append(first)
            a.append(data[at + 1])
            b.append(data[at + 2])
            at += 3
        entries += 1
    for r in range(sizes[1][1]):                           # bit 8 from HiBits
        for c in range(w1):
            planes[1][r * w1 + c] |= (hi[r * w1 + c] & 1) << 8
    w2, h2 = sizes[2]
    for r in range(min(h1, h2)):
        for c in range(min(w1, w2)):
            planes[2][r * w2 + c] |= (hi[r * w1 + c] >> 1 & 1) << 8
    out.update({"planes": planes, "hiBits": hi, "attrA": a, "attrB": b, "entries": entries, "runs": runs,
                "used": min(at, end), "length": end, "staleTiles": 0 if stale is None else n - stale})
    return out


def props_pointer(rom, entry):
    return u24(rom, MAP_PROPS_PTRS + 3 * entry)


def decode_props(rom, entry):
    at = props_pointer(rom, entry)
    data, mode, packed = unpack(rom, at)
    p = parse_props(data)
    p.update({"entry": entry, "at": snes(at), "packedBytes": packed, "mode": mode})
    return p


def pack_props(p):
    """The unpacked MapProps image of a parsed map: the header, the planes and
    the triples, a run for each stretch of 2+ equal tiles (up to 256). This is
    one valid encoding; the ROM's own runs may be split differently."""
    out = bytearray([p["size1"], p["size3"], p["move2"], p["move3"], p["screens"], p["colorMath"]])
    for layer in (1, 2, 3):
        if layer in p["planes"]:
            out += bytes(v & 0xFF for v in p["planes"][layer])
    # HiBits bit 7 starts a run, so a tile cannot keep it: shapes stop at $1F.
    hi, a, b = [v & 0x7F for v in p["hiBits"]], p["attrA"], p["attrB"]
    i = 0
    while i < len(hi):
        j = i + 1
        while j < len(hi) and j - i < 256 and (hi[j], a[j], b[j]) == (hi[i], a[i], b[i]):
            j += 1
        if j - i >= 2:
            out += bytes([hi[i] | RUN_FLAG, a[i], b[i], (j - i) & 0xFF])
        else:
            out += bytes([hi[i], a[i], b[i]])
        i = j
    return bytes(out)


# --- Exits and treasure ------------------------------------------------------------------------

def exit_records(rom, i):
    """[(offset, 7 bytes)] of location i (ExitRom_LocOfs[i] up to [i + 1])."""
    first, end = u16(rom, EXIT_OFS + 2 * i), u16(rom, EXIT_OFS + 2 * i + 2)
    return [(o, [u8(rom, EXIT_BANK + o + k) for k in range(EXIT_BYTES)]) for o in range(first, end, EXIT_BYTES)]


def decode_exit(raw):
    x, y, span, lo, hi, dx, dy = raw
    return {"x": x, "y": y, "span": span & SPAN_LEN, "vertical": bool(span & SPAN_COLUMN),
            "dest": lo | (hi & 1) << 8, "facing": hi >> 1 & 0x0F, "destFlag": bool(hi & 0x80),
            "destX": dx, "destY": dy, "unusedBits": hi & 0x60}


def exit_tiles(exits, colmask, rowmask):
    """{row << 8 | column: record} the way Map_LoadExitTiles writes
    Map_TileExitIdx: along the row only the column wraps; down the column the
    row wraps too. A later record overwrites an earlier one."""
    out = {}
    for n, e in enumerate(exits):
        for k in range(e["span"] + 1):
            if e["vertical"]:
                idx = (((e["y"] + k) & 0xFF) << 8 | e["x"]) & (rowmask << 8 | colmask)
            else:
                idx = (e["y"] & rowmask) << 8 | (e["x"] + k) & colmask
            out[idx] = n
    return out


def treasure_list(rom, i):
    """(location whose list is used, [(offset, tile, contents)]) as
    Map_LoadTreasureTiles reads them: a first record with tile 0 sends it on
    to the list of the location in its contents word."""
    loc, seen = i, set()
    while True:
        first, end = u16(rom, TREASURE_OFS + 2 * loc), u16(rom, TREASURE_OFS + 2 * loc + 2)
        if first == end:
            return loc, []
        if u16(rom, TREASURE_BANK + first) != 0:
            break
        nxt = u16(rom, TREASURE_BANK + first + 2)        # not masked: ASL then the table
        if nxt in seen or nxt >= LOC_COUNT:
            raise ValueError(f"treasure redirect loop at {i}")
        seen.add(loc)
        loc = nxt
    return loc, [(o, u16(rom, TREASURE_BANK + o), u16(rom, TREASURE_BANK + o + 2))
                 for o in range(first, end, TREASURE_BYTES)]


def decode_treasure(tile, contents):
    out = {"x": tile & 0xFF, "y": tile >> 8, "contents": contents}
    if contents & 0x8000:
        out.update(kind="gold", amount=(contents & 0x7FFF) * 2)
    elif contents & 0x4000:
        out.update(kind="empty")
    else:
        out.update(kind="item", item=contents & 0x1FF)
    return out


# --- Location ----------------------------------------------------------------------------

def decode(rom, i, planes=True):
    h = header(rom, i)
    p = decode_props(rom, h["mapProps"])
    tm, ts_, cgadsub = screens(p, h["tileset3"])
    w1, h1 = p["sizes"][1]
    masks = {k: (wrap_mask(w), wrap_mask(hh)) for k, (w, hh) in p["sizes"].items()}
    lim = h["limits"]
    limits = ({"left": 0, "top": 0, "right": w1 - 1, "bottom": h1 - 1} if lim["left"] & LIMITS_NONE
              else dict(lim))
    exits = [dict(decode_exit(raw), at=snes(EXIT_BANK + o)) for o, raw in exit_records(rom, i)]
    tloc, tlist = treasure_list(rom, i)
    out = {"id": i, "header": h, "limits": limits, "fromRecord": not lim["left"] & LIMITS_NONE,
           "props": {k: p[k] for k in ("entry", "at", "packedBytes", "mode", "length", "used", "entries", "runs",
                                       "staleTiles",
                                       "size1", "size3", "move2", "move3", "screens", "colorMath",
                                       "layer3Plane", "halfRate2", "ownStep2", "ownStep3")},
           "sizes": {str(k): list(v) for k, v in p["sizes"].items()},
           "masks": {str(k): list(v) for k, v in masks.items()},
           "steps": {"2": list(own_step(p["move2"])), "3": list(own_step(p["move3"]))},
           "ppu": {"BGMODE": BGMODE, "BG12NBA": BG12NBA, "BG34NBA": BG34NBA, "TM": tm, "TS": ts_,
                   "CGWSEL": CGWSEL, "CGADSUB": cgadsub, "COLDATA": COLDATA},
           "exits": exits,
           "treasure": {"list": tloc, "records": [dict(decode_treasure(t, c), at=snes(TREASURE_BANK + o))
                                                  for o, t, c in tlist]}}
    if planes:
        out.update({"planes": {str(k): v for k, v in p["planes"].items()},
                    "hiBits": p["hiBits"], "attrA": p["attrA"], "attrB": p["attrB"]})
    return out


# --- The ROM's own routines, run ------------------------------------------------------------

class MapRunner(ts.RomRunner):
    """ct_tilesets.RomRunner (multiplier, WMADD/WMDATA writes) with WMDATA
    reads (fullsnes: a read returns the WRAM byte at the port address and
    steps it), run concretely: every value is known, so the routine is
    stepped to its return without the interpreter's state joins."""

    DP_MAP = 0x1D00

    def __init__(self, rom, ref=REF):
        super().__init__(rom, ref)
        absint = self.absint
        base = type(self.machine)

        class Ports(base):
            def read8(self, s, addr):
                if addr is not None:
                    a = addr & 0xFFFFFF
                    bank, low = a >> 16, a & 0xFFFF
                    if (bank < 0x40 or 0x80 <= bank < 0xC0) and low == 0x2180:
                        port = [s.mem.get(0x1002181 + i) for i in range(3)]
                        if None in port:
                            raise absint.Unresolved("WMDATA read with an unknown address")
                        w = port[0] | port[1] << 8 | (port[2] & 1) << 16
                        v = super().read8(s, 0x7E0000 + w)
                        w = (w + 1) & 0x1FFFF
                        for i, b in enumerate((w & 0xFF, w >> 8 & 0xFF, w >> 16)):
                            s.mem[0x1002181 + i] = b
                        return v
                return super().read8(s, addr)

        self.machine.__class__ = Ports

    def run_concrete(self, entry, known, d=0, db=0, m=True, x=False, limit=5 * 10 ** 7):
        """Step `entry` to its return; memory out ({address: byte})."""
        absint, mach = self.absint, self.machine
        s = absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, 0, 0, 0, 0
        s.d, s.db, s.m, s.xf, s.c = d, db, m, x, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        mach.known, mach.reads, mach.control, mach.opaque = known, set(), set(), set()
        for steps in range(limit):
            mach._steps = steps
            r = mach.step(s, 0)
            if r is None:
                continue
            kind, _ = r
            if kind == "fork":
                raise RuntimeError(f"a branch on an unknown value at ${s.pc:06X}")
            if kind not in ("rts", "rtl"):
                raise RuntimeError(f"ended by {kind} at ${s.pc:06X}")
            return {**known, **s.mem}
        raise RuntimeError("too many steps")

    def load_map(self, i, treasure=None):
        """LocLoad_UnkA33B ($C0:A33B) for location i (Map_InitMasksAndLimits,
        Map_UnpackTilePlanes and Map_LoadExitTiles inside); then, when
        `treasure` is 0 or 1, Map_LoadTreasureTiles ($C0:A712) with every
        Treasure_Flags bit clear (0) or set (1): memory out."""
        rec = LOC_BYTES * i
        t3 = u8(self.image, LOC_ROM + rec + 2)
        known = {0x7E01FE: rec & 0xFF, 0x7E01FF: rec >> 8, 0x7E0100: i & 0xFF, 0x7E0101: i >> 8,
                 0x7E01BB: 1 if t3 == NONE else 0}
        at = 0x7EB500 + len(unpack(self.image, props_pointer(self.image, u16(self.image, LOC_ROM + rec + 4)))[0])
        known.update({at + k: 0 for k in range(0x1000)})  # WRAM past the map, as parse_props takes it
        mem = self.run_concrete(0xC0A33B, known, d=0x0100)
        if treasure is not None:
            flags = {0x7F0001 + k: 0xFF if treasure else 0 for k in range(64)}     # !Treasure_Flags
            mem = self.run_concrete(0xC0A712, {**mem, **flags}, d=self.DP_MAP)
        return mem

    def bg_layout(self):
        """Ppu_SetBgLayout ($FD:C0D7): {register: last value written}."""
        mem = self.run_concrete(0xFDC0D7, {})
        return {a & 0xFFFF: v for a, v in mem.items() if a >> 16 == 0 and 0x2100 <= a & 0xFFFF < 0x2140}

    def apply_screens(self, tm, ts_, cgadsub):
        """Ppu_ApplyMapScreens ($C0:A509) on the three shadows: {register: value}."""
        mem = self.run_concrete(0xC0A509, {0x7E0BD7: tm, 0x7E0BD8: ts_, 0x7E0BDF: cgadsub})
        return {a & 0xFFFF: v for a, v in mem.items() if a >> 16 == 0 and 0x2100 <= a & 0xFFFF < 0x2140}


# --- Evidence: ChronoRET's source --------------------------------------------------------

# Each routine holds these lines in this order (comments stripped).
ASM_CLAIMS = (
    # The header: sizes, screens, colour math, own steps; then the planes and the exits.
    ("bankC0/bankC0.asm", "LocLoad_UnkA33B",
     ("LDA.l LocRom.MapProps,X", "LDA.l !Map_PropsPtrs,X", "LDA.w #MapProps&$FFFF", "JSL Decomp_ToWramVec",
      "LDA.l MapProps.Size3", "BPL .no_layer3_plane", "BIT.b #!MapProps_HalfRate2", "BIT.b #!MapProps_OwnStep3",
      "BIT.b #!MapProps_OwnStep2", "AND.b #!MapProps_WidthBits", "INC A", "STA.w !Map_Unk0BD3",
      "AND.b #!MapProps_HeightBits", "ADC.b #!MapProps_HeightAdd", "STA.w !Map_Unk0BD5", "LDA.l MapProps.Size1",
      "AND.b #!MapProps_WidthBits", "STA.w !Map_Unk0BCB", "AND.b #!MapProps_HeightBits", "STA.w !Map_Unk0BCD",
      "AND.b #!MapProps_L2WidthBits", "ADC.b #!Map_ScreenMetatiles", "STA.w !Map_Unk0BCF",
      "AND.b #!MapProps_L2HeightBits", "LSR A", "LSR A", "ADC.b #!Map_ScreenMetatiles", "STA.w !Map_Unk0BD1",
      "LDA.l MapProps.ColorMath", "STA.w !Ppu_Unk0BDF", "LDA.l MapProps.Screens", "AND.b #!MapScreens_MainBgs",
      "AND.b #!MapScreens_MainObj", "ASL A", "STA.w !Ppu_Unk0BD7", "LDA.w !DP_Field+!Field_UnkBB",
      "AND.b #!Layer_Bg12Obj", "AND.b #!MapScreens_SubBgs", "AND.b #!MapScreens_SubObj", "STA.w !Ppu_Unk0BD8",
      "AND.b #!Layer_Bg12Obj", "LDA.l MapProps.Move2", "AND.b #!MapMove_XBits", "BIT.b #!MapMove_XNeg",
      "AND.b #!MapMove_YBits", "BIT.b #!MapMove_YNeg", "LDA.l MapProps.Move3", "JSR Map_InitMasksAndLimits",
      "JSR Map_UnpackTilePlanes", "JSR Map_LoadExitTiles")),
    ("bankC0/bankC0.asm", "Map_InitMasksAndLimits",
     ("CMP.b #!Map_Metatiles64", "CMP.b #!Map_Metatiles32", "CMP.b #!Map_Metatiles48", "LDA.b #!Map_WrapMask16",
      "LDA.b #!Map_WrapMask32", "LDA.b #!Map_WrapMask64", "LDA.b #!Map_WrapMask64", "LDA.l LocRom.LimitLeft,X",
      "BMI .map_edges", "LDA.l LocRom.LimitTop,X", "LDA.l LocRom.LimitRight,X", "STZ.b !Map_Unk1D1A-!DP_Map",
      "LDA.w !Map_Unk0BCB", "DEC A", "LDA.w !Map_Unk0BCD", "DEC A")),
    ("bankC0/bankC0.asm", "Map_UnpackTilePlanes",
     ("LDX.w #MapProps.Planes&$FFFF", "STX.w WMADDL", "LDA.w WMDATA", "STA.l !Map_TileProps,X",
      "LDA.w WMDATA", "STA.l !Map_Layer2Tiles,X", "AND.b #!Map_Unk0BCAOn", "LDA.w WMDATA",
      "STA.l !Map_Layer3Tiles,X", "LDA.w WMDATA", "BMI .run", "STA.l !Map_TileHiBits,X", "LDA.w WMDATA",
      "STA.l !Map_TileAttrA,X", "LDA.w WMDATA", "STA.l !Map_TileAttrB,X", "AND.b #!Map_RunFlagMask",
      "LDY.w #!Map_RunLen256")),
    ("bankC0/bankC0.asm", "Map_LoadExitTiles",
     ("LDA.b #!Map_ExitNone", "LDA.l !ExitRom_LocOfs,X", "LDA.l !ExitRom_LocOfs,X", "LDA.l ExitRom.Span,X",
      "BMI .column", "LDA.l ExitRom.TileX,X", "AND.b !Map_ColMask1-!DP_Map", "STA.l !Map_TileExitIdx,X",
      "AND.b #!Exit_SpanLenMask", "LDA.l ExitRom.TileX,X", "AND.b !Map_ColMask1-!DP_Map",
      "STA.l !Map_TileExitIdx,X", "ADC.w #!Map_RowStride", "ADC.w #!Map_ExitRecSize")),
    ("bankC0/bankC0.asm", "Map_LoadTreasureTiles",
     ("LDA.b #!Map_TreasureNone", "LDA.l !TreasureRom_LocOfs", "LDA.l !TreasureRom_LocOfs+2,X",
      "LDA.l !TreasureRom_LocOfs,X", "LDA.l TreasureRom.Tile,X", "LDA.l TreasureRom.Contents,X",
      "LDA.l TreasureRom.Tile,X", "AND.b !Map_ColMask1-!DP_Map", "STA.l !Map_TreasureIdx,X",
      "JSR Map_TreasureTaken", "BIT.b #!TileHiBits_L1Bit8", "CMP.b #!TileAnim_StateFE", "CMP.b #!TileAnim_StateE0",
      "LDA.b #!TileAnim_StateE1", "LDA.b #!TileAnim_StateFF", "ADC.w #!Map_TreasureRecSize")),
    ("bankC0/bankC0.asm", "Ppu_ApplyMapScreens",
     ("LDA.w !Ppu_Unk0BD7", "STA.w TM", "LDA.w !Ppu_Unk0BD8", "STA.w TS", "LDA.w !Ppu_Unk0BDF", "STA.w CGADSUB")),
    ("bankC0/bankC0.asm", "LocLoad_DrawMap",
     ("JSR Map_LoadTreasureTiles", "JSL Ppu_SetBgLayout", "JSR Ppu_ApplyMapScreens", "JSR Map_InitOrigin",
      "LDX.w #!Map_VramTilemap1", "STX.w !Map_TilemapVram", "LDX.w #!Map_VramTilemap2", "STX.w !Map_TilemapVram3",
      "LDX.w #!Map_VramTilemap3", "STX.w !Map_TilemapVramL3", "LDA.b #!Map_ScSizeInit", "JSR Field_BuildC800Mode1",
      "JSR Field_BuildC800Mode2", "LDA.w !Map_Unk0BCA", "AND.b #!Map_Unk0BCAOn", "LDA.w !DP_Field+!Field_UnkBB",
      "JSR Field_BuildC800Mode4")),
    ("bankC0/bankC0.asm", "Map_InitOrigin",
     ("LDA.w !Map_Unk0BC9", "BPL .biases", "LDA.b !Map_TileOriginX-!DP_Map")),
    ("bankC0/bankC0.asm", "Map_WriteRow2",
     ("LDA.l !Map_TileHiBits,X", "LSR A", "AND.b #$01", "XBA", "LDA.l !Map_Layer2Tiles,X")),
    # Collision: the three bytes of a tile, the half and its level, and what blocks.
    ("bankC0/bankC0.asm", "Map_ProbeTileAttrs",
     ("LDA.l !Map_TreasureIdx,X", "BMI Map_ProbeTileAttrs_Load", "SEC")),
    ("bankC0/bankC0.asm", "Map_ProbeTileAttrs_Load",
     ("LDA.l !Map_TileHiBits,X", "LDA.l !Map_TileAttrA,X", "LDA.l !Map_TileAttrB,X")),
    ("bankC0/bankC0.asm", "Map_ProbeTileLevel",
     ("AND.b #!Map_ShapeMask", "LSR A", "LSR A", "BEQ .half_a", "DEC A", "BEQ .half_b", "CMP.b #!Map_ShapeTables",
      "LDA.l Map_SlopeShift,X", "AND.b #!TileAttrB_LevelA", "AND.b #!TileAttrB_NoLevelA", "AND.b #!TileAttr_PrioBit",
      "ORA.b #!Oam_Prio2", "AND.b #!TileAttrB_LevelB", "AND.b #!TileAttrB_NoLevelB", "CMP.b #!MapShape_TopB",
      "CMP.b #!MapShape_BottomLeftB", "CMP.b #!MapShape_BottomRightB", "CMP.b #!MapShape_TopRightB",
      "CMP.b #!MapShape_TopLeftB", "CMP.b #!MapShape_Unk1E", "LDA.b #!Map_ProbeShape1E", "LDA.b #!Map_StepPos",
      "LDA.b #!Map_StepNeg")),
    ("bankC0/bankC0.asm", "Map_ProbeLevelBlocked",
     ("LDA.b !Map_ProbeNoLevel-!DP_Map", "BNE .no_level", "LDA.b !Map_ProbeLevel-!DP_Map", "BEQ .blocked",
      "CMP.b #!Map_LevelAny", "BEQ .free", "CMP.w !DP_Field+!Field_Unk55", "BEQ .free",
      "LDA.w !DP_Field+!Field_Unk55", "CMP.b #!Map_LevelAny", "BEQ .free", "SEC", "CLC",
      "LDA.w !DP_Field+!Field_Unk55", "CMP.b #!Map_LevelAny", "BEQ .blocked", "CLC")),
    ("bankC0/bankC0.asm", "Map_StepTileEffects",
     ("JSR Map_ProbeTileAttrsAny", "JSR Map_ProbeTileLevel", "JSR Map_ProbeLevelBlocked",
      "LDA.l !Map_TileExitIdx,X", "BMI .anim_tile", "LDA.b #!Map_ExitRecSize", "ADC.b !Map_ExitRec0-!DP_Map",
      "LDA.l ExitRom.TileX,X", "LDA.l ExitRom.TileY,X", "CMP.b #!Map_ExitRowRange", "LDA.l ExitRom.DestHiFacing,X",
      "LSR A", "AND.b #!Exit_FacingMask", "AND.b #!Exit_FacingBit7", "AND.b #!Exit_DestHiBit",
      "LDA.l ExitRom.DestLo,X", "LDA.l ExitRom.DestX,X", "LDA.l ExitRom.DestY,X", "ORA.b #!SceneFlag_Warp",
      "LDA.l !Map_TileAttrA,X", "BIT.b #!TileAttrA_AnimNear", "LDA.b !Map_ProbeNoLevel-!DP_Map",
      "LDA.b !Map_ProbeLevel-!DP_Map", "STA.w !DP_Field+!Field_Unk55", "STA.w !Obj_PrioLow,X",
      "STA.w !Obj_PrioHigh,X", "AND.b #!TileAttrA_PushSpeed", "CMP.b #!TileAttrA_PushSlow",
      "CMP.b #!TileAttrA_PushMid", "LDA.b #!Map_PushFast", "LDA.b #!Map_PushSlow")),
    ("bankC0/bankC0.asm", "Obj_SetVelocityChecked",
     ("BIT.b #!Obj_Unk1C80Block", "LDA.l !Map_TileAttrB,X", "BMI .blocked")),
    ("bankC0/bankC0.asm", "Evt_PushTarget",
     ("LDA.l !Map_TileAttrB,X", "BMI .refused")),
    ("bankC0/bankC0.asm", "LocLoad_AudioSetup",
     ("LDA.l LocRom.Music,X", "BMI .done", "LDA.b #!Audio_CmdPlayMusic")),
    ("bankFD/bankFD.asm", "Ppu_SetBgLayout",
     ("LDA.b #BG_MODE_1|BG3_HIGH_PRIO", "STA.b BGMODE-!DP_PPU", "LDA.b #!BG12NBA_Both1000",
      "LDA.b #!BG34NBA_Bg3At5000", "LDA.b #!TM_Bg1Bg2Obj", "LDA.b #!CGWSEL_AddSubscreen", "STA.b CGWSEL-!DP_PPU",
      "LDA.b #!COLDATA_AllZero", "STA.b COLDATA-!DP_PPU")),
)

CONSTANT_CLAIMS = (
    ("include/ram_engine.inc", "!ExitRom_LocOfs = $E50000"),
    ("include/ram_engine.inc", "!TreasureRom_LocOfs = $F5F000"),
    ("include/ram_engine.inc", "!Map_TileProps = $7E3000"),
    ("include/ram_engine.inc", "!Map_Layer2Tiles = $7E3040"),
    ("include/ram_engine.inc", "!Map_Layer3Tiles = $7E3080"),
    ("include/ram_engine.inc", "!Map_TileHiBits = $7E30C0"),
    ("include/ram_engine.inc", "!Map_TileAttrA = $7E7000"),
    ("include/ram_engine.inc", "!Map_TileAttrB = $7E7040"),
    ("include/ram_engine.inc", "!Map_TileExitIdx = $7E7080"),
    ("include/ram_engine.inc", "!Map_TreasureIdx = $7E70C0"),
    ("include/ram_engine.inc", "!Map_PropsPtrs = $F61E00"),
    ("include/ram_engine.inc", "!Treasure_Flags = $7F0001"),
    ("include/constants_engine.inc", "!MapProps_WidthBits = $03"),
    ("include/constants_engine.inc", "!MapProps_HeightBits = $0C"),
    ("include/constants_engine.inc", "!MapProps_HeightAdd = $04"),
    ("include/constants_engine.inc", "!MapProps_L2WidthBits = $30"),
    ("include/constants_engine.inc", "!MapProps_L2HeightBits = $C0"),
    ("include/constants_engine.inc", "!Map_ScreenMetatiles = $10"),
    ("include/constants_engine.inc", "!MapProps_OwnStep2 = $10"),
    ("include/constants_engine.inc", "!MapProps_OwnStep3 = $20"),
    ("include/constants_engine.inc", "!MapProps_HalfRate2 = $40"),
    ("include/constants_engine.inc", "!MapMove_XBits = $07"),
    ("include/constants_engine.inc", "!MapMove_XNeg = $08"),
    ("include/constants_engine.inc", "!MapMove_YBits = $70"),
    ("include/constants_engine.inc", "!MapMove_YNeg = $80"),
    ("include/constants_engine.inc", "!MapScreens_MainBgs = $07"),
    ("include/constants_engine.inc", "!MapScreens_MainObj = $08"),
    ("include/constants_engine.inc", "!MapScreens_SubBgs = $70"),
    ("include/constants_engine.inc", "!MapScreens_SubObj = $80"),
    ("include/constants_engine.inc", "!Map_Metatiles32 = $20"),
    ("include/constants_engine.inc", "!Map_Metatiles48 = $30"),
    ("include/constants_engine.inc", "!Map_Metatiles64 = $40"),
    ("include/constants_engine.inc", "!Map_WrapMask16 = $0F"),
    ("include/constants_engine.inc", "!Map_WrapMask32 = $1F"),
    ("include/constants_engine.inc", "!Map_WrapMask64 = $3F"),
    ("include/constants_engine.inc", "!Map_RunFlagMask = $7F"),
    ("include/constants_engine.inc", "!Map_RunLen256 = $0100"),
    ("include/constants_engine.inc", "!Map_ExitNone = $80"),
    ("include/constants_engine.inc", "!Map_TreasureNone = $80"),
    ("include/constants_engine.inc", "!Exit_SpanLenMask = $7F"),
    ("include/constants_engine.inc", "!Exit_DestHiBit = $01"),
    ("include/constants_engine.inc", "!Exit_FacingMask = $0F"),
    ("include/constants_engine.inc", "!Exit_FacingBit7 = $80"),
    ("include/constants_engine.inc", "!Map_ExitRecSize = $07"),
    ("include/constants_engine.inc", "!Map_TreasureRecSize = $0004"),
    ("include/constants_engine.inc", "!Map_RowStride = $0100"),
    ("include/constants_engine.inc", "!Map_ShapeMask = $FC"),
    ("include/constants_engine.inc", "!Map_ShapeTables = $16"),
    ("include/constants_engine.inc", "!MapShape_LeftB = $16"),
    ("include/constants_engine.inc", "!MapShape_Unk1E = $1C"),
    ("include/constants_engine.inc", "!TileAttrB_LevelA = $03"),
    ("include/constants_engine.inc", "!TileAttrB_NoLevelA = $04"),
    ("include/constants_engine.inc", "!TileAttrB_LevelB = $18"),
    ("include/constants_engine.inc", "!TileAttrB_NoLevelB = $20"),
    ("include/constants_engine.inc", "!TileAttr_PrioBit = $10"),
    ("include/constants_engine.inc", "!Oam_Prio2 = $20"),
    ("include/constants_engine.inc", "!Map_LevelAny = $03"),
    ("include/constants_engine.inc", "!TileAttrA_AnimNear = $10"),
    ("include/constants_engine.inc", "!TileAttrA_PushSpeed = $0C"),
    ("include/constants_engine.inc", "!TileAttrA_PushSlow = $04"),
    ("include/constants_engine.inc", "!TileAttrA_PushMid = $08"),
    ("include/constants_engine.inc", "!TileAttrA_PushDir = $03"),
    ("include/constants_engine.inc", "!Map_PushSlow = $08"),
    ("include/constants_engine.inc", "!Map_PushMid = $10"),
    ("include/constants_engine.inc", "!Map_PushFast = $20"),
    ("include/constants_engine.inc", "!TileHiBits_L1Bit8 = $01"),
    ("include/constants_engine.inc", "!TileHiBits_L2Bit8 = $02"),
    ("include/constants_engine.inc", "!Map_VramTilemap1 = $6000"),
    ("include/constants_engine.inc", "!Map_VramTilemap2 = $6800"),
    ("include/constants_engine.inc", "!Map_VramTilemap3 = $7000"),
    ("include/constants_engine.inc", "!Map_ScSizeInit = $01"),
    ("hardware.inc", "!Layer_Bg12Obj         = $13"),
    ("hardware.inc", "!CGWSEL_AddSubscreen   = $02"),
    ("hardware.inc", "!COLDATA_AllZero       = $E0"),
)


def asm_claims(ref=REF):
    """As ct_tilesets.asm_claims, over this module's routines and constants."""
    saved = ts.ASM_CLAIMS, ts.CONSTANT_CLAIMS
    ts.ASM_CLAIMS, ts.CONSTANT_CLAIMS = ASM_CLAIMS, CONSTANT_CLAIMS
    try:
        return ts.asm_claims(ref)
    finally:
        ts.ASM_CLAIMS, ts.CONSTANT_CLAIMS = saved


# --- Evidence: the ROM's code bytes ----------------------------------------------------

def code_claims(rom):
    """Operands of the readers, from the ROM's own code bytes."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    body = ts._body
    a33b = body(rom, 0xC0A33B, 0xC0A507)
    claim("$C0:A33B reads Map_PropsPtrs (LDA.l $F61E00,X) into $7E:B500 (LDA #$B500)",
          b"\xbf\x00\x1e\xf6" in a33b and b"\xa9\x00\xb5" in a33b)
    claim("$C0:A33B masks the sizes (AND #$03 / #$0C / #$30 / #$C0), adds 4 and $10 (ADC #$04 / #$10)",
          all(b"\x29" + bytes([m]) in a33b for m in (0x03, 0x0C, 0x30, 0xC0))
          and b"\x69\x04" in a33b and b"\x69\x10" in a33b)
    claim("$C0:A33B splits Screens (AND #$07 / #$08 / #$70 / #$80) and keeps BG1/BG2/OBJ with no layer 3 (AND #$13)",
          all(b"\x29" + bytes([m]) in a33b for m in (0x07, 0x08, 0x70, 0x80, 0x13)))
    claim("$C0:A33B calls $C0:7399, $C0:A521 and $C0:A66B (JSR)",
          b"\x20\x99\x73\x20\x21\xa5\x20\x6b\xa6" in a33b)
    masks = body(rom, 0xC07399, 0xC074A5)
    claim("$C0:7399 compares the sizes with $40 / $20 / $30 and stores masks $0F / $1F / $3F",
          all(b"\xc9" + bytes([v]) in masks for v in (0x40, 0x20, 0x30))
          and all(b"\xa9" + bytes([v]) in masks for v in (0x0F, 0x1F, 0x3F)))
    claim("$C0:7399 reads LocRom.LimitLeft (LDA.l $F6000A,X)", b"\xbf\x0a\x00\xf6" in masks)
    planes = body(rom, 0xC0A521, 0xC0A66A)
    claim("$C0:A521 reads WMDATA (LDA $2180) into $7E:3000/$3040/$3080/$30C0 and $7E:7000/$7040 (STA.l ...,X)",
          b"\xad\x80\x21" in planes and all(b"\x9f" + struct.pack("<H", a) + b"\x7e" in planes
                                            for a in (0x3000, 0x3040, 0x3080, 0x30C0, 0x7000, 0x7040)))
    claim("$C0:A521 masks a run's first byte with $7F (AND #$7F) and counts 0 as 256 (LDY #$0100)",
          b"\x29\x7f" in planes and b"\xa0\x00\x01" in planes)
    exits = body(rom, 0xC0A66B, 0xC0A711)
    claim("$C0:A66B reads $E5:0000 (LDA.l $E50000,X), Span (LDA.l $E50002,X), writes $7E:7080 (STA.l $7E7080,X)",
          b"\xbf\x00\x00\xe5" in exits and b"\xbf\x02\x00\xe5" in exits and b"\x9f\x80\x70\x7e" in exits)
    claim("$C0:A66B steps 7 bytes (ADC #$0007) and $100 down a column (ADC #$0100), fills with $80 (LDA #$80)",
          b"\x69\x07\x00" in exits and b"\x69\x00\x01" in exits and b"\xa9\x80" in exits)
    tre = body(rom, 0xC0A712, 0xC0A7BB)
    claim("$C0:A712 reads $F5:F000 (LDA.l $F5F000,X / $F5F002,X) and $F5:0000 records, writes $7E:70C0, steps 4",
          b"\xbf\x00\xf0\xf5" in tre and b"\xbf\x02\xf0\xf5" in tre and b"\xbf\x00\x00\xf5" in tre
          and b"\x9f\xc0\x70\x7e" in tre and b"\x69\x04\x00" in tre)
    apply = body(rom, 0xC0A509, 0xC0A520)
    claim("$C0:A509 writes $0BD7 to TM, $0BD8 to TS and $0BDF to CGADSUB (LDA $0BD7; STA $212C ...)",
          b"\xad\xd7\x0b\x8d\x2c\x21\xad\xd8\x0b\x8d\x2d\x21\xad\xdf\x0b\x8d\x31\x21" in apply)
    draw = body(rom, 0xC00A50, 0xC00AFE)
    claim("$C0:0A50 sets the tilemaps $6000 / $6800 / $7000 (LDX #$6000 ...) and SC size 1 (LDA #$01)",
          all(b"\xa2\x00" + bytes([h]) in draw for h in (0x60, 0x68, 0x70)) and b"\xa9\x01" in draw)
    layout = body(rom, 0xFDC0D7, 0xFDC123)
    claim("$FD:C0D7 writes BGMODE $09, TM $13, CGWSEL $02, COLDATA $E0 (LDA #n; STA $05/$2C/$30/$32 with D = $2100)",
          all(bytes([0xA9, v, 0x85, r]) in layout for v, r in ((0x09, 0x05), (0x13, 0x2C), (0x02, 0x30), (0xE0, 0x32))))
    level = body(rom, 0xC09AD3, 0xC09BF4)
    claim("$C0:9AD3 masks HiBits with $FC and AttrB with $03 / $04 / $18 / $20, the priority bit with $10, ORA #$20",
          all(b"\x29" + bytes([m]) in level for m in (0xFC, 0x03, 0x04, 0x18, 0x20, 0x10)) and b"\x09\x20" in level)
    blocked = body(rom, 0xC09C37, 0xC09C5B)
    claim("$C0:9C37 compares the level with 3 (CMP #$03)", b"\xc9\x03" in blocked)
    step = body(rom, 0xC09C5C, 0xC09DC2)
    claim("$C0:9C5C reads $7E:7080 and $7E:7000 (LDA.l ...,X), 7-byte records (LDA #$07), facing AND #$0F, BIT #$10, "
          "push AND #$0C and $08 / $10 / $20",
          b"\xbf\x80\x70\x7e" in step and b"\xbf\x00\x70\x7e" in step and b"\xa9\x07" in step and b"\x29\x0f" in step
          and b"\x89\x10" in step and b"\x29\x0c" in step and all(b"\xa9" + bytes([v]) in step for v in (0x08, 0x10, 0x20)))
    return out


# --- Evidence: the data, ROM-wide ------------------------------------------------------------

def data_claims(rom, csv=ts.CSV):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    heads = [header(rom, i) for i in range(LOC_COUNT)]
    entries = sorted({h["mapProps"] for h in heads})
    claim(f"LocRom: {LOC_COUNT} records name {len(entries)} MapProps entries, all below {MAP_PROPS_COUNT}, none a zero pointer",
          entries[-1] < MAP_PROPS_COUNT and all(props_pointer(rom, e) for e in entries), f"max {entries[-1]}")
    claim("LocRom.Unk06 is 0 in every record (no reader traced)", all(h["unk06"] == 0 for h in heads))
    packs = ts.csv_packs(csv)
    props = {}
    bad = []
    for e in entries:
        p = decode_props(rom, e)
        props[e] = p
        at = props_pointer(rom, e)
        want = packs.get(at)
        if want is None or (want[1], want[2], want[3]) != (p["packedBytes"], p["length"], p["mode"]):
            bad.append((e, snes(at), want and want[1:]))
    claim(f"{len(entries)} MapProps packs unpack with the packed size, unpacked size and mode data_assets.csv gives",
          not bad and packs, str(bad[:4]) if packs else "data_assets.csv missing")
    exact = [e for e, p in props.items() if p["used"] == p["length"]]
    short = {e: p["staleTiles"] for e, p in props.items() if p["staleTiles"]}
    claim(f"Map_UnpackTilePlanes' parse uses every byte of all {len(entries)} maps (planes, triples and runs)",
          len(exact) == len(entries), f"not exact: {sorted(set(entries) - set(exact))[:8]}")
    claim(f"{len(short)} maps end before their triples cover layer 1; their last tiles read WRAM past the map",
          len(short) < 8, ", ".join(f"entry {e}: {n} tiles" for e, n in sorted(short.items())))
    sizes = Counter((p["sizes"][1], p["sizes"][2], p["sizes"][3] if p["layer3Plane"] else None) for p in props.values())
    dims = {d for p in props.values() for d in (*p["sizes"][1], *p["sizes"][2], *p["sizes"][3])}
    claim("every layer is 16, 32, 48 or 64 metatiles each way", dims <= {16, 32, 48, 64}, str(sorted(dims)))
    l2_outside = sum(1 for p in props.values() for r in range(p["sizes"][2][1]) for c in range(p["sizes"][2][0])
                     if r >= p["sizes"][1][1] or c >= p["sizes"][1][0])
    claim(f"layer-2 cells outside layer 1 (their bit 8 is whatever Map_TileHiBits held): {l2_outside}", True,
          ", ".join(f"{k}" for k in sorted(e for e, p in props.items()
                                           if p["sizes"][2][0] > p["sizes"][1][0] or p["sizes"][2][1] > p["sizes"][1][1])))
    l3_users = [i for i, h in enumerate(heads) if props[h["mapProps"]]["layer3Plane"] and h["tileset3"] == NONE]
    claim(f"locations whose map has a layer-3 plane but no Tileset3 (LocLoad_DrawMap skips it): {len(l3_users)}", True,
          str(l3_users[:12]))
    # Tile properties, ROM-wide.
    hi = Counter(); a = Counter(); b = Counter(); cells = 0
    for p in props.values():
        for h_, a_, b_ in zip(p["hiBits"], p["attrA"], p["attrB"]):
            cells += 1
            hi[h_ >> 2] += 1
            a[a_] += 1
            b[b_] += 1
    shapes = sorted(hi)
    claim(f"{cells} tiles: shapes used {', '.join(f'${s:02X}' for s in shapes)} (all below $40)", shapes[-1] < 0x40)
    raw_a = {bit: sum(n for v, n in a.items() if v >> bit & 1) for bit in (5, 7)}
    claim("AttrA bits 5 / 7 (read by nothing traced) are kept raw", True,
          f"AttrA bit 5: {raw_a[5]}, bit 7: {raw_a[7]} tiles; AttrB bit 7 (blocks objects): "
          f"{sum(n for v, n in b.items() if v & 0x80)} tiles")
    push = sum(n for v, n in a.items() if v & 0x0C)
    anim = sum(n for v, n in a.items() if v & 0x10)
    levels = Counter()
    for v, n in b.items():
        levels["A" + ("-" if v & 4 else str(v & 3))] += n
        levels["B" + ("-" if v & 0x20 else str(v >> 3 & 3))] += n
    claim(f"push tiles {push}, animation triggers {anim}; levels " +
          ", ".join(f"{k} {levels[k]}" for k in sorted(levels)), True)
    # Exits.
    ofs = [u16(rom, EXIT_OFS + 2 * i) for i in range(LOC_COUNT + 1)]
    claim(f"ExitRom_LocOfs: {LOC_COUNT + 1} offsets rise, from {2 * (LOC_COUNT + 1)} (just past the table), in 7-byte steps",
          ofs[0] == 2 * (LOC_COUNT + 1) and all(y >= x and (y - x) % EXIT_BYTES == 0 for x, y in zip(ofs, ofs[1:])),
          f"{(ofs[-1] - ofs[0]) // EXIT_BYTES} records")
    bad_dest, world, unused, outside, spans = [], 0, 0, [], Counter()
    for i, h in enumerate(heads):
        p = props[h["mapProps"]]
        w1, h1 = p["sizes"][1]
        for o, raw in exit_records(rom, i):
            e = decode_exit(raw)
            spans["column" if e["vertical"] else "row"] += 1
            if e["dest"] >= LOC_COUNT:
                bad_dest.append((i, o))
            world += e["dest"] >= DEST_WORLD
            unused += bool(e["unusedBits"])
            last = (e["x"], e["y"] + e["span"]) if e["vertical"] else (e["x"] + e["span"], e["y"])
            if not (e["x"] < w1 and e["y"] < h1 and last[0] < w1 and last[1] < h1):
                outside.append(i)
    claim(f"every exit names a location below 512 ({world} name $1F0 and up), bits 5-6 of byte 4 are 0",
          not bad_dest and not unused, str(bad_dest[:4]))
    claim(f"exits along a row {spans['row']}, down a column {spans['column']}; exits not wholly inside layer 1: "
          f"{len(outside)} (wrapped by the masks)", True, str(sorted(set(outside))[:12]))
    # Treasure.
    tofs = [u16(rom, TREASURE_OFS + 2 * i) for i in range(LOC_COUNT + 1)]
    claim("TreasureRom_LocOfs: offsets rise in 4-byte steps",
          all(y >= x and (y - x) % TREASURE_BYTES == 0 for x, y in zip(tofs, tofs[1:])),
          f"{(tofs[-1] - tofs[0]) // TREASURE_BYTES} records from ${tofs[0]:04X}")
    redirect, kinds, t_out = [], Counter(), []
    for i, h in enumerate(heads):
        loc, recs = treasure_list(rom, i)
        if loc != i:
            redirect.append((i, loc))
        p = props[h["mapProps"]]
        for _, tile, contents in recs:
            if loc == i:
                kinds[decode_treasure(tile, contents)["kind"]] += 1
            if (tile & 0xFF) >= p["sizes"][1][0] or tile >> 8 >= p["sizes"][1][1]:
                t_out.append((i, f"${tile:04X}", f"${contents:04X}"))
    claim(f"treasure: {sum(kinds.values())} records ({', '.join(f'{k} {v}' for k, v in sorted(kinds.items()))}); "
          f"{len(redirect)} locations use another's list", True, str(redirect[:8]))
    claim("every treasure tile lies inside its location's layer 1 but location 0's one record ($2F2F, $FFFF)",
          t_out == [(0, "$2F2F", "$FFFF")], str(t_out[:8]))
    music = Counter(h["music"] >= 0x80 for h in heads)
    claim(f"LocRom.Music: {music[True]} records keep the music (bit 7)", True)
    return out


def wram_planes(mem, d):
    """The planes LocLoad_UnkA33B left in WRAM, in decode's shapes."""
    def plane(base, w, h):
        return [mem.get(base + r * 0x100 + c) for r in range(h) for c in range(w)]
    out = {}
    for k, base in (("1", 0x7E3000), ("2", 0x7E3040), ("3", 0x7E3080)):
        if k in d["planes"]:
            out[k] = plane(base, *d["sizes"][k])
    w1, h1 = d["sizes"]["1"]
    for k, base in (("hiBits", 0x7E30C0), ("attrA", 0x7E7000), ("attrB", 0x7E7040)):
        out[k] = plane(base, w1, h1)
    out["exitIdx"] = plane(0x7E7080, 64, 64)
    out["treasureIdx"] = plane(0x7E70C0, 64, 64)
    return out


def expected_planes(d):
    w1, h1 = d["sizes"]["1"]
    out = {k: [v & 0xFF for v in d["planes"][k]] for k in d["planes"]}
    out.update(hiBits=d["hiBits"], attrA=d["attrA"], attrB=d["attrB"])
    cm, rm = d["masks"]["1"]
    exits = exit_tiles(d["exits"], cm, rm)
    out["exitIdx"] = [exits.get(r << 8 | c, EXIT_NONE) for r in range(64) for c in range(64)]
    tiles = {}
    for n, t in enumerate(d["treasure"]["records"]):
        tiles[(t["y"] & rm) << 8 | t["x"] & cm] = n
    out["treasureIdx"] = [tiles.get(r << 8 | c, TREASURE_NONE) for r in range(64) for c in range(64)]
    return out


def taken_props(d):
    """Map_TileProps (layer 1's low bytes) after Map_LoadTreasureTiles with every
    treasure taken: a chest tile whose metatile has bit 8 set steps $FE -> $FF
    and $E0 -> $E1."""
    w1, _ = d["sizes"]["1"]
    cm, rm = d["masks"]["1"]
    low = [v & 0xFF for v in d["planes"]["1"]]
    for t in d["treasure"]["records"]:
        r, c = t["y"] & rm, t["x"] & cm
        if c >= w1 or r * w1 + c >= len(low):
            continue
        i = r * w1 + c
        if d["hiBits"][i] & 1:
            low[i] = {0xFE: 0xFF, 0xE0: 0xE1}.get(low[i], low[i])
    return low


def run_claims(rom, ref=REF, locations=None):
    """LocLoad_UnkA33B and Map_LoadTreasureTiles for every location (or the
    ones given), Ppu_SetBgLayout and Ppu_ApplyMapScreens, against decode."""
    runner = MapRunner(rom, ref)
    out = []
    locations = range(LOC_COUNT) if locations is None else locations
    bad = {k: [] for k in ("planes", "exits", "treasure", "taken", "header", "screens")}
    chests = 0
    for i in locations:
        d = decode(rom, i)
        mem = runner.load_map(i, treasure=0)
        got, want = wram_planes(mem, d), expected_planes(d)
        for k in want:
            if got[k] != want[k]:
                bad["exits" if k == "exitIdx" else "treasure" if k == "treasureIdx" else "planes"].append((i, k))
        w = {0x7E0BCB: d["sizes"]["1"][0], 0x7E0BCD: d["sizes"]["1"][1], 0x7E0BCF: d["sizes"]["2"][0],
             0x7E0BD1: d["sizes"]["2"][1], 0x7E0BD3: d["sizes"]["3"][0], 0x7E0BD5: d["sizes"]["3"][1],
             0x7E1D1E: d["masks"]["1"][0], 0x7E1D1F: d["masks"]["1"][1], 0x7E1D20: d["masks"]["2"][0],
             0x7E1D21: d["masks"]["2"][1], 0x7E1D22: d["masks"]["3"][0], 0x7E1D23: d["masks"]["3"][1],
             0x7E1D1A: d["limits"]["left"], 0x7E1D1C: d["limits"]["top"], 0x7E1D1B: d["limits"]["right"],
             0x7E1D1D: d["limits"]["bottom"], 0x7E0BC9: 0x80 if d["props"]["halfRate2"] else 0,
             0x7E0BCA: 1 if d["props"]["layer3Plane"] else 0}
        for layer, base in (("2", 0x7E1D37), ("3", 0x7E1D39)):
            sx, sy = d["steps"][layer]
            if sx:
                w[base] = sx & 0xFF
            if sy:
                w[base + 1] = sy & 0xFF
        if any(mem.get(a) != v for a, v in w.items()):
            bad["header"].append((i, [f"${a & 0xFFFF:04X}" for a, v in w.items() if mem.get(a) != v][:3]))
        ppu = (mem.get(0x7E0BD7), mem.get(0x7E0BD8), mem.get(0x7E0BDF))
        if ppu != (d["ppu"]["TM"], d["ppu"]["TS"], d["ppu"]["CGADSUB"]):
            bad["screens"].append(i)
        if d["treasure"]["records"]:
            taken = runner.load_map(i, treasure=1)
            w1, h1 = d["sizes"]["1"]
            low = [taken.get(0x7E3000 + r * 0x100 + c) for r in range(h1) for c in range(w1)]
            expect = taken_props(d)
            chests += sum(x != y for x, y in zip(expect, want["1"]))
            if low != expect:
                bad["taken"].append(i)
    n = len(locations)
    out.append((f"LocLoad_UnkA33B ($C0:A33B, run) = decode for {n} locations: layer 1-3 planes, HiBits, AttrA, AttrB",
                not bad["planes"], str(bad["planes"][:4])))
    out.append((f"... and the sizes, wrap masks, limits, half rate, layer-3 flag and own steps for {n} locations",
                not bad["header"], str(bad["header"][:4])))
    out.append((f"... and TM, TS and CGADSUB ($0BD7 / $0BD8 / $0BDF) for {n} locations",
                not bad["screens"], str(bad["screens"][:4])))
    out.append((f"Map_LoadExitTiles (run inside) = exit_tiles over all 64 x 64 tiles for {n} locations",
                not bad["exits"], str(bad["exits"][:4])))
    out.append((f"Map_LoadTreasureTiles ($C0:A712, run) = the treasure records' tiles for {n} locations",
                not bad["treasure"], str(bad["treasure"][:4])))
    out.append((f"... with every treasure taken: {chests} chest tiles step $FE -> $FF / $E0 -> $E1 as taken_props says",
                not bad["taken"], str(bad["taken"][:4])))
    layout = runner.bg_layout()
    want = {0x2105: BGMODE, 0x210B: BG12NBA, 0x210C: BG34NBA, 0x2130: CGWSEL, 0x2132: COLDATA, 0x212C: 0x13}
    out.append(("Ppu_SetBgLayout ($FD:C0D7, run): BGMODE $09, BG12NBA $11, BG34NBA $05, CGWSEL $02, COLDATA $E0, TM $13",
                all(layout.get(k) == v for k, v in want.items()), str({f"${k:04X}": layout.get(k) for k in want})))
    regs = runner.apply_screens(0x13, 0x04, 0x03)
    out.append(("Ppu_ApplyMapScreens ($C0:A509, run) writes the shadows to TM, TS and CGADSUB and 0 to MOSAIC",
                regs == {0x212C: 0x13, 0x212D: 0x04, 0x2131: 0x03, 0x2106: 0}, str(regs)))
    return out


# --- Synthetic vectors for the Swift twin ------------------------------------------------

VECTORS = WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "maps" / "map_vectors.json"


def synthetic_rom():
    """Sparse ROM regions (address -> bytes) with four locations and three
    maps in the real tables' places (no ROM data): a 16 x 16 map with a
    layer-3 plane, runs, a row and a wrapping column exit and two treasures;
    a 32 x 48 map whose layer 2 is 64 x 32 and moves at half rate and by its
    own step, with no Tileset3, edge limits and a redirected treasure list;
    a 64 x 16 map that ends before its triples do; a location sharing map 0."""
    rng = ts.Lcg(0x3A95)
    regions = {}

    def put(long, data):
        regions[long] = bytes(data)

    def triples(n, hi_bits, short=0):
        """n tiles of (HiBits, AttrA, AttrB), runs where a value repeats."""
        out = bytearray()
        k = 0
        while k < n - short:
            h = hi_bits(k) | rng.next(0x20) << 2 if rng.next(3) else hi_bits(k)
            a, b = rng.next(256), rng.next(256)
            run = rng.next(6) + 1 if rng.next(2) else 1
            run = min(run, n - short - k)
            if run > 1 or rng.next(5) == 0:
                out += bytes([h & 0x7F | RUN_FLAG, a, b, run & 0xFF])
            else:
                out += bytes([h & 0x7F, a, b])
            k += run
        return bytes(out)

    def plane(n, top):
        return bytes(rng.next(top) for _ in range(n))

    maps = []
    # Map 0: 16 x 16, layer 2 16 x 16, a layer-3 plane; screens BG1-3 + OBJ main, BG3 sub.
    m0 = bytes([0x00, 0x80, 0x00, 0x00, 0x47, 0x04]) + plane(256, 256) + plane(256, 256) + plane(256, 200)
    m0 += triples(256, lambda k: (k * 7 & 1) | (k * 5 & 2))
    maps.append(m0)
    # Map 1: layer 1 32 x 48 (size1 bits 0-1 = 1, 2-3 = 8), layer 2 64 x 32 (bits 4-5 = $30, 6-7 = $40);
    # Size3: own step 2, half rate 2, layer 3 16 x 16 with no plane; Move2 X -2 Y -1, Move3 X +4 Y +2.
    m1 = bytes([0x01 | 0x08 | 0x30 | 0x40, 0x10 | 0x40, 0x0A | 0x90, 0x03 | 0x20, 0xF7, 0x82])
    m1 += plane(32 * 48, 256) + plane(64 * 32, 256)
    m1 += triples(32 * 48, lambda k: k & 3)
    maps.append(m1)
    # Map 2: 64 x 16, ends 9 tiles before its triples cover layer 1.
    m2 = bytes([0x03 | 0x30, 0x00, 0, 0, 0x13, 0x00]) + plane(64 * 16, 256) + plane(64 * 16, 256)
    m2 += triples(64 * 16, lambda k: 0, short=9)
    maps.append(m2)
    at = 0xE10000
    ptrs = []
    for m in maps:
        packed = ts.pack_bytes(m, 12)
        put(at, packed)
        ptrs.append(at)
        at += len(packed) + 1
    put(MAP_PROPS_PTRS, b"".join(p.to_bytes(3, "little") for p in ptrs))
    # LocRom: music, Tileset12, Tileset3, Palette, MapProps, Unk06, Events, limits.
    recs = [bytes([0x10, 0, 0, 0]) + struct.pack("<HHH", 0, 0, 7) + bytes([2, 1, 13, 14]),
            bytes([0x22, 1, NONE, 1]) + struct.pack("<HHH", 1, 0, 9) + bytes([0x80, 0, 0, 0]),
            bytes([0x05, 0, 0, 1]) + struct.pack("<HHH", 2, 0, 11) + bytes([0, 0, 63, 15]),
            bytes([0x81, 0, 0, 0]) + struct.pack("<HHH", 0, 0, 13) + bytes([0x80, 0, 0, 0])]
    put(LOC_ROM, b"".join(recs))
    # Exits: location 0 has a row exit and a column exit that wraps at 16 rows; location 1 one exit.
    exits = {0: [bytes([3, 4, 2, 1, 0x05, 10, 11]), bytes([15, 14, 0x83, 0xF0, 0x81 | 0x02, 1, 2])],
             1: [bytes([30, 47, 0, 0, 0x06, 3, 4])]}
    first = 2 * (LOC_COUNT + 1)
    offs, body = [], bytearray()
    for i in range(LOC_COUNT + 1):
        offs.append(first + len(body))
        body += b"".join(exits.get(i, []))
    put(EXIT_OFS, b"".join(struct.pack("<H", o) for o in offs) + body)
    # Treasure: location 0 two records, location 1 sends on to location 0's list.
    tre = {0: [struct.pack("<HH", 5 << 8 | 6, 0x0123), struct.pack("<HH", 9 << 8 | 2, 0x8000 | 250)],
           1: [struct.pack("<HH", 0, 0)]}
    base = 0x0400
    offs, body = [], bytearray()
    for i in range(LOC_COUNT + 1):
        offs.append(base + len(body))
        body += b"".join(tre.get(i, []))
    put(TREASURE_OFS, b"".join(struct.pack("<H", o) for o in offs))
    put(TREASURE_BANK + base, body)
    image = bytearray(ts.ROM_SIZE)
    for long, data in regions.items():
        image[pc(long):pc(long) + len(data)] = data
    rom = bytes(image)
    expect = []
    for i in range(4):
        d = decode(rom, i)
        cm, rm = d["masks"]["1"]
        d["exitTiles"] = sorted([k, v] for k, v in exit_tiles(d["exits"], cm, rm).items())
        d["unpacked"] = len(maps[d["header"]["mapProps"]])
        d["image"] = maps[d["header"]["mapProps"]].hex()
        expect.append(d)
    return regions, expect


def vectors_text():
    regions, expect = synthetic_rom()
    head = {"schema": "ct-map-vectors/1",
            "note": "synthetic locations and maps in the real tables' places (no ROM data); expected decode by "
                    "re_workspace/tools/ct_maps.py",
            "regions": [{"at": snes(k), "hex": v.hex()} for k, v in sorted(regions.items())]}
    lines = ["{"]
    for k, v in head.items():
        lines.append(f" {json.dumps(k)}: {json.dumps(v)},")
    lines.append(' "locations": [')
    lines.append(",\n".join("  " + json.dumps(d, sort_keys=True) for d in expect))
    lines.append(" ]")
    lines.append("}")
    return "\n".join(lines) + "\n"


# --- A Studio import ------------------------------------------------------------------------

def map_id(i):
    return f"loc_{i:03d}"


def verify_import(rom, project, locations=None, content_only=False):
    """A Studio import (maps/loc_NNN.map.json) against the decode: [(name, ok, detail)].
    With `content_only` (a ROM built from the project) the `rom` provenance,
    which a build may move, is not compared."""
    out = []
    root = Path(project)
    locations = range(LOC_COUNT) if locations is None else locations
    missing = []
    for i in locations:
        path = root / "maps" / f"{map_id(i)}.map.json"
        if not path.exists():
            missing.append(i)
            continue
        m = json.loads(path.read_text())
        d = decode(rom, i)
        h = d["header"]
        problems = []

        def check(what, ok):
            if not ok:
                problems.append(what)

        layers = {l["bg"]: l for l in m["layers"]}
        for k, plane in d["planes"].items():
            l = layers.get(int(k))
            w, hh = d["sizes"][k]
            check(f"layer {k}", l is not None and l["metatiles"] == plane
                  and (l.get("width", m["width"]), l.get("height", m["height"])) == (w, hh))
        check("layer count", len(m["layers"]) == len(d["planes"]))
        check("size", (m["width"], m["height"]) == tuple(d["sizes"]["1"]))
        tp = m.get("tileProps") or {}
        check("tile properties", (tp.get("width"), tp.get("height")) == tuple(d["sizes"]["1"])
              and bytes.fromhex(tp.get("hiBits", "")) == bytes(d["hiBits"])
              and bytes.fromhex(tp.get("attrA", "")) == bytes(d["attrA"])
              and bytes.fromhex(tp.get("attrB", "")) == bytes(d["attrB"]))
        loc = m.get("location") or {}
        lim = h["limits"]
        check("location record", (loc.get("music"), loc.get("tileset12"), loc.get("tileset3"), loc.get("palette"),
                                  loc.get("events"), loc.get("unk06"), loc.get("limits"))
              == (h["music"], h["tileset12"], h["tileset3"], h["palette"], h["events"], h["unk06"],
                  [lim["left"], lim["top"], lim["right"], lim["bottom"]]))
        s = m.get("settings") or {}
        p = d["props"]
        check("settings", (s.get("screens"), s.get("colorMath"), s.get("move2"), s.get("move3"), s.get("halfRate2"),
                           s.get("ownStep2"), s.get("ownStep3"))
              == (p["screens"], p["colorMath"], p["move2"], p["move3"], p["halfRate2"], p["ownStep2"], p["ownStep3"]))
        want_ts = (f"t12_{h['tileset12']:02d}" if h["tileset12"] != NONE
                   else f"t3_{h['tileset3']:02d}" if h["tileset3"] != NONE else "t12_none")
        check("tileset", m["tileset"] == want_ts)
        ex = m["exits"]
        check("exits", len(ex) == len(d["exits"]) and all(
            (a["x"], a["y"], a["map"], a["toX"], a["toY"], a.get("span", 0), a.get("vertical", False),
             a.get("facing", 0), a.get("facingBit7", False))
            == (e["x"], e["y"], map_id(e["dest"]), e["destX"], e["destY"], e["span"], e["vertical"], e["facing"],
                e["destFlag"]) for a, e in zip(ex, d["exits"])))
        tr = m.get("treasure") or []
        check("treasure", [(t["x"], t["y"], t["contents"]) for t in tr]
              == [(t["x"], t["y"], t["contents"]) for t in d["treasure"]["records"]])
        r = m.get("rom") or {}
        check("rom", content_only or (r.get("location"), r.get("mapProps"), r.get("packedAt"), r.get("packedBytes"),
                      r.get("unpackedBytes"), r.get("staleTiles"), r.get("treasureList"))
              == (i, p["entry"], p["at"], p["packedBytes"], p["length"], p["staleTiles"], d["treasure"]["list"]))
        out.append((f"{map_id(i)}: {d['sizes']['1'][0]} x {d['sizes']['1'][1]}, {len(d['planes'])} layers, "
                    f"{len(d['exits'])} exits, {len(d['treasure']['records'])} treasure as decoded",
                    not problems, ", ".join(problems)))
    if missing:
        out.append((f"{len(missing)} locations not in the project", False, str(missing[:12])))
    return out


# --- CLI ------------------------------------------------------------------------------------------

def summary(d):
    """decode() without the per-tile planes: their sizes and a few counts."""
    out = {k: v for k, v in d.items() if k not in ("planes", "hiBits", "attrA", "attrB")}
    b = d["attrB"]
    out["tiles"] = {"cells": len(b), "blocked": sum(1 for v in b if not v & 4 and not v & 3),
                    "pushing": sum(1 for v in d["attrA"] if v & 0x0C),
                    "shapes": sorted({v >> 2 for v in d["hiBits"]})}
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    d = sub.add_parser("decode")
    d.add_argument("location", type=int)
    d.add_argument("--planes", action="store_true", help="include the per-tile planes")
    d.add_argument("--rom", default=str(ROM_PATH))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(ROM_PATH))
    k.add_argument("--run", action="store_true", help="also run the ROM's own routines in ChronoRET's interpreter")
    v = sub.add_parser("verify-import")
    v.add_argument("project")
    v.add_argument("--rom", default=str(ROM_PATH))
    v.add_argument("--content", action="store_true", help="skip the rom provenance (a ROM built from the project)")
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
        out = decode(rom, args.location)
        print(json.dumps(out if args.planes else summary(out), indent=1))
        return 0
    if args.command == "verify-import":
        return report(verify_import(rom, args.project, content_only=args.content))
    claims = asm_claims() + code_claims(rom) + data_claims(rom)
    if args.run:
        claims += run_claims(rom)
    return report(claims)


if __name__ == "__main__":
    sys.exit(main())
