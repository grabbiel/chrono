"""HiROM address translation for the Chrono Trigger (USA) SNES ROM.

Memory model (verified against the ROM's internal header at PC 0xFFC0):
  - Map mode byte 0xFFD5 = 0x31  -> HiROM, FastROM
  - ROM size byte  0xFFD7 = 0x0C  -> 4 MB (32 Mbit), 64 banks of 64 KB

HiROM address map (SNES 24-bit bus -> PC file offset in the unheadered image):
  $00-$3F : banks 0..63 map linearly.   PC = (bank & 0x3F) << 16 | addr
  $40-$7D : mirror of $C0-$FF          PC = (bank & 0x3F) << 16 | addr   (same physical banks)
  $7E/$7F : WRAM 128 KB               (not in the ROM file)
  $80-$BF : FastROM execution mirror; only $8000-$FFFF of each bank maps,
            aliasing the same physical banks. $80-$BF:$0000-$7FFF is not ROM.
  $C0-$FF : banks 0..63 map linearly.  PC = (bank & 0x3F) << 16 | addr

The SNES header lives at $C0:FFC0 == PC 0xFFC0 (bank $C0 & 0x3F == 0).
The 65c816 CPU vectors live at $C0:FFE0-$FFFF == PC 0xFFE0-$FFFF
(what the community calls "$00:FFEA / $00:FFFC" is the same physical location,
since bank $00 and bank $C0 alias in HiROM).
"""

from __future__ import annotations

import struct

ROM_SIZE = 4 * 1024 * 1024

# WRAM is $7E:0000-$7F:FFFF (128 KB) plus the 64 KB echo region $60-$7D (HiROM).
WRAM_BANK_LO = 0x7E
WRAM_BANK_HI = 0x7F
ECHO_BANK_LO = 0x60
ECHO_BANK_HI = 0x7D
SRAM_BANK_LO = 0x70
SRAM_BANK_HI = 0x7D


class Rom:
    """Byte-addressable view of the unheadered HiROM image with SNES-bus reads."""

    def __init__(self, data: bytes):
        if len(data) != ROM_SIZE:
            raise ValueError(f"expected {ROM_SIZE}-byte unheadered image, got {len(data)}")
        self.data = data

    # -- address translation -------------------------------------------------
    @staticmethod
    def snes_to_pc(bank: int, addr: int) -> int:
        """Translate a 24-bit SNES bus address (bank, addr) to a PC file offset.

        Raises ValueError for addresses that are not ROM (WRAM/SRAM/echo/NVRAM).
        """
        bank &= 0xFF
        addr &= 0xFFFF
        if WRAM_BANK_LO <= bank <= WRAM_BANK_HI:
            raise ValueError(f"${bank:02X}:{addr:04X} is WRAM, not ROM")
        if ECHO_BANK_LO <= bank <= ECHO_BANK_HI and bank < SRAM_BANK_LO:
            raise ValueError(f"${bank:02X}:{addr:04X} is echo RAM, not ROM")
        if SRAM_BANK_LO <= bank <= SRAM_BANK_HI:
            raise ValueError(f"${bank:02X}:{addr:04X} is SRAM, not ROM")
        if 0x80 <= bank <= 0xBF and addr < 0x8000:
            raise ValueError(f"${bank:02X}:{addr:04X} not mapped in HiROM")
        return ((bank & 0x3F) << 16) | addr

    @staticmethod
    def linear_to_snes(pc: int) -> tuple[int, int]:
        """Canonical SNES address ($C0-bank form used by the game's code) for a PC offset."""
        pc &= 0x3FFFFF
        return (0xC0 | (pc >> 16), pc & 0xFFFF)

    @staticmethod
    def is_rom(bank: int, addr: int) -> bool:
        try:
            Rom.snes_to_pc(bank, addr)
            return True
        except ValueError:
            return False

    # -- reads ---------------------------------------------------------------
    def read(self, bank: int, addr: int, size: int) -> bytes:
        pc = self.snes_to_pc(bank, addr)
        return self.data[pc:pc + size]

    def u8(self, bank: int, addr: int) -> int:
        return self.data[self.snes_to_pc(bank, addr)]

    def u16(self, bank: int, addr: int) -> int:
        return struct.unpack_from("<H", self.data, self.snes_to_pc(bank, addr))[0]

    def u24(self, bank: int, addr: int) -> int:
        pc = self.snes_to_pc(bank, addr)
        return self.data[pc] | (self.data[pc + 1] << 8) | (self.data[pc + 2] << 16)

    def read_pc(self, pc: int, size: int) -> bytes:
        return self.data[pc:pc + size]

    # -- helpers -------------------------------------------------------------
    def follow_24bit_ptr(self, bank: int, addr: int) -> tuple[int, int]:
        """Read a 24-bit pointer at (bank, addr) and return it as (bank, addr)."""
        ptr = self.u24(bank, addr)
        return (ptr >> 16, ptr & 0xFFFF)

    @property
    def hardware_vectors(self) -> dict:
        """Hardware boot vector area $FF:FFE0-$FFFF (physical bank 63, PC 0x3FFE0).

        In Chrono Trigger this whole area is $0000, so the 65c816 boots in
        emulation mode with PC=$0000 and starts executing at $00:8000
        (== $C0:8000 in HiROM, the game's real entry point).
        """
        return {f"$FF:{0xFFE0 + 2 * i:04X}": struct.unpack_from("<H", self.data, 0x3FFE0 + 2 * i)[0]
                for i in range(16)}

    @property
    def vector_stub_table(self) -> dict:
        """Game's own 16-bit stub table at $C0:FFE0-$FFFF.

        Verified entries: $FFEA (emul NMI) -> $FF10 = JML $000500,
        $FFEE (emul IRQ) -> $FF14 = JML $000504, $FFFC -> $FF00 (soft-reset stub).
        """
        return {f"$C0:{0xFFE0 + 2 * i:04X}": struct.unpack_from("<H", self.data, 0xFFE0 + 2 * i)[0]
                for i in range(16)}

    BOOT_ENTRY = (0xC0, 0x8000)


def load(path: str) -> Rom:
    with open(path, "rb") as f:
        return Rom(f.read())
