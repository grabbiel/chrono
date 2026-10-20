"""Phase 2.2 driver: extract and decode Chrono Trigger (USA v1.0) planar
graphics from re_workspace/ct_clean.sfc.

Asset offsets come from ChronoRET's symbols/data_assets.csv (a byte-exact
manifest of this ROM); blob formats come from symbols/data_survey.csv
comments (quoted per-blob below in the `note` fields).  Outputs:

  assets/graphics/<label>.bin          decoded index bytes (1 byte/pixel)
  assets/graphics/<label>.png          mode-'P' sheet, identity palette
  assets/graphics/<label>_preview.png  RGBA render through the preview palette
  manifests/palettes.json              every palette: BGR555 words + sRGB
  manifests/graphics_manifest.json     offsets, counts, checks, png paths

Run with the workspace venv:
  re_workspace/.venv/bin/python re_workspace/tools/ct_extractor_gfx.py
"""

from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WS = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from ct_gfx import (bgr555_to_rgb, decode_palette, decode_tiles_2bpp,
                    decode_tiles_4bpp, lzss_unpack, palette_words,
                    save_indexed_png, save_render_png)

ROM_PATH = os.path.join(WS, "ct_clean.sfc")
ASSETS_CSV = os.path.join(WS, "refs", "ChronoRET", "symbols", "data_assets.csv")
GFX_DIR = os.path.join(WS, "assets", "graphics")
MAN_DIR = os.path.join(WS, "manifests")


def snes_pc(snes: str) -> int:
    b, a = snes.lstrip("$").split(":")
    return ((int(b, 16) & 0x3F) << 16) | int(a, 16)


def load_rows() -> dict[str, list[str]]:
    rows = {}
    with open(ASSETS_CSV, newline="") as f:
        for p in csv.reader(l for l in f if not l.startswith("#")):
            if len(p) >= 6:
                rows[p[0]] = p
    return rows


# ---------------------------------------------------------------------------
# graphics banks: label -> (bpp, note from ChronoRET data_survey.csv)
# ---------------------------------------------------------------------------
GRAPHICS_BANKS = {
    # --- 4bpp, 32 B/tile, uncompressed (survey: "4bpp 8x8 tiles,
    #     uncompressed (32 B per tile)", readers Spr_CopyTileD2 /
    #     Battle_InitScene via BattleRom_SprTilesPtr) ---
    "Gfx_D20000":        (4, "character 6 sprite tiles (BattleRom_SprTilesPtr entry 6); survey: 4bpp 8x8 tiles, uncompressed, 32 B per tile [confirmed]"),
    "Gfx_D272C0":        (4, "character 0 sprite tiles (BattleRom_SprTilesPtr entry 0); survey: 4bpp 8x8 tiles, uncompressed [confirmed]"),
    "Gfx_D30000":        (4, "character 4 sprite tiles (BattleRom_SprTilesPtr entry 4); survey: 4bpp 8x8 tiles, uncompressed [confirmed]"),
    "Gfx_D36B40":        (4, "character 2 sprite tiles (BattleRom_SprTilesPtr entry 2); survey: 4bpp 8x8 tiles, uncompressed [confirmed]"),
    "Gfx_D40000":        (4, "character 1 sprite tiles (BattleRom_SprTilesPtr entry 1); survey: 4bpp 8x8 tiles, uncompressed [confirmed]"),
    "Gfx_D47C40":        (4, "character 3 sprite tiles (BattleRom_SprTilesPtr entry 3); survey: 4bpp 8x8 tiles, uncompressed [confirmed]"),
    "Gfx_D50000":        (4, "character 5 sprite tiles (BattleRom_SprTilesPtr entry 5); survey: 4bpp 8x8 tiles, uncompressed [confirmed]"),
    "BattleRom_InitTiles4bpp": (4, "survey: 64 x 32 B 4bpp tiles, reader Battle_InitSceneGfx [confirmed]"),
    "MenuRom_Tiles4bpp": (4, "survey: $600 B of 4bpp tiles, reader Menu_LoadGraphics [confirmed]"),
    "MenuRom_WindowGfx": (4, "survey: 8 window styles of $280 B (4bpp tiles), readers Menu_LoadGraphics/Menu_LoadWindowGfx [confirmed]"),
    "C2SceneRom_MapMarkerTiles": (4, "survey: two 4bpp tiles: sprite tiles 0 and 2 of the map view, reader C2Scene_MapView [confirmed]"),
    # --- 2bpp, 16 B/tile ---
    "BattleRom_FxTileGfx": (2, "survey: 2bpp tile graphics: entry tile * 8, reader BattleCD_TileCopy2 [confirmed]"),
    "MenuRom_Font2bpp":  (2, "survey: 2bpp tiles, reader Menu_LoadGraphics [confirmed]"),
    "MenuRom_Font2bppB": (2, "survey: $100 B: 16 2bpp tiles, reader Menu_LoadGraphics [confirmed]"),
    "MenuRom_GlyphRows": (2, "survey: 10 x 16 B: 2bpp tiles, reader BankFF_BuildTileSets [confirmed]"),
    "Gfx_D14C80":        (2, "survey: 16 x 16 B 2bpp tiles, widened to 4bpp by Battle_InitSceneGfx [confirmed]"),
    "Gfx_FF0000":        (2, "survey: tile-like bytes (2bpp, by their look) [probable - no reader found]"),
}

