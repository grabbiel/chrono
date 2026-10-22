#!/usr/bin/env python3
"""Chrono Trigger location tilesets: graphics packs, 16x16 metatiles, palettes, palette and tile animation, evidence.

A location's LocRom record ($F6:0000, 14 B) picks three independent things,
each read by a matched, commented ChronoRET routine (MIT; refs/ChronoRET):

  .Tileset12 (+1)  layers 1/2: LocGfx_Lists entry = 8 graphics-pack numbers
                   (LocLoad_Unk0960 $C0:0960), LocGfx_Meta12Ptrs entry = the
                   packed Map_Meta12 table (LocLoad_Unk09DD $C0:09DD), and,
                   & $3F, the tile-animation list (FieldFD_LoadAnimSetA $FD:DE98)
  .Tileset3  (+2)  layer 3: a LocGfx_PackPtrs entry uploaded to VRAM $5000
                   (LocLoad_Unk6DCF $C0:6DCF) and a LocGfx_Meta3Ptrs entry =
                   the packed Map_Meta3 table (LocLoad_Unk0A14 $C0:0A14)
  .Palette   (+3)  LocPal_Rom entry: colours 1-15 of CGRAM rows 1-7
                   (LocLoad_Unk7084 $C0:7084), and the palette-animation list
                   (FieldFD_LoadAnimSetB $FD:E292, run by PalAnim_TickAll)
  $FF in .Tileset12 / .Tileset3 = nothing loaded.

Graphics. Every pack is Square-LZSS packed (Decomp_ToWram $C3:0557). Packs 0-5
of a list are unpacked one by one to one stage ($7E:3000) and the first $1000
bytes of the stage ($0F80 for pack 5) are DMAed to VRAM word $2000 + $800 k;
packs 6/7 are unpacked to $7F:6000 / $7F:7000 and never uploaded: they are the
frames the tile animations copy from. A pack shorter than its upload sends the
rest of the stage, i.e. what an earlier pack of the list left there. The field
runs mode 1 with BG1/BG2 characters at VRAM word $1000 and BG3's at $5000
(Ppu_SetBgLayout $FD:C0D7), so BG1/2 character n is at $1000 + 16 n (packs 0-5
fill characters 256-1019) and BG3 character n (2bpp) at $5000 + 8 n.

Metatiles. A Map_Meta12 entry (512 per table) or Map_Meta3 entry (256) is four
SNES tilemap words, TL TR BL BR. Map_WriteRow1/Col1 (and 2/3) copy them byte
for byte through WMDATA into a buffer DMAed to the tilemap: the word is the
hardware's (bits 0-9 character, 10-12 palette, 13 priority, 14 hflip, 15
vflip). A map is one byte per 16x16 cell indexing the metatiles directly (bit
8 for layers 1/2 from Map_TileHiBits): there is no 32x32 block layer.

Animation. 12 FieldAnimA records each send 128 bytes (4 tiles) from $7F:xxxx
to a VRAM address, frame f = accumulator bits 9-11, accumulator += step[f] x 4
per upload, each record every other FieldFD_UploadTileAnims call. 12
FieldAnimB records (6 from a location's list) tick every frame
(PalAnim_TickAll): kind 1 copies frame k of `count` colours from $F6:offset,
kind 8 the same with the frame picked by a byte list, kind 2/3 rotate
`count + 1` colours down/up; a record acts when its counter reaches `delay`.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_tilesets.py decode (t12|t3|pal) <n> [--rom PATH]   one tileset as JSON (no tile bytes)
    ct_tilesets.py check [--rom PATH] [--run]             every evidence claim (exit 1 on a failure);
                                                          --run also runs the ROM's decompressor, both
                                                          animation-list loaders and PalAnim_TickAll
    ct_tilesets.py render <t12> --out P [--pal N] [--rom] the 512 metatiles, 16 per row (PNG)
    ct_tilesets.py verify-import <project> [--rom PATH]   a Studio import (tilesets/*) against decode
    ct_tilesets.py vectors (--out | --check) P            synthetic vectors for the Swift twin
"""

import argparse
import json
import re
import struct
import sys
import zlib
from collections import Counter
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
REF = WS / "refs" / "ChronoRET"
ROM_PATH = WS / "ct_clean.sfc"
ROM_SIZE = 4 * 1024 * 1024
CSV = REF / "symbols" / "data_assets.csv"


def pc(long):
    """HiROM file offset of a 24-bit address."""
    return (long >> 16 & 0x3F) << 16 | long & 0xFFFF


def snes(long):
    return f"${long >> 16:02X}:{long & 0xFFFF:04X}"


def u8(rom, long):
    return rom[pc(long)]


def u16(rom, long):
    return rom[pc(long)] | rom[pc(long + 1)] << 8


def u24(rom, long):
    return u16(rom, long) | rom[pc(long + 2)] << 16


# --- Tables ----------------------------------------------------------------------------

LOC_ROM, LOC_COUNT, LOC_BYTES = 0xF60000, 512, 14        # struct LocRom
NONE = 0xFF                                              # !LocRom_SetNone
LISTS, LIST_COUNT, LIST_BYTES = 0xF61C00, 64, 8          # !LocGfx_Lists
MAP_PROPS_PTRS, MAP_PROPS_COUNT = 0xF61E00, 256          # !Map_PropsPtrs
META12_PTRS, META12_COUNT = 0xF62100, 64                 # !LocGfx_Meta12Ptrs
META3_PTRS, META3_COUNT = 0xF621C0, 32                   # !LocGfx_Meta3Ptrs
PACK_PTRS, PACK_COUNT = 0xF62220, 224                    # !LocGfx_PackPtrs
LOC_PAL, PAL_COUNT, PAL_SET_BYTES = 0xF624C0, 88, 0xD2   # !LocPal_Rom, !LocPal_SetBytes
PAL_ROWS, ROW_COLOURS = 7, 15                            # rows 1-7, colours 1-15 (!LocPal_RowBytes = $1E)
META12_BYTES, META3_BYTES = 4096, 2048                   # 512 / 256 metatiles x 4 words

VRAM0, VRAM_STEP = 0x2000, 0x0800                        # !LocGfx_Vram0, !LocGfx_VramStep
PACK_BYTES, PACK5_BYTES = 0x1000, 0x0F80                 # !LocGfx_PackBytes, !LocGfx_Pack5Bytes
VRAM_L3 = 0x5000                                         # !LocGfx_VramL3
BG12_CHAR, BG3_CHAR = 0x1000, 0x5000                     # BG12NBA $11, BG34NBA $05 (Ppu_SetBgLayout)
WINDOW = 1024                                            # characters a tilemap word can name
SLOTS = 6                                                # packs uploaded; 6 and 7 go to bank $7F
ANIM_WRAM = 0x7F6000                                     # !LocGfx_Unk7F6000 (pack 6); pack 7 at +$1000
ANIM_WRAM_BYTES = 0x2000

ANIM_A_PTRS, ANIM_A = 0xFDF290, 0xFDF310                 # !FieldRom_AnimListAPtrs / AnimListA
ANIM_B_PTRS, ANIM_B = 0xFDF9C7, 0xFDFA77                 # !FieldRom_AnimListBPtrs / AnimListB
ANIM_SET_MASK = 0x3F                                     # !LocRom_AnimSetMask
RECORDS, B_FILLED = 12, 6                                # !FieldAnim_NumRecs, !FieldAnimB_Filled
END_RECORD = 0x80                                        # !FieldAnim_EndRecord
TILE_ANIM_BYTES, FRAME_MASK = 0x80, 0x0E00               # !FieldAnimA_TileBytes, !FieldAnimA_FrameMask
ANIM_DATA = 0x7F0400                                     # !FieldAnimA_Data: 32 B per record
PAL_ANIM_ROM = 0xF60000                                  # !PalAnimRom
CYCLE_KINDS = {1: "rom-frames", 2: "rotate-down", 3: "rotate-up", 4: "fade-white", 5: "fade",
               6: "pulse-white", 7: "pulse", 8: "list-frames"}


# --- Square LZSS (Decomp_ToWram $C3:0557) ------------------------------------------------

def unpack_bytes(src):
    """(unpacked, mode 11 | 12, packed bytes consumed) of the stream at the
    start of `src`: u16 W, then 8-item groups behind control bytes (LSB first,
    0 = 8 literals, set bit = u16 back-reference: lz12 distance v & $FFF,
    length (v >> 12) + 3; lz11 v & $7FF, (v >> 11) + 3) up to offset 2 + W,
    where a marker byte ends the stream (count bits 0-5 = 0) or gives the
    next group's item count and the next segment's end (u16 from the start).
    Bits 6-7 of the first marker pick the mode."""
    src = bytes(src)

    def word(i):
        if i + 2 > len(src):
            raise ValueError("stream runs past its source")
        return src[i] | src[i + 1] << 8

    seg = 2 + word(0)
    if seg >= len(src):
        raise ValueError("first end marker past the source")
    mode = 11 if src[seg] & 0xC0 else 12
    out = bytearray()
    x = 2
    while True:
        left = 8
        while True:
            if x == seg:
                count = src[x] & 0x3F
                if count == 0:
                    return bytes(out), mode, x + 1
                left = count
                seg = word(x + 1)
                x += 3
                continue
            if x >= len(src):
                raise ValueError("stream runs past its source")
            control = src[x]
            if control == 0:
                if x + 9 > len(src):
                    raise ValueError("literal run past the source")
                out += src[x + 1:x + 9]
                x += 9
                break
            x += 1
            group_done = False
            while True:
                if control & 1:
                    v = word(x)
                    x += 2
                    dist, n = (v & 0xFFF, (v >> 12) + 3) if mode == 12 else (v & 0x7FF, (v >> 11) + 3)
                    if not 0 < dist <= len(out):
                        raise ValueError(f"back-reference {dist} with {len(out)} bytes out")
                    at = len(out) - dist
                    for _ in range(n):
                        out.append(out[at])
                        at += 1
                else:
                    if x >= len(src):
                        raise ValueError("stream runs past its source")
                    out.append(src[x])
                    x += 1
                if len(out) > 0x10000:
                    raise ValueError("more than 64 KiB out")
                left -= 1
                if left == 0:
                    group_done = True
                    break
                control >>= 1
            if group_done:
                break


