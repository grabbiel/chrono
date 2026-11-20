#!/usr/bin/env python3
"""Chrono Trigger frames from the register writes the game makes.

Runs the ROM's own routines in ChronoRET's 65816 interpreter (MIT;
refs/ChronoRET/tools/absint.py), as `ct_maps.py check --run` does for the
field, and records what they write to the PPU:

  - the PPU registers $2100-$2133, in order, with the scanline when known
    (writes made between frames are "vblank"; an IRQ handler's writes carry
    the visible line they take effect on);
  - DMA and HDMA set-ups ($43x0-$43xA, MDMAEN $420B, HDMAEN $420C), with
    each HDMA channel's table read back from WRAM or the ROM;
  - VRAM, CGRAM and OAM, written through the ports or by DMA.

A capture becomes a frame description (`describe`): the register set of
every visible line (the vblank state, then the HDMA writes of each line and
the IRQ's writes), the HDMA writes per line, the channels with their decoded
tables, and the three memory images. The Swift twin
(ChronoForgeCore/CTPPUCapture.swift) builds a `PPUFrame` from it. Captures
are made at run time from the ROM and are never stored in the repository.

The interpreter has no hardware, so `Bus` gives it the parts these routines
use, from fullsnes ("SNES I/O Map", "SNES DMA Transfers", "SNES PPU ...")
and the SNESdev Wiki (PPU registers, DMA registers, HDMA):

  - the PPU write ports: VMAIN/VMADD/VMDATA (the increment modes; address
    remapping raises), CGADD/CGDATA (the low byte latched, the colour written
    with the high byte), OAMADD/OAMDATA (low-table pairs written on the odd
    byte, the high table byte by byte), and every register of `Registers`;
  - general DMA on MDMAEN: the eight transfer patterns, fixed / increment /
    decrement A-bus, A to B and B to A;
  - the multipliers and the divider: WRMPYA x WRMPYB (ct_tilesets.RomRunner),
    WRDIVL/H / WRDIVB to RDDIVL/H (quotient) and RDMPYL/H (remainder; a
    divisor 0 gives $FFFF and the dividend), and MPYL-H = M7A x the last
    byte written to M7B (fullsnes);
  - the WRAM port (WMADD / WMDATA, ct_tilesets.RomRunner and ct_maps);
  - status reads: RDNMI toggles bit 7 and HVBJOY bits 7 and 6 (V-blank,
    H-blank) on every read, so a wait for a flag and a wait for it to clear
    both end; APUIO0-2 echo the last byte
    written to them (the transfer handshakes), APUIO3 reads its low nibble 1
    (the sound driver's status once a song plays); other I/O reads 0;
  - the sound CPU is not run: Audio_DriverCommand ($C7:0004) returns at once;
  - WRAM no routine has written reads 0 (cleared WRAM);
  - code in WRAM (the bank $C3 module) runs from the bytes there.

The frame (fullsnes "SNES DMA ... H-DMA", Wiki HDMA): HDMA starts at V=0 with
each enabled channel's first line count (and, indirect, its data address);
it transfers in the H-blank of scanlines 0-223, so the transfer of scanline k
is in effect on visible line k (scanline k + 1, docs/ppu.md). After each
transfer the count steps down; a count byte's bit 7 makes the channel
transfer on every line of the entry, a count byte 0 ends the channel.

Frames (each made from the ROM at run time):

  battle  a field location loaded (ct_maps.MapRunner.load_map), its screen
          saved for the battle (FieldBtl_SavePpu $C0:066D), the HDMA line data
          (BattleCD_InitHdmaDataL $CD:0C9D), HDMA set 8 as BattleFx_Init loads
          it (BattleCE_UnkEE6E $CE:EE6E), BattleCD_NmiSetup ($CD:09F1: the
          palette by DMA, channels 0-7, HDMAEN, INIDISP), then the battle IRQ
          at line 211 (BattleFx_Irq $D1:FE97)
  title   the bank $C3 module (C3_BootModule's unpack, Decomp_ToWram $C3:0557
          to $7E:3000), C3Mod_Init, program 2 (C3Mod_Prog2 $7E:5978: the
          title's pendulum, then mode 2 with BG1 waved by offset-per-tile),
          C3Mod_UploadPalette, then module frames (the idle routine, then
          C3_ModuleFrame $C3:08D0) until TITLE_AFTER frames after its BGMODE 2
          write; the module's IRQ at line 211 (C3_BootIrq $C3:0529)
  lavos   the same with program 6 (C3Mod_Prog6 $7E:78DD: a mode-7 plane with
          SETINI's interlace and EXTBG bits, per-line matrices, a mode-1 strip
          and colour ramps by HDMA), LAVOS_FRAMES module frames

Usage:
    ct_ppu_frames.py capture <battle|title|lavos> --out FILE [--rom PATH] [--location N]
    ct_ppu_frames.py show <battle|title|lavos> [--rom PATH]     the register and HDMA listing
    ct_ppu_frames.py check [--rom PATH] [--run]                  evidence claims
"""

import argparse
import base64
import copy
import json
import re
import struct
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_tilesets as ts  # noqa: E402
from ct_tilesets import REF, ROM_PATH, read_rom, report, u16  # noqa: E402

WS = Path(__file__).resolve().parents[1]

LINES = 224
IRQ_LINE = 211                   # Scene_VIrqLine / BattleFx_IrqLine: the V-count IRQ's line
SCRATCH = 4 * 1024 * 1024        # where an instruction fetched from WRAM is put for the interpreter
FORMAT = "chronoforge.ppu-capture"

