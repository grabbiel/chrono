"""The playable characters' sprites: frames, tiles, animations (tools/ct_sprites.py).

ROM-free: the SNES planar tile layout, the frame record codec, the cell order
of the four 16x16 OBJs, mirroring and blank cells, OAM front order, the
animation end rules and the Swift vectors file, all on synthetic bytes.

Local (ROM, ChronoRET): every source, code and data claim of `check`, the
ROM's own frame decoder ($C1:1C55) run in ChronoRET's 65816 interpreter
against `decode_frame` for every frame of the seven sets, and the same
decoder fed the synthetic sets of the vectors (patched into a copy).
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

import ct_sprites as cs  # noqa: E402


def record(words, pairs):
    return b"".join(struct.pack("<H", w) for w in words) + bytes(v & 0xFF for v in pairs)


def solid_tile(index):
    """A 4bpp tile whose 64 pixels are all `index` (SNES planar layout)."""
    raw = bytearray(32)
    for r in range(8):
        for p in range(4):
            if index >> p & 1:
                raw[(16 if p >= 2 else 0) + 2 * r + (p & 1)] = 0xFF
    return bytes(raw)


# --- ROM-free ---------------------------------------------------------------------------

def test_tile_layout_interleaves_planes_per_row():
    raw = bytearray(32)
    raw[2 * 3] = 0x80          # plane 0, row 3, leftmost pixel
    raw[2 * 3 + 1] = 0x80      # plane 1, same pixel
    raw[16 + 2 * 5] = 0x01     # plane 2, row 5, rightmost pixel
    raw[17 + 2 * 6] = 0x40     # plane 3, row 6, second pixel
    px = cs.tile_indices(bytes(raw))
    assert px[3 * 8 + 0] == 3 and px[5 * 8 + 7] == 4 and px[6 * 8 + 1] == 8
    assert sum(1 for v in px if v) == 3
    for v in range(16):
        assert cs.tile_indices(solid_tile(v)) == [v] * 64


def test_frame_record_codec():
    words = [0x0000, 0x0001, 0x47FF, 0x8002] + [0x0100 + k for k in range(12)]
    rec = record(words, [-8, 0, 127, -128, 0, -1, 5, 6])
    frame = cs.decode_frame(rec)
    assert frame["cells"] == words
    assert frame["pieces"] == [[-8, 0], [127, -128], [0, -1], [5, 6]]
    with pytest.raises(AssertionError):
        cs.decode_frame(rec[:-1])


def test_obj_n_shows_two_columns_of_both_rows():
    assert [cs.piece_cells(n) for n in range(4)] == [[0, 1, 8, 9], [2, 3, 10, 11], [4, 5, 12, 13], [6, 7, 14, 15]]


def test_cells_blank_mirrored_and_out_of_range():
    left = bytearray(32)
    for r in range(8):
        left[2 * r] = 0xF0     # index 1 in the left half of every row
    tb = [bytes(32), bytes(left)]
    assert cs.cell_pixels(0x0000, tb) == [0] * 64
    assert cs.cell_pixels(0x4000, tb) == [0] * 64             # tile 0 is blank, mirrored or not
    assert cs.cell_pixels(0x0001, tb)[:8] == [1, 1, 1, 1, 0, 0, 0, 0]
    assert cs.cell_pixels(0x4001, tb)[:8] == [0, 0, 0, 0, 1, 1, 1, 1]
    assert cs.cell_pixels(0x8001, tb) == cs.cell_pixels(0x0001, tb)   # bit 15 is not tested
    assert cs.cell_pixels(0x0002, tb) == [0] * 64             # beyond the set: nothing


def test_compose_places_objs_and_keeps_the_lower_one_in_front():
    tb = [bytes(32), solid_tile(1), solid_tile(2)]
    cells = [0] * 16
    cells[0] = 1                              # OBJ 0, top-left: index 1
    cells[2] = 2                              # OBJ 1, top-left: index 2
    frame = {"cells": cells, "pieces": [[0, 0], [4, 0], [-20, 30], [0, 0]]}
    img = cs.compose(frame, tb)
    assert img[(0, 0)] == 1 and img[(7, 7)] == 1          # OBJ 0 over OBJ 1 where they overlap
    assert img[(8, 0)] == 2 and img[(11, 7)] == 2         # OBJ 1 alone
    assert (12, 0) not in img and (0, 8) not in img
    assert len(img) == 64 + 32


def test_expected_buffer_bit_reverses_mirrored_cells():
    tb = [bytes(32), bytes(range(32))]
    cells = [1, 0x4001] + [0] * 14
    rows, extra = cs.expected_buffer({"cells": cells, "pieces": [[-1, 2], [0, 0], [3, -4], [0, 0]]}, tb)
    assert rows[0][:32] == bytes(range(32))
    assert rows[0][32:64] == bytes(int(f"{b:08b}"[::-1], 2) for b in range(32))
    assert rows[1] == bytes(256)
    assert extra == struct.pack("<8h", -1, 2, 0, 0, 3, -4, 0, 0)


def test_block_end_is_the_next_pointer_in_the_bank():
    pointers = [0xD20000, 0xD20400, 0xD30000, 0xD2F000, 0xD20400]
    assert cs.block_end(pointers, 0xD20000) == 0xD20400
    assert cs.block_end(pointers, 0xD20400) == 0xD2F000
    assert cs.block_end(pointers, 0xD2F000) == 0xD30000      # the bank's end
    assert cs.block_end(pointers, 0xD30000) == 0xD40000


def synthetic_image():
    regions, expect = cs.synthetic_rom()
    image = bytearray(cs.ROM_SIZE)
    for long, data in regions.items():
        image[cs.pc(long):cs.pc(long) + len(data)] = data
    return bytes(image), regions, expect


def test_synthetic_sets_decode_with_the_end_rules():
    image, _, expect = synthetic_image()
    s0, s1 = (cs.decode_set(image, c) for c in (0, 1))
    assert s0["frames"]["count"] == 12 and s1["frames"]["count"] == 9   # set 1's zero record is trimmed
    assert s0["tiles"]["count"] == 40 and s1["tiles"]["count"] == 24
    assert s0["animations"]["rows"] == 5 and s1["animations"]["rows"] == 3
    ids0 = {a["id"] for a in s0["animationList"]}
    assert not any(i.startswith("r01.") for i in ids0)                  # the $FF row is empty
    left = next(a for a in s0["animationList"] if a["id"] == "r02.left")
    assert len(left["frames"]) == 1                                     # $FF after one entry
    assert not any(a["row"] == 2 for a in s1["animationList"])          # starts with duration 0
    for d in (s0, s1):
        for a in d["animationList"]:
            assert a["frames"] and len(a["frames"]) == len(a["durations"]) and 0 not in a["durations"]
            assert cs.END_MARKER not in a["frames"]
    assert s1["palette"]["address"] == "$E4:0030"                       # record 1's palette byte = 2
    for got, want in zip((s0, s1), expect):
        assert got["frameList"] == want["frameList"] and got["animationList"] == want["animationList"]


def test_encode_tile_inverts_tile_indices():
    rng = cs.Lcg(0xE1C0)
    for _ in range(20):
        raw = bytes(rng.next(256) for _ in range(cs.TILE_BYTES))
        assert cs.encode_tile(cs.tile_indices(raw)) == raw
    assert cs.encode_tile([0] * 64) == bytes(32)
    assert cs.encode_tile([15] + [0] * 63) == bytes([0x80, 0x80] + [0] * 14 + [0x80, 0x80] + [0] * 14)


def test_set_spans_cover_the_write_back_blocks():
    image, _, _ = synthetic_image()
    spans = cs.set_spans(image, 1)
    d = cs.decode_set(image, 1)
    assert len(spans["tiles"]) == 32 * d["tiles"]["count"] and len(spans["frames"]) == 40 * d["frames"]["count"]
    assert len(spans["frameIds"]) == 16 * 3 and len(spans["durations"]) == 4 * 3 and len(spans["palette"]) == 24
    assert spans["palette"].start == cs.pc(0xE40030)
    assert spans["tiles"].stop == cs.set_spans(image, 0)["tiles"].start + 32 * 64   # set 1 follows set 0's 40 tiles
    for key in ("tiles", "frames", "frameIds", "durations", "palette"):
        assert spans[key].start >> 16 == (spans[key].stop - 1) >> 16


def test_swift_vectors_file_is_current():
    path = cs.VECTORS
    assert path.exists(), "regenerate with ct_sprites.py vectors --out"
    assert path.read_text() == cs.vectors_text()
    vectors = json.loads(path.read_text())
    assert vectors["schema"] == "ct-sprite-vectors/1" and len(vectors["sets"]) == 2
    for s in vectors["sets"]:
        assert len(s["tileIndices"]) == 2 * 64 * s["tiles"]["count"]
        for c in s["composed"]:
            assert len(c["indices"]) == 2 * c["width"] * c["height"]


# --- Local: the ROM and ChronoRET --------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return cs.read_rom(rom_path)


def failed(claims):
    return [(name, *detail) for name, ok, *detail in claims if not ok]


def test_chronoret_source_claims(rom, chronoret):
    claims = cs.asm_claims(chronoret)
    assert len(claims) == len(cs.ASM_CLAIMS) + len(cs.CONSTANT_CLAIMS)
    assert not failed(claims)


def test_code_claims(rom):
    assert not failed(cs.code_claims(rom))


def test_data_claims(rom):
    assert not failed(cs.data_claims(rom))


def test_sets_decode_as_documented(rom):
    counts = {c: (cs.decode_set(rom, c)["frames"]["count"], cs.tile_count(rom, c)) for c in range(cs.SETS)}
    assert all(1 <= f <= 256 and t > 1 for f, t in counts.values())
    crono = cs.decode_set(rom, 0)
    assert len(crono["palette"]["colours"]) == 12
    assert all(len(f["cells"]) == 16 and len(f["pieces"]) == 4 for f in crono["frameList"])
    assert {a["facing"] for a in crono["animationList"]} == {0, 1, 2, 3}


def test_rom_frame_decoder_runs_as_decode_frame(rom, chronoret):
    assert not failed(cs.run_claims(rom, ref=chronoret))


def test_rom_frame_decoder_with_synthetic_sets_matches_the_vectors(rom, chronoret):
    _, regions, expect = synthetic_image()
    image = bytearray(rom)
    for long, data in regions.items():
        if long >> 16 in (0xD2, 0xDC):        # the synthetic tiles and frames; the code stays the ROM's
            image[cs.pc(long):cs.pc(long) + len(data)] = data
    runner = cs.RomFrameDecoder(bytes(image), chronoret)
    for c, want in enumerate(expect):
        tiles_at = int(want["tiles"]["address"][1:3], 16) << 16 | int(want["tiles"]["address"][4:], 16)
        frames_at = int(want["frames"]["address"][1:3], 16) << 16 | int(want["frames"]["address"][4:], 16)
        tile_bytes = [bytes(image[cs.pc(tiles_at) + 32 * t:cs.pc(tiles_at) + 32 * (t + 1)])
                      for t in range(want["tiles"]["count"])]
        for i, frame in enumerate(want["frameList"]):
            assert runner.decode(0, tiles_at, frames_at, i) == cs.expected_buffer(frame, tile_bytes), (c, i)


def test_render_writes_a_png(rom, tmp_path):
    out = tmp_path / "crono.png"
    w, h, left, top = cs.render(rom, 0, 0, out, scale=1)
    data = out.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", data[16:24]) == (w, h)
    assert 8 <= w <= 64 and 8 <= h <= 64 and left < 0 and top < 0


# --- Enemy battle sprites ----------------------------------------------------------------

def test_pack_literals_is_a_decomp_stream():
    import ct_tilesets
    rng = cs.Lcg(0xE4F6)
    for n in (0, 1, 7, 8, 9, 32, 300):
        data = bytes(rng.next(256) for _ in range(n))
        got, _, _ = ct_tilesets.unpack_bytes(cs.pack_literals(data) + b"\xAA" * 8)
        assert bytes(got) == data.ljust(-(-n // 8) * 8, b"\x00")      # the last group zero-padded


def test_enemy_obj_assembly_runs_along_row_pairs():
    assert cs.enemy_piece_cells(0, 8) == [0, 1, 8, 9]
    assert cs.enemy_piece_cells(3, 8) == [6, 7, 14, 15]
    assert cs.enemy_piece_cells(4, 8) == [16, 17, 24, 25]          # layout 2: the next row pair
    assert cs.enemy_piece_cells(7, 16) == [14, 15, 30, 31]         # layout 1: 8 OBJs on one pair
    for layout, (columns, rows, record_bytes, objs) in cs.LAYOUTS.items():
        if layout not in cs.ASSEMBLED:
            continue
        cells = sorted(k for n in range(objs) for k in cs.enemy_piece_cells(n, columns))
        assert cells == list(range(columns * rows)) and record_bytes == 2 * columns * rows + 2 * objs


def synthetic_enemy_image():
    regions, expect = cs.synthetic_enemy_rom()
    image = bytearray(cs.ROM_SIZE)
    for long, data in regions.items():
        image[cs.pc(long):cs.pc(long) + len(data)] = data
    return bytes(image), expect


def test_synthetic_enemies_decode_by_layout_and_graphics_source():
    image, expect = synthetic_enemy_image()
    got = {i: cs.decode_enemy(image, i) for i in (0, 1, 2, 0xF8)}
    assert [got[i]["layout"]["index"] for i in (0, 1, 2, 0xF8)] == [0, 1, 2, 0]
    assert [got[i]["frames"]["count"] for i in (0, 1, 2)] == [6, 5, 4]
    assert [got[i]["tiles"]["source"] for i in (0, 1, 0xF8)] == ["packed", "packed", "rom"]
    assert got[0]["tiles"]["count"] == got[2]["tiles"]["count"] == 30 and got[1]["tiles"]["count"] == 50
    assert got[1]["palette"]["address"] == "$E4:0030"
    for i, d in got.items():
        lay = d["layout"]
        assert all(len(f["cells"]) == lay["columns"] * lay["rows"] and len(f["pieces"]) == lay["objs"]
                   for f in d["frameList"])
    for d, want in zip(got.values(), expect):
        assert d["frameList"] == want["frameList"] and d["animationList"] == want["animationList"]


def test_swift_enemy_vectors_file_is_current():
    path = cs.ENEMY_VECTORS
    assert path.exists(), "regenerate with ct_sprites.py enemy-vectors --out"
    assert path.read_text() == cs.enemy_vectors_text()
    vectors = json.loads(path.read_text())
    assert vectors["schema"] == "ct-enemy-sprite-vectors/1" and len(vectors["enemies"]) == 4
    for e in vectors["enemies"]:
        assert len(e["tileIndices"]) == 2 * 64 * e["tiles"]["count"]
        c = e["composed"]
        assert len(c["indices"]) == 2 * c["width"] * c["height"]


def test_enemy_chronoret_source_claims(rom, chronoret):
    claims = cs.asm_claims(chronoret, routines=cs.ENEMY_ASM_CLAIMS, constants=cs.ENEMY_CONSTANT_CLAIMS)
    assert len(claims) == len(cs.ENEMY_ASM_CLAIMS) + len(cs.ENEMY_CONSTANT_CLAIMS)
    assert not failed(claims)


def test_enemy_code_and_data_claims(rom):
    assert not failed(cs.enemy_code_claims(rom) + cs.enemy_data_claims(rom))


def test_rom_unpacker_and_frame_decoder_run_as_decoded_for_some_enemies(rom, chronoret):
    # The full run (every enemy) is ct_sprites.py check --run.
    claims = cs.enemy_run_claims(rom, ref=chronoret, ids=(0, 2, 26, 117, 253))
    assert len(claims) == 2 and not failed(claims)