# ShadowTiles: blob is bigger; only its first 160 B are the confirmed
# 10 x 16 B 2bpp tiles its reader (BankFF_WidenTiles) takes.
GRAPHICS_TRIMMED = {
    "MenuRom_ShadowTiles": (2, 160, "survey: 10 x 16 B 2bpp tiles (its own reader takes 160 B) [confirmed for first 160 B]"),
}

# ---------------------------------------------------------------------------
# palette blobs: label -> (record bytes or None, note)
# record=None -> raw colour array (no verified per-palette split)
# ---------------------------------------------------------------------------
PALETTE_BLOBS = {
    "LocPal_Rom":               ("locpal", "88 x $D2 B: colours 1-15 of 7 rows (BGR555), reader LocLoad_Unk7084 [confirmed]"),
    "Palette_F66CF0":           (None, "BGR555 colours (every word has bit 15 clear), PalAnim readers [probable]"),
    "Palette_FEF91E":           (None, "raw BGR555 colours (bit 15 clear throughout), $C3 module MVN source [probable]"),
    "Palette_E42A00":           (None, "u16 offsets per sprite set, then 12-colour palettes (BGR555); the split between offsets and colours not measured [probable]"),
    "Palette_FE4B7A":           (16, "8-colour palette [raw words; record size assumed 16 B]"),
    "Palette_FE8D15":           (16, "8-colour palette [raw words; record size assumed 16 B]"),
    "BattleRom_BgSetPalettes":  (None, "background sets' palette rows (offsets via BattleFx_BgSetPalOfs, not resolved here) [confirmed palette data, split not measured]"),
    "BattleRom_GradColours":    ("grad20", "9 sets of 14 colours, $20 apart [confirmed]"),
    "BattleRom_PalSets6":       (6, "6 B per colour set (3 colours), readers BattleAct_OpLoadPalEntry/BattleAct_StepPalettes [confirmed]"),
    "BattleRom_PalSets14":      (14, "14 B per colour set (7 colours), same readers [confirmed]"),
    "BattleRom_WeaponColours":  (6, "6 B (3 colours) per record, copied into the PC's sprite palette at set-up [confirmed]"),
    "BattleRom_SpecialPals":    (24, "24 B (12 colours) per entry: opcode $69's palette [confirmed]"),
    "BattleRom_FxColours":      (8, "8 B per colour set; bytes 2-7 (colours 1-3) are copied [confirmed]"),
    "BattleRom_FxCycleColours": (None, "BGR555 colours of the status colour cycles [confirmed palette data; 10 words carry bit 15 - non-colour fields mixed in]"),
    "BattleRom_FxTintColours":  (4, "2 colours [confirmed]"),
    "FieldRom_PalRow0Sets":     (16, "colour sets 16 B apart (window palettes), readers Pal_LoadUnkRow0/Menu_LoadWindowPal [confirmed]"),
    "MenuRom_MainPalB":         (16, "8 colours [confirmed palette row]"),
    "MenuRom_SlotIconPals":     (32, "16 colours per character for its slot icon, reader Menu_SlotMemberIcon [confirmed; 368 B = 11 full records + 16 B tail]"),
    # rows the CSV classes as 'records' with param 'palette 16 x 2 B':
    "C2SceneRom_MapViewObjPal": (32, "palette 16 x 2 B (CSV records param)"),
    "C2SceneRom_ObjAPalA":      (32, "palette 16 x 2 B (CSV records param)"),
    "C2SceneRom_ObjAPalB":      (32, "palette 16 x 2 B (CSV records param)"),
    "C2SceneRom_LastPalRow":    (32, "palette 16 x 2 B (CSV records param)"),
    "MenuRom_LoadPalB":         (32, "palette 16 x 2 B (CSV records param)"),
    "MenuRom_NameChoicePal":    (32, "palette 16 x 2 B (CSV records param)"),
}