# The routines, by the addresses of ChronoRET's headers (`check` verifies them).
ROUTINES = {
    "FieldBtl_SavePpu": 0xC0066D, "BattleCD_InitHdmaDataL": 0xCD0C9D, "BattleCE_UnkEE6E": 0xCEEE6E,
    "BattleCD_NmiSetup": 0xCD09F1, "BattleFx_Init": 0xD1F1B0, "BattleFx_Nmi": 0xD1E77C, "BattleFx_Irq": 0xD1FE97, "Decomp_ToWram": 0xC30557,
    "C3_ModuleFrame": 0xC308D0, "C3_BootIrq": 0xC30529, "C3Mod_Init": 0x7E3063,
    "C3Mod_UploadPalette": 0x7E388B, "C3Mod_Prog2": 0x7E5978, "C3Mod_Prog6": 0x7E78DD,
    "C3Mod_Prog2ToMode2": 0x7E5DA7, "C3Mod_WaveTask": 0x7E5FFE, "C3Mod_ProgramTable": 0x7E3043,
}
AUDIO_DRIVER_COMMAND = 0xC70004
STUBS = {AUDIO_DRIVER_COMMAND: 0x6B}       # RTL: the sound CPU is not modelled

BATTLE_HDMA_SET = 8              # BattleFx_Init's A for BattleCE_UnkEE6E
BATTLE_LOCATION = 1              # the field the battle starts from (any location; --location)
C3_PACK_PTR = 0xFE0003           # C3Rom_PackPtrs entry 1: the module's offset in bank $C3
C3_MODULE = 0x7E3000
C3_MODULE_BYTES = 0x857F
C3_ENTRY_ARG = 0x7E0384
C3_IDLE_OPERAND = 0x7E3024       # C3Mod_Start's idle JSR operand (programs write over it)
TITLE_PROGRAM, LAVOS_PROGRAM = 2, 6
# C3Mod_Prog2Wave ($7E:5B51) waits 184 frames after mode 2 before
# sliding BG1 into view for 104 frames. Capture during that slide, before
# its white flash: at +96 the wave exists but BG1 is still off screen.
TITLE_AFTER = 256
LAVOS_FRAMES = 240               # module frames run for the lavos capture

REG_NAMES = {
    0x2100: "INIDISP", 0x2101: "OBSEL", 0x2102: "OAMADDL", 0x2103: "OAMADDH", 0x2104: "OAMDATA",
    0x2105: "BGMODE", 0x2106: "MOSAIC", 0x2107: "BG1SC", 0x2108: "BG2SC", 0x2109: "BG3SC", 0x210A: "BG4SC",
    0x210B: "BG12NBA", 0x210C: "BG34NBA", 0x210D: "BG1HOFS", 0x210E: "BG1VOFS", 0x210F: "BG2HOFS",
    0x2110: "BG2VOFS", 0x2111: "BG3HOFS", 0x2112: "BG3VOFS", 0x2113: "BG4HOFS", 0x2114: "BG4VOFS",
    0x2115: "VMAIN", 0x2116: "VMADDL", 0x2117: "VMADDH", 0x2118: "VMDATAL", 0x2119: "VMDATAH",
    0x211A: "M7SEL", 0x211B: "M7A", 0x211C: "M7B", 0x211D: "M7C", 0x211E: "M7D", 0x211F: "M7X",
    0x2120: "M7Y", 0x2121: "CGADD", 0x2122: "CGDATA", 0x2123: "W12SEL", 0x2124: "W34SEL",
    0x2125: "WOBJSEL", 0x2126: "WH0", 0x2127: "WH1", 0x2128: "WH2", 0x2129: "WH3", 0x212A: "WBGLOG",
    0x212B: "WOBJLOG", 0x212C: "TM", 0x212D: "TS", 0x212E: "TMW", 0x212F: "TSW", 0x2130: "CGWSEL",
    0x2131: "CGADSUB", 0x2132: "COLDATA", 0x2133: "SETINI",
}
DATA_PORTS = {0x2104, 0x2118, 0x2119, 0x2122}

# DMAP bits 0-2: the B-bus offsets of one unit (fullsnes "SNES DMA Transfers"; Wiki DMAPn).
PATTERNS = {0: (0,), 1: (0, 1), 2: (0, 0), 3: (0, 0, 1, 1), 4: (0, 1, 2, 3), 5: (0, 1, 0, 1), 6: (0, 0),
            7: (0, 0, 1, 1)}


def io_bank(addr):
    """True when the 24-bit address is in a bank that maps the I/O ports."""
    bank = addr >> 16 & 0xFF
    return bank < 0x40 or 0x80 <= bank < 0xC0


def is_wram(addr):
    bank, low = addr >> 16 & 0xFF, addr & 0xFFFF
    return bank in (0x7E, 0x7F) or (io_bank(addr) and low < 0x2000)


def wram_long(addr):
    return addr if addr >> 16 & 0xFF in (0x7E, 0x7F) else 0x7E0000 | addr & 0xFFFF


def signed13(v):
    v &= 0x1FFF
    return v - 0x2000 if v & 0x1000 else v


def signed16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


# --- The PPU ------------------------------------------------------------------------------