def unpack(rom, long):
    return unpack_bytes(rom[pc(long):pc(long) + 0x10000])


def pack_bytes(data, mode=12):
    """A one-segment stream the decoder above (and the game's) reads back as
    `data`: greedy matches, for the synthetic vectors only (not the ROM's packer)."""
    data = bytes(data)
    window, longest = (0xFFF, 18) if mode == 12 else (0x7FF, 34)
    items, i = [], 0
    while i < len(data):
        best, best_d = 0, 0
        for d in range(1, min(i, window) + 1):
            n = 0
            while n < longest and i + n < len(data) and data[i + n - d] == data[i + n]:
                n += 1
            if n > best:
                best, best_d = n, d
        if best >= 3:
            v = best_d | (best - 3) << (12 if mode == 12 else 11)
            items.append((True, v))
            i += best
        else:
            items.append((False, data[i]))
            i += 1
    mode_bits = 0x40 if mode == 11 else 0x00

    def group_bytes(group):
        control = sum(1 << k for k, (ref, _) in enumerate(group) if ref)
        if control == 0 and len(group) < 8:
            control = 1 << len(group)                    # a bit past the group's count: never read
        out = bytearray([control])
        for ref, v in group:
            out += struct.pack("<H", v) if ref else bytes([v])
        return out

    whole = len(items) // 8 * 8
    body = bytearray()
    for g in range(0, whole, 8):
        body += group_bytes(items[g:g + 8])
    stream = bytearray(struct.pack("<H", len(body))) + body
    rest = items[whole:]
    if rest:                                             # a marker gives the last group's count
        tail = group_bytes(rest)
        stream += bytes([len(rest) | mode_bits]) + struct.pack("<H", len(stream) + 3 + len(tail)) + tail
    return bytes(stream + bytes([mode_bits]))


# --- Locations ---------------------------------------------------------------------------

def locations(rom):
    out = []
    for i in range(LOC_COUNT):
        at = LOC_ROM + LOC_BYTES * i
        out.append({"id": i, "tileset12": u8(rom, at + 1), "tileset3": u8(rom, at + 2),
                    "palette": u8(rom, at + 3), "mapProps": u16(rom, at + 4)})
    return out


def users(rom, field):
    """{value: [location ids]} of a LocRom field, $FF left out."""
    out = {}
    for loc in locations(rom):
        if loc[field] != NONE:
            out.setdefault(loc[field], []).append(loc["id"])
    return out


def most_common(rom, key_field, key, field):
    picks = Counter(loc[field] for loc in locations(rom) if loc[key_field] == key and loc[field] != NONE)
    return min(picks, key=lambda v: (-picks[v], v)) if picks else None


# --- Graphics ----------------------------------------------------------------------------

def pack_list(rom, t):
    at = LISTS + LIST_BYTES * t
    return [None if u8(rom, at + k) == NONE else u8(rom, at + k) for k in range(LIST_BYTES)]


def pack(rom, n):
    at = u24(rom, PACK_PTRS + 3 * n)
    data, mode, used = unpack(rom, at)
    return {"pack": n, "at": at, "data": data, "mode": mode, "packed": used}


