"""SNES planar graphics decode for Chrono Trigger (USA v1.0, HiROM).

Formats (all verified against re_workspace/refs/ChronoRET, a byte-exact
decompilation of this ROM):

* 4bpp tile: 32 bytes per 8x8 tile.  Bytes 0..15 are planes 0 and 1
  interleaved per row (byte 2*r = plane0 of row r, byte 2*r+1 = plane1);
  bytes 16..31 are planes 2 and 3 interleaved the same way.
  Pixel index = bit7(plane0) | bit7(plane1)<<1 | bit7(plane2)<<2 | bit7(plane3)<<3,
  bit 7 of each plane byte is the LEFT-most pixel (x=0).
* 2bpp tile: 16 bytes per tile, planes 0/1 interleaved per row
  (byte 2*r = plane0 row r, byte 2*r+1 = plane1 row r).
* Palettes: 15-bit BGR555 little-endian words.  8-bit sRGB expansion per
  channel: (c << 3) | (c >> 2).

The lzss_unpack() probe implements the pack format documented verbatim in
ChronoRET's asm/bankC3/bankC3.asm (Decomp_ToWram header comment, the packed
$C3 module): header u16 W at +0, items from +2, end marker at +2+W; control
byte per group (0 => 8 literals; else one item per bit from bit 0: 0-bit =
literal, 1-bit = 16-bit little-endian back-reference); lz12:
dist = v & 0xFFF, len = (v >> 12) + 3; lz11: dist = v & 0x7FF,
len = (v >> 11) + 3; bits 6-7 of the FIRST end marker pick the mode
(0 => lz12, nonzero => lz11); m & 0x3F == 0 ends the stream, else the next
segment's marker sits at Src + (u16 after m) and the next group has m & 0x3F
items.  Verified by unpacking to the exact sizes listed in
ChronoRET/symbols/data_assets.csv (see tools/ct_extractor_gfx.py).
"""

from __future__ import annotations

import math

import numpy as np
from PIL import Image

TILE_BYTES_4BPP = 32
TILE_BYTES_2BPP = 16


# --------------------------------------------------------------------------
# palette
# --------------------------------------------------------------------------
def bgr555_to_rgb(u16: int) -> tuple[int, int, int]:
    """15-bit BGR555 word -> 8-bit sRGB (r, g, b) via (c<<3)|(c>>2)."""
    u16 &= 0x7FFF
    b5 = u16 & 0x1F
    g5 = (u16 >> 5) & 0x1F
    r5 = (u16 >> 10) & 0x1F
    return (((r5 << 3) | (r5 >> 2)),
            ((g5 << 3) | (g5 >> 2)),
            ((b5 << 3) | (b5 >> 2)))


def rgb_to_bgr555(r: int, g: int, b: int) -> int:
    """Nearest 15-bit BGR555 word for an 8-bit sRGB triple."""
    return ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)


def decode_palette(data: bytes) -> list[tuple[int, int, int]]:
    """Decode a blob of 16-bit little-endian BGR555 words to sRGB triples."""
    if len(data) % 2:
        raise ValueError(f"palette blob has odd length {len(data)}")
    words = np.frombuffer(data, dtype="<u2")
    return [bgr555_to_rgb(int(w)) for w in words]


def palette_words(data: bytes) -> list[int]:
    """Raw 15-bit colour words (bit 15 masked off) from a palette blob."""
    return [int(w) & 0x7FFF for w in np.frombuffer(data, dtype="<u2")]


# --------------------------------------------------------------------------
# tiles
# --------------------------------------------------------------------------
def _bits_to_index(planes: list[np.ndarray]) -> np.ndarray:
    """planes: list of (ntiles, 8, 8) uint8 arrays of 0/1, MSB = left pixel."""
    idx = np.zeros(planes[0].shape, dtype=np.uint8)
    for i, p in enumerate(planes):
        idx |= (p & 1).astype(np.uint8) << i
    return idx


def _plane_bytes(tiles: np.ndarray, cols: list[int]) -> np.ndarray:
    """(tiles,8,8) 0/1 bits of the given byte columns of each tile, MSB =
    left pixel.  cols[r] is the byte index of plane row r."""
    raw = tiles[:, cols]                     # (ntiles, 8) row bytes
    return np.unpackbits(raw, axis=1).reshape(raw.shape[0], 8, 8)


def decode_tiles_4bpp(data: bytes | np.ndarray) -> np.ndarray:
    """Decode planar 4bpp bytes -> uint8 index array, shape (ntiles, 8, 8)."""
    arr = np.frombuffer(data, dtype=np.uint8) if isinstance(data, bytes) else np.asarray(data, dtype=np.uint8)
    if arr.size % TILE_BYTES_4BPP:
        raise ValueError(f"4bpp blob size {arr.size} is not a multiple of 32")
    tiles = arr.reshape(-1, TILE_BYTES_4BPP)
    # byte 2r = plane0 row r, 2r+1 = plane1 row r (bytes 0..15);
    # byte 16+2r = plane2 row r, 17+2r = plane3 row r (bytes 16..31)
    p0 = _plane_bytes(tiles, list(range(0, 16, 2)))
    p1 = _plane_bytes(tiles, list(range(1, 16, 2)))
    p2 = _plane_bytes(tiles, list(range(16, 32, 2)))
    p3 = _plane_bytes(tiles, list(range(17, 32, 2)))
    return _bits_to_index([p0, p1, p2, p3])