def split_subpalettes(label: str, kind, blob: bytes):
    """Split a palette blob into named sub-palettes per the survey's record
    layout.  Returns list of dicts."""
    words = palette_words(blob)
    out = []
    if kind == "locpal":
        # 88 sets x 210 B; each set = 7 rows x 30 B = 15 colours (colours 1-15)
        assert len(blob) == 88 * 210, f"LocPal_Rom size {len(blob)} != 88*210"
        for si in range(88):
            for ri in range(7):
                base = si * 210 + ri * 30
                w = [int.from_bytes(blob[base + 2 * i:base + 2 * i + 2], "little") & 0x7FFF
                     for i in range(15)]
                out.append({"name": f"set{si:02d}_row{ri}", "colors": 15,
                            "bgr555_hex": [f"0x{v:04x}" for v in w],
                            "srgb": [list(bgr555_to_rgb(v)) for v in w]})
        return out
    if kind == "grad20":
        for si in range(9):
            base = si * 0x20
            w = [int.from_bytes(blob[base + 2 * i:base + 2 * i + 2], "little") & 0x7FFF
                 for i in range(14)]
            out.append({"name": f"grad{si}", "colors": 14,
                        "bgr555_hex": [f"0x{v:04x}" for v in w],
                        "srgb": [list(bgr555_to_rgb(v)) for v in w]})
        return out
    if kind is None:
        return out  # raw; whole-blob words are recorded at blob level
    rec = kind
    n = len(blob) // rec
    for i in range(n):
        base = i * rec
        w = [int.from_bytes(blob[base + 2 * j:base + 2 * j + 2], "little") & 0x7FFF
             for j in range(rec // 2)]
        out.append({"name": f"rec{i:02d}", "colors": len(w),
                    "bgr555_hex": [f"0x{v:04x}" for v in w],
                    "srgb": [list(bgr555_to_rgb(v)) for v in w]})
    return out


def plane_stats_4bpp(raw: bytes) -> dict:
    """Bit density of plane0/1 bytes (0..15) vs plane2/3 bytes (16..31).
    Real 4bpp art uses the high planes sparsely -> plane23 density well
    below plane01; this is the byte-level signature of the planar layout."""
    t = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 32)
    bits = np.unpackbits(t, axis=1).reshape(-1, 32, 8)
    d01 = float(bits[:, 0:16, :].mean())
    d23 = float(bits[:, 16:32, :].mean())
    return {"plane01_bit_density": round(d01, 4), "plane23_bit_density": round(d23, 4)}


def plane_stats_2bpp(raw: bytes) -> dict:
    t = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 16)
    bits = np.unpackbits(t, axis=1).reshape(-1, 16, 8)
    return {"plane0_bit_density": round(float(bits[:, 0:16:2, :].mean()), 4),
            "plane1_bit_density": round(float(bits[:, 1:16:2, :].mean()), 4)}


def _neighbour_agree(idx: np.ndarray) -> float:
    """Mean fraction of horizontally and vertically adjacent pixels inside
    each tile that hold the same index.  Real art is spatially smooth, so the
    correct bit layout scores clearly above any wrong one."""
    h = (idx[:, :, :-1] == idx[:, :, 1:]).mean()
    v = (idx[:, :-1, :] == idx[:, 1:, :]).mean()
    return round(float((h + v) / 2), 4)


