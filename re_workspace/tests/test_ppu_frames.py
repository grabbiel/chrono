"""ct_ppu_frames.py: CT frames from the register writes the game makes.

Synthetic: the register write ports (scroll and mode-7 latches, COLDATA, the
character bases, OAMADD's priority rotation), the memory ports (VRAM steps,
the CGRAM latch, OAM pairs and the high table), HDMA tables (direct and
indirect, repeat, a count of $80, the end byte, an IRQ that stops a channel),
and the interpreter's bus on a synthetic ROM (DMA, HDMAEN, the divider, code
run from WRAM). With ChronoRET: the routines' headers and set-ups in its
source. With the ROM: the three frames and their invariants.
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import ct_ppu_frames as pf  # noqa: E402
import ct_tilesets as ts  # noqa: E402


# --- The write ports ---------------------------------------------------------------------

def test_scroll_registers_share_one_latch():
    r = pf.Registers()
    r.write(0x210F, 0x2D)                    # BG2HOFS: $2D << 8, 10 bits: $100
    r.write(0x210F, 0x01)                    # (1 << 8) | (latch $2D & ~7) | (old $100 >> 8 & 7)
    assert r.r["bg"][1]["hofs"] == 0x129
    r.write(0x2110, 0x34)                    # BG2VOFS low
    r.write(0x2110, 0x02)
    assert r.r["bg"][1]["vofs"] == 0x234
    r.write(0x2111, 0x07)                    # BG3HOFS: $700 & $3FF = $300
    r.write(0x2111, 0x00)                    # the latch's low three bits are not used, the old value's are
    assert r.r["bg"][2]["hofs"] == 0x003


def test_bg1_scroll_also_writes_the_mode7_offsets_and_matrix_latches():
    r = pf.Registers()
    r.write(0x210D, 0xF0)
    r.write(0x210D, 0x1F)                    # M7HOFS = $1FF0, 13 bits signed: -16
    assert r.r["m7hofs"] == -16
    r.write(0x211B, 0x00)
    r.write(0x211B, 0xFF)                    # M7A = $FF00 = -256
    r.write(0x2120, 0x10)
    r.write(0x2120, 0x00)                    # M7Y = $0010
    assert (r.r["m7a"], r.r["m7y"]) == (-256, 0x10)


def test_coldata_character_bases_and_the_obj_rotation():
    r = pf.Registers()
    r.write(0x2132, 0x3F)                    # red 31
    r.write(0x2132, 0x85)                    # blue 5
    assert r.r["fixedColor"] == (5 << 10) | 31
    r.write(0x210B, 0x52)
    r.write(0x210C, 0x07)
    assert [b["charBase"] for b in r.r["bg"]] == [2, 5, 7, 0]
    r.write(0x2102, 0x0A)
    r.write(0x2103, 0x80)                    # priority rotation from OBJ (OAMADD >> 1) & 127
    assert r.r["objFirst"] == 5
    r.write(0x2103, 0x00)
    assert r.r["objFirst"] == 0


def test_memory_ports():
    p = pf.PPUState()
    p.write(0x2115, 0x80)                    # step after the high byte
    p.write(0x2116, 0x00)
    p.write(0x2117, 0x10)
    for b in (0x34, 0x12, 0x78, 0x56):
        p.write(0x2118 if b in (0x34, 0x78) else 0x2119, b)
    assert p.vram[0x1000:0x1002] == [0x1234, 0x5678]
    p.write(0x2115, 0x01)                    # step 32 after the low byte
    p.write(0x2116, 0x00)
    p.write(0x2117, 0x20)
    p.write(0x2118, 1)
    p.write(0x2118, 2)
    assert (p.vram[0x2000] & 0xFF, p.vram[0x2020] & 0xFF) == (1, 2)
    p.write(0x2121, 3)
    p.write(0x2122, 0xFF)
    assert p.cgram[3] == 0                   # the low byte waits for the high one
    p.write(0x2122, 0xFF)
    assert p.cgram[3] == 0x7FFF              # bit 15 dropped
    p.write(0x2102, 0)
    p.write(0x2103, 1)                       # word $100: the high table
    p.write(0x2104, 0xAA)
    assert p.oam[0x200] == 0xAA
    p.write(0x2102, 1)
    p.write(0x2103, 0)
    p.write(0x2104, 0x11)
    assert p.oam[2] == 0
    p.write(0x2104, 0x22)
    assert p.oam[2:4] == [0x11, 0x22]


# --- HDMA ---------------------------------------------------------------------------------

def capture_with(channels, log=()):
    cap = pf.Capture()
    cap.channels = channels
    cap.log = list(log)
    return cap


def test_indirect_tables_repeat_and_the_end_byte():
    mem = {}
    table = [0x03, 0x00, 0x30, 0x82, 0x10, 0x30, 0x00]       # 3 lines once from $3000, 2 repeat from $3010, end
    for i, b in enumerate(table):
        mem[0x7E2000 + i] = b
    mem[0x7E3000] = 0x41
    mem[0x7E3010], mem[0x7E3011] = 0x51, 0x52
    regs = [0x40, 0x05, 0x00, 0x20, 0x7E, 0, 0, 0x7E, 0, 0, 0]  # indirect, one register, BGMODE
    writes = pf.hdma_writes(capture_with({2: regs}), mem, bytes(ts.ROM_SIZE))
    assert writes == [(0, 0x2105, 0x41), (3, 0x2105, 0x51), (4, 0x2105, 0x52)]


def test_direct_tables_count_80_and_an_irq_stop():
    mem = {}
    table = [0x80, 0x07, 0x01, 0x09, 0x00]                   # 128 lines once of 07, 1 line of 09, end
    for i, b in enumerate(table):
        mem[0x7E2100 + i] = b
    regs = [0x00, 0x05, 0x00, 0x21, 0x7E, 0, 0, 0, 0, 0, 0]
    writes = pf.hdma_writes(capture_with({0: regs}), mem, bytes(ts.ROM_SIZE))
    assert writes == [(0, 0x2105, 0x07), (128, 0x2105, 0x09)]
    stopped = capture_with({0: regs}, [(0x420C, 0x00, 100)])
    assert pf.hdma_writes(stopped, mem, bytes(ts.ROM_SIZE)) == [(0, 0x2105, 0x07)]


def test_two_registers_written_twice_per_line():
    mem = {0x7E2200: 0x81, 0x7E2201: 0x00, 0x7E2202: 0x40}
    for i, b in enumerate((1, 2, 3, 4)):
        mem[0x7E4000 + i] = b
    regs = [0x43, 0x1B, 0x00, 0x22, 0x7E, 0, 0, 0x7E, 0, 0, 0]  # M7A/M7B, two registers twice
    writes = pf.hdma_writes(capture_with({1: regs}), mem, bytes(ts.ROM_SIZE))
    assert writes == [(0, 0x211B, 1), (0, 0x211B, 2), (0, 0x211C, 3), (0, 0x211C, 4)]


# --- The bus, on a synthetic ROM ----------------------------------------------------------

def synthetic_rom():
    rom = bytearray(ts.ROM_SIZE)
    code = bytes([
        0xE2, 0x20, 0xC2, 0x10,              # SEP #$20, REP #$10
        0xA9, 0x80, 0x8D, 0x15, 0x21,        # VMAIN = $80
        0xA2, 0x00, 0x30, 0x8E, 0x16, 0x21,  # VMADD = $3000
        0xA9, 0x01, 0x8D, 0x00, 0x43,        # DMAP0 = 1 (two registers)
        0xA9, 0x18, 0x8D, 0x01, 0x43,        # BBAD0 = VMDATAL
        0xA2, 0x00, 0x90, 0x8E, 0x02, 0x43,  # A1T0 = $9000
        0xA9, 0xC0, 0x8D, 0x04, 0x43,        # A1B0 = $C0
        0xA2, 0x04, 0x00, 0x8E, 0x05, 0x43,  # DAS0 = 4
        0xA9, 0x01, 0x8D, 0x0B, 0x42,        # MDMAEN = 1
        0xA9, 0x42, 0x8D, 0x10, 0x43,        # DMAP1 = $42 (indirect, one register twice)
        0xA9, 0x01, 0x8D, 0x0C, 0x42,        # HDMAEN = 1 (channel 0 only; 1 is not on)
        0xA2, 0x64, 0x00, 0x8E, 0x04, 0x42,  # WRDIV = 100
        0xA9, 0x07, 0x8D, 0x06, 0x42,        # WRDIVB = 7
        0xAD, 0x14, 0x42, 0x8D, 0x00, 0x10,  # $1000 = RDDIVL
        0xAD, 0x16, 0x42, 0x8D, 0x01, 0x10,  # $1001 = RDMPYL (the remainder)
        0x22, 0x00, 0x20, 0x7E,              # JSL $7E:2000 (code in WRAM)
        0xA9, 0x0F, 0x8D, 0x00, 0x21,        # INIDISP = $0F
        0x6B,                                # RTL
    ])
    rom[0x8000:0x8000 + len(code)] = code
    rom[0x9000:0x9004] = bytes([0x34, 0x12, 0x78, 0x56])
    return bytes(rom)


def test_the_bus_runs_dma_hdmaen_the_divider_and_wram_code(chronoret):
    bus = pf.Bus(synthetic_rom(), chronoret)
    wram = {0x7E2000 + i: b for i, b in enumerate((0xA9, 0x09, 0x8D, 0x05, 0x21, 0x6B))}  # BGMODE = 9, RTL
    mem = bus.call(0xC08000, wram)
    cap = bus.cap
    assert cap.ppu.vram[0x3000:0x3002] == [0x1234, 0x5678]
    assert cap.dma == [{"channel": 0, "dmap": 1, "bbad": 0x2118, "source": 0xC09000, "bytes": 4, "line": "vblank"}]
    assert cap.hdmaen == 1 and sorted(cap.channels) == [0]
    assert (mem[0x7E1000], mem[0x7E1001]) == (14, 2)
    assert cap.regs.r["bgmode"] == 9 and cap.regs.r["inidisp"] == 0x0F
    names = [pf.port_name(p) for p, _, _ in cap.log]
    assert names == ["VMAIN", "VMADDL", "VMADDH", "HDMAEN", "BGMODE", "INIDISP"]   # DMA's port writes not logged


# --- ChronoRET's source and the ROM -------------------------------------------------------

def test_asm_claims(chronoret):
    bad = [c for c in pf.asm_claims(chronoret) if not c[1]]
    assert not bad, bad


@pytest.fixture(scope="module")
def rom(rom_path):
    return pf.read_rom(rom_path)


@pytest.mark.parametrize("name", ["battle", "title", "lavos"])
def test_frame_invariants(rom, chronoret, name):
    d = pf.capture(rom, name, chronoret)
    bad = [c for c in pf.frame_claims(d) if not c[1]]
    assert not bad, bad
    assert len(d["lines"]) == pf.LINES
