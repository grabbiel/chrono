"""Phase 2.2 verification: SNES planar graphics decode (4bpp/2bpp tiles,
BGR555 palettes), synthetic-tile format tests, PNG/manifest checks, and a
scalar-reference cross-check of the vectorised decoders.

Run:  cd <repo root> && re_workspace/.venv/bin/pytest re_workspace/tests/test_phase2_2.py -q
"""
import json
import math
import os
import random
import sys

import numpy as np
import pytest
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
WS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(WS, "tools"))

from ct_gfx import (bgr555_to_rgb, decode_palette, decode_tiles_2bpp,  # noqa: E402
                    decode_tiles_4bpp, lzss_unpack, rgb_to_bgr555,
                    render_sheet)

GFX = os.path.join(WS, "assets", "graphics")


# ---------------------------------------------------------------------------
# (a) BGR555 round-trip
# ---------------------------------------------------------------------------
def test_bgr555_decode_all_words_in_range():
    for w in range(32768):
        r, g, b = bgr555_to_rgb(w)
        assert 0 <= r <= 255 and 0 <= g <= 255 and 0 <= b <= 255


def test_bgr555_exact_for_representable():
    # every decoded triple of a 15-bit word re-encodes to the same word
    for w in range(32768):
        assert rgb_to_bgr555(*bgr555_to_rgb(w)) == w


def test_bgr555_error_bound():
    # arbitrary 8-bit colours: nearest-word round-trip error <= 7 per channel
    # (exhaustive per channel value, plus a randomised triple check)
    for v in range(256):
        q = v >> 3
        assert abs(v - ((q << 3) | (q >> 2))) <= 7
    rng = random.Random(222)
    for _ in range(20000):
        rgb = (rng.randrange(256), rng.randrange(256), rng.randrange(256))
        back = bgr555_to_rgb(rgb_to_bgr555(*rgb))
        assert all(abs(a - b) <= 7 for a, b in zip(rgb, back))


def test_bgr555_known_values():
    assert bgr555_to_rgb(0x0000) == (0, 0, 0)
    assert bgr555_to_rgb(0x7FFF) == (255, 255, 255)
    assert bgr555_to_rgb(0x001F) == (0, 0, 255)      # blue field set
    assert bgr555_to_rgb(0x03E0) == (0, 255, 0)      # green field set
    assert bgr555_to_rgb(0x7C00) == (255, 0, 0)      # red field set


def test_decode_palette_vector():
    # little-endian bytes for words 0x7C00, 0x03E0, 0x001F
    pals = decode_palette(bytes.fromhex("007C E003 1F00".replace(" ", "")))
    assert pals == [(255, 0, 0), (0, 255, 0), (0, 0, 255)]