class Registers:
    """The registers that shape a line, as the write ports leave them (fields
    named as PPURegisters in SNESPPU.swift). Write-twice ports (fullsnes "SNES
    PPU BG Control", "Rotation/Scaling"; Wiki PPU registers): BGnHOFS = value
    << 8 | (latch AND NOT 7) | (old >> 8 AND 7), BGnVOFS = value << 8 | latch,
    both sharing one latch; M7A-M7D, M7X, M7Y and M7HOFS/M7VOFS (which BG1HOFS
    and BG1VOFS also write) = value << 8 | the mode-7 latch. COLDATA sets the
    selected channels of the fixed colour."""

    def __init__(self):
        self.r = {"inidisp": 0x80, "obsel": 0, "objFirst": 0, "bgmode": 0, "mosaic": 0, "m7sel": 0,
                  "m7a": 0, "m7b": 0, "m7c": 0, "m7d": 0, "m7x": 0, "m7y": 0, "m7hofs": 0, "m7vofs": 0,
                  "w12sel": 0, "w34sel": 0, "wobjsel": 0, "wh0": 0, "wh1": 0, "wh2": 0, "wh3": 0,
                  "wbglog": 0, "wobjlog": 0, "tm": 0, "ts": 0, "tmw": 0, "tsw": 0, "cgwsel": 0,
                  "cgadsub": 0, "fixedColor": 0, "setini": 0,
                  "bg": [{"sc": 0, "charBase": 0, "hofs": 0, "vofs": 0} for _ in range(4)]}
        self.bg_latch = 0
        self.m7_latch = 0
        self.oamadd = 0

    SIMPLE = {0x2100: "inidisp", 0x2101: "obsel", 0x2105: "bgmode", 0x2106: "mosaic", 0x211A: "m7sel",
              0x2123: "w12sel", 0x2124: "w34sel", 0x2125: "wobjsel", 0x2126: "wh0", 0x2127: "wh1",
              0x2128: "wh2", 0x2129: "wh3", 0x212A: "wbglog", 0x212B: "wobjlog", 0x212C: "tm", 0x212D: "ts",
              0x212E: "tmw", 0x212F: "tsw", 0x2130: "cgwsel", 0x2131: "cgadsub", 0x2133: "setini"}
    M7 = {0x211B: "m7a", 0x211C: "m7b", 0x211D: "m7c", 0x211E: "m7d"}

    def write(self, port, v):
        r = self.r
        if port in self.SIMPLE:
            r[self.SIMPLE[port]] = v
        elif 0x2107 <= port <= 0x210A:
            r["bg"][port - 0x2107]["sc"] = v
        elif port == 0x210B:
            r["bg"][0]["charBase"], r["bg"][1]["charBase"] = v & 15, v >> 4
        elif port == 0x210C:
            r["bg"][2]["charBase"], r["bg"][3]["charBase"] = v & 15, v >> 4
        elif 0x210D <= port <= 0x2114:
            bg = r["bg"][(port - 0x210D) >> 1]
            if port & 1:                                    # HOFS ($210D, $210F, ...)
                bg["hofs"] = (v << 8 | self.bg_latch & ~7 & 0xFF | bg["hofs"] >> 8 & 7) & 0x3FF
            else:
                bg["vofs"] = (v << 8 | self.bg_latch) & 0x3FF
            self.bg_latch = v
            if port in (0x210D, 0x210E):
                r["m7hofs" if port == 0x210D else "m7vofs"] = signed13(v << 8 | self.m7_latch)
                self.m7_latch = v
        elif port in self.M7:
            r[self.M7[port]] = signed16(v << 8 | self.m7_latch)
            self.m7_latch = v
        elif port in (0x211F, 0x2120):
            r["m7x" if port == 0x211F else "m7y"] = signed13(v << 8 | self.m7_latch)
            self.m7_latch = v
        elif port == 0x2132:
            c, i = r["fixedColor"], v & 31
            if v & 0x20:
                c = c & ~0x001F | i
            if v & 0x40:
                c = c & ~0x03E0 | i << 5
            if v & 0x80:
                c = c & ~0x7C00 | i << 10
            r["fixedColor"] = c
        elif port in (0x2102, 0x2103):
            self.oamadd = (self.oamadd & 0xFF00 | v) if port == 0x2102 else (self.oamadd & 0xFF | v << 8)
            r["objFirst"] = (self.oamadd >> 1) & 0x7F if self.oamadd & 0x8000 else 0

    def snapshot(self):
        return json.loads(json.dumps(self.r))