def bg12_vram(rom, t):
    """The BG1/2 character window (1024 x 32 B, None = not set by this
    tileset) after LocLoad_Unk0960, and its uploads."""
    window = [None] * (WINDOW * 32)
    stage = [None] * PACK_BYTES
    uploads = []
    for k, n in enumerate(pack_list(rom, t)[:SLOTS]):
        size = PACK5_BYTES if k == SLOTS - 1 else PACK_BYTES
        vram = VRAM0 + VRAM_STEP * k
        first = (vram - BG12_CHAR) // 16
        up = {"slot": k, "pack": n, "vram": vram, "firstTile": first, "tiles": size // 32}
        if n is not None:
            p = pack(rom, n)
            stage[:min(len(p["data"]), PACK_BYTES)] = p["data"][:PACK_BYTES]
            window[first * 32:first * 32 + size] = stage[:size]
            up.update(at=snes(p["at"]), packed=p["packed"], unpacked=len(p["data"]),
                      ownTiles=min(len(p["data"]), size) // 32)
        uploads.append(up)
    return window, uploads


def anim_wram(rom, t):
    """$7F:6000-$7FFF after LocLoad_UnpackPacks67 (None = not set), and its packs."""
    image = [None] * ANIM_WRAM_BYTES
    used = []
    for k, n in ((6, pack_list(rom, t)[6]), (7, pack_list(rom, t)[7])):
        if n is None:
            continue
        p = pack(rom, n)
        base = 0x1000 * (k - 6)
        data = p["data"][:ANIM_WRAM_BYTES - base]
        image[base:base + len(data)] = data
        used.append({"slot": k, "pack": n, "at": snes(p["at"]), "packed": p["packed"],
                     "unpacked": len(p["data"]), "wram": snes(ANIM_WRAM + base)})
    return image, used


def bg3_vram(rom, n):
    """The BG3 character window (1024 x 16 B) after LocLoad_Unk6DCF: the pack
    as unpacked; the rest of its $1000-byte upload comes from past the stage
    ($7F:5080 + length), which this tileset does not set."""
    window = [None] * (WINDOW * 16)
    p = pack(rom, n)
    own = min(len(p["data"]), PACK_BYTES)
    first = (VRAM_L3 - BG3_CHAR) // 8
    window[first * 16:first * 16 + own] = p["data"][:own]
    return window, {"slot": 0, "pack": n, "vram": VRAM_L3, "firstTile": first, "tiles": PACK_BYTES // 16,
                    "at": snes(p["at"]), "packed": p["packed"], "unpacked": len(p["data"]), "ownTiles": own // 16}


def known_tiles(window, tile_bytes):
    return [all(b is not None for b in window[t * tile_bytes:(t + 1) * tile_bytes]) for t in range(WINDOW)]


def ranges(flags):
    """[[first, end)] of the runs of True."""
    out, start = [], None
    for i, f in enumerate(list(flags) + [False]):
        if f and start is None:
            start = i
        elif not f and start is not None:
            out.append([start, i])
            start = None
    return out


def tile_indices(raw, bpp):
    """64 row-major palette indices of one SNES planar tile (planes 0/1
    interleaved per row; 4bpp: planes 2/3 sixteen bytes later)."""
    out = []
    for r in range(8):
        planes = [raw[2 * r], raw[2 * r + 1]] + ([raw[16 + 2 * r], raw[17 + 2 * r]] if bpp == 4 else [])
        for c in range(8):
            out.append(sum((p >> (7 - c) & 1) << k for k, p in enumerate(planes)))
    return out


def window_indices(window, bpp):
    tb = 32 if bpp == 4 else 16
    return [tile_indices([b or 0 for b in window[t * tb:(t + 1) * tb]], bpp) for t in range(WINDOW)]


# --- Metatiles ---------------------------------------------------------------------------

def meta_table(rom, ptrs, i):
    at = u24(rom, ptrs + 3 * i)
    data, mode, used = unpack(rom, at)
    words = [data[k] | data[k + 1] << 8 for k in range(0, len(data) - 1, 2)]
    return {"at": at, "mode": mode, "packed": used, "length": len(data),
            "metatiles": [words[k:k + 4] for k in range(0, len(words) - 3, 4)]}


def chip(word):
    return {"tile": word & 0x3FF, "palette": word >> 10 & 7, "priority": word >> 13 & 1,
            "hflip": word >> 14 & 1, "vflip": word >> 15 & 1}


# --- Palettes ----------------------------------------------------------------------------

def palette_set(rom, p):
    """Colours 1-15 of rows 1-7 (BGR555 words)."""
    at = LOC_PAL + PAL_SET_BYTES * p
    return [[u16(rom, at + 2 * (ROW_COLOURS * r + c)) for c in range(ROW_COLOURS)] for r in range(PAL_ROWS)]


def cgram(rom, p):
    """256 CGRAM words with the location's rows set and the rest 0."""
    out = [0] * 256
    for r, row in enumerate(palette_set(rom, p)):
        out[16 * (r + 1) + 1:16 * (r + 1) + 16] = row
    return out


# --- Tile animations (FieldAnimA) --------------------------------------------------------

def anim_list_a(rom, t):
    """The 12 records FieldFD_LoadAnimSetA reads for LocRom.Tileset12 t:
    (records, list address, end address); an $80 record is None."""
    start = ANIM_A + u16(rom, ANIM_A_PTRS + 2 * (t & ANIM_SET_MASK))
    at, records = start, []
    for _ in range(RECORDS):
        kind = u8(rom, at)
        if kind == END_RECORD:
            records.append(None)
            at += 1
            continue
        n = 2 if kind == 2 else 4 if kind == 4 else 8
        vram = u16(rom, at + 1)
        steps = [u8(rom, at + 3 + i) for i in range(n)]
        sources = [u16(rom, at + 3 + n + 2 * i) for i in range(n)]
        records.append({"kind": kind, "vram": vram, "steps": steps, "sources": sources,
                        "steps8": steps * (8 // n), "sources8": sources * (8 // n)})
        at += 3 + 3 * n
    return records, start, at


def anim_data(records):
    """The 32 bytes per record FieldFD_LoadAnimSetA writes at $7F:0400 on
    (8 step words = byte x 4, then 8 source words), $80 records adding none."""
    out = b""
    for r in records:
        if r is not None:
            out += b"".join(struct.pack("<H", 4 * s) for s in r["steps8"])
            out += b"".join(struct.pack("<H", s) for s in r["sources8"])
    return out


def anim_frames(record, uploads):
    """The frame FieldFD_UploadTileAnims sends at each of the record's first
    `uploads` turns (the accumulator starts at 0)."""
    acc, out = 0, []
    for _ in range(uploads):
        f = (acc & FRAME_MASK) >> 9
        out.append(f)
        acc = (acc + 4 * record["steps8"][f]) & 0xFFFF
    return out


# --- Palette animations (FieldAnimB) -----------------------------------------------------

def anim_list_b(rom, p):
    """The 6 records FieldFD_LoadAnimSetB reads for LocRom.Palette p:
    (records, list address, end address); an empty record is None."""
    start = ANIM_B + u16(rom, ANIM_B_PTRS + 2 * p)
    at, records = start, []
    for _ in range(B_FILLED):
        b = u8(rom, at)
        kind = b >> 4
        if kind == 0:
            records.append(None)
            at += 1
            continue
        r = {"byte0": b, "kind": kind, "name": CYCLE_KINDS[kind], "first": u8(rom, at + 1),
             "count": u8(rom, at + 2), "delay": u8(rom, at + 3)}
        if kind in (1, 8):
            r["offset"] = u16(rom, at + 4)
            r["bank"] = u8(rom, at + 6)
            at += 7
            if kind == 8:
                r["order"] = [u8(rom, at + i) for i in range((b & 0x0F) + 1)]
                at += (b & 0x0F) + 1
            r["frames"] = (b & 0x0F) + 1
            shown = max(r["order"]) + 1 if kind == 8 else r["frames"]
            r["colours"] = [[u16(rom, PAL_ANIM_ROM + r["offset"] + 2 * (f * r["count"] + c))
                             for c in range(r["count"])] for f in range(shown)]
        else:
            at += 4
        records.append(r)
    return records, start, at


class CycleState:
    """PalAnim_TickAll for the location kinds (1, 2, 3, 8) over a CGRAM image."""

    def __init__(self, records):
        self.records = [dict(r, frame=0, counter=0) if r else None for r in records]

    def tick(self, cg):
        for r in self.records:
            if r is None:
                continue
            r["counter"] = (r["counter"] + 1) & 0xFF
            if r["counter"] != r["delay"]:
                continue
            r["counter"] = 0
            k, first, count = r["kind"], r["first"], r["count"]
            if k in (1, 8):
                r["frame"] = (r["frame"] + 1) & 0xFF
                if r["frame"] == (r["byte0"] & 0x0F) + 1:
                    r["frame"] = 0
                shown = r["order"][r["frame"]] if k == 8 else r["frame"]
                for c in range(count):
                    cg[(first + c) & 0xFF] = r["colours"][shown][c]
            elif k == 2:                                  # down: each takes the one above
                keep = cg[first]
                for c in range(first, first + count):
                    cg[c] = cg[c + 1]
                cg[first + count] = keep
            elif k == 3:                                  # up: each takes the one below
                keep = cg[first + count]
                for c in range(first + count, first, -1):
                    cg[c] = cg[c - 1]
                cg[first] = keep
        return cg


# --- Maps (for the reference invariants) -----------------------------------------------------

def map_planes(rom, entry):
    """Layer grids {1: [[metatile]], 2: ..., 3: ...} of a MapProps pack
    (Map_UnpackTilePlanes), with bit 8 from the HiBits of the attr triples
    over layer 1's size; also whether the parse used every byte."""
    data, _, _ = unpack(rom, u24(rom, MAP_PROPS_PTRS + 3 * entry))
    s1, s3 = data[0], data[1]
    w1, h1 = ((s1 & 3) + 1) * 16, ((s1 & 0x0C) + 4) * 4      # !MapProps_WidthBits / HeightBits
    w2, h2 = (s1 & 0x30) + 0x10, ((s1 & 0xC0) >> 2) + 0x10   # !MapProps_L2WidthBits / L2HeightBits
    w3, h3 = ((s3 & 3) + 1) * 16, ((s3 & 0x0C) + 4) * 4
    at = 6
    grids = {}
    for layer, (w, h) in ((1, (w1, h1)), (2, (w2, h2)), (3, (w3, h3))):
        if layer == 3 and not s3 & 0x80:
            continue
        grids[layer] = [list(data[at + r * w:at + (r + 1) * w]) for r in range(h)]
        at += w * h
    hi, n = [], w1 * h1
    while len(hi) < n and at < len(data):
        b = data[at]
        if b & 0x80:
            count = data[at + 3] or 256
            hi += [b & 0x7F] * count
            at += 4
        else:
            hi.append(b)
            at += 3
    short = max(0, n - len(hi))                           # the game reads on past the unpacked data
    hi = hi[:n] + [0] * short
    for r in range(h1):
        for c in range(w1):
            grids[1][r][c] |= (hi[r * w1 + c] & 1) << 8
            if r < h2 and c < w2:
                grids[2][r][c] |= (hi[r * w1 + c] >> 1 & 1) << 8
    return grids, (w1, h1), (at == len(data), short)


# --- Decoders ----------------------------------------------------------------------------

def decode_t12(rom, t):
    window, uploads = bg12_vram(rom, t)
    meta = meta_table(rom, META12_PTRS, t)
    wram, anim_packs = anim_wram(rom, t)
    records, list_at, list_end = anim_list_a(rom, t)
    known = known_tiles(window, 32)
    return {"kind": "bg12", "index": t, "bpp": 4, "list": {"at": snes(LISTS + LIST_BYTES * t), "packs": pack_list(rom, t)},
            "meta": {k: (snes(v) if k == "at" else v) for k, v in meta.items() if k != "metatiles"},
            "metatiles": meta["metatiles"], "uploads": uploads, "knownTiles": ranges(known),
            "animWram": anim_packs, "animKnown": ranges(b is not None for b in wram),
            "tileAnims": {"set": t & ANIM_SET_MASK, "at": snes(list_at), "end": snes(list_end),
                          "records": [r and {k: v for k, v in r.items() if k not in ("steps8", "sources8")} for r in records]},
            "locations": users(rom, "tileset12").get(t, []),
            "preview": {"palette": most_common(rom, "tileset12", t, "palette"),
                        "tileset3": most_common(rom, "tileset12", t, "tileset3")}}


def decode_t3(rom, n):
    window, upload = bg3_vram(rom, n)
    meta = meta_table(rom, META3_PTRS, n)
    return {"kind": "bg3", "index": n, "bpp": 2,
            "meta": {k: (snes(v) if k == "at" else v) for k, v in meta.items() if k != "metatiles"},
            "metatiles": meta["metatiles"], "uploads": [upload], "knownTiles": ranges(known_tiles(window, 16)),
            "locations": users(rom, "tileset3").get(n, [])}


def decode_pal(rom, p):
    records, list_at, list_end = anim_list_b(rom, p)
    return {"kind": "palette", "index": p, "at": snes(LOC_PAL + PAL_SET_BYTES * p), "rows": palette_set(rom, p),
            "cycles": {"at": snes(list_at), "end": snes(list_end), "records": records},
            "locations": users(rom, "palette").get(p, [])}


def used_t12(rom):
    return sorted(users(rom, "tileset12"))


def used_t3(rom):
    return sorted(users(rom, "tileset3"))


def used_pal(rom):
    return sorted(users(rom, "palette"))


# --- Evidence: ChronoRET's source --------------------------------------------------------

# Each routine holds these lines in this order (comments stripped).
ASM_CLAIMS = (
    ("bankC0/bankC0.asm", "LocLoad_Unk0960",
     ("LDA.l LocRom.Tileset12,X", "CMP.b #!LocRom_SetNone", "LDA.b #!LocGfx_ListSize", "ADC.w #!LocGfx_Lists&$FFFF",
      "LDX.w #!LocGfx_Vram0", "LDX.w #!LocGfx_Stage&$FFFF", "LDX.w #!LocGfx_PackBytes", "JSR LocLoad_UploadPack",
      "LDX.w #!LocGfx_Vram0+(1*!LocGfx_VramStep)", "JSR LocLoad_UploadPack",
      "LDX.w #!LocGfx_Vram0+(5*!LocGfx_VramStep)", "LDX.w #!LocGfx_Pack5Bytes", "JSR LocLoad_UploadPack",
      "BRL LocLoad_UnpackPacks67")),
    ("bankC0/bankC0.asm", "LocLoad_UploadPack",
     ("LDA.b [!LocGfx_PackListPtr]", "CMP.b #!LocRom_SetNone", "LDA.l !LocGfx_PackPtrs,X",
      "LDA.w #!LocGfx_Stage&$FFFF", "JSL Decomp_ToWramVec", "JSR VramDma_Upload")),
    ("bankC0/bankC0.asm", "LocLoad_UnpackPacks67",
     ("LDA.l !LocGfx_PackPtrs,X", "LDA.w #!LocGfx_Unk7F6000&$FFFF", "LDA.b #!Bank7F", "JSL Decomp_ToWramVec",
      "LDA.l !LocGfx_PackPtrs,X", "LDA.w #!LocGfx_Unk7F7000&$FFFF", "JSL Decomp_ToWramVec")),
    ("bankC0/bankC0.asm", "LocLoad_Unk09DD",
     ("LDA.l LocRom.Tileset12,X", "CMP.b #!LocRom_SetNone", "LDA.l !LocGfx_Meta12Ptrs,X",
      "LDA.w #!Map_Meta12TL&$FFFF", "JSL Decomp_ToWramVec")),
    ("bankC0/bankC0.asm", "LocLoad_Unk0A14",
     ("LDA.l LocRom.Tileset3,X", "CMP.b #!LocRom_SetNone", "LDA.l !LocGfx_Meta3Ptrs,X",
      "LDA.w #!Map_Meta3TL&$FFFF", "JSL Decomp_ToWramVec")),
    ("bankC0/bankC0.asm", "LocLoad_Unk6DCF",
     ("LDA.l LocRom.Tileset3,X", "CMP.b #!LocRom_SetNone", "LDA.l !LocGfx_PackPtrs,X",
      "LDA.w #!LocGfx_StageL3&$FFFF", "JSL Decomp_ToWramVec", "LDX.w #!LocGfx_VramL3",
      "LDX.w #!LocGfx_PackBytes", "JSR VramDma_Upload")),
    ("bankC0/bankC0.asm", "LocLoad_Unk7084",
     ("LDA.l LocRom.Palette,X", "LDA.b #!LocPal_SetBytes", "ADC.w #!LocPal_Rom&$FFFF", "LDY.w #!Pal_LocRows&$FFFF",
      "LDA.w #!LocPal_RowBytes-1", "INY", "INY", "LDA.w #!LocPal_RowBytes-1")),
    # Field PPU layout: mode 1, BG1/2 characters at $1000, BG3's at $5000.
    ("bankFD/bankFD.asm", "Ppu_SetBgLayout",
     ("LDA.b #BG_MODE_1|BG3_HIGH_PRIO", "STA.b BGMODE-!DP_PPU", "LDA.b #!BG12NBA_Both1000", "STA.b BG12NBA-!DP_PPU",
      "LDA.b #!BG34NBA_Bg3At5000", "STA.b BG34NBA-!DP_PPU")),
    # A map cell's metatile number x 8 indexes Map_Meta12; the words go out unchanged.
    ("bankC0/bankC0.asm", "Map_WriteRow1",
     ("LDA.l !Map_TileHiBits,X", "AND.b #$01", "XBA", "LDA.l !Map_TileProps,X", "ASL A", "ASL A", "ASL A", "TAX",
      "LDA.l !Map_Meta12TL,X", "STA.w WMDATA", "XBA", "STA.w WMDATA", "LDA.l !Map_Meta12TR,X", "STA.w WMDATA",
      "LDA.l !Map_Meta12TR+1,X", "STA.w WMDATA")),
    ("bankC0/bankC0.asm", "Map_WriteRow3",
     ("LDA.l !Map_Layer3Tiles,X", "AND.w #!Eng_LowByteMask", "ASL A", "ASL A", "ASL A", "TAX",
      "LDA.l !Map_Meta3TL,X", "STA.w WMDATA", "XBA", "STA.w WMDATA")),
    ("bankC0/bankC0.asm", "Map_UploadBuf_Tail",
     ("LDA.b #$01", "STA.b !VramDma_Mode", "LDX.w #!Map_BufC800&$FFFF", "BRL VramDma_Upload")),
    ("bankFD/bankFD.asm", "FieldFD_LoadAnimSetA",
     ("LDA.l LocRom.Tileset12,X", "AND.b #!LocRom_AnimSetMask", "ASL A", "LDA.l !FieldRom_AnimListAPtrs,X",
      "LDA.w #!FieldAnimA_Wram", "LDA.b #!Bank7F", "CMP.b #!FieldAnim_EndRecord", "CMP.b #!FieldAnim_Kind2",
      "CMP.b #!FieldAnim_Kind4")),
    ("bankFD/bankFD.asm", "FieldFD_UploadTileAnims",
     ("INC.b !FieldAnimA_Phase", "LDY.b #!FieldAnimA_TileBytes", "LSR A", "AND.w #!FieldAnimA_FrameMask", "XBA",
      "ADC.l !FieldAnimA_Data,X", "LDA.l !FieldAnimA_Data+16,X", "STY.w MDMAEN")),
    ("bankFD/bankFD.asm", "FieldFD_LoadAnimSetB",
     ("LDA.l LocRom.Palette,X", "LDA.l !FieldRom_AnimListBPtrs,X", "AND.b #!FieldAnimB_KindMask",
      "CMP.b #!FieldAnimB_Kind10", "CMP.b #!FieldAnimB_Kind80", "AND.b #!FieldAnimB_SkipMask")),
    ("bankFD/bankFD.asm", "PalAnim_TickAll",
     ("CMP.w FieldAnimB.Unk5,Y", "AND.b #!PalAnim_KindMask", "CMP.b #!PalAnimKind_Rom", "CMP.b #!PalAnimKind_List",
      "AND.b #!PalAnim_LenMask", "JSR PalAnim_CopyRomFrame", "JSR PalAnim_RotateDown", "JSR PalAnim_RotateUp",
      "JSR PalAnim_CopyListFrame")),
    ("bankFD/bankFD.asm", "PalAnim_CopyRomFrame",
     ("ADC.w #!Pal_CgramBuf&$FFFF", "LDA.w FieldAnimB.Unk6,Y", "ADC.w RDMPYL", "LDA.l !PalAnimRom,X")),
    ("bankFD/bankFD.asm", "PalAnim_RotateDown",
     ("LDA.w !Pal_Buf+2,X", "STA.w !Pal_Buf,X", "LDA.w !Pal_CgramBuf+2,X", "STA.w !Pal_CgramBuf,X")),
    ("bankFD/bankFD.asm", "PalAnim_RotateUp",
     ("LDA.w !Pal_Buf-2,X", "STA.w !Pal_Buf,X", "LDA.w !Pal_CgramBuf-2,X", "STA.w !Pal_CgramBuf,X")),
)

CONSTANT_CLAIMS = (
    ("include/constants_engine.inc", "!LocRom_SetNone = $FF"),
    ("include/constants_engine.inc", "!LocGfx_ListSize = $08"),
    ("include/constants_engine.inc", "!LocGfx_Vram0 = $2000"),
    ("include/constants_engine.inc", "!LocGfx_VramStep = $0800"),
    ("include/constants_engine.inc", "!LocGfx_PackBytes = $1000"),
    ("include/constants_engine.inc", "!LocGfx_Pack5Bytes = $0F80"),
    ("include/constants_engine.inc", "!LocGfx_VramL3 = $5000"),
    ("include/constants_engine.inc", "!LocPal_RowBytes = $1E"),
    ("include/constants_engine.inc", "!LocPal_RowStep = $20"),
    ("include/constants_engine.inc", "!LocPal_SetBytes = $D2"),
    ("include/constants_engine.inc", "!FieldRom_AnimListAPtrs = $FDF290"),
    ("include/constants_engine.inc", "!FieldRom_AnimListA = $FDF310"),
    ("include/constants_engine.inc", "!FieldRom_AnimListBPtrs = $FDF9C7"),
    ("include/constants_engine.inc", "!FieldRom_AnimListB = $FDFA77"),
    ("include/constants_engine.inc", "!LocRom_AnimSetMask = $3F"),
    ("include/constants_engine.inc", "!FieldAnimA_Wram = $0400"),
    ("include/constants_engine.inc", "!FieldAnim_NumRecs = 12"),
    ("include/constants_engine.inc", "!FieldAnimA_FrameMask = $0E00"),
    ("include/constants_engine.inc", "!FieldAnimA_TileBytes = $80"),
    ("include/constants_engine.inc", "!PalAnim_KindMask = $F0"),
    ("include/constants_engine.inc", "!PalAnim_LenMask = $0F"),
    ("include/constants_engine.inc", "!FieldAnimB_Filled = 6"),
    ("include/ram_engine.inc", "!LocGfx_Lists = $F61C00"),
    ("include/ram_engine.inc", "!LocGfx_PackPtrs = $F62220"),
    ("include/ram_engine.inc", "!LocGfx_Meta12Ptrs = $F62100"),
    ("include/ram_engine.inc", "!LocGfx_Meta3Ptrs = $F621C0"),
    ("include/ram_engine.inc", "!LocPal_Rom = $F624C0"),
    ("include/ram_engine.inc", "!LocGfx_Unk7F6000 = $7F6000"),
    ("include/ram_engine.inc", "!LocGfx_Unk7F7000 = $7F7000"),
    ("include/ram_engine.inc", "!Pal_LocRows = $7E2022"),
    ("include/ram_engine.inc", "!Map_PropsPtrs = $F61E00"),
    ("include/ram_engine.inc", "!PalAnimRom = $F60000"),
    ("hardware.inc", "!BG12NBA_Both1000      = $11"),
    ("hardware.inc", "!BG34NBA_Bg3At5000     = $05"),
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

    gfx = _body(rom, 0xC00960, 0xC009DC)
    claim("$C0:0960 multiplies Tileset12 by 8 (LDA #$08; STA WRMPYB) and adds $1C00 (ADC #$1C00)",
          b"\xa9\x08\x8d\x03\x42" in gfx and b"\x69\x00\x1c" in gfx)
    claim("$C0:0960 uploads to VRAM $2000, $2800 ... $4800 (LDX #$2000 ... LDX #$4800), $0F80 bytes last",
          all(struct.pack("<BH", 0xA2, VRAM0 + VRAM_STEP * k) in gfx for k in range(SLOTS))
          and b"\xa2\x80\x0f" in gfx)
    l3 = _body(rom, 0xC06DCF, 0xC06E26)
    claim("$C0:6DCF uploads $1000 bytes (LDX #$1000) to VRAM $5000 (LDX #$5000)",
          b"\xa2\x00\x50" in l3 and b"\xa2\x00\x10" in l3)
    m12 = _body(rom, 0xC009DD, 0xC00A13)
    claim("$C0:09DD reads LocGfx_Meta12Ptrs (LDA.l $F62100,X) into $7E:B000 (LDA #$B000)",
          b"\xbf\x00\x21\xf6" in m12 and b"\xa9\x00\xb0" in m12)
    m3 = _body(rom, 0xC00A14, 0xC00A4F)
    claim("$C0:0A14 reads LocGfx_Meta3Ptrs (LDA.l $F621C0,X) into $7E:C000 (LDA #$C000)",
          b"\xbf\xc0\x21\xf6" in m3 and b"\xa9\x00\xc0" in m3)
    pal = _body(rom, 0xC07084, 0xC070E8)
    claim("$C0:7084 multiplies the palette by $D2 (LDA #$D2) and copies 30-byte rows (LDA #$001D) to $7E:2022",
          b"\xa9\xd2\x8d\x03\x42" in pal and pal.count(b"\xa9\x1d\x00") == PAL_ROWS and b"\xa0\x22\x20" in pal)
    layout = _body(rom, 0xFDC0D7, 0xFDC123)
    claim("$FD:C0D7 writes BG12NBA $11 and BG34NBA $05 (LDA #$11; STA $0B; LDA #$05; STA $0C with D = $2100)",
          b"\xa9\x11\x85\x0b" in layout and b"\xa9\x05\x85\x0c" in layout)
    row1 = _body(rom, 0xC07612, 0xC077E3)
    claim("$C0:7612 reads Map_Meta12TL (LDA.l $7EB000,X) and writes WMDATA (STA $2180)",
          b"\xbf\x00\xb0\x7e" in row1 and b"\x8d\x80\x21" in row1)
    seta = _body(rom, 0xFDDE98, 0xFDE021)
    claim("$FD:DE98 masks Tileset12 with $3F and reads $FD:F290 / $FD:F310 lists (LDA.l $FDF290,X; LDA.l $FDF310,X)",
          b"\x29\x3f" in seta and b"\xbf\x90\xf2\xfd" in seta and b"\xbf\x10\xf3\xfd" in seta)
    setb = _body(rom, 0xFDE292, 0xFDE39B)
    claim("$FD:E292 reads $FD:F9C7 / $FD:FA77 lists (LDA.l $FDF9C7,X; LDA.l $FDFA77,X)",
          b"\xbf\xc7\xf9\xfd" in setb and b"\xbf\x77\xfa\xfd" in setb)
    up = _body(rom, 0xFDE022, 0xFDE274)
    claim("$FD:E022 masks the accumulator with $0E00 (AND #$0E00) and sends $80 bytes (LDY #$80)",
          b"\x29\x00\x0e" in up and b"\xa0\x80" in up)
    rom_frame = _body(rom, 0xFDE437, 0xFDE484)
    claim("$FD:E437 reads colours from bank $F6 (LDA.l $F60000,X)", b"\xbf\x00\x00\xf6" in rom_frame)
    return out


# --- Evidence: the data ------------------------------------------------------------------

def csv_packs(path=CSV):
    """{start address: (name, packed bytes, unpacked bytes, mode)} of the packed pieces."""
    out = {}
    if not Path(path).exists():
        return out
    for line in Path(path).read_text().splitlines():
        cols = line.split(",")
        if line.startswith("#") or len(cols) < 7 or cols[4] != "packed":
            continue
        m = re.match(r"lz(11|12) -> (\d+) B", cols[6])
        if not m:
            continue
        bank, low = cols[1].lstrip("$").split(":")
        out[int(bank, 16) << 16 | int(low, 16)] = (cols[0], int(cols[3]), int(m.group(2)), int(m.group(1)))
    return out


def data_claims(rom, csv=CSV):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    locs = locations(rom)
    t12s, t3s, pals = used_t12(rom), used_t3(rom), used_pal(rom)
    claim(f"LocRom: {LOC_COUNT} records; .Tileset12 values {min(t12s)}-{max(t12s)} ({len(t12s)} used) or $FF, "
          f".Tileset3 {min(t3s)}-{max(t3s)} ({len(t3s)}) or $FF, .Palette below {PAL_COUNT} ({len(pals)} used)",
          max(t12s) < META12_COUNT and max(t3s) < META3_COUNT and max(pals) < PAL_COUNT,
          f"{sum(1 for x in locs if x['tileset12'] == NONE)} without layers 1/2, "
          f"{sum(1 for x in locs if x['tileset3'] == NONE)} without layer 3")
    packs = csv_packs(csv)

    # Metatile tables.
    m12 = {i: meta_table(rom, META12_PTRS, i) for i in range(META12_COUNT)}
    real12 = sorted(i for i, m in m12.items() if m["length"] == META12_BYTES)
    stub12 = sorted(i for i, m in m12.items() if m["length"] != META12_BYTES)
    claim(f"LocGfx_Meta12Ptrs: every used .Tileset12 unpacks to {META12_BYTES} B = 512 metatiles; "
          f"the {len(stub12)} others ({stub12}) to {sorted({m12[i]['length'] for i in stub12})} B",
          set(t12s) <= set(real12) and not set(stub12) & set(t12s), f"real {len(real12)}")
    m3 = {}
    for i in range(META3_COUNT):
        p = u24(rom, META3_PTRS + 3 * i)
        try:
            m3[i] = meta_table(rom, META3_PTRS, i) if p else None
        except ValueError:
            m3[i] = None
    real3 = sorted(i for i, m in m3.items() if m and m["length"] == META3_BYTES)
    claim(f"LocGfx_Meta3Ptrs: entries {real3[0]}-{real3[-1]} unpack to {META3_BYTES} B = 256 metatiles and hold every "
          f"used .Tileset3; the other {META3_COUNT - len(real3)} are zero or not packs",
          set(t3s) <= set(real3) and real3 == list(range(len(real3))),
          f"zero pointers {sum(1 for i in range(META3_COUNT) if u24(rom, META3_PTRS + 3 * i) == 0)}")
    tables = [m12[i] for i in real12 + stub12] + [m3[i] for i in real3]
    if packs:
        bad = [snes(m["at"]) for m in tables
               if m["at"] not in packs or packs[m["at"]][1:] != (m["packed"], m["length"], m["mode"])]
        claim(f"every metatile table's packed size, unpacked size and mode = data_assets.csv ({len(tables)} tables)",
              not bad, f"differs at {bad[:4]}")
    claim("every metatile table is lz11", all(m["mode"] == 11 for m in tables))
    words12 = [w for i in t12s for mt in m12[i]["metatiles"] for w in mt]
    words3 = [w for i in t3s for mt in m3[i]["metatiles"] for w in mt]
    claim(f"Meta12 words of used tables: palette 0-7 all used, priority set in {sum(1 for w in words12 if w & 0x2000)} "
          f"of {len(words12)}; both flips occur", {w >> 10 & 7 for w in words12} == set(range(8))
          and any(w & 0x4000 for w in words12) and any(w & 0x8000 for w in words12))

    # Graphics packs.
    lists = {t: pack_list(rom, t) for t in t12s}
    numbers = sorted({n for t in t12s for n in lists[t] if n is not None} | set(t3s))
    got = {n: pack(rom, n) for n in numbers}
    claim(f"LocGfx_PackPtrs: the {len(numbers)} packs the used lists and .Tileset3 values name all unpack",
          all(got[n]["data"] for n in numbers))
    if packs:
        bad = [n for n in numbers if got[n]["at"] not in packs
               or packs[got[n]["at"]][1:] != (got[n]["packed"], len(got[n]["data"]), got[n]["mode"])]
        claim("every one's packed size, unpacked size and mode = data_assets.csv", not bad, f"differs at {bad[:5]}")
    claim("no used list names a pack in slot 7", all(lists[t][7] is None for t in t12s))
    sizes = Counter(len(got[n]["data"]) for t in t12s for n in lists[t][:SLOTS] if n is not None)
    short = sorted((t, k) for t in t12s for k, n in enumerate(lists[t][:SLOTS])
                   if n is not None and len(got[n]["data"]) < (PACK5_BYTES if k == 5 else PACK_BYTES))
    claim(f"slots 0-5 packs: {dict(sorted(sizes.items()))} bytes; {len(short)} (tileset, slot) shorter than "
          f"their upload, none in slot 0: {short}", all(k > 0 for _, k in short))
    unset = []
    for t in t12s:
        _, uploads = bg12_vram(rom, t)
        unset += [(t, u["slot"]) for u in uploads if u["pack"] is not None and u.get("ownTiles", 0) < u["tiles"]
                  and not any(v["pack"] is not None for v in uploads[:u["slot"]])]
    claim("every short pack has an earlier pack of its list below it on the stage", not unset, str(unset[:4]))
    l3 = Counter(len(got[n]["data"]) for n in t3s)
    claim(f"layer-3 packs: {dict(sorted(l3.items()))} bytes (<= the $1000 uploaded)", all(s <= PACK_BYTES for s in l3))

    # Palettes.
    claim(f"LocPal_Rom: {PAL_COUNT} sets of {PAL_SET_BYTES} B end at $F6:{(LOC_PAL + PAL_COUNT * PAL_SET_BYTES) & 0xFFFF:04X}",
          (LOC_PAL & 0xFFFF) + PAL_COUNT * PAL_SET_BYTES <= 0x10000)
    claim("every colour word of the used palette sets has bit 15 clear",
          all(c < 0x8000 for p in pals for row in palette_set(rom, p) for c in row))

    # Tile animations.
    lists_a = {s: anim_list_a(rom, s) for s in range(ANIM_SET_MASK + 1)}
    trail = [s for s, (r, _, _) in lists_a.items()
             if any(r[i] is None and r[i + 1] is not None for i in range(RECORDS - 1))]
    claim("FieldAnimListA: in all 64 lists the $80 records come last (record n's data is at $7F:0400 + 32 n)",
          not trail, str(trail))
    kinds = Counter(r["kind"] for rs, _, _ in lists_a.values() for r in rs if r)
    claim(f"FieldAnimListA record kinds: {dict(kinds)} (2 / 4 / other = 2, 4, 8 frames)", set(kinds) <= {2, 4, 8})
    ends = max(e for _, _, e in lists_a.values())
    claim(f"FieldAnimListA: the lists end by {snes(ends)}, before FieldAnimListBPtrs", ends <= ANIM_B_PTRS)
    bad_vram, bad_src, stale = [], [], set()
    for t in t12s:
        recs = lists_a[t & ANIM_SET_MASK][0]
        wram, unpacked = anim_wram(rom, t)
        for r in recs:
            if r is None:
                continue
            if r["vram"] % 16 or not VRAM0 <= r["vram"] < BG12_CHAR + WINDOW * 16:
                bad_vram.append((t, hex(r["vram"])))
            for s in r["sources"]:
                lo = s - (ANIM_WRAM & 0xFFFF)
                if lo < 0 or lo % 32 or lo + TILE_ANIM_BYTES > ANIM_WRAM_BYTES:
                    bad_src.append((t, hex(s)))
                elif None in wram[lo:lo + TILE_ANIM_BYTES]:
                    (stale.add(t) if not unpacked else bad_src.append((t, hex(s))))
    claim("every used tile animation targets a 16-word-aligned BG1/2 character address from $2000", not bad_vram,
          str(bad_vram[:4]))
    claim("every frame of a used tile animation is 4 whole tiles at $7F:6000-$7FFF, inside the unpacked packs 6/7 "
          f"wherever the list has them; tilesets {sorted(stale)} animate with no pack 6/7 (their frames are what an "
          "earlier location left in bank $7F)", not bad_src, f"{len(bad_src)} outside: {bad_src[:4]}")

    # Palette animations.
    lists_b = {p: anim_list_b(rom, p) for p in range(PAL_COUNT)}
    kinds_b = Counter(r["kind"] for rs, _, _ in lists_b.values() for r in rs if r)
    claim(f"FieldAnimListB record kinds: {dict(sorted(kinds_b.items()))} (1 ROM frames, 2/3 rotations, 8 listed frames)",
          set(kinds_b) <= {1, 2, 3, 8})
    endb = max(e for _, _, e in lists_b.values())
    claim(f"FieldAnimListB: the lists end by {snes(endb)}, before FieldAnimListBOldTail ($FD:FF29)", endb <= 0xFDFF29)
    recs = [r for rs, _, _ in lists_b.values() for r in rs if r]
    claim("every kind-1/8 record's bank byte is $F6 and its frames lie past LocPal_Rom in bank $F6",
          all(r["bank"] == 0xF6 and r["offset"] >= (LOC_PAL & 0xFFFF) + PAL_COUNT * PAL_SET_BYTES
              and r["offset"] + 2 * r["count"] * len(r["colours"]) <= 0x10000 for r in recs if r["kind"] in (1, 8)))
    claim("every kind-8 record's frame list names frames 0-15 (the low nibble + 1 bytes)",
          all(max(r["order"]) <= 15 for r in recs if r["kind"] == 8))
    claim("every location palette animation stays inside CGRAM rows 1-7 (colours $11-$7F)",
          all(0x11 <= r["first"] and r["first"] + r["count"] + (1 if r["kind"] in (2, 3) else 0) <= 0x80 for r in recs),
          str(sorted({(hex(r["first"]), r["count"]) for r in recs})[:6]))

    # References from the maps: the 32x32 question and the loaded tiles.
    windows12 = {t: known_tiles(bg12_vram(rom, t)[0], 32) for t in t12s}
    windows3 = {n: known_tiles(bg3_vram(rom, n)[0], 16) for n in t3s}
    parsed, exact, shorts, cells, outside, beyond = 0, 0, {}, 0, Counter(), Counter()
    for loc in locs:
        if loc["tileset12"] == NONE:
            continue
        grids, (w1, h1), (ok, short) = map_planes(rom, loc["mapProps"])
        parsed += 1
        exact += ok and not short
        if short:
            shorts[loc["mapProps"]] = short
        for layer, grid in grids.items():
            for r, row in enumerate(grid):
                for c, mt in enumerate(row):
                    if layer == 2 and not (r < h1 and c < w1):
                        continue                          # bit 8 is not set from this map's triples
                    if layer == 3:
                        if loc["tileset3"] == NONE:
                            continue
                        words = m3[loc["tileset3"]]["metatiles"][mt]
                        known = windows3[loc["tileset3"]]
                    else:
                        if mt >= 512:
                            beyond[layer] += 1
                            continue
                        words = m12[loc["tileset12"]]["metatiles"][mt]
                        known = windows12[loc["tileset12"]]
                    cells += 1
                    if not all(known[w & 0x3FF] for w in words):
                        outside[(layer, loc["tileset12"] if layer < 3 else loc["tileset3"])] += 1
    claim(f"the maps of the {parsed} locations with layers 1/2: {exact} parse to their exact unpacked size; in "
          f"MapProps {sorted(shorts)} the attr triples end {sorted(set(shorts.values()))} tiles short (the game reads "
          f"on past the unpacked data; HiBits taken as 0 there)", exact + sum(1 for x in locs if x["tileset12"] != NONE
                                                                              and x["mapProps"] in shorts) == parsed)
    claim("map cells are metatile numbers (layers 1/2: 9 bits with HiBits, all below 512): no 32x32 block layer",
          not beyond, str(dict(beyond)))
    share = sum(outside.values())
    claim(f"{cells} map cells checked: {cells - share} ({100 * (cells - share) / max(cells, 1):.2f}%) use only characters "
          f"their tileset loads", share * 50 < cells,
          "outside, by (layer, tileset): " + ", ".join(f"{k}: {v}" for k, v in sorted(outside.items())))
    return out


# --- Evidence: the ROM's own routines, run ----------------------------------------------------

class RomRunner:
    """Routines run by ChronoRET's 65816 interpreter (refs/ChronoRET/tools/
    absint.py) over the ROM. The interpreter has no hardware, so this
    subclass gives it the multiplier (WRMPYB $4203 writes WRMPYA x WRMPYB to
    RDMPYL/H) and the WRAM port (WMADD $2181-$2183, WMDATA $2180 writes and
    steps the address), from fullsnes."""

    DP_FIELD, LOC_RECOFS = 0x0100, 0xFE

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
                            if None in port:
                                raise absint.Unresolved("WMDATA with an unknown address")
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
                            x = s.mem.get(0x004202)
                            p = None if x is None or v is None else x * v
                            s.mem[0x004216] = None if p is None else p & 0xFF
                            s.mem[0x004217] = None if p is None else p >> 8
                            return
                super().write8(s, addr, v)

        self.image = bytearray(rom)
        self.machine = Hardware(self.image, bytearray(b"\x01") * len(rom), max_steps=10 ** 7, callee_steps=10 ** 7)
        self.machine.widen_after = 10 ** 9

    def run(self, entry, known, m=True, x=False):
        absint = self.absint
        s = absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, 0, 0, 0, 0
        s.d, s.db, s.m, s.xf, s.c = 0, 0, m, x, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] not in ("rts", "rtl") or self.machine.opaque:
            raise RuntimeError(f"{[how for _, how in ends]} opaque {self.machine.opaque}")
        return {**known, **ends[0][0].mem}

    def decomp(self, src, dest=0x7EB000):
        """Decomp_ToWram ($C3:0557) on the pack at `src` to `dest`: (bytes written, in order)."""
        known = {0x7E0300 + i: b for i, b in enumerate((src & 0xFF, src >> 8 & 0xFF, src >> 16,
                                                         dest & 0xFF, dest >> 8 & 0xFF, dest >> 16))}
        mem = self.run(0xC30557, known)
        written = sorted(a for a in mem if dest <= a < dest + 0x10000 and a not in known)
        if written != list(range(dest, dest + len(written))):
            raise RuntimeError("the writes are not one run")
        return bytes(mem[a] for a in written), mem.get(0x7E0306, 0) | mem.get(0x7E0307, 0) << 8

    def _with_location0(self, offset, value, entry):
        old = self.image[pc(LOC_ROM + offset)]
        self.image[pc(LOC_ROM + offset)] = value
        try:
            known = {0x7E0000 | self.DP_FIELD + self.LOC_RECOFS: 0, 0x7E0000 | self.DP_FIELD + self.LOC_RECOFS + 1: 0}
            return self.run(entry, known)
        finally:
            self.image[pc(LOC_ROM + offset)] = old

    def anim_set_a(self, t):
        """FieldFD_LoadAnimSetA ($FD:DE98) for .Tileset12 = t: (records at $05B0, data at $7F:0400)."""
        mem = self._with_location0(1, t, 0xFDDE98)
        recs = bytes(mem.get(0x7E05B0 + i, 0) or 0 for i in range(5 * RECORDS))
        data = []
        for a in range(ANIM_DATA, ANIM_DATA + 32 * RECORDS):
            if a not in mem:
                break
            data.append(mem[a])
        return recs, bytes(data)

    def anim_set_b(self, p):
        """FieldFD_LoadAnimSetB ($FD:E292) for .Palette = p: the 12 records at $0520."""
        mem = self._with_location0(3, p, 0xFDE292)
        return [[mem.get(0x7E0520 + 12 * r + i) for i in range(12)] for r in range(RECORDS)]

    def tick(self, records, cg):
        """PalAnim_TickAll ($FD:E39C) once: the 12 records (12 bytes each) and
        CGRAM (Pal_Buf = Pal_CgramBuf = cg) in, both out."""
        known = {}
        for r, rec in enumerate(records):
            for i, b in enumerate(rec):
                known[0x7E0520 + 12 * r + i] = b
        for i, w in enumerate(cg):
            for base in (0x7E2000, 0x7E2200):
                known[base + 2 * i] = w & 0xFF
                known[base + 2 * i + 1] = w >> 8
        known[0x7E0000 | self.DP_FIELD] = 0
        absint = self.absint
        s = absint.State()
        s.pc, s.a, s.b, s.x, s.y = 0xFDE39C, 0, 0, 0, 0
        s.d, s.db, s.m, s.xf, s.c = self.DP_FIELD, 0, True, False, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or self.machine.opaque:
            raise RuntimeError(f"{[how for _, how in ends]} opaque {self.machine.opaque}")
        mem = {**known, **ends[0][0].mem}
        out_recs = [[mem[0x7E0520 + 12 * r + i] for i in range(12)] for r in range(RECORDS)]
        out_cg = [mem[0x7E2200 + 2 * i] | mem[0x7E2200 + 2 * i + 1] << 8 for i in range(256)]
        out_buf = [mem[0x7E2000 + 2 * i] | mem[0x7E2000 + 2 * i + 1] << 8 for i in range(256)]
        return out_recs, out_cg, out_buf


def b_record_bytes(r):
    """A FieldAnimB record as FieldFD_LoadAnimSetB fills it (12 bytes; .Ptr
    of kind 8 is checked separately)."""
    if r is None:
        return [0] + [None] * 11
    out = [r["byte0"], r["first"], r["count"], 0, 0, r["delay"]]
    if r["kind"] in (1, 8):
        out += [r["offset"] & 0xFF, r["offset"] >> 8, r["bank"]]
    else:
        out += [None, None, None]
    return out + [None, None, None]


def run_claims(rom, ref=REF, tables=None, packs=None, sets_a=None, sets_b=None, ticks=40):
    """The ROM's decompressor, both list loaders and PalAnim_TickAll against
    this decode (all tables, used packs and lists unless limited)."""
    runner = RomRunner(rom, ref)
    out = []
    t12s, t3s = used_t12(rom), used_t3(rom)
    if tables is None:
        tables = [(META12_PTRS, i) for i in t12s] + [(META3_PTRS, i) for i in t3s]
    bad = []
    for ptrs, i in tables:
        at = u24(rom, ptrs + 3 * i)
        got, length = runner.decomp(at)
        mine = unpack(rom, at)[0]
        if got != mine or length != len(mine):
            bad.append(snes(at))
    out.append((f"Decomp_ToWram ($C3:0557, run) = unpack for {len(tables)} metatile tables", not bad, str(bad[:4])))
    if packs is None:
        packs = sorted({n for t in t12s for n in pack_list(rom, t) if n is not None} | set(t3s))
    bad = []
    for n in packs:
        at = u24(rom, PACK_PTRS + 3 * n)
        got, length = runner.decomp(at, 0x7E3000 if len(unpack(rom, at)[0]) <= 0x4000 else 0x7F6000)
        if got != unpack(rom, at)[0]:
            bad.append(n)
    out.append((f"Decomp_ToWram ($C3:0557, run) = unpack for {len(packs)} graphics packs", not bad, str(bad[:4])))
    sets_a = range(ANIM_SET_MASK + 1) if sets_a is None else sets_a
    bad = []
    for t in sets_a:
        recs, data = runner.anim_set_a(t)
        mine, _, _ = anim_list_a(rom, t)
        want = b"".join(bytes([0, 0, r["vram"] & 0xFF, r["vram"] >> 8, 0x7F]) if r else None for r in mine if r)
        got = b"".join(recs[5 * i:5 * i + 5] for i, r in enumerate(mine) if r)
        ends_ok = all(recs[5 * i + 3] == END_RECORD for i, r in enumerate(mine) if r is None)
        if data != anim_data(mine) or got != want or not ends_ok:
            bad.append(t)
    out.append((f"FieldFD_LoadAnimSetA ($FD:DE98, run) = anim_list_a for {len(sets_a)} sets (records and $7F:0400 data)",
                 not bad, str(bad[:4])))
    sets_b = range(PAL_COUNT) if sets_b is None else sets_b
    bad, ticked = [], 0
    for p in sets_b:
        recs = runner.anim_set_b(p)
        mine, _, _ = anim_list_b(rom, p)
        for i in range(RECORDS):
            want = b_record_bytes(mine[i] if i < B_FILLED else None)
            if any(w is not None and w != g for w, g in zip(want, recs[i])):
                bad.append((p, i))
            if i < B_FILLED and mine[i] and mine[i]["kind"] == 8:
                ptr = recs[i][9] | recs[i][10] << 8 | recs[i][11] << 16
                if [u8(rom, ptr + k) for k in range(len(mine[i]["order"]))] != mine[i]["order"]:
                    bad.append((p, i, "ptr"))
        if not any(mine) or not ticks:
            continue
        # PalAnim_TickAll from the loaded records over a synthetic CGRAM, tick by tick.
        state = [[0 if b is None else b for b in rec] for rec in recs]
        cg = [(37 * i + 11) & 0x7FFF for i in range(256)]
        sim, mcg = CycleState(mine), list(cg)
        for _ in range(ticks):
            state, cg, buf = runner.tick(state, cg)
            sim.tick(mcg)
            ticked += 1
            if cg != mcg:
                bad.append((p, "tick"))
                break
    out.append((f"FieldFD_LoadAnimSetB ($FD:E292, run) = anim_list_b for {len(sets_b)} sets; PalAnim_TickAll "
                f"($FD:E39C, run) = CycleState over {ticked} ticks", not bad, str(bad[:4])))
    return out


# --- Synthetic vectors for the Swift twin ------------------------------------------------

class Lcg:
    """Deterministic numbers (no ROM data)."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self, n):
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.state >> 8) % n


VECTORS = WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "tilesets" / "tileset_vectors.json"


def synthetic_rom():
    """Sparse ROM regions (address -> bytes) with two layer-1/2 tilesets, one
    layer-3 tileset and two palette sets in the real tables' places, and the
    expected decode of each. No ROM data."""
    rng = Lcg(0x7153)
    regions = {}

    def put(long, data):
        regions[long] = bytes(data)

    def tiles(n, depth):
        return bytes(rng.next(256) if rng.next(4) else 0 for _ in range(n * 8 * depth))

    # LocRom: location 0 = (t12 0, t3 0, palette 0), location 1 = (t12 1, $FF, palette 1).
    put(LOC_ROM, bytes([0, 0, 0, 0, 0, 0]) + bytes(8) + bytes([0, 1, NONE, 1, 0, 0]) + bytes(8))
    # Packs: 0 = 64 tiles (2 KB), 1 = 128 tiles, 2 = 16 tiles (short: the stage tail is pack 1's), 3 = 2bpp
    # 248 tiles, 4 = 8 KB of animation frames.
    contents = [tiles(64, 4), tiles(128, 4), tiles(16, 4), tiles(248, 2), tiles(256, 4)]
    at = 0xE20000
    ptrs = []
    for k, c in enumerate(contents):
        packed = pack_bytes(c, 12)
        put(at, packed)
        ptrs.append(at)
        at += len(packed) + 1
    put(PACK_PTRS, b"".join(p.to_bytes(3, "little") for p in ptrs))
    put(LISTS, bytes([1, 0, NONE, 2, NONE, 1, 4, NONE]) + bytes([0, NONE, NONE, NONE, NONE, 2, NONE, NONE]))
    # Metatile tables (lz11, as the ROM's).
    words12 = [[rng.next(0x10000) for _ in range(4)] for _ in range(512)]
    words12b = [[(256 + rng.next(80)) | rng.next(8) << 10 | rng.next(8) << 13 for _ in range(4)] for _ in range(512)]
    words3 = [[rng.next(248) | rng.next(8) << 10 | rng.next(8) << 13 for _ in range(4)] for _ in range(256)]
    metas = []
    for words in (words12, words12b, words3):
        blob = b"".join(struct.pack("<H", w) for mt in words for w in mt)
        packed = pack_bytes(blob, 11)
        put(at, packed)
        metas.append(at)
        at += len(packed) + 1
    put(META12_PTRS, metas[0].to_bytes(3, "little") + metas[1].to_bytes(3, "little"))
    put(META3_PTRS, metas[2].to_bytes(3, "little"))
    # Palettes 0 and 1.
    put(LOC_PAL, b"".join(struct.pack("<H", rng.next(0x8000)) for _ in range(2 * PAL_ROWS * ROW_COLOURS)))
    # Tile animations: set 0 = a kind-4 and a kind-2 record then $80s; set 1 = all $80.
    list_a = (bytes([4]) + struct.pack("<H", 0x3290) + bytes([0x40, 0x20, 0x40, 0x80])
              + b"".join(struct.pack("<H", 0x6000 + 0x80 * i) for i in range(4))
              + bytes([2]) + struct.pack("<H", 0x4600) + bytes([0x2B, 0x10]) + struct.pack("<HH", 0x7000, 0x7080)
              + bytes([END_RECORD] * 10))
    put(ANIM_A_PTRS, struct.pack("<HH", 0, len(list_a) - 10))     # set 1 = 12 of the $80s
    put(ANIM_A, list_a + bytes([END_RECORD] * 2))
    # Palette animations: set 0 = rotate down, kind 1 (3 frames), kind 8 (frames by list); set 1 = rotate up.
    offset = 0x7400
    put(PAL_ANIM_ROM + offset, b"".join(struct.pack("<H", rng.next(0x8000)) for _ in range(3 * 4 + 4 * 2)))
    list_b0 = (bytes([0x20, 0x21, 0x03, 0x04])
               + bytes([0x12, 0x31, 0x04, 0x06]) + struct.pack("<H", offset) + bytes([0xF6])
               + bytes([0x85, 0x41, 0x02, 0x03]) + struct.pack("<H", offset + 24) + bytes([0xF6])
               + bytes([0, 1, 2, 3, 2, 1])
               + bytes([0, 0, 0]))
    list_b1 = bytes([0x30, 0x51, 0x05, 0x02, 0, 0, 0, 0, 0])
    put(ANIM_B_PTRS, struct.pack("<HH", 0, len(list_b0)))
    put(ANIM_B, list_b0 + list_b1)
    image = bytearray(ROM_SIZE)
    for long, data in regions.items():
        image[pc(long):pc(long) + len(data)] = data
    rom = bytes(image)
    expect = {"tileset12": [], "tileset3": [], "palettes": []}
    for t in (0, 1):
        d = decode_t12(rom, t)
        window, _ = bg12_vram(rom, t)
        wram, _ = anim_wram(rom, t)
        known = known_tiles(window, 32)
        idx = window_indices(window, 4)
        d["tileIndices"] = [{"first": a, "hex": bytes(i for t2 in range(a, b) for i in idx[t2]).hex()}
                            for a, b in ranges(known)]
        d["animIndices"] = bytes(i for k in range(ANIM_WRAM_BYTES // 32)
                                 for i in tile_indices([b or 0 for b in wram[32 * k:32 * k + 32]], 4)).hex()
        recs = anim_list_a(rom, t)[0]
        d["frameRuns"] = [anim_frames(r, 40) if r else [] for r in recs]
        for key in ("locations",):
            d.pop(key)
        expect["tileset12"].append(d)
    d = decode_t3(rom, 0)
    window, _ = bg3_vram(rom, 0)
    idx = window_indices(window, 2)
    d["tileIndices"] = [{"first": a, "hex": bytes(i for t2 in range(a, b) for i in idx[t2]).hex()}
                        for a, b in ranges(known_tiles(window, 16))]
    d.pop("locations")
    expect["tileset3"].append(d)
    for p in (0, 1):
        d = decode_pal(rom, p)
        d.pop("locations")
        cg = cgram(rom, p)
        state = CycleState(d["cycles"]["records"])
        snaps = []
        for k in range(1, 31):
            state.tick(cg)
            if k % 3 == 0:
                snaps.append({"tick": k, "cgram": cg[:128]})
        d["ticks"] = snaps
        expect["palettes"].append(d)
    return regions, expect


def vectors_text():
    regions, expect = synthetic_rom()
    head = {"schema": "ct-tileset-vectors/1",
            "note": "synthetic tilesets in the real tables' places (no ROM data); expected decode by "
                    "re_workspace/tools/ct_tilesets.py",
            "regions": [{"at": snes(k), "hex": v.hex()} for k, v in sorted(regions.items())]}
    lines = ["{"]
    lines += [f' "{k}": {json.dumps(v, separators=(",", ":"))},' for k, v in head.items()]
    groups = []
    for key, items in expect.items():
        body = ",\n".join("  " + json.dumps(d, separators=(",", ":")) for d in items)
        groups.append(f' "{key}": [\n{body}]')
    return "\n".join(lines) + "\n" + ",\n".join(groups) + "}\n"


# --- Output helpers ----------------------------------------------------------------------

def bgr555_rgb(w):
    return tuple(((w >> s & 31) << 3) | ((w >> s & 31) >> 2) for s in (0, 5, 10))


def write_png_rgba(path, width, height, rgba):
    raw = b"".join(b"\x00" + bytes(rgba[4 * width * y:4 * width * (y + 1)]) for y in range(height))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def metatile_pixels(word, idx):
    """64 (palette, index) pairs of one subtile word with its flips."""
    t = idx[word & 0x3FF]
    out = []
    for i in range(64):
        x, y = i % 8, i // 8
        if word & 0x4000:
            x = 7 - x
        if word & 0x8000:
            y = 7 - y
        out.append(t[y * 8 + x])
    return out


def render(rom, t, out, pal=None, scale=2):
    """The 512 metatiles of .Tileset12 t, 16 per row, in palette set `pal`."""
    pal = most_common(rom, "tileset12", t, "palette") if pal is None else pal
    window, _ = bg12_vram(rom, t)
    idx = window_indices(window, 4)
    cg = cgram(rom, pal)
    mts = meta_table(rom, META12_PTRS, t)["metatiles"]
    w, h = 16 * 16, 32 * 16
    rgba = bytearray(4 * w * h * scale * scale)
    for m, words in enumerate(mts):
        for q, word in enumerate(words):
            px = metatile_pixels(word, idx)
            for i, v in enumerate(px):
                x = (m % 16) * 16 + (q % 2) * 8 + i % 8
                y = (m // 16) * 16 + (q // 2) * 8 + i // 8
                c = bgr555_rgb(cg[16 * (word >> 10 & 7) + v]) if v else (24, 24, 32)
                for dy in range(scale):
                    for dx in range(scale):
                        o = 4 * ((y * scale + dy) * w * scale + x * scale + dx)
                        rgba[o:o + 4] = bytes(c) + b"\xff"
    write_png_rgba(out, w * scale, h * scale, rgba)
    return pal


def verify_import(rom, project):
    """A Studio import (tilesets/<id>.tileset.json and sheets) against the
    decode: [(name, ok, detail)]."""
    from PIL import Image
    out = []
    root = Path(project)

    def load(name):
        path = root / "tilesets" / f"{name}.tileset.json"
        return json.loads(path.read_text()) if path.exists() else None

    def sheet_ok(ts, window, bpp):
        img = Image.open(root / ts["sheet"])
        tb = 32 if bpp == 4 else 16
        idx = window_indices(window, bpp)
        known = known_tiles(window, tb)
        px = img.load()
        cols = img.width // 8
        return img.mode == "P" and img.width == 128 and img.height == WINDOW // 16 * 8 and all(
            [px[(t % cols) * 8 + i % 8, (t // cols) * 8 + i // 8] for i in range(64)] == (idx[t] if known[t] else [0] * 64)
            for t in range(WINDOW))

    def chips_of(ts):
        return [[c["tile"] | c["pal"] << 10 | c["priority"] << 13 | c["hflip"] << 14 | c["vflip"] << 15
                 for c in mt["chips"]] for mt in ts["metatiles"]]

    for t in used_t12(rom):
        name = f"t12_{t:02d}"
        ts = load(name)
        if ts is None:
            out.append((f"{name}: imported", False))
            continue
        d = decode_t12(rom, t)
        window, _ = bg12_vram(rom, t)
        wram, _ = anim_wram(rom, t)
        ok_meta = chips_of(ts) == d["metatiles"]
        ok_vram = [[s["firstTile"], s["firstTile"] + s["tiles"]] for s in ts["vram"]["known"]] == d["knownTiles"]
        recs = [r for r in anim_list_a(rom, t)[0] if r]
        anims = ts.get("tileAnimations") or []
        ok_anim = len(anims) == len(recs) and all(
            a["tile"] == (r["vram"] - BG12_CHAR) // 16 and a["steps"] == r["steps8"]
            and a["frames"] == [(s - (ANIM_WRAM & 0xFFFF)) // 32 for s in r["sources8"]] for a, r in zip(anims, recs))
        anim_img = Image.open(root / ts["animSheet"]) if ts.get("animSheet") else None
        ok_anim_sheet = anim_img is None if not d["animWram"] else anim_img is not None and all(
            [anim_img.load()[(k % 16) * 8 + i % 8, (k // 16) * 8 + i // 8] for i in range(64)]
            == tile_indices([b or 0 for b in wram[32 * k:32 * k + 32]], 4) for k in range(ANIM_WRAM_BYTES // 32))
        out.append((f"{name}: 512 metatiles, characters {d['knownTiles']}, {len(recs)} tile animations as decoded",
                    ok_meta and ok_vram and ok_anim and ok_anim_sheet and ts["kind"] == "bg12",
                    f"meta {ok_meta} vram {ok_vram} anim {ok_anim} animSheet {ok_anim_sheet}"))
        out.append((f"{name}: sheet = the BG1/2 character window", sheet_ok(ts, window, 4)))
    for n in used_t3(rom):
        name = f"t3_{n:02d}"
        ts = load(name)
        if ts is None:
            out.append((f"{name}: imported", False))
            continue
        d = decode_t3(rom, n)
        window, _ = bg3_vram(rom, n)
        out.append((f"{name}: 256 metatiles and the BG3 window as decoded",
                    chips_of(ts) == d["metatiles"] and sheet_ok(ts, window, 2) and ts["bpp"] == 2))
    for p in used_pal(rom):
        name = f"pal_{p:02d}"
        ts = load(name)
        if ts is None:
            out.append((f"{name}: imported", False))
            continue
        d = decode_pal(rom, p)
        rows = [[int(c, 16) for c in row] for row in ts["palettes"]]
        ok_rows = len(rows) == 8 and all(rows[r + 1][1:] == d["rows"][r] for r in range(PAL_ROWS))
        recs = [r for r in d["cycles"]["records"] if r]
        cyc = ts.get("paletteCycles") or []
        ok_cyc = len(cyc) == len(recs) and all(
            c["kind"] == r["name"] and c["first"] == r["first"] and c["count"] == r["count"] and c["delay"] == r["delay"]
            and [[int(x, 16) for x in f] for f in c.get("frames") or []] == r.get("colours", [])
            and c.get("order") == r.get("order") for c, r in zip(cyc, recs))
        out.append((f"{name}: rows 1-7 and {len(recs)} palette cycles as decoded", ok_rows and ok_cyc))
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
    d.add_argument("kind", choices=("t12", "t3", "pal"))
    d.add_argument("index", type=int)
    d.add_argument("--rom", default=str(ROM_PATH))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(ROM_PATH))
    k.add_argument("--run", action="store_true", help="also run the ROM's own routines in ChronoRET's interpreter")
    r = sub.add_parser("render")
    r.add_argument("t12", type=int)
    r.add_argument("--out", required=True)
    r.add_argument("--pal", type=int)
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
        fn = {"t12": decode_t12, "t3": decode_t3, "pal": decode_pal}[args.kind]
        print(json.dumps(fn(rom, args.index), indent=1))
        return 0
    if args.command == "render":
        pal = render(rom, args.t12, args.out, args.pal)
        print(f"wrote {args.out}: tileset12 {args.t12} in palette set {pal}")
        return 0
    if args.command == "verify-import":
        return report(verify_import(rom, args.project))
    claims = asm_claims() + code_claims(rom) + data_claims(rom)
    if args.run:
        claims += run_claims(rom)
    return report(claims)


if __name__ == "__main__":
    sys.exit(main())
