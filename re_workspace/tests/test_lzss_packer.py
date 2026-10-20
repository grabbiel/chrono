"""The C packer is the original one: it rebuilds the ROM's packs byte for byte.

libctcodec's ct_lzss_compress is a port of Okumura's LZSS as ChronoRET's
tools/c3pack.py describes Square's packer. These tests require every packed
block and every event-pack stream to be rebuilt exactly, and the C port to
agree with the Python transcription on inputs the ROM does not contain.
"""
import csv
import os
import random
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "refs", "ChronoRET", "tools"))
import c3pack  # noqa: E402
import ct_lzss  # noqa: E402

ROM = os.path.join(ROOT, "ct_clean.sfc")
CSV = os.path.join(ROOT, "refs", "ChronoRET", "symbols", "data_assets.csv")


def snes_to_pc(s):
    return ((int(s[1:3], 16) & 0x3F) << 16) | int(s[4:], 16)


@pytest.fixture(scope="module")
def rom():
    return open(ROM, "rb").read()


def test_every_packed_block_is_rebuilt_exactly(rom):
    rows = [r for r in csv.DictReader(l for l in open(CSV) if not l.startswith("#"))
            if r["piece"] == "packed"]
    assert len(rows) == 1053
    for r in rows:
        start, end = snes_to_pc(r["start"]), snes_to_pc(r["end"]) + 1
        data = rom[start:end]
        mode = ct_lzss.detect_mode(data)
        assert ct_lzss.compress(ct_lzss.decompress(data), mode) == data, r["label"]


def test_every_event_pack_stream_is_rebuilt_exactly(rom):
    starts = {((rom[p + 2] & 0x3F) << 16) | rom[p] | rom[p + 1] << 8
              for p in range(0x3CF9F0, 0x3CF9F0 + 3 * 513, 3)}
    rebuilt = 0
    for start in sorted(starts):
        try:
            out, end, mode = c3pack.unpack(rom, start)
        except c3pack.PackError:
            continue
        assert ct_lzss.compress(out, "lz%d" % mode) == rom[start:end], hex(start)
        rebuilt += 1
    assert rebuilt == 463


@pytest.mark.parametrize("mode", [11, 12])
def test_c_port_matches_python_transcription(mode):
    rng = random.Random(0x5EED + mode)
    cases = [b"", b"\x00", b"ab", b"abc", b"\x00" * 40, b"\x00" * 5000,
             bytes(range(256)) * 20, b"ABC" * 2000, bytes(rng.randrange(4) for _ in range(9000))]
    for n in (1, 7, 8, 9, 17, 18, 19, 33, 34, 35, 2047, 2048, 2049, 4095, 4097):
        cases.append(bytes(rng.randrange(3) for _ in range(n)))
    cases.append(bytes(rng.randrange(256) for _ in range(30000)))
    cases.append(bytes(rng.choice(b"\x00\x01\xff") for _ in range(0xFFFF)))
    for data in cases:
        packed = ct_lzss.compress(data, "lz%d" % mode)
        assert packed == c3pack.pack(data, mode), (mode, len(data))
        assert ct_lzss.decompress(packed) == data


def test_output_length_is_bounded():
    with pytest.raises(ct_lzss.CtLzssError):
        ct_lzss.compress(b"\x00" * 0x10000, "lz11")