class PPUState:
    """VRAM, CGRAM and OAM as the write ports leave them, and the port latches."""

    def __init__(self):
        self.vram = [0] * 0x8000
        self.cgram = [0] * 256
        self.oam = [0] * 544
        self.vmain = 0
        self.vmadd = 0
        self.cgadd = 0           # byte address, 0-511
        self.cg_latch = 0
        self.oamadd = 0          # byte address, 0-543
        self.oam_reload = 0
        self.oam_latch = 0
        self.m7_latch = 0
        self.m7a = 0             # M7A as written twice, for the multiplier
        self.m7b_byte = 0        # the last byte written to M7B

    def product(self):
        """MPYL/MPYM/MPYH: M7A x the last byte written to M7B, signed (fullsnes)."""
        a = signed16(self.m7a)
        b = self.m7b_byte - 0x100 if self.m7b_byte & 0x80 else self.m7b_byte
        return (a * b) & 0xFFFFFF

    def _vstep(self, high):
        if bool(self.vmain & 0x80) == high:
            self.vmadd = (self.vmadd + (1, 32, 128, 128)[self.vmain & 3]) & 0xFFFF

    def write(self, port, v):
        if 0x211B <= port <= 0x2120:
            if port == 0x211B:
                self.m7a = v << 8 | self.m7_latch
            elif port == 0x211C:
                self.m7b_byte = v
            self.m7_latch = v
        elif port == 0x2115:
            if v & 0x0C:
                raise RuntimeError("VMAIN address remapping is not modelled")
            self.vmain = v
        elif port == 0x2116:
            self.vmadd = self.vmadd & 0xFF00 | v
        elif port == 0x2117:
            self.vmadd = self.vmadd & 0x00FF | v << 8
        elif port in (0x2118, 0x2119):
            w = self.vmadd & 0x7FFF
            if port == 0x2118:
                self.vram[w] = self.vram[w] & 0xFF00 | v
            else:
                self.vram[w] = self.vram[w] & 0x00FF | v << 8
            self._vstep(port == 0x2119)
        elif port == 0x2121:
            self.cgadd = v * 2
        elif port == 0x2122:
            if self.cgadd & 1 == 0:
                self.cg_latch = v
            else:
                self.cgram[self.cgadd >> 1 & 0xFF] = (v & 0x7F) << 8 | self.cg_latch
            self.cgadd = (self.cgadd + 1) & 0x1FF
        elif port in (0x2102, 0x2103):
            if port == 0x2102:
                self.oam_reload = self.oam_reload & 0x100 | v
            else:
                self.oam_reload = self.oam_reload & 0xFF | (v & 1) << 8
            self.oamadd = self.oam_reload * 2
        elif port == 0x2104:
            a = self.oamadd % 0x440
            if a >= 0x200:
                self.oam[0x200 + (a & 0x1F)] = v
            elif a & 1 == 0:
                self.oam_latch = v
            else:
                self.oam[a - 1], self.oam[a] = self.oam_latch, v
            self.oamadd = (self.oamadd + 1) % 0x440


class Capture:
    """What a run wrote: the register log, the DMA log and the PPU memory and registers."""

    def __init__(self):
        self.ppu = PPUState()
        self.regs = Registers()
        self.log = []            # (port, value, "vblank" or a visible line), registers only
        self.dma = []            # one dict per general DMA channel transfer
        self.hdmaen = 0
        self.channels = {}       # channel -> its $43x0-$43xA bytes when HDMAEN was last written nonzero
        self.line = "vblank"
        self.in_dma = False

    def write(self, port, v):
        self.ppu.write(port, v)
        self.regs.write(port, v)
        if port not in DATA_PORTS and not self.in_dma:
            self.log.append((port, v, self.line))


_PROXY = {}