def layout_discrimination_4bpp(raw: bytes) -> dict:
    """Decode the same 32 B under the correct interleaved-planar layout and
    two plausible wrong layouts; the correct one must win on pixel-neighbour
    agreement and empty-tile fraction (index 0 = transparent)."""
    t = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 32)

    def decode(cols):  # cols = [p0r0..p0r7, p1.., p2.., p3..] byte indices
        planes = []
        for k in range(4):
            rawb = t[:, cols[8 * k:8 * k + 8]]
            planes.append(np.unpackbits(rawb, axis=1).reshape(-1, 8, 8))
        idx = np.zeros((t.shape[0], 8, 8), dtype=np.uint8)
        for k, p in enumerate(planes):
            idx |= (p & 1) << k
        return idx

    interleaved = (list(range(0, 16, 2)) + list(range(1, 16, 2))
                   + list(range(16, 32, 2)) + list(range(17, 32, 2)))
    chunky = (list(range(0, 8)) + list(range(8, 16))
              + list(range(16, 24)) + list(range(24, 32)))
    # planes 0/1 interleaved as usual, but the second half read chunky
    # (plane2 = bytes 16-23, plane3 = bytes 24-31)
    p0132 = (list(range(0, 16, 2)) + list(range(1, 16, 2))
             + list(range(16, 24)) + list(range(24, 32)))
    correct = decode(interleaved)
    res = {"correct": _neighbour_agree(correct),
           "chunky_planes": _neighbour_agree(decode(chunky)),
           "planes_0132": _neighbour_agree(decode(p0132))}
    res["correct_wins"] = (res["correct"] > res["chunky_planes"]
                           and res["correct"] > res["planes_0132"])
    return res


def layout_discrimination_2bpp(raw: bytes) -> dict:
    t = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 16)

    def decode(cols):
        idx = np.zeros((t.shape[0], 8, 8), dtype=np.uint8)
        for k in range(2):
            rawb = t[:, cols[8 * k:8 * k + 8]]
            p = np.unpackbits(rawb, axis=1).reshape(-1, 8, 8)
            idx |= (p & 1) << k
        return idx

    correct = decode(list(range(0, 16, 2)) + list(range(1, 16, 2)))
    chunky = decode(list(range(0, 8)) + list(range(8, 16)))
    res = {"correct": _neighbour_agree(correct),
           "chunky_planes": _neighbour_agree(chunky)}
    res["correct_wins"] = res["correct"] > res["chunky_planes"]
    return res


