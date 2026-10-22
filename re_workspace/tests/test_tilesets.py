"""Location tilesets: graphics packs, metatiles, palettes, palette and tile animations (tools/ct_tilesets.py).

ROM-free: the square-LZSS stream codec (both modes, partial last groups),
the SNES planar layouts, the tilemap word, the stage simulation of the pack
uploads (short packs keep the stage tail), both animation list readers,
the palette-cycle simulator and the Swift vectors file, all on synthetic bytes.

Local (ROM, ChronoRET): every source, code and data claim of `check`, a
subset of the `--run` claims (the ROM's decompressor, both list loaders and
PalAnim_TickAll in ChronoRET's 65816 interpreter) and the metatile render.
"""

import json
import os
import struct
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_tilesets as ct  # noqa: E402


@pytest.fixture(scope="module")
def synthetic():
    regions, expect = ct.synthetic_rom()
    image = bytearray(ct.ROM_SIZE)
    for long, data in regions.items():
        image[ct.pc(long):ct.pc(long) + len(data)] = data
    return bytes(image), expect


# --- ROM-free ---------------------------------------------------------------------------

@pytest.mark.parametrize("mode", (11, 12))
def test_lzss_round_trip_with_partial_last_groups(mode):
    rng = ct.Lcg(mode)
    for n in (0, 1, 7, 8, 9, 63, 64, 65, 300, 4096):
        data = bytes(rng.next(4) * 17 if rng.next(3) else rng.next(256) for _ in range(n))
        packed = ct.pack_bytes(data, mode)
        out, got_mode, used = ct.unpack_bytes(packed + b"\xEE" * 4)
        assert (out, used) == (data, len(packed)), n
        if n:
            assert got_mode == mode


def test_lzss_reads_back_references_by_mode():
    # 3 literals, then one reference: distance 3, length 3 + 2 (lz12: v >> 12; lz11: v >> 11).
    for mode, v in ((12, 3 | 2 << 12), (11, 3 | 2 << 11)):
        body = bytes([0b1000]) + b"abc" + struct.pack("<H", v)
        stream = struct.pack("<H", 0) + bytes([4 | (0x40 if mode == 11 else 0)]) + struct.pack("<H", 5 + len(body))
        stream += body + bytes([0x40 if mode == 11 else 0])
        assert ct.unpack_bytes(stream)[:2] == (b"abcabcab", mode)


def test_tile_layouts_and_tilemap_word():
    raw = bytearray(32)
    raw[2 * 3] = raw[2 * 3 + 1] = 0x80          # row 3, pixel 0: planes 0 and 1
    raw[16 + 2 * 5] = 0x01                      # row 5, pixel 7: plane 2
    px = ct.tile_indices(bytes(raw), 4)
    assert px[24] == 3 and px[47] == 4 and sum(1 for v in px if v) == 2
    assert ct.tile_indices(bytes(raw[:16]), 2)[24] == 3
    assert ct.chip(0x2C05 | 0x8000) == {"tile": 5, "palette": 3, "priority": 1, "hflip": 0, "vflip": 1}
    assert ct.chip(0x4000)["hflip"] == 1 and ct.chip(0x4000)["priority"] == 0


def test_short_pack_uploads_the_stage_tail(synthetic):
    rom, _ = synthetic
    window, uploads = ct.bg12_vram(rom, 0)           # list [1, 0, -, 2, -, 1, 4, -]
    assert [u["firstTile"] for u in uploads] == [256, 384, 512, 640, 768, 896]
    assert [u["pack"] for u in uploads] == [1, 0, None, 2, None, 1]
    assert uploads[3]["ownTiles"] == 16 and uploads[3]["tiles"] == 128
    pack0, pack1 = ct.pack(rom, 0)["data"], ct.pack(rom, 1)["data"]
    # Pack 2 is 16 tiles: the rest of its upload is what packs 1 and 0 left on the stage.
    assert bytes(window[656 * 32:704 * 32]) == pack0[16 * 32:64 * 32]
    assert bytes(window[704 * 32:768 * 32]) == pack1[64 * 32:128 * 32]
    assert uploads[5]["tiles"] == ct.PACK5_BYTES // 32 == 124
    assert ct.ranges(ct.known_tiles(window, 32)) == [[256, 512], [640, 768], [896, 1020]]