class Bus(ts.RomRunner):
    """ct_tilesets.RomRunner with the hardware these routines use (module docstring)."""

    def __init__(self, rom, ref=REF):
        super().__init__(rom, ref)
        absint = self.absint
        self.image.extend(b"\0" * 8)
        self.machine.code = bytearray(b"\x01") * len(self.image)
        self.cap = Capture()
        bus = self
        if "real" not in _PROXY:
            real = _PROXY["real"] = absint.disasm

            class Disasm(types.ModuleType):
                def __getattr__(self, name):
                    return getattr(real, name)

                @staticmethod
                def snes_to_file(bank, addr):
                    if is_wram(bank << 16 | addr) or (bank << 16 | addr) in STUBS:
                        return SCRATCH
                    return real.snes_to_file(bank, addr)

            absint.disasm = Disasm("disasm_wram")
        base = type(self.machine)
        self.flip = {0x4210: 0, 0x4212: 0}
        self.apu = [0, 0, 0, 0]

        class Hardware(base):
            def read8(self, s, addr):
                if addr is None:
                    return None
                a = addr & 0xFFFFFF
                low = a & 0xFFFF
                if io_bank(a) and 0x2000 <= low < 0x8000:
                    if low == 0x2180:
                        port = [s.mem.get(0x1002181 + i) or 0 for i in range(3)]
                        w = port[0] | port[1] << 8 | (port[2] & 1) << 16
                        v = self.read8(s, 0x7E0000 + w)
                        w = (w + 1) & 0x1FFFF
                        for i, b in enumerate((w & 0xFF, w >> 8 & 0xFF, w >> 16)):
                            s.mem[0x1002181 + i] = b
                        return v
                    if low in (0x2134, 0x2135, 0x2136):
                        return bus.cap.ppu.product() >> 8 * (low - 0x2134) & 0xFF
                    if low in bus.flip:
                        bus.flip[low] ^= 0x80 if low == 0x4210 else 0xC0
                        return bus.flip[low]
                    if 0x2140 <= low < 0x2180:
                        if low & 3 == 3:
                            return bus.apu[3] & 0xF0 | 1
                        return bus.apu[low & 3]
                    if 0x4214 <= low <= 0x4217 or 0x4300 <= low < 0x4380:
                        v = super().read8(s, addr)
                        return 0 if v is None else v
                    return 0
                v = super().read8(s, addr)
                if v is None and is_wram(a):
                    return 0
                return v

            def write8(self, s, addr, v):
                if addr is not None and v is not None and io_bank(addr & 0xFFFFFF):
                    low = addr & 0xFFFF
                    if 0x2100 <= low < 0x2134:
                        bus.cap.write(low, v)
                    elif 0x2140 <= low < 0x2180:
                        bus.apu[low & 3] = v
                    elif low == 0x4206:
                        super().write8(s, addr, v)
                        n = (s.mem.get(0x004204) or 0) | (s.mem.get(0x004205) or 0) << 8
                        q, r = (n // v, n % v) if v else (0xFFFF, n)
                        for i, b in enumerate((q & 0xFF, q >> 8, r & 0xFF, r >> 8)):
                            s.mem[0x004214 + i] = b
                        return
                    elif low == 0x420B:
                        for ch in range(8):
                            if v >> ch & 1:
                                bus.dma_channel(s, ch)
                    elif low == 0x420C:
                        bus.cap.hdmaen = v
                        bus.cap.log.append((low, v, bus.cap.line))
                        if v:
                            bus.cap.channels = {ch: [s.mem.get(0x4300 + ch * 16 + r, 0) or 0 for r in range(11)]
                                                for ch in range(8) if v >> ch & 1}
                super().write8(s, addr, v)

            def step(self, s, base_depth):
                pc = s.pc
                if pc in STUBS:
                    bus.image[SCRATCH] = STUBS[pc]
                elif is_wram(pc):
                    for i in range(4):
                        b = self.read8(s, wram_long(pc) + i)
                        bus.image[SCRATCH + i] = 0 if b is None else b
                return super().step(s, base_depth)

        self.machine.__class__ = Hardware

    def dma_channel(self, s, ch):
        """General DMA on channel `ch` from its registers in memory."""
        m = self.machine
        reg = [s.mem.get(0x4300 + ch * 16 + r, 0) or 0 for r in range(11)]
        dmap, bbad = reg[0], reg[1]
        a = reg[2] | reg[3] << 8
        bank = reg[4]
        count = reg[5] | reg[6] << 8 or 0x10000
        pattern = PATTERNS[dmap & 7]
        step = 0 if dmap & 0x08 else (-1 if dmap & 0x10 else 1)
        start = bank << 16 | a
        self.cap.in_dma = True
        for k in range(count):
            port = 0x2100 | (bbad + pattern[k % len(pattern)]) & 0xFF
            if dmap & 0x80:
                v = m.read8(s, port)
                m.write8(s, bank << 16 | a, 0 if v is None else v)
            else:
                v = m.read8(s, bank << 16 | a)
                m.write8(s, port, 0 if v is None else v)
            a = (a + step) & 0xFFFF
        self.cap.in_dma = False
        self.cap.dma.append({"channel": ch, "dmap": dmap, "bbad": 0x2100 | bbad, "source": start,
                             "bytes": count, "line": self.cap.line})
        s.mem[0x4300 + ch * 16 + 2], s.mem[0x4300 + ch * 16 + 3] = a & 0xFF, a >> 8
        s.mem[0x4300 + ch * 16 + 5] = s.mem[0x4300 + ch * 16 + 6] = 0

    def call(self, entry, mem=None, d=0, db=0, m=True, x=False, a=0, limit=3 * 10 ** 6):
        """Step `entry` to its return (RTS, RTL, or RTI at the top) over memory
        `mem` ({address: byte}); the memory after it."""
        absint, mach = self.absint, self.machine
        s = absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, a & 0xFF, a >> 8 & 0xFF, 0, 0
        s.d, s.db, s.m, s.xf, s.c = d, db, m, x, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], dict(mem or {}), {}, []
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        mach.known, mach.reads, mach.control, mach.opaque = {}, set(), set(), set()
        for steps in range(limit):
            mach._steps = steps
            if not s.sp and mach.read8(s, s.pc) == 0x40:       # RTI at the top level
                return s.mem
            r = mach.step(s, 0)
            if r is None:
                continue
            kind, _ = r
            if kind not in ("rts", "rtl"):
                raise RuntimeError(f"${entry:06X} ended by {kind} at ${s.pc:06X}")
            return s.mem
        raise RuntimeError(f"too many steps from ${entry:06X} (at ${s.pc:06X})")

    def irq(self, entry, mem, line=IRQ_LINE):
        """Run an IRQ handler; its writes take effect from visible `line`.
        The registers as the frame starts are kept first (vblank_regs)."""
        self.vblank_regs = copy.deepcopy(self.cap.regs)
        self.cap.line = line
        try:
            return self.call(entry, mem)
        finally:
            self.cap.line = "vblank"


# --- The frames ---------------------------------------------------------------------------

def run_battle(rom, location=BATTLE_LOCATION, ref=REF):
    import ct_maps
    mem = ct_maps.MapRunner(rom, ref).load_map(location)
    bus = Bus(rom, ref)
    mem = bus.call(ROUTINES["FieldBtl_SavePpu"], mem, d=0x0100)
    mem = bus.call(ROUTINES["BattleFx_Init"], mem)
    bus.cap.log.clear()
    bus.cap.dma.clear()
    mem = bus.call(ROUTINES["BattleFx_Nmi"], mem)
    vblank = len(bus.cap.log)
    mem = bus.irq(ROUTINES["BattleFx_Irq"], mem)
    return bus, mem, {"frame": "battle", "location": location, "hdmaSet": BATTLE_HDMA_SET,
                      "runs": ["ct_maps.MapRunner.load_map", "FieldBtl_SavePpu", "BattleFx_Init", "BattleFx_Nmi",
                               "BattleFx_Irq"],
                      "vblankWrites": vblank}


def module_boot(bus, program):
    """The module unpacked as C3_BootModule does, C3Mod_Init, the program and the palette."""
    rom = bus.image
    src = 0xC30000 | rom[ts.pc(C3_PACK_PTR)] | rom[ts.pc(C3_PACK_PTR) + 1] << 8
    mem = {0x7E0300 + i: b for i, b in enumerate((src & 0xFF, src >> 8 & 0xFF, src >> 16, C3_MODULE & 0xFF,
                                                   C3_MODULE >> 8 & 0xFF, 0))}
    mem = bus.call(ROUTINES["Decomp_ToWram"], mem)
    if mem.get(0x7E0306, 0) | mem.get(0x7E0307, 0) << 8 != C3_MODULE_BYTES:
        raise RuntimeError("the module did not unpack to $857F bytes")
    mem[C3_ENTRY_ARG] = program
    mem = bus.call(ROUTINES["C3Mod_Init"], mem)
    table = ROUTINES["C3Mod_ProgramTable"] + 2 * program
    mem = bus.call(0x7E0000 | mem[table] | mem[table + 1] << 8, mem)
    mem = bus.call(ROUTINES["C3Mod_UploadPalette"], mem)
    return mem