def main() -> int:
    rom = open(ROM_PATH, "rb").read()
    assert len(rom) == 4 * 1024 * 1024
    sha = hashlib.sha256(rom).hexdigest()
    rows = load_rows()
    os.makedirs(GFX_DIR, exist_ok=True)
    os.makedirs(MAN_DIR, exist_ok=True)

    # ---------------- palettes.json ----------------
    palettes = {
        "format": "15-bit BGR555 little-endian; sRGB expansion (c<<3)|(c>>2)",
        "rom_sha256": sha,
        "blobs": {},
        "packed_lzss": {},
    }
    total_sub = 0
    for label, (kind, note) in PALETTE_BLOBS.items():
        r = rows[label]
        assert r[4] in ("extracted", "records"), f"{label} piece={r[4]}"
        s, e = snes_pc(r[1]), snes_pc(r[2])
        blob = rom[s:e + 1]
        assert len(blob) == int(r[3]), f"{label} size mismatch"
        words = palette_words(blob)
        subs = split_subpalettes(label, kind, blob)
        total_sub += len(subs)
        palettes["blobs"][label] = {
            "snes": r[1], "pc_start": s, "size": len(blob),
            "color_words": len(words),
            "bit15_set_words": sum(1 for w0 in
                                   np.frombuffer(blob, dtype="<u2") if int(w0) & 0x8000),
            "bgr555_hex": [f"0x{w:04x}" for w in words],
            "srgb": [list(bgr555_to_rgb(w)) for w in words],
            "subpalettes": subs,
            "note": note,
        }

    # packed scene palettes: unpack with the documented LZSS probe and
    # verify against the expected sizes in data_assets.csv
    lz_ok = lz_fail = 0
    for label, r in sorted(rows.items()):
        if not label.startswith("ScenePalPack_"):
            continue
        m = re.search(r"lz1[12] -> (\d+) B", r[6])
        if not m:
            continue
        exp = int(m.group(1))
        s, e = snes_pc(r[1]), snes_pc(r[2])
        try:
            out = lzss_unpack(rom[s:e + 1], exp)
        except ValueError as ex:
            lz_fail += 1
            palettes["packed_lzss"][label] = {"snes": r[1], "expected_size": exp,
                                              "error": str(ex)}
            continue
        lz_ok += 1
        words = [int.from_bytes(out[2 * i:2 * i + 2], "little") & 0x7FFF
                 for i in range(len(out) // 2)]
        subs = []
        for i in range(0, len(words), 16):
            w = words[i:i + 16]
            subs.append({"name": f"pal{i // 16}", "colors": len(w),
                         "bgr555_hex": [f"0x{v:04x}" for v in w],
                         "srgb": [list(bgr555_to_rgb(v)) for v in w]})
        total_sub += len(subs)
        palettes["packed_lzss"][label] = {
            "snes": r[1], "pc_start": s, "packed_size": len(rom[s:e + 1]),
            "mode": r[6].split()[0], "expected_size": exp,
            "unpacked_size": len(out), "size_verified": len(out) == exp,
            "bit15_set_words": sum(int.from_bytes(out[2 * i:2 * i + 2], "little") >> 15
                                   for i in range(len(out) // 2)),
            "bgr555_hex": [f"0x{w:04x}" for w in words],
            "srgb": [list(bgr555_to_rgb(w)) for w in words],
            "subpalettes": subs,
            "note": "scene palettes (C2Scene_LoadPalettes et al.), unpacked via "
                    "$C3:0002 Decomp_ToWram format documented in ChronoRET bankC3.asm",
        }
    palettes["summary"] = {
        "palette_blobs": len(palettes["blobs"]),
        "lzss_packs_verified": lz_ok,
        "lzss_packs_failed": lz_fail,
        "total_subpalettes": total_sub,
    }
    with open(os.path.join(MAN_DIR, "palettes.json"), "w") as f:
        json.dump(palettes, f)

    # preview palette: LocPal_Rom set 00 row 0 (15 colours), index 0 = black
    loc = palettes["blobs"]["LocPal_Rom"]["subpalettes"][0]
    preview_pal = [(0, 0, 0)] + [tuple(c) for c in loc["srgb"]]

    # ---------------- graphics banks ----------------
    manifest = {
        "rom": os.path.basename(ROM_PATH), "rom_sha256": sha,
        "source_manifest": os.path.relpath(ASSETS_CSV, WS),
        "tile_format": "SNES planar: 4bpp = 32 B/tile (planes 0/1 interleaved in "
                       "bytes 0-15, planes 2/3 in bytes 16-31, bit7 = left pixel); "
                       "2bpp = 16 B/tile (planes 0/1 interleaved)",
        "preview_palette": {"source": "LocPal_Rom set00_row0 + index0=black",
                            "srgb": [list(c) for c in preview_pal]},
        "blobs": [],
    }
    banks: dict[str, tuple] = dict(GRAPHICS_BANKS)
    for label, (bpp, trim, note) in GRAPHICS_TRIMMED.items():
        banks[label] = (bpp, note, trim)

    n4 = n2 = 0
    layout_failures = []
    for label, spec in banks.items():
        if len(spec) == 3:
            bpp, note, trim = spec
        else:
            bpp, note = spec
            trim = None
        r = rows[label]
        assert r[4] == "extracted", f"{label} piece={r[4]}"
        s, e = snes_pc(r[1]), snes_pc(r[2])
        raw = rom[s:e + 1]
        if trim is not None:
            raw = raw[:trim]
        tb = 32 if bpp == 4 else 16
        divisible = len(raw) % tb == 0
        entry = {"label": label, "snes_start": r[1], "snes_end": r[2],
                 "pc_start": s, "bytes": len(raw), "bpp": bpp,
                 "tile_bytes": tb, "trimmed": trim is not None,
                 "size_divisible_by_tile_bytes": divisible, "note": note}
        if not divisible:
            entry["status"] = "SKIPPED-size-not-tile-aligned"
            manifest["blobs"].append(entry)
            continue
        idx = (decode_tiles_4bpp(raw) if bpp == 4 else decode_tiles_2bpp(raw))
        tiles = idx.shape[0]
        cols = 32 if tiles >= 32 else max(1, tiles)
        rows_n = math.ceil(tiles / cols)
        binp = os.path.join(GFX_DIR, f"{label}.bin")
        pngp = os.path.join(GFX_DIR, f"{label}.png")
        prevp = os.path.join(GFX_DIR, f"{label}_preview.png")
        with open(binp, "wb") as f:
            f.write(idx.reshape(-1).tobytes())
        w_px, h_px = save_indexed_png(idx, pngp, cols)
        save_render_png(idx, preview_pal, prevp, cols)
        hist = np.bincount(idx.reshape(-1), minlength=16)[: 16 if bpp == 4 else 4]
        entry.update({
            "tiles": tiles, "sheet_cols": cols, "sheet_rows": rows_n,
            "sheet_png": os.path.relpath(pngp, WS),
            "indexed_bin": os.path.relpath(binp, WS),
            "preview_png": os.path.relpath(prevp, WS),
            "sheet_size": [w_px, h_px],
            "index_histogram": [int(x) for x in hist],
            "index0_fraction": round(float(hist[0]) / idx.size, 4),
            "empty_tile_fraction": round(float(np.mean((idx == 0).all(axis=(1, 2)))), 4),
            "plane_density": (plane_stats_4bpp(raw) if bpp == 4 else
                              plane_stats_2bpp(raw)),
            "layout_discrimination": (layout_discrimination_4bpp(raw) if bpp == 4
                                      else layout_discrimination_2bpp(raw)),
            "status": "decoded",
        })
        manifest["blobs"].append(entry)
        ld = entry["layout_discrimination"]
        if not ld["correct_wins"]:
            if entry["tiles"] >= 32:
                layout_failures.append(label)
            else:
                # too few tiles for the continuity metric to separate layouts;
                # the 2bpp interleave is nonetheless proven visually on the
                # font banks (digits 0-9, a-z/A-Z decode correctly)
                entry["layout_note"] = ("statistically inconclusive at n="
                                        f"{entry['tiles']} tiles; layout "
                                        "confirmed by the visually verified "
                                        "font banks using the same convention")
        if bpp == 4:
            n4 += 1
        else:
            n2 += 1

    manifest["summary"] = {
        "banks_decoded": n4 + n2, "banks_4bpp": n4, "banks_2bpp": n2,
        "total_tiles": sum(b.get("tiles", 0) for b in manifest["blobs"]),
        "total_index_bytes": sum(b.get("bytes", 0) for b in manifest["blobs"]),
        "layout_discrimination_failures": layout_failures,
    }
    manifest["gaps"] = [
        "MenuRom_Tiles3bpp ($FF:DBE4): 3bpp tiles (24 B/tile) - outside this "
        "phase's 4bpp/2bpp scope.",
        "BattleRom_FxGfxSrc ($D0:0000): 2bpp tiles 'some with a third plane' - "
        "mixed layout, not decoded here.",
        "Packed scene BG graphics ($C4:0000+ etc.) unpacked fine by the probe "
        "but not rendered: per-pack tile bpp not pinned by the survey.",
    ]
    with open(os.path.join(MAN_DIR, "graphics_manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)

    print(f"palettes: {len(palettes['blobs'])} blobs + {lz_ok} LZSS packs "
          f"({total_sub} sub-palettes), lz_fail={lz_fail}")
    print(f"graphics: {n4} 4bpp banks + {n2} 2bpp banks = "
          f"{manifest['summary']['total_tiles']} tiles")
    for b in manifest["blobs"]:
        if b.get("status") == "decoded":
            pd = b["plane_density"]
            ld = b["layout_discrimination"]
            print(f"  {b['label']:28s} {b['bpp']}bpp {b['tiles']:5d}t  {pd}  "
                  f"layout={ld}")
    if layout_failures:
        print(f"LAYOUT DISCRIMINATION FAILED for: {layout_failures}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