def test_animation_lists_and_frames(synthetic):
    rom, _ = synthetic
    recs, start, end = ct.anim_list_a(rom, 0)
    assert [r and r["kind"] for r in recs[:3]] == [4, 2, None] and recs[0]["vram"] == 0x3290
    assert recs[1]["steps8"] == [0x2B, 0x10] * 4 and recs[1]["sources8"] == [0x7000, 0x7080] * 4
    assert len(ct.anim_data(recs)) == 64
    # The accumulator steps by 4 x step; the frame is its bits 9-11.
    assert ct.anim_frames(recs[0], 6) == [0, 0, 1, 1, 1, 1]      # steps $40, $20: +$100, +$100, +$80 ...
    assert ct.anim_list_a(rom, 1)[0] == [None] * 12
    b, _, _ = ct.anim_list_b(rom, 0)
    assert [r and r["name"] for r in b] == ["rotate-down", "rom-frames", "list-frames", None, None, None]
    assert b[2]["order"] == [0, 1, 2, 3, 2, 1] and len(b[2]["colours"]) == 4 and b[1]["frames"] == 3


def test_cycle_state_rotates_and_steps_frames(synthetic):
    rom, _ = synthetic
    b, _, _ = ct.anim_list_b(rom, 1)                  # rotate up 6 colours from $51 every 2 ticks
    cg = list(range(256))
    state = ct.CycleState(b)
    state.tick(cg)
    assert cg == list(range(256))
    state.tick(cg)
    assert cg[0x51:0x57] == [0x56, 0x51, 0x52, 0x53, 0x54, 0x55] and cg[0x57] == 0x57
    b0, _, _ = ct.anim_list_b(rom, 0)
    cg = [0] * 256
    state = ct.CycleState(b0)
    for _ in range(6):
        state.tick(cg)
    assert cg[0x31:0x35] == b0[1]["colours"][1]       # frame 1 after the first 6-tick delay
    assert cg[0x41:0x43] == b0[2]["colours"][b0[2]["order"][2]]  # every 3 ticks: twice so far
    for _ in range(3):
        state.tick(cg)
    assert cg[0x41:0x43] == b0[2]["colours"][b0[2]["order"][3]]


def test_swift_vectors_file_is_current():
    path = ct.VECTORS
    assert path.exists(), "regenerate with ct_tilesets.py vectors --out"
    assert path.read_text() == ct.vectors_text()
    vectors = json.loads(path.read_text())
    assert vectors["schema"] == "ct-tileset-vectors/1"
    assert [len(vectors[k]) for k in ("tileset12", "tileset3", "palettes")] == [2, 1, 2]
    for d in vectors["tileset12"]:
        assert len(d["metatiles"]) == 512
        assert sum(len(r["hex"]) for r in d["tileIndices"]) == 128 * sum(b - a for a, b in d["knownTiles"])


# --- Local: the ROM and ChronoRET --------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return ct.read_rom(rom_path)


def failed(claims):
    return [(name, *detail) for name, ok, *detail in claims if not ok]


def test_chronoret_source_claims(rom, chronoret):
    claims = ct.asm_claims(chronoret)
    assert len(claims) == len(ct.ASM_CLAIMS) + len(ct.CONSTANT_CLAIMS)
    assert not failed(claims)


def test_code_claims(rom):
    assert not failed(ct.code_claims(rom))


def test_data_claims(rom, data_assets_csv):
    assert not failed(ct.data_claims(rom, data_assets_csv))


def test_rom_routines_run_as_decoded(rom, chronoret):
    t12 = ct.used_t12(rom)
    claims = ct.run_claims(rom, ref=chronoret, tables=[(ct.META12_PTRS, t12[0]), (ct.META3_PTRS, 0)],
                           packs=[n for n in ct.pack_list(rom, t12[0]) if n is not None][:3],
                           sets_a=range(4), sets_b=range(4), ticks=60)
    assert not failed(claims)


def test_decoded_tilesets_are_consistent(rom):
    for t in ct.used_t12(rom):
        d = ct.decode_t12(rom, t)
        assert len(d["metatiles"]) == 512 and d["locations"]
        assert all(256 <= a < b <= 1020 for a, b in d["knownTiles"])
    for n in ct.used_t3(rom):
        assert len(ct.decode_t3(rom, n)["metatiles"]) == 256
    assert len(ct.used_pal(rom)) == 83


def test_render_writes_a_png(rom, tmp_path):
    out = tmp_path / "t12.png"
    pal = ct.render(rom, ct.used_t12(rom)[0], out, scale=1)
    data = out.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", data[16:24]) == (256, 512)
    assert pal in ct.used_pal(rom)