def module_frame(bus, mem):
    """One pass of C3Mod_Start's loop (its idle call, M=0) and one NMI (C3_ModuleFrame)."""
    idle = 0x7E0000 | mem[C3_IDLE_OPERAND] | mem[C3_IDLE_OPERAND + 1] << 8
    mem = bus.call(idle, mem, m=False)
    bus.cap.log.clear()
    bus.cap.dma.clear()
    return bus.call(ROUTINES["C3_ModuleFrame"], mem)


def run_module(rom, program, stop, ref=REF):
    """Module frames until stop(frames, bus) says so; then the module's IRQ."""
    bus = Bus(rom, ref)
    mem = module_boot(bus, program)
    mem = bus.call(ROUTINES["C3_ModuleFrame"], mem)
    frames = 1
    while not stop(frames, bus):
        mem = module_frame(bus, mem)
        frames += 1
    vblank = len(bus.cap.log)
    mem = bus.irq(ROUTINES["C3_BootIrq"], mem)
    return bus, mem, frames, vblank


def run_title(rom, ref=REF):
    seen = {}

    def stop(frames, bus):
        if "mode2" not in seen and any(p == 0x2105 and v & 7 == 2 for p, v, _ in bus.cap.log):
            seen["mode2"] = frames
        return "mode2" in seen and frames >= seen["mode2"] + TITLE_AFTER

    bus, mem, frames, vblank = run_module(rom, TITLE_PROGRAM, stop, ref)
    return bus, mem, {"frame": "title", "program": TITLE_PROGRAM, "moduleFrames": frames,
                      "mode2Frame": seen["mode2"], "vblankWrites": vblank,
                      "runs": ["Decomp_ToWram", "C3Mod_Init", "C3Mod_Prog2", "C3Mod_UploadPalette",
                               f"C3_ModuleFrame x {frames}", "C3_BootIrq"]}


def run_lavos(rom, ref=REF, frames=LAVOS_FRAMES):
    bus, mem, n, vblank = run_module(rom, LAVOS_PROGRAM, lambda k, _: k >= frames, ref)
    return bus, mem, {"frame": "lavos", "program": LAVOS_PROGRAM, "moduleFrames": n, "vblankWrites": vblank,
                      "runs": ["Decomp_ToWram", "C3Mod_Init", "C3Mod_Prog6", "C3Mod_UploadPalette",
                               f"C3_ModuleFrame x {n}", "C3_BootIrq"]}


RUNS = {"battle": run_battle, "title": run_title, "lavos": run_lavos}


# --- HDMA and the frame description ------------------------------------------------------

def read_byte(mem, rom, addr):
    """A byte as the HDMA reads it: WRAM from the run's memory, the ROM from the image."""
    addr &= 0xFFFFFF
    if is_wram(addr):
        return mem.get(wram_long(addr), 0) or 0
    off = ts.pc(addr) if addr >> 16 >= 0x40 or addr & 0xFFFF >= 0x8000 else None
    return 0 if off is None else rom[off]


def hdma_tables(regs, mem, rom):
    """The channel's table entries: [{lines, repeat, address, data: [[bytes of one transfer], ...]}]."""
    dmap = regs[0]
    indirect = bool(dmap & 0x40)
    unit = len(PATTERNS[dmap & 7])
    bank, ibank = regs[4], regs[7]
    a = regs[2] | regs[3] << 8
    entries = []
    total = 0
    while total < LINES and len(entries) < 256:
        count = read_byte(mem, rom, bank << 16 | a)
        a = (a + 1) & 0xFFFF
        if count == 0:
            break
        lines = count & 0x7F or 0x80
        repeat = bool(count & 0x80) and count != 0x80
        if indirect:
            src = read_byte(mem, rom, bank << 16 | a) | read_byte(mem, rom, bank << 16 | (a + 1) & 0xFFFF) << 8
            a = (a + 2) & 0xFFFF
            src_bank = ibank
        else:
            src, src_bank = a, bank
        n = lines if repeat else 1
        data = [[read_byte(mem, rom, src_bank << 16 | (src + k * unit + u) & 0xFFFF) for u in range(unit)]
                for k in range(n)]
        if not indirect:
            a = (a + n * unit) & 0xFFFF
        entries.append({"count": count, "lines": lines, "repeat": repeat,
                        "address": (src_bank << 16) | src, "data": data})
        total += lines
    return entries


def hdma_writes(cap, mem, rom):
    """[(visible line, port, value)] the enabled channels write over the frame
    (fullsnes / Wiki HDMA: channel order 0-7 within a line). An IRQ's HDMAEN
    write stops the channels it clears from its line on."""
    stops = {}
    for port, v, line in cap.log:
        if port == 0x420C and line != "vblank":
            for ch in range(8):
                if not v >> ch & 1:
                    stops.setdefault(ch, line)
    out = []
    for ch in sorted(cap.channels):
        regs = cap.channels[ch]
        bbad, pattern = regs[1], PATTERNS[regs[0] & 7]
        line = 0
        for e in hdma_tables(regs, mem, rom):
            for k in range(e["lines"]):
                ln = line + k
                if ln >= min(LINES, stops.get(ch, LINES)):
                    break
                if e["repeat"] or k == 0:
                    unit = e["data"][k if e["repeat"] else 0]
                    for off, v in zip(pattern, unit):
                        out.append((ln, ch, 0x2100 | (bbad + off) & 0xFF, v))
            line += e["lines"]
    out.sort(key=lambda w: (w[0], w[1]))
    return [(ln, port, v) for ln, _, port, v in out]