def decode_tiles_2bpp(data: bytes | np.ndarray) -> np.ndarray:
    """Decode planar 2bpp bytes -> uint8 index array, shape (ntiles, 8, 8)."""
    arr = np.frombuffer(data, dtype=np.uint8) if isinstance(data, bytes) else np.asarray(data, dtype=np.uint8)
    if arr.size % TILE_BYTES_2BPP:
        raise ValueError(f"2bpp blob size {arr.size} is not a multiple of 16")
    tiles = arr.reshape(-1, TILE_BYTES_2BPP)
    p0 = _plane_bytes(tiles, list(range(0, 16, 2)))
    p1 = _plane_bytes(tiles, list(range(1, 16, 2)))
    return _bits_to_index([p0, p1])


# --------------------------------------------------------------------------
# sheets / PNGs
# --------------------------------------------------------------------------
def _grid(indexed: np.ndarray, cols: int) -> np.ndarray:
    """(ntiles,8,8) -> (rows*8, cols*8) with right padding of index 0."""
    nt = indexed.shape[0]
    rows = math.ceil(nt / cols)
    canvas = np.zeros((rows * 8, cols * 8), dtype=np.uint8)
    for i in range(nt):
        r, c = divmod(i, cols)
        canvas[r * 8:(r + 1) * 8, c * 8:(c + 1) * 8] = indexed[i]
    return canvas


def save_indexed_png(indexed: np.ndarray, path: str, cols: int = 32) -> tuple[int, int]:
    """Write the raw index grid as a mode-'P' PNG with an IDENTITY palette,
    so no colour is baked in and re-colouring is a palette swap.
    Returns (width, height)."""
    grid = _grid(indexed, cols)
    img = Image.fromarray(grid, mode="P")
    img.putpalette([i for i in range(256) for i in (i, i, i)])
    img.save(path)
    return grid.shape[1], grid.shape[0]


def render_sheet(indexed: np.ndarray, palette: list[tuple[int, int, int]],
                 cols: int = 32) -> Image.Image:
    """Render (ntiles,8,8) indices through palette -> RGBA PIL image.
    palette entries beyond len are black; index 0 is rendered as given."""
    lut = np.zeros((256, 4), dtype=np.uint8)
    lut[:, 3] = 255
    for i, (r, g, b) in enumerate(palette[:256]):
        lut[i, :3] = (r, g, b)
    grid = _grid(indexed, cols)
    rgba = lut[grid]
    return Image.fromarray(rgba, mode="RGBA")


def save_render_png(indexed: np.ndarray, palette: list[tuple[int, int, int]],
                    path: str, cols: int = 32) -> tuple[int, int]:
    img = render_sheet(indexed, palette, cols)
    img.save(path)
    return img.size


# --------------------------------------------------------------------------
# LZSS probe (format documented in ChronoRET bankC3.asm, Decomp_ToWram)
# --------------------------------------------------------------------------
def lzss_unpack(data: bytes, expected_size: int | None = None) -> bytes:
    """Unpack a $C3:0002-style pack. Returns the decompressed bytes.

    Raises ValueError on malformed streams or size mismatch when
    expected_size is given.
    """
    if len(data) < 3:
        raise ValueError("pack too short")
    w = int.from_bytes(data[0:2], "little")
    seg_end = 2 + w
    if seg_end >= len(data):
        raise ValueError("segment 1 end marker past end of pack")
    mode = 11 if (data[seg_end] & 0xC0) else 12
    mask = 0x7FF if mode == 11 else 0xFFF
    shift = 11 if mode == 11 else 12

    out = bytearray()
    src = 2
    group_left = 8
    guard = 0
    while True:
        guard += 1
        if guard > 10_000_000:
            raise ValueError("runaway decompression")
        if src == seg_end:
            m = data[seg_end]
            if (m & 0x3F) == 0:
                break
            off = int.from_bytes(data[seg_end + 1:seg_end + 3], "little")
            group_left = m & 0x3F
            src = seg_end + 3                 # items resume right after the
            seg_end = off                     # 3-byte marker record just read
            continue
        if src > len(data):
            raise ValueError("source overran pack")
        c = data[src]
        if c == 0:
            # 8 literal bytes; does not consume group_left
            out += data[src + 1:src + 9]
            src += 9
            continue
        src += 1
        for bit in range(group_left):
            if (c >> bit) & 1:
                v = int.from_bytes(data[src:src + 2], "little")
                src += 2
                dist = v & mask
                ln = (v >> shift) + 3
                if dist == 0 or dist > len(out):
                    raise ValueError(f"bad back-reference dist={dist}")
                start = len(out) - dist
                for k in range(ln):           # forward copy (repeats if dist < ln)
                    out.append(out[start + k])
            else:
                out.append(data[src])
                src += 1
        group_left = 8
        if expected_size is not None and len(out) > expected_size:
            raise ValueError(f"produced {len(out)} > expected {expected_size}")
    if expected_size is not None and len(out) != expected_size:
        raise ValueError(f"produced {len(out)} != expected {expected_size}")
    return bytes(out)
