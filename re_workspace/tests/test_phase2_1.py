"""Phase 2 Step 2.1 tests: libctcodec.dylib LZSS codec vs the packed corpus.

Run: cd <repo root> && re_workspace/.venv/bin/pytest re_workspace/tests/test_phase2_1.py -q

Format ground truth: ChronoRET bankC3.asm Decomp_ToWram (lines 1150-1520).
lz12: dist = v & $0FFF (window 4096), len = (v >> 12) + 3 (max 18)
lz11: dist = v & $07FF (window 2048), len = (v >> 11) + 3 (max 34)
"""
import csv
import os
import random
import struct
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # re_workspace
sys.path.insert(0, os.path.join(ROOT, "tools"))
import ct_lzss  # noqa: E402

ROM = os.path.join(ROOT, "ct_clean.sfc")
CSV = os.path.join(ROOT, "refs", "ChronoRET", "symbols", "data_assets.csv")


def snes_to_pc(s):
    return ((int(s[1:3], 16) & 0x3F) << 16) | int(s[4:], 16)


@pytest.fixture(scope="module")
def rom():
    return open(ROM, "rb").read()


@pytest.fixture(scope="module")
def packed_rows():
    return [r for r in csv.DictReader(
        l for l in open(CSV) if not l.startswith("#"))
        if r["piece"] == "packed"]


def seg_kind(rom, r):
    """'single' if the first end marker terminates the data, 'two' if it
    continues into a second segment (m & $3F != 0)."""
    pc = snes_to_pc(r["start"])
    w = struct.unpack_from("<H", rom, pc)[0]
    return "two" if (rom[pc + 2 + w] & 0x3F) else "single"


@pytest.fixture(scope="module")
def corpus_samples(rom, packed_rows):
    """>= 20 blocks covering all four varieties: lz11/lz12 x single/two-seg."""
    kinds = {}
    for r in packed_rows:
        k = (r["param"].split()[0], seg_kind(rom, r))
        kinds.setdefault(k, []).append(r)
    for k in (("lz11", "single"), ("lz11", "two"),
              ("lz12", "single"), ("lz12", "two")):
        assert k in kinds, "corpus missing variety %s" % (k,)
    samples = []
    for k in sorted(kinds):
        for r in sorted(kinds[k], key=lambda x: int(x["size"]))[:6]:
            pc = snes_to_pc(r["start"])
            span = snes_to_pc(r["end"]) - pc + 1
            samples.append((r, rom[pc:pc + span]))
    assert len(samples) >= 20
    return samples


def test_dylib_loads():
    """The ctypes wrapper loaded the dylib and the codec symbols resolve."""
    assert ct_lzss._lib._name.endswith("libctcodec.dylib") or \
        "libctcodec.dylib" in ct_lzss._lib._name
    for fn in ("ct_lzss_decompress", "ct_lzss_compress",
               "ct_lzss_detect_mode", "ct_bgr555_to_rgb"):
        assert hasattr(ct_lzss._lib, fn)


def test_corpus_sizes_and_roundtrip(corpus_samples):
    """Header/claim sizes honored; decompress(recompress(x)) == x."""
    for r, data in corpus_samples:
        mode, claimed = r["param"].split()[0], int(r["param"].split("->")[1].split()[0])
        dec = ct_lzss.decompress(data)              # auto-detect mode
        assert len(dec) == claimed, (r["label"], len(dec), claimed)
        assert ct_lzss.detect_mode(data) == mode, r["label"]
        # explicit-mode decode must agree with the auto-detected one
        assert ct_lzss.decompress(data, mode) == dec
        rec = ct_lzss.compress(dec, mode)
        assert ct_lzss.decompress(rec) == dec, r["label"]


def test_both_modes_present(corpus_samples):
    modes = {r["param"].split()[0] for r, _ in corpus_samples}
    assert modes == {"lz11", "lz12"}


def test_header_size_field_is_segment_length(rom, packed_rows):
    """The u16le at +0 is segment 1's PACKED length: for single-segment packs
    2 + W + 1 (final 1-byte marker) == the pack size; for two-segment packs
    the continuation marker sits exactly at 2 + W."""
    seen_single = seen_two = 0
    for r in packed_rows:
        pc = snes_to_pc(r["start"])
        span = snes_to_pc(r["end"]) - pc + 1
        w = struct.unpack_from("<H", rom, pc)[0]
        m = rom[pc + 2 + w] & 0x3F
        if m == 0:
            assert 2 + w + 1 == span, r["label"]
            seen_single += 1
        else:
            off = struct.unpack_from("<H", rom, pc + 2 + w + 1)[0]
            assert 2 + w + 3 <= off < span, r["label"]
            seen_two += 1
        if seen_single > 40 and seen_two > 40:
            break
    assert seen_single and seen_two


def test_edge_empty_input():
    for mode in ("lz11", "lz12"):
        packed = ct_lzss.compress(b"", mode)
        assert ct_lzss.decompress(packed) == b""
        assert ct_lzss.detect_mode(packed) == mode


def test_edge_all_literals():
    """Bytes with no repeats: the item stream is pure literals / run8."""
    src = bytes(random.Random(1234).sample(range(256), 256)) * 4
    assert len(src) == 1024
    for mode in ("lz11", "lz12"):
        packed = ct_lzss.compress(src, mode)
        assert ct_lzss.decompress(packed) == src
        assert ct_lzss.detect_mode(packed) == mode


def test_edge_highly_repetitive():
    """Long runs and repeating patterns exercise maximal match lengths
    (lz12 caps at 18, lz11 at 34) and overlapping dist<len copies."""
    cases = [b"\x00" * 5000,
             b"\xff" * 5000,
             b"ABCD" * 1500,
             b"ABC" * 2000,           # period 3: overlapping matches
             b"the quick brown fox " * 400]
    for src in cases:
        for mode in ("lz11", "lz12"):
            packed = ct_lzss.compress(src, mode)
            assert len(packed) < len(src) // 2, (mode, len(packed))
            assert ct_lzss.decompress(packed) == src


def test_edge_random_roundtrip_both_modes():
    rng = random.Random(20261018)
    for n in (1, 2, 7, 8, 9, 63, 64, 65, 1000):
        src = bytes(rng.randrange(256) for _ in range(n))
        for mode in ("lz11", "lz12"):
            packed = ct_lzss.compress(src, mode)
            assert ct_lzss.decompress(packed) == src, (mode, n)


def test_garbage_fails_cleanly():
    """Malformed streams raise CtLzssError, never crash the interpreter."""
    bad = [b"", b"\x00", b"\xff\xff", b"\x05\x00\x00\x00\x00\x00",
           b"\xfe\xff" + b"\x00" * 8, bytes(range(40))]
    for b in bad:
        with pytest.raises(ct_lzss.CtLzssError):
            ct_lzss.decompress(b)


def test_bgr555_helpers():
    assert ct_lzss.bgr555_to_rgb(0x0000) == (0, 0, 0)
    assert ct_lzss.bgr555_to_rgb(0x7FFF) == (255, 255, 255)
    assert ct_lzss.bgr555_to_rgb(0x001F) == (255, 0, 0)      # red is bits 0-4
    assert ct_lzss.bgr555_to_rgb(0x03E0) == (0, 255, 0)      # green bits 5-9
    assert ct_lzss.bgr555_to_rgb(0x7C00) == (0, 0, 255)      # blue bits 10-14
    assert ct_lzss.bgr555_to_rgb(0x0001) == (8, 0, 0)        # 1 -> 1<<3 | 1>>2
    assert ct_lzss.bgr555_to_rgba(0x7FFF) == (255, 255, 255, 255)