def describe(bus, mem, meta, rom):
    """The frame description: per-line registers, HDMA writes, channels, memory."""
    cap = bus.cap
    vblank = meta["vblankWrites"]
    hdma = hdma_writes(cap, mem, rom)
    # Keep HDMAEN as evidence too: the Swift replay needs it to know which
    # channels the IRQ stopped. Registers.write ignores non-PPU ports.
    irq = [(line, port, v) for port, v, line in cap.log[vblank:]
           if line != "vblank" and (port < 0x2134 or port == 0x420C)]
    cur = copy.deepcopy(bus.vblank_regs)
    lines = []
    i = j = 0
    for ln in range(LINES):
        while i < len(hdma) and hdma[i][0] == ln:
            cur.write(hdma[i][1], hdma[i][2])
            i += 1
        while j < len(irq) and irq[j][0] == ln:
            cur.write(irq[j][1], irq[j][2])
            j += 1
        lines.append(cur.snapshot())
    ppu = cap.ppu
    channels = []
    for ch in sorted(cap.channels):
        r = cap.channels[ch]
        channels.append({"channel": ch, "dmap": r[0], "bbad": 0x2100 | r[1], "table": r[4] << 16 | r[2] | r[3] << 8,
                         "indirectBank": r[7], "entries": hdma_tables(r, mem, rom)})
    return {
        "format": FORMAT, "version": 1, **meta,
        "irqLine": IRQ_LINE,
        "start": {"registers": bus.vblank_regs.snapshot(), "bgLatch": bus.vblank_regs.bg_latch,
                  "m7Latch": bus.vblank_regs.m7_latch, "oamadd": bus.vblank_regs.oamadd},
        "vblank": [[port, v] for port, v, _ in cap.log[:vblank]],
        "irq": [[line, port, v] for line, port, v in irq],
        "hdmaen": sum(1 << c for c in cap.channels),
        "channels": channels,
        "hdma": [[ln, port, v] for ln, port, v in hdma],
        "dma": cap.dma,
        "lines": lines,
        "vram": base64.b64encode(struct.pack("<32768H", *ppu.vram)).decode(),
        "cgram": base64.b64encode(struct.pack("<256H", *ppu.cgram)).decode(),
        "oam": base64.b64encode(bytes(ppu.oam)).decode(),
    }


def capture(rom, name, ref=REF, **kw):
    """Run frame `name` and describe it."""
    bus, mem, meta = RUNS[name](rom, ref=ref, **kw)
    return describe(bus, mem, meta, rom)


# --- The listing --------------------------------------------------------------------------

def port_name(port):
    return REG_NAMES.get(port) or {0x420C: "HDMAEN", 0x420B: "MDMAEN"}.get(port, f"${port:04X}")


def listing(d):
    """The register and HDMA listing of a frame description, as text lines."""
    out = [f"frame {d['frame']}: " + ", ".join(d["runs"])]
    out.append(f"vblank writes ({len(d['vblank'])}):")
    out += [f"  {port_name(p)} = ${v:02X}" for p, v in d["vblank"]]
    for c in d["channels"]:
        mode = "indirect" if c["dmap"] & 0x40 else "direct"
        out.append(f"HDMA channel {c['channel']}: {mode}, pattern {c['dmap'] & 7}, B-bus {port_name(c['bbad'])}, "
                   f"table ${c['table']:06X}")
        line = 0
        for e in c["entries"]:
            first = " ".join(f"{b:02X}" for b in e["data"][0])
            kind = "repeat" if e["repeat"] else "once"
            out.append(f"  lines {line:3d}-{line + e['lines'] - 1:3d} ({kind}) from ${e['address']:06X}: {first}"
                       + (" ..." if len(e["data"]) > 1 else ""))
            line += e["lines"]
    out.append(f"IRQ writes at line {d['irqLine']}: " + ", ".join(f"{port_name(p)} = ${v:02X}" for _, p, v in d["irq"]))
    return out


# --- Evidence -----------------------------------------------------------------------------

def asm_text(ref=REF):
    files = list((ref / "asm").glob("bank*/*.asm")) + [ref / "asm" / "bankC3" / "packed" / "module.asm"]
    return "\n".join(f.read_text(errors="replace") for f in files)