# ---------------------------------------------------------------------------
# scalar reference decoders (independent of the numpy vectorised path)
# ---------------------------------------------------------------------------
def ref_decode_4bpp(data: bytes):
    """Pure-Python reference: byte 2r = plane0 row r, byte 2r+1 = plane1 row r
    (bytes 0-15); byte 16+2r = plane2, 17+2r = plane3.  Bit 7 = left pixel."""
    out = []
    for t in range(len(data) // 32):
        b = data[t * 32:(t + 1) * 32]
        tile = []
        for y in range(8):
            p0, p1 = b[2 * y], b[2 * y + 1]
            p2, p3 = b[16 + 2 * y], b[17 + 2 * y]
            row = []
            for x in range(8):
                m = 0x80 >> x
                row.append((1 if p0 & m else 0) | (2 if p1 & m else 0)
                           | (4 if p2 & m else 0) | (8 if p3 & m else 0))
            tile.extend(row)
        out.append(tile)
    return out


def ref_decode_2bpp(data: bytes):
    out = []
    for t in range(len(data) // 16):
        b = data[t * 16:(t + 1) * 16]
        tile = []
        for y in range(8):
            p0, p1 = b[2 * y], b[2 * y + 1]
            row = []
            for x in range(8):
                m = 0x80 >> x
                row.append((1 if p0 & m else 0) | (2 if p1 & m else 0))
            tile.extend(row)
        out.append(tile)
    return out


# ---------------------------------------------------------------------------
# (b) synthetic 4bpp tile with hand-written expected output
# ---------------------------------------------------------------------------
def _synth4_bytes():
    # plane0: row y even -> 0xFF, odd -> 0x00
    # plane1: every row -> 0x0F   (right four pixels)
    # plane2: row 0 -> 0x81 (left+right pixel), rows 1-7 -> 0x00
    # plane3: row 3 -> 0xAA (pixels x=0,2,4,6), else 0x00
    p0 = [0xFF if y % 2 == 0 else 0x00 for y in range(8)]
    p1 = [0x0F] * 8
    p2 = [0x81] + [0x00] * 7
    p3 = [0x00, 0x00, 0x00, 0xAA, 0x00, 0x00, 0x00, 0x00]
    b = bytearray(32)
    for y in range(8):
        b[2 * y] = p0[y]
        b[2 * y + 1] = p1[y]
        b[16 + 2 * y] = p2[y]
        b[17 + 2 * y] = p3[y]
    return bytes(b)


def test_synth_4bpp_exact():
    # Expected by hand from the bit layout (index = p0 | p1<<1 | p2<<2 | p3<<3,
    # bit 7 = leftmost pixel):
    #   row 0: p0=FF p1=0F p2=81 -> x0:1+4=5, x1-3:1, x4-6:1+2=3, x7:1+2+4=7
    #   row 1: p0=00 p1=0F       -> 0,0,0,0,2,2,2,2
    #   row 3: p0=00 p1=0F p3=AA -> x0:8, x1:0, x2:8, x3:0, x4:8+2, x5:2, x6:10, x7:2
    expected = [
        [5, 1, 1, 1, 3, 3, 3, 7],
        [0, 0, 0, 0, 2, 2, 2, 2],
        [1, 1, 1, 1, 3, 3, 3, 3],
        [8, 0, 8, 0, 10, 2, 10, 2],
        [1, 1, 1, 1, 3, 3, 3, 3],
        [0, 0, 0, 0, 2, 2, 2, 2],
        [1, 1, 1, 1, 3, 3, 3, 3],
        [0, 0, 0, 0, 2, 2, 2, 2],
    ]
    flat = [v for row in expected for v in row]
    assert len(flat) == 64
    got = decode_tiles_4bpp(_synth4_bytes())
    assert got.shape == (1, 8, 8)
    assert got.dtype == np.uint8
    assert got.reshape(-1).tolist() == flat
    # scalar reference agrees
    assert ref_decode_4bpp(_synth4_bytes())[0] == flat


def test_synth_2bpp_exact():
    # plane0 all rows 0xF0 (left four pixels), plane1 even rows 0x03
    # (pixels x=6,7), odd rows 0x00.
    b = bytearray(16)
    for y in range(8):
        b[2 * y] = 0xF0
        b[2 * y + 1] = 0x03 if y % 2 == 0 else 0x00
    expected = [
        [1, 1, 1, 1, 0, 0, 2, 2],
        [1, 1, 1, 1, 0, 0, 0, 0],
        [1, 1, 1, 1, 0, 0, 2, 2],
        [1, 1, 1, 1, 0, 0, 0, 0],
        [1, 1, 1, 1, 0, 0, 2, 2],
        [1, 1, 1, 1, 0, 0, 0, 0],
        [1, 1, 1, 1, 0, 0, 2, 2],
        [1, 1, 1, 1, 0, 0, 0, 0],
    ]
    flat = [v for row in expected for v in row]
    got = decode_tiles_2bpp(bytes(b))
    assert got.shape == (1, 8, 8)
    assert got.reshape(-1).tolist() == flat
    assert ref_decode_2bpp(bytes(b))[0] == flat


# ---------------------------------------------------------------------------
# vectorised vs scalar reference on real ROM bytes
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def rom(rom_path):
    with open(rom_path, "rb") as f:
        data = f.read()
    assert len(data) == 4 * 1024 * 1024
    return data


def _pc(snes):
    b, a = snes.lstrip("$").split(":")
    return ((int(b, 16) & 0x3F) << 16) | int(a, 16)


def test_numpy_matches_scalar_reference(rom):
    rng = random.Random(22)
    for snes, nbytes, bpp in [("D2:0000", 4096, 4), ("FF:8E60", 1024, 2),
                              ("D4:7C40", 2048, 4), ("CF:0000", 1024, 2)]:
        pc = _pc(snes)
        # tile-aligned random window
        off = rng.randrange(0, nbytes // 16) * 16
        blob = rom[pc + off: pc + off + 512]
        if bpp == 4:
            assert decode_tiles_4bpp(blob).reshape(-1).tolist() == sum(
                ref_decode_4bpp(blob), [])
        else:
            assert decode_tiles_2bpp(blob).reshape(-1).tolist() == sum(
                ref_decode_2bpp(blob), [])


def test_random_bytes_decoders_agree():
    rng = random.Random(222)
    blob4 = bytes(rng.randrange(256) for _ in range(320))
    assert decode_tiles_4bpp(blob4).reshape(-1).tolist() == sum(
        ref_decode_4bpp(blob4), [])
    blob2 = bytes(rng.randrange(256) for _ in range(160))
    assert decode_tiles_2bpp(blob2).reshape(-1).tolist() == sum(
        ref_decode_2bpp(blob2), [])


def test_decode_rejects_misaligned():
    with pytest.raises(ValueError):
        decode_tiles_4bpp(b"\x00" * 33)
    with pytest.raises(ValueError):
        decode_tiles_2bpp(b"\x00" * 17)


# ---------------------------------------------------------------------------
# LZSS probe (documented $C3:0002 format) against CSV-pinned sizes
# ---------------------------------------------------------------------------
def test_lzss_scene_pal_packs(rom, data_assets_csv):
    import csv
    import re as _re
    checked = 0
    with open(data_assets_csv, newline="") as f:
        for p in csv.reader(l for l in f if not l.startswith("#")):
            if len(p) < 7 or not p[0].startswith("ScenePalPack_"):
                continue
            m = _re.search(r"lz1[12] -> (\d+) B", p[6])
            if not m:
                continue
            exp = int(m.group(1))
            blob = rom[_pc(p[1]):_pc(p[2]) + 1]
            out = lzss_unpack(blob, exp)
            assert len(out) == exp
            checked += 1
    assert checked == 19


# ---------------------------------------------------------------------------
# (d) every PNG written by the extractor is loadable, mode P, right size
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def gfx_manifest(manifest_path, require):
    require(GFX, "extracted graphics (assets/graphics)")
    with open(manifest_path("graphics_manifest.json")) as f:
        return json.load(f)


def test_indexed_pngs_loadable_mode_p(gfx_manifest):
    n = 0
    for b in gfx_manifest["blobs"]:
        if b.get("status") != "decoded":
            continue
        p = os.path.join(WS, b["sheet_png"])
        with Image.open(p) as img:
            img.load()
            assert img.mode == "P", f"{b['label']} mode {img.mode}"
            tiles, cols = b["tiles"], b["sheet_cols"]
            rows = math.ceil(tiles / cols)
            assert img.size == (cols * 8, rows * 8), f"{b['label']} {img.size}"
            assert img.size == tuple(b["sheet_size"])
        n += 1
    assert n >= 5


def test_preview_pngs_loadable_rgba(gfx_manifest):
    for b in gfx_manifest["blobs"]:
        if b.get("status") != "decoded":
            continue
        p = os.path.join(WS, b["preview_png"])
        with Image.open(p) as img:
            img.load()
            assert img.mode == "RGBA", f"{b['label']} {img.mode}"


def test_indexed_bins_match_tiles(gfx_manifest):
    for b in gfx_manifest["blobs"]:
        if b.get("status") != "decoded":
            continue
        with open(os.path.join(WS, b["indexed_bin"]), "rb") as f:
            data = f.read()
        assert len(data) == b["tiles"] * 64
        hi = 15 if b["bpp"] == 4 else 3
        assert max(data) <= hi, f"{b['label']} index out of {b['bpp']}bpp range"


def test_layout_is_interleaved_planar(gfx_manifest):
    # The correct interleaved-planar layout must beat chunky-plane variants
    # on pixel-neighbour continuity for every bank big enough for the
    # statistic (small banks are covered by the visual font verification).
    checked = 0
    for b in gfx_manifest["blobs"]:
        if b.get("status") != "decoded" or b["tiles"] < 32:
            continue
        ld = b["layout_discrimination"]
        assert ld["correct"] > ld["chunky_planes"], b["label"]
        if "planes_0132" in ld:
            assert ld["correct"] > ld["planes_0132"], b["label"]
        checked += 1
    assert checked >= 10


def test_font_glyph_rows_decode_to_digits(rom):
    # MenuRom_GlyphRows ($FF:CAFC, 10 x 16 B 2bpp tiles) renders the digits
    # 0-9 (verified visually); structurally: every tile must contain pixels
    # of index 0 and at least one stroke pixel, and the 10 tiles must all be
    # distinct glyph patterns.
    pc = _pc("FF:CAFC")
    idx = decode_tiles_2bpp(rom[pc:pc + 160])
    assert idx.shape == (10, 8, 8)
    for i, t in enumerate(idx):
        assert (t == 0).any(), f"tile {i} has no background"
        assert (t != 0).any(), f"tile {i} is blank"
    assert len({t.reshape(-1).tobytes() for t in idx}) == 10


# ---------------------------------------------------------------------------
# (e) manifests are valid JSON with nonzero counts
# ---------------------------------------------------------------------------
def test_manifests_valid_json_nonzero(manifest_path):
    gpath = manifest_path("graphics_manifest.json")
    ppath = manifest_path("palettes.json")
    with open(gpath) as f:
        g = json.load(f)
    with open(ppath) as f:
        p = json.load(f)
    dec = [b for b in g["blobs"] if b.get("status") == "decoded"]
    assert len(dec) >= 5
    assert any(b["bpp"] == 4 for b in dec)
    assert any(b["bpp"] == 2 for b in dec)
    assert g["summary"]["banks_decoded"] == len(dec)
    assert g["summary"]["total_tiles"] > 0
    assert len(p["blobs"]) > 0
    assert p["summary"]["total_subpalettes"] > 0
    assert p["summary"]["lzss_packs_verified"] == 19
    assert p["summary"]["lzss_packs_failed"] == 0
    # palette entries carry both hex words and sRGB triples
    blob = p["blobs"]["LocPal_Rom"]
    assert blob["color_words"] == 9240
    assert blob["bit15_set_words"] == 0
    assert len(blob["srgb"]) == len(blob["bgr555_hex"])
    sub = blob["subpalettes"][0]
    assert sub["colors"] == 15 and len(sub["srgb"]) == 15
    # hex words and srgb triples agree
    for hx, trip in zip(sub["bgr555_hex"], sub["srgb"]):
        assert list(bgr555_to_rgb(int(hx, 16))) == trip


def test_render_sheet_output_shape():
    idx = np.zeros((3, 8, 8), dtype=np.uint8)
    pal = [(i * 10, i * 20, i * 30) for i in range(4)]
    img = render_sheet(idx, pal, cols=2)
    assert img.size == (16, 16)  # 2 cols x 8, 2 rows x 8
    assert img.mode == "RGBA"
    assert img.getpixel((0, 0)) == (0, 0, 0, 255)
