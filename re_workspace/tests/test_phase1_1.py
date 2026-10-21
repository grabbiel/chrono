"""Phase 1.1 verification: header normalization + HiROM address map."""
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
WS = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(WS))
sys.path.insert(0, os.path.join(WS, "tools"))

from address_map import Rom, load  # noqa: E402


@pytest.fixture(scope="module")
def rom(rom_path) -> Rom:
    return load(rom_path)


def test_clean_size(rom):
    assert len(rom.data) == 4 * 1024 * 1024


def test_header_fields(rom):
    assert rom.read_pc(0xFFC0, 21) == b"CHRONO TRIGGER       "
    assert rom.data[0xFFD5] == 0x31
    assert rom.data[0xFFD7] == 0x0C


def test_snes_to_pc_linear():
    # $C0:0000 -> first byte of physical bank 0
    assert Rom.snes_to_pc(0xC0, 0x0000) == 0x000000
    # $C2:8000 -> bank 2, upper half
    assert Rom.snes_to_pc(0xC2, 0x8000) == 0x028000
    # $FF:FFFE -> last two bytes
    assert Rom.snes_to_pc(0xFF, 0xFFFE) == 0x3FFFFE


def test_snes_to_pc_mirrors():
    # $40-$7D mirror $C0-$FF
    assert Rom.snes_to_pc(0x40, 0x8000) == Rom.snes_to_pc(0xC0, 0x8000)
    assert Rom.snes_to_pc(0x5A, 0xFFC0) == Rom.snes_to_pc(0xDA, 0xFFC0)
    # $00-$3F alias $C0-$FF (HiROM header visible from bank $00 too)
    assert Rom.snes_to_pc(0x00, 0xFFC0) == Rom.snes_to_pc(0xC0, 0xFFC0)
    # FastROM mirror $80-$BF upper half
    assert Rom.snes_to_pc(0xC0, 0x8000) == Rom.snes_to_pc(0x80, 0x8000)


def test_non_rom_rejected():
    for bank, addr in [(0x7E, 0x0000), (0x7F, 0xFFFF), (0x70, 0x2000), (0x80, 0x7FFF), (0xBF, 0x2000)]:
        with pytest.raises(ValueError):
            Rom.snes_to_pc(bank, addr)


def test_mirror_reads_identical_bytes(rom):
    # reading through any alias must return identical bytes
    a = rom.read(0xC2, 0x8000, 64)
    b = rom.read(0x42, 0x8000, 64)
    c = rom.read(0x82, 0x8000, 64)
    assert a == b == c


def test_boot_entry(rom):
    # Hardware vector area in bank $FF is all zero -> CPU boots at $00:8000 (== $C0:8000).
    hv = rom.hardware_vectors
    assert all(v == 0 for v in hv.values())
    # $C0:8000 must be real code, not FF/00 fill: starts TYA / CLC / ADC dp
    boot = rom.read_pc(0x8000, 4)
    assert boot[:3] == bytes([0x98, 0x18, 0x65])
    # The game's stub table: emul-NMI $FFEA -> $FF10 = JML $000500.
    st = rom.vector_stub_table
    assert st["$C0:FFEA"] == 0xFF10
    assert rom.read_pc(0xFF10, 4) == bytes([0x5C, 0x00, 0x05, 0x00])


def test_complement_checksum(rom):
    import struct
    s, c = struct.unpack_from("<HH", rom.data, 0xFFDC)
    assert (s + c) & 0xFFFF == 0xFFFF


def test_manifest_written(manifest_path):
    m = json.load(open(manifest_path("rom_identity.json")))
    assert m["all_passed"] is True
    assert m["map_mode"] == "HiROM FastROM (0x31)"