def asm_claims(ref=REF):
    """The routine addresses and the register set-ups this tool depends on, in ChronoRET's source."""
    text = asm_text(ref)
    out = []
    for name, addr in ROUTINES.items():
        head = f"; ${addr >> 16:02X}:{addr & 0xFFFF:04X} — {name} "
        out.append((f"ChronoRET header {head[2:].strip()}", head in text))

    def body(name):
        m = re.search(rf"^{name}:\n(.*?)(?=^; \$|\Z)", text, re.S | re.M)
        return re.sub(r";.*", "", m.group(1)) if m else ""

    nmi = body("BattleCD_NmiSetup")
    out.append(("BattleCD_NmiSetup: channel 5 indirect four registers from CGWSEL, channel 6 two from BGMODE",
                bool(re.search(r"#!DMAP_HdmaIndirect\|!DMAP_FourRegs\s+STA\.w DMAP5\s+LDA\.b #!BBAD_CGWSEL", nmi))
                and bool(re.search(r"#!DMAP_HdmaIndirect\|!DMAP_TwoRegs\s+STA\.w DMAP6\s+LDA\.b #!BBAD_BGMODE", nmi))))
    out.append(("BattleCD_NmiSetup: HDMAEN = all eight, INIDISP = the brightness",
                "STA.w HDMAEN" in nmi and "STA.w INIDISP" in nmi))
    mode2 = body("C3Mod_Prog2ToMode2")
    out.append(("C3Mod_Prog2ToMode2 writes BGMODE (and MOSAIC) with !C3_BgMode2NoMosaic",
                "LDA.w #!C3_BgMode2NoMosaic" in mode2 and "STA.l BGMODE" in mode2))
    prog6 = body("C3Mod_Prog6")
    inc = (ref / "asm" / "bankC3" / "packed" / "module.inc").read_text(errors="replace")
    out.append(("C3Mod_Prog6 writes SETINI = !C3_Prog6Setini = $41 (EXTBG, screen interlace)",
                "STA.b SETINI-!DP_PPU" in prog6 and bool(re.search(r"!C3_Prog6Setini = \$41\b", inc))))
    return out


def frame_claims(d):
    """Structural invariants of a frame description."""
    lines, out = d["lines"], []
    shown = range(IRQ_LINE)
    out.append((f"{d['frame']}: lines {IRQ_LINE}-223 forced blank by the IRQ",
                all(lines[i]["inidisp"] & 0x80 for i in range(IRQ_LINE, LINES))))
    if d["frame"] == "battle":
        chans = {c["channel"]: c for c in d["channels"]}
        ok5 = 5 in chans and chans[5]["bbad"] == 0x2130 and chans[5]["dmap"] == 0x44
        ok6 = 6 in chans and chans[6]["bbad"] == 0x2105 and chans[6]["dmap"] == 0x41
        out.append(("battle: HDMA channel 5 = CGWSEL-SETINI (indirect, 4 registers), 6 = BGMODE/MOSAIC (2)", ok5 and ok6))
        ok = ok5 and ok6
        for c, names in ((5, ("cgwsel", "cgadsub", None, "setini")), (6, ("bgmode", "mosaic"))):
            line = 0
            for e in chans.get(c, {"entries": []})["entries"]:
                for k in range(e["lines"]):
                    if line + k < IRQ_LINE:
                        for n, v in zip(names, e["data"][0]):
                            ok &= n is None or lines[line + k][n] == v
                line += e["lines"]
        out.append(("battle: every shown line's CGWSEL, CGADSUB, SETINI, BGMODE and MOSAIC = its table entry", ok))
        out.append(("battle: the main screen is on (TM nonzero) on every shown line",
                    all(lines[i]["tm"] for i in shown)))
    if d["frame"] == "title":
        out.append(("title: BGMODE 2 (offset-per-tile) on every shown line", all(lines[i]["bgmode"] & 7 == 2 for i in shown)))
        sc = lines[0]["bg"][2]["sc"]
        out.append((f"title: BG3's map (the offset table) at VRAM word $7000 (BG3SC ${sc:02X})", sc >> 2 << 10 == 0x7000))
        vram = struct.unpack("<32768H", base64.b64decode(d["vram"]))
        row1 = vram[0x7020:0x7040]
        out.append(("title: the offset table's second row has bit 13 (BG1) on its moving words",
                    all(w & 0x2000 for w in row1[1:]) and not any(w & 0xC000 for w in row1)))
    if d["frame"] == "lavos":
        out.append(("lavos: SETINI interlace and EXTBG on every line", all(l["setini"] & 0x41 == 0x41 for l in lines)))
        modes = {lines[i]["bgmode"] & 7 for i in shown}
        out.append((f"lavos: mode 7 on the shown lines, with HDMA's mode-1 strip where its table says ({sorted(modes)})",
                    7 in modes and modes <= {1, 7}))
        m7a = {lines[i]["m7a"] for i in shown if lines[i]["bgmode"] & 7 == 7}
        out.append((f"lavos: the matrix changes per line on the plane ({len(m7a)} values of M7A)", len(m7a) > 16))
    return out


def run_claims(rom, ref=REF):
    out = []
    for name in RUNS:
        out += frame_claims(capture(rom, name, ref))
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rom", default=str(ROM_PATH))
    sub = p.add_subparsers(dest="command", required=True)
    c = sub.add_parser("capture")
    c.add_argument("frame", choices=sorted(RUNS))
    c.add_argument("--out", required=True)
    c.add_argument("--location", type=int, default=BATTLE_LOCATION)
    s = sub.add_parser("show")
    s.add_argument("frame", choices=sorted(RUNS))
    k = sub.add_parser("check")
    k.add_argument("--run", action="store_true", help="also run the three frames and check their invariants")
    args = p.parse_args()
    if args.command == "check" and not args.run:
        return report(asm_claims())
    rom = read_rom(args.rom)
    if args.command == "check":
        return report(asm_claims() + run_claims(rom))
    kw = {"location": args.location} if args.command == "capture" and args.frame == "battle" else {}
    d = capture(rom, args.frame, **kw)
    if args.command == "show":
        print("\n".join(listing(d)))
        return report(frame_claims(d))
    Path(args.out).write_text(json.dumps(d, separators=(",", ":")))
    print(f"wrote {args.out}: {d['frame']}, {len(d['channels'])} HDMA channels, {len(d['hdma'])} HDMA writes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
