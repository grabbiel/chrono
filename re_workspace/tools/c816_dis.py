#!/usr/bin/env python3
"""State-aware 65c816 recursive-descent disassembler for the Chrono Trigger ROM.

HiROM (banks $C0-$FF map to PC (bank&0x3F)<<16 | addr).  The disassembler
tracks the (M, X) processor-state across basic blocks:

  * SEP #imm sets P bits (bit5=0x20 M, bit4=0x10 X); REP #imm clears them.
  * Instruction LENGTH depends on state only through opc816.FLAG_DEPENDENT:
    immediateA (m) and immediateX (x).  abs,x / abs,y operand fields are
    always 16-bit; BIT abs ($0C/$2C/$3C) is always 3 bytes total.
  * Branches (BRA/BRL/cc) propagate the state to the target; a target that
    is reached with a *different* (M,X) state is re-queued (state merge =
    per-state visited set, so conflicting states re-trace the block).
  * JSR abs / JSL absL: the callee is entered with the caller's state; the
    return site is re-entered with the state the callee had at its RTS/RTL
    (per-function entry/exit state, tracked through a root tag that follows
    the callee's blocks).
  * JML absL / tail JMP: propagate state, no return edge.  RTL/RTS return
    to every recorded caller of the enclosing function root.
  * Jump tables: JSR/JMP (abs,X) read the 256-word table at the operand and
    seed every plausible target (in-ROM via Rom.snes_to_pc); the table bytes
    are marked as data so the walker never decodes them as code.

Data heuristics:
  * a run of >= FILL_RUN bytes of $00 (or $FF) at the walk position stops
    the block (fill/padding);
  * the ROM ranges listed in refs/ChronoRET/symbols/data_assets.csv for
    banks C3-C7 are a hard blocklist.

Seeds: boot ($C0:8000, per the Phase-1 spec; the byte-verified reset entry
is $C0:FF00, see the engine_vectors.json "discrepancies"), the NMI/IRQ/BRK
stubs, GameLoop, the 225 distinct Evt_OpcodeTable targets, the $C2:0000 /
$C2:8000 / $C7:0000 vector areas, MainInit ($FD:C000/$FD:C0D3) and the NMI
handler.

Run as a script to (re)generate:
  re_workspace/manifests/engine_vectors.json
  re_workspace/manifests/disasm_coverage.json
"""

from __future__ import annotations

import csv
import json
import os
import struct
import sys
from collections import defaultdict, deque

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, _HERE)

import opc816  # vendored MIT table (refs/mos65xx-python)  # noqa: E402
from address_map import Rom, load as load_rom  # noqa: E402

ROM_PATH = os.path.join(_ROOT, "ct_clean.sfc")
DATA_ASSETS_CSV = os.path.join(_ROOT, "refs", "ChronoRET", "symbols", "data_assets.csv")

M_BIT = 0x20
X_BIT = 0x10

FILL_RUN = 16  # >= this many identical $00/$FF bytes => stop the walk

# instruction mnemonics that end a basic block without a fallthrough
_JMP_MN = ("jmp", "jml")
# mnemonics that end a block and "return" control
_RET_MN = ("rts", "rtl")
# mnemonics that end a block outright
_STOP_MN = ("rti", "stp", "wai", "brk", "cop")


def snes_str(bank: int, addr: int) -> str:
    return f"${bank:02X}:{addr:04X}"


def parse_snes(s: str) -> tuple[int, int]:
    bank_s, addr_s = s.lstrip("$").split(":")
    return int(bank_s, 16), int(addr_s, 16)


class Blocklist:
    """Union of address ranges that must never be disassembled as code."""

    def __init__(self) -> None:
        self.ranges: list[tuple[int, int]] = []  # (start_pc, end_pc) inclusive
        self._starts: list[int] = []
        self._dirty = True

    def add(self, start: int, end: int) -> None:
        if end >= start:
            self.ranges.append((start, end))
            self._dirty = True

    def _prep(self) -> None:
        self.ranges.sort()
        merged: list[tuple[int, int]] = []
        for s, e in self.ranges:
            if merged and s <= merged[-1][1] + 1:
                merged[-1] = (merged[-1][0], max(merged[-1][1], e))
            else:
                merged.append((s, e))
        self.ranges = merged
        self._starts = [s for s, _ in merged]
        self._dirty = False

    def __contains__(self, pc: int) -> bool:
        if self._dirty:
            self._prep()
        import bisect

        i = bisect.bisect_right(self._starts, pc) - 1
        return i >= 0 and pc <= self.ranges[i][1]

    def total(self) -> int:
        if self._dirty:
            self._prep()
        return sum(e - s + 1 for s, e in self.ranges)


def load_data_asset_blocklist(rom: Rom) -> Blocklist:
    """Blocklist from ChronoRET's data_assets.csv (banks C3-C7 ROM ranges)."""
    bl = Blocklist()
    with open(DATA_ASSETS_CSV, newline="") as f:
        rows = [ln for ln in f if not ln.startswith("#")]
    for row in csv.DictReader(rows):
        try:
            sb, sa = parse_snes(row["start"])
            eb, ea = parse_snes(row["end"])
        except (KeyError, ValueError):
            continue
        if 0xC3 <= sb <= 0xC7:
            try:
                s = Rom.snes_to_pc(sb, sa)
                e = Rom.snes_to_pc(eb, ea)
            except ValueError:
                continue
            bl.add(s, e)
    return bl


class Instruction:
    __slots__ = ("pc", "bank", "addr", "opcode", "mnemonic", "mode", "operand",
                 "size", "m", "x", "text", "root")

    def __init__(self, pc, bank, addr, opcode, mnemonic, mode, operand, size,
                 m, x, text, root):
        self.pc, self.bank, self.addr = pc, bank, addr
        self.opcode, self.mnemonic, self.mode = opcode, mnemonic, mode
        self.operand, self.size, self.m, self.x = operand, size, m, x
        self.text, self.root = text, root

    @property
    def snes(self) -> str:
        return snes_str(self.bank, self.addr)

    def __repr__(self) -> str:  # pragma: no cover
        return f"<{self.snes} {self.text} m={int(self.m)} x={int(self.x)}>"


class Disassembler:
    """Worklist recursive-descent disassembler with (M,X) state tracking.

    domain: list of (lo, hi) inclusive PC ranges the walk may trace.
    Default = engine banks $C0-$C7 (PC 0x000000-0x07FFFF) plus bank $FD
    (0x3D0000-0x3DFFFF, MainInit); the rest of the image is graphics /
    music data whose misdecodes would otherwise cascade through the whole
    ROM via bogus JSL/JML targets.
    """

    DEFAULT_DOMAIN = [(0x000000, 0x07FFFF), (0x3D0000, 0x3DFFFF)]

    def __init__(self, rom: Rom, blocklist: Blocklist | None = None,
                 domain: list[tuple[int, int]] | None = None):
        self.rom = rom
        self.data = rom.data
        self.blocklist = blocklist if blocklist is not None else load_data_asset_blocklist(rom)
        self.domain = sorted(domain if domain is not None else self.DEFAULT_DOMAIN)
        self.insts: dict[int, Instruction] = {}
        # pc -> set of (m,x) states already queued/traced from this pc
        self.seen: dict[int, set[tuple[bool, bool]]] = defaultdict(set)
        self.queue: deque[tuple[int, int, bool, bool, int | None]] = deque()
        # return pc -> caller function's root (so RTS re-enters the right function)
        self.ret_owner: dict[int, int] = {}
        self.functions: dict[int, dict] = {}                   # root pc -> info
        self.jump_tables: list[dict] = []
        # discovered jump-table regions: a *soft* marker — the linear walk
        # stops at them, but explicit seeds/targets inside still trace
        # (real dispatch tables are often shorter than 256 words with live
        # code right behind them, e.g. the 16-entry table at $C0:6467)
        self.soft_tables: list[tuple[int, int]] = []
        self.blocks: list[dict] = []
        self.stats = defaultdict(int)

    # ------------------------------------------------------------------ util
    def _function(self, root_pc: int) -> dict:
        f = self.functions.get(root_pc)
        if f is None:
            f = {"entry_pc": root_pc, "entry_states": set(), "exit_states": set(),
                 "callers": set(), "labels": set()}
            self.functions[root_pc] = f
        return f

    def seed(self, bank: int, addr: int, m: bool, x: bool, label: str | None = None,
             root: int | None = None) -> None:
        try:
            pc = Rom.snes_to_pc(bank, addr)
        except ValueError:
            return
        if root is None:
            root = pc
        self._function(root)["labels"].add(f"{snes_str(bank, addr)} {label or ''}".strip())
        self._enqueue(bank, addr, m, x, root)

    def _in_domain(self, pc: int) -> bool:
        return any(lo <= pc <= hi for lo, hi in self.domain)

    def _in_soft(self, pc: int) -> bool:
        return any(lo <= pc <= hi for lo, hi in self.soft_tables)

    def _enqueue(self, bank: int, addr: int, m: bool, x: bool, root: int | None) -> None:
        try:
            pc = Rom.snes_to_pc(bank, addr)
        except ValueError:
            self.stats["enqueue_non_rom"] += 1
            return
        if not self._in_domain(pc):
            self.stats["enqueue_out_of_domain"] += 1
            return
        if pc in self.blocklist:
            self.stats["enqueue_blocklisted"] += 1
            return
        if (m, x) in self.seen[pc]:
            return
        self.seen[pc].add((m, x))
        self.queue.append((bank, addr, m, x, root))

    def _fill_run(self, pc: int) -> bool:
        chunk = self.data[pc:pc + FILL_RUN]
        return len(chunk) == FILL_RUN and (chunk == b"\x00" * FILL_RUN or chunk == b"\xff" * FILL_RUN)

    def _in_rom(self, bank: int, addr: int) -> bool:
        return Rom.is_rom(bank, addr)

    def _register_caller(self, root_pc: int, ret_bank: int, ret_addr: int,
                         caller_root: int | None, m: bool, x: bool) -> None:
        """Record that (ret_bank, ret_addr) is the return site of the function
        rooted at root_pc; if that function's RTS/RTL exit states are already
        known, re-enter the return site with them (fixpoint over call edges)."""
        fn = self._function(root_pc)
        ret_pc = Rom.snes_to_pc(ret_bank, ret_addr)
        if (ret_bank, ret_addr) in fn["callers"]:
            return
        fn["callers"].add((ret_bank, ret_addr))
        self.ret_owner[ret_pc] = caller_root if caller_root is not None else ret_pc
        for (em, ex) in list(fn["exit_states"]):
            self._enqueue(ret_bank, ret_addr, em, ex, self.ret_owner[ret_pc])

    # ------------------------------------------------------- table following
    def _follow_word_table(self, bank: int, base_addr: int, m: bool, x: bool,
                           ret_pc: tuple[int, int] | None, site_pc: int, kind: str,
                           site_root: int | None = None) -> int:
        """Read the 256-word jump table at (bank, base_addr); seed each
        plausible target.  ret_pc=(rbank,raddr) adds a caller edge to every
        target (JSR form).  Returns the number of targets seeded."""
        seeded = 0
        try:
            base_pc = Rom.snes_to_pc(bank, base_addr)
        except ValueError:
            return 0
        if base_pc + 2 * 256 > len(self.data):
            return 0  # table would run past the ROM image: not a plausible table
        # Per-entry plausibility: non-zero, in-ROM, outside the data-asset
        # blocklist, and the target must not start with a fill byte (real
        # handlers never begin with BRK/unused-$FF).  The table is accepted
        # (and its region marked data) only when >= 87.5% of entries pass;
        # partially-plausible candidates below that are misdecodes and are
        # rejected wholesale so they neither seed bogus targets nor mark real
        # code as data.  The real Evt_OpcodeTable passes 256/256.
        entries = []
        for i in range(256):
            w = struct.unpack_from("<H", self.data, base_pc + 2 * i)[0]
            if w == 0 or not self._in_rom(bank, w):
                continue
            tgt_pc = Rom.snes_to_pc(bank, w)
            if tgt_pc in self.blocklist or self.data[tgt_pc] in (0x00, 0xFF):
                continue
            entries.append((w, tgt_pc))
        if len(entries) < 224:  # 87.5% of 256
            self.stats["table_rejected"] += 1
            return 0
        seeded = 0
        for w, tgt_pc in entries:
            if ret_pc is not None:
                self._register_caller(tgt_pc, ret_pc[0], ret_pc[1], site_root, m, x)
            self._enqueue(bank, w, m, x, tgt_pc)
            seeded += 1
        # the table region is soft data: the linear walk stops at it, but
        # seeds/targets inside still trace (see soft_tables comment)
        if not any(lo <= base_pc and base_pc + 511 <= hi for lo, hi in self.soft_tables):
            self.soft_tables.append((base_pc, base_pc + 2 * 256 - 1))
        self.jump_tables.append({"kind": kind, "snes": snes_str(bank, base_addr),
                                 "pc": base_pc, "words": 256, "seeded": seeded,
                                 "site_pc": site_pc})
        return seeded

    # ------------------------------------------------------------- traversal
    def trace_block(self, bank: int, addr: int, m: bool, x: bool, root: int | None) -> None:
        pc = Rom.snes_to_pc(bank, addr)
        if root is not None:
            self._function(root)["entry_states"].add((m, x))
        start_pc = pc
        n = 0
        stop = "fallout"
        while True:
            if addr > 0xFFFF:
                stop = "bank_edge"
                break
            if pc in self.blocklist:
                stop = "data"
                break
            if self._in_soft(pc) and n > 0:
                # linear walk hit a discovered jump table; entering a table
                # cell directly (seed/target) is still allowed to decode
                stop = "table"
                break
            if not self._in_domain(pc):
                stop = "domain_edge"
                break
            if self._fill_run(pc):
                stop = "fill"
                break
            opcode = self.data[pc]
            mnemonic, mode = opc816.OPCODES[opcode]
            width = opc816.operand_size(mode, m, x)
            operand = int.from_bytes(self.data[pc + 1:pc + 1 + width], "little") if width else None
            size = 1 + width
            text = opc816.render(mode, operand, addr, size, width)
            inst = Instruction(pc, bank, addr, opcode, mnemonic, mode, operand,
                               size, m, x, f"{mnemonic} {text}".strip(), root)
            if pc not in self.insts:
                self.insts[pc] = inst
            n += 1
            next_addr = (addr + size) & 0x1FFFFF  # allow wrap flag below
            wrapped = addr + size > 0xFFFF

            # ---- state-changing instructions
            if mnemonic == "sep":
                m = m or bool(operand & M_BIT)
                x = x or bool(operand & X_BIT)
            elif mnemonic == "rep":
                m = m and not operand & M_BIT
                x = x and not operand & X_BIT

            # ---- control flow
            elif mode in ("relative", "relativeWord"):
                tgt = opc816.branch_target(addr, size, operand, width) & 0xFFFF
                if not wrapped:
                    self._enqueue(bank, tgt, m, x, root)

            elif mnemonic in ("jsr", "jsl"):
                tbank = taddr = None
                if mode == "absolutePC":
                    tbank, taddr = bank, operand
                elif mode == "absoluteLong":
                    tbank, taddr = operand >> 16, operand & 0xFFFF
                elif mode == "indirectX":
                    # JSR (abs,X) jump table (the event-VM dispatch)
                    ret = (bank, (addr + size) & 0xFFFF)
                    if not wrapped:
                        self._follow_word_table(bank, operand, m, x, ret, pc, "jsr_absX", root)
                        addr += size
                        pc += size
                        continue
                    stop = "bank_edge"
                    break
                if not wrapped and tbank is not None and self._in_rom(tbank, taddr):
                    root_pc = Rom.snes_to_pc(tbank, taddr)
                    self._register_caller(root_pc, bank, (addr + size) & 0xFFFF, root, m, x)
                    self._enqueue(tbank, taddr, m, x, root_pc)
                # fallthrough: the callee's RTS re-enters us (see rts below)

            elif mnemonic in _JMP_MN:
                if mode == "absolutePC":
                    tbank, taddr = bank, operand
                elif mode == "absoluteLong":
                    tbank, taddr = operand >> 16, operand & 0xFFFF
                elif mode == "indirectX":
                    if not wrapped:
                        self._follow_word_table(bank, operand, m, x, None, pc, "jmp_absX")
                    stop = "jmp"
                    break
                elif mode == "indirectPC":
                    try:
                        w = self.rom.u16(bank, operand)
                        tbank, taddr = bank, w
                    except ValueError:
                        stop = "bad_table"
                        break
                elif mode == "indirectLongPC":
                    try:
                        p = self.rom.u24(bank, operand)
                        tbank, taddr = p >> 16, p & 0xFFFF
                    except ValueError:
                        stop = "bad_table"
                        break
                else:
                    stop = "jmp_dyn"
                    break
                if not wrapped and self._in_rom(tbank, taddr):
                    self._enqueue(tbank, taddr, m, x, root)  # tail call keeps root
                stop = "jmp"
                break

            elif mnemonic in _RET_MN:
                if root is not None:
                    fn = self._function(root)
                    fn["exit_states"].add((m, x))
                    for (rbank, raddr) in sorted(fn["callers"]):
                        caller_root = self.ret_owner.get(Rom.snes_to_pc(rbank, raddr))
                        self._enqueue(rbank, raddr, m, x, caller_root)
                stop = "ret"
                break

            elif mnemonic in _STOP_MN:
                stop = mnemonic
                break
            # everything else: fall through

            if wrapped:
                stop = "bank_edge"
                break
            addr = next_addr
            pc += size
        self.blocks.append({"pc": start_pc, "snes": snes_str(bank, addr if stop != 'bank_edge' else 0),
                            "count": n, "stop": stop, "m": m, "x": x, "root": root})

    def run(self, max_blocks: int = 2_000_000) -> None:
        while self.queue and len(self.blocks) < max_blocks:
            bank, addr, m, x, root = self.queue.popleft()
            try:
                Rom.snes_to_pc(bank, addr)
            except ValueError:
                continue
            self.trace_block(bank, addr, m, x, root)

    # ------------------------------------------------------------- reporting
    def decode_linear(self, bank: int, addr: int, m: bool, x: bool, nbytes: int) -> list[Instruction]:
        """Decode forward from (bank, addr) in the given state WITHOUT following
        control flow — the same decode path trace_block uses.  Returns the
        instructions covering at least nbytes."""
        out: list[Instruction] = []
        covered = 0
        pc = Rom.snes_to_pc(bank, addr)
        while covered < nbytes:
            opcode = self.data[pc]
            mnemonic, mode = opc816.OPCODES[opcode]
            width = opc816.operand_size(mode, m, x)
            operand = int.from_bytes(self.data[pc + 1:pc + 1 + width], "little") if width else None
            size = 1 + width
            text = opc816.render(mode, operand, addr, size, width)
            inst = Instruction(pc, bank, addr, opcode, mnemonic, mode, operand,
                               size, m, x, f"{mnemonic} {text}".strip(), None)
            out.append(inst)
            if mnemonic == "sep":
                m = m or bool(operand & M_BIT)
                x = x or bool(operand & X_BIT)
            elif mnemonic == "rep":
                m = m and not operand & M_BIT
                x = x and not operand & X_BIT
            covered += size
            addr += size
            pc += size
        return out

    def coverage(self) -> dict:
        per_bank = defaultdict(lambda: {"instructions": 0, "code_bytes": 0})
        for inst in self.insts.values():
            b = per_bank[f"{inst.bank & 0x3F | 0xC0:02X}"]
            b["instructions"] += 1
            b["code_bytes"] += inst.size
        entry_dist = defaultdict(int)
        for f in self.functions.values():
            key = ",".join(f"m={int(mm)},x={int(xx)}" for mm, xx in sorted(f["entry_states"]))
            entry_dist[key or "unreached"] += 1
        return {
            "per_bank": {k: dict(v) for k, v in sorted(per_bank.items())},
            "total_instructions": len(self.insts),
            "total_code_bytes": sum(i.size for i in self.insts.values()),
            "functions": len(self.functions),
            "blocks": len(self.blocks),
            "jump_tables": self.jump_tables,
            "entry_state_distribution": dict(sorted(entry_dist.items())),
            "stats": dict(self.stats),
        }

    def write_sites(self, addrs: tuple[int, ...]) -> list[Instruction]:
        """Traced absolute stores to the given 16-bit addresses (e.g. $420B)."""
        out = []
        for inst in self.insts.values():
            if inst.mode == "absolute" and inst.mnemonic in ("sta", "stz") and inst.operand in addrs:
                out.append(inst)
        return sorted(out, key=lambda i: i.pc)

    def port_sites(self, lo: int, hi: int) -> list[Instruction]:
        """Traced absolute accesses (any mnemonic) to [lo, hi]."""
        out = []
        for inst in self.insts.values():
            if inst.mode == "absolute" and lo <= inst.operand <= hi:
                out.append(inst)
        return sorted(out, key=lambda i: i.pc)


# --------------------------------------------------------------------- seeds
def evt_opcode_targets(rom: Rom) -> list[int]:
    """The 225 distinct handler offsets in Evt_OpcodeTable (PC 0x5D6E)."""
    return sorted({struct.unpack_from("<H", rom.data, 0x5D6E + 2 * i)[0] for i in range(256)})


def jsl_decomp_sites(rom: Rom) -> list[int]:
    """Every JSL $C3:0002 (bytes 22 02 00 c3) site in the ROM."""
    pat = bytes([0x22, 0x02, 0x00, 0xC3])
    sites, i = [], 0
    while True:
        i = rom.data.find(pat, i)
        if i < 0:
            return sites
        sites.append(i)
        i += 1


def default_seeds(rom: Rom) -> list[tuple[int, int, bool, bool, str]]:
    seeds = [
        (0xC0, 0x8000, False, False, "boot_seed(spec)"),
        (0xC0, 0xFF00, True, True, "Reset"),
        (0xC0, 0xFF10, True, True, "NMI_Stub"),
        (0xC0, 0xFF14, True, True, "IRQ_Stub"),
        (0xC0, 0xFF18, True, True, "BRK_Handler"),
        (0xC0, 0x0000, True, False, "Engine_EntryTable"),
        (0xC0, 0x000E, True, False, "GameLoop"),
        (0xC0, 0xEA63, True, True, "NmiHandler"),
        (0xC2, 0x0000, True, False, "BankC2_Entry0000"),
        (0xC2, 0x8000, True, False, "BankC2_Entry8000"),
        (0xC7, 0x0000, True, False, "Audio_DriverInit"),
        (0xFD, 0xC000, True, True, "MainInit"),
        (0xFD, 0xC0D3, True, True, "MainInit_JML_GameLoop"),
    ]
    for w in evt_opcode_targets(rom):
        seeds.append((0xC0, w, True, False, f"Evt_handler_{w:04X}"))
    return seeds


def build(rom: Rom) -> Disassembler:
    dis = Disassembler(rom, load_data_asset_blocklist(rom))
    for bank, addr, m, x, label in default_seeds(rom):
        dis.seed(bank, addr, m, x, label)
    dis.run()
    return dis


# ----------------------------------------------------------------- manifests
def _entry(label, bank, addr, evidence, rom, bytes_len=4, **extra):
    pc = Rom.snes_to_pc(bank, addr)
    e = {"label": label, "snes": snes_str(bank, addr), "pc": pc,
         "evidence": evidence,
         "bytes": rom.data[pc:pc + bytes_len].hex(" ")}
    e.update(extra)
    return e


def build_engine_vectors(dis: Disassembler) -> dict:
    rom = dis.rom
    data = rom.data

    def at(bank, addr, n):
        return data[Rom.snes_to_pc(bank, addr):Rom.snes_to_pc(bank, addr) + n].hex(" ")

    main_loop = [
        _entry("Reset", 0xC0, 0xFF00, "byte-verified reset entry (bank00.asm): SEI/CLC/XCE/JML MainInit; "
               "hardware reset vector $FFFC -> $FF00", rom, 4),
        _entry("MainInit", 0xFD, 0xC000, "MainInit proper (bankFD.asm); ends in JML $C0:000E at $FD:C0D3", rom, 4),
        _entry("MainInit_JML_GameLoop", 0xFD, 0xC0D3, "JML $C0:000E — cold entry into GameLoop", rom, 4),
        _entry("Engine_EntryTable", 0xC0, 0x0000, "fixed JSL/JML entry stubs; [0] BRA -> GameLoop_Main", rom, 2),
        _entry("GameLoop", 0xC0, 0x000E, "cold init then frame loop (bankC0.asm '$C0:000E — GameLoop')", rom, 4),
        _entry("GameLoop_Main", 0xC0, 0x005D, "frame-loop entry: InitHW/InstallNMI/InstallIRQ then Loc_Id dispatch", rom, 6),
        _entry("GameLoop_Main_JML_BankC2", 0xC0, 0x006E,
               "JML $C2:0000 scene-mode vector (Loc_Id $01F0-$81EF); bytes 5c 00 00 c2 verified at this pc",
               rom, 4),
        _entry("GameLoop_NotBankC2", 0xC0, 0x0072,
               "CPX.w #$01FF / BMI GameLoop_LoadField / LDX #$7C00 / BRL Sys_HaltWithColor (bankC0.asm label; "
               "the spec's '$C0:007A' is the BRL inside it)", rom, 3),
        _entry("GameLoop_NotBankC2_BRL_Halt", 0xC0, 0x007A,
               "BRL $2E1E Sys_HaltWithColor — the instruction the task spec cites as 'GameLoop_NotBankC2 $C0:007A'",
               rom, 3),
        _entry("GameLoop_LoadField", 0xC0, 0x007D, "REP #$20/LDA #!DP_Field/TCD/SEP #$20 then location load", rom, 8),
        _entry("BankC2_Entry0000", 0xC2, 0x0000, "bank $C2 scene-mode entry vectors (JMP table, 5 entries)", rom, 3),
        _entry("BankC2_Entry8000", 0xC2, 0x8000, "bank $C2 $8000 vectors (BRA table + JSR/RTS wrappers)", rom, 6),
    ]

    bdmaen = [i for i in dis.write_sites((0x420B,))]
    hdmaen = [i for i in dis.write_sites((0x420C,))]
    dma = [
        _entry("NmiHandler", 0xC0, 0xEA63, "NMI handler: upload steps Pal_UploadCgram, Oam_UploadShadow, "
               "VramQ_Flush (bankC0.asm '$C0:EA63 — NmiHandler')", rom, 6),
        _entry("VramQ_Flush", 0xC0, 0xB1B2, "VRAM upload queue flush, JSR'd from NmiHandler "
               "(bankC0.asm '$C0:B1B2 — VramQ_Flush')", rom, 4),
    ]
    for i in bdmaen:
        dma.append(_entry(f"BDMAEN_write@{i.snes}", i.bank, i.addr,
                          f"STA $420B (BDMAEN) traced in this traversal; encoding {i.text}", rom, 3))
    for i in hdmaen:
        dma.append(_entry(f"HDMAEN_write@{i.snes}", i.bank, i.addr,
                          f"STA $420C (HDMAEN) traced in this traversal; encoding {i.text}", rom, 3))

    decomp_sites = jsl_decomp_sites(rom)
    decomp = [
        _entry("Decomp_ToWramVec", 0xC3, 0x0002, "global decompression entry: JMP Decomp_ToWram; "
               "42 JSL sites (bytes 22 02 00 c3) enumerated from ROM", rom, 3),
        _entry("Decomp_ToWram", 0xC3, 0x0557, "LZSS wrapper (bankC3.asm '$C3:0557 — Decomp_ToWram'); "
               "real loop in packed module.asm", rom, 6),
    ]
    for n, pc in enumerate(decomp_sites):
        b, a = Rom.linear_to_snes(pc)
        decomp.append(_entry(f"JSL_Decomp_ToWramVec_{n:02d}", b, a,
                             f"JSL Decomp_ToWramVec (call site {n + 1}/42, enumerated from ROM bytes)", rom, 4))

    evt = [
        _entry("Evt_OpcodeTable", 0xC0, 0x5D6E, "event VM opcode handler table: 256 words, 225 distinct "
               "targets, 32 unused -> $C0:5F6E (all verified in ROM bytes)", rom, 8),
        _entry("Evt_UnusedOpcode", 0xC0, 0x5F6E, "halt handler shared by all 32 unused opcodes "
               "(bankC0.asm '$C0:5F6E — Evt_UnusedOpcode')", rom, 3),
    ]
    for off in (0x5910, 0x5977, 0x59A0, 0x5AB1):
        evt.append(_entry(f"Evt_Dispatch@{snes_str(0xC0, off)}", 0xC0, off,
                          "JSR (Evt_OpcodeTable,X) — opcode $FC dispatch, bytes fc 6e 5d verified at this pc", rom, 3))
    evt += [
        _entry("Evt_InitObjects", 0xC0, 0x5709, "per-location object init pass; runs every object's init "
               "function (bankC0.asm '$C0:5709 — Evt_InitObjects')", rom, 4),
        _entry("Evt_RunObjInit", 0xC0, 0x597D, "runs one object's init script (bankC0.asm '$C0:597D — Evt_RunObjInit')",
               rom, 4),
        _entry("Evt_RunObjScriptSteps", 0xC0, 0x5A93, "per-frame stepped object scripts with the "
               "Evt_StepsLeft budget (bankC0.asm '$C0:5A93 — Evt_RunObjScriptSteps')", rom, 4),
    ]

    spc = [
        _entry("Audio_DriverInit", 0xC7, 0x0000, "JMP vector 1/4 at $C7:0000 -> Audio_Boot", rom, 3),
        _entry("Audio_DriverCommand", 0xC7, 0x0004, "JMP vector 2/4 -> Audio_RunCommand", rom, 3),
        _entry("Audio_VecLoadNewSamples", 0xC7, 0x0008, "JMP vector 3/4 -> Audio_LoadNewSamples", rom, 3),
        _entry("Audio_VecSendSampleDir", 0xC7, 0x000C, "JMP vector 4/4 -> Audio_SendSampleDir", rom, 3),
        _entry("Audio_Boot", 0xC7, 0x0038, "SPC700 boot: sends the 6 IPL blocks incl. the SPC program "
               "(bankC7.asm '$C7:0038 — Audio_Boot')", rom, 6),
    ]
    for i in dis.port_sites(0x2140, 0x2143):
        spc.append(_entry(f"APU_port_{i.mnemonic}@{i.snes}", i.bank, i.addr,
                          f"{i.text} — $2140-$2143 SPC700 comm port access traced in this traversal", rom, 3))

    return {
        "meta": {
            "rom": "ct_clean.sfc (Chrono Trigger USA v1.0, HiROM FastROM, CRC32 2D206BF7)",
            "generated_by": "tools/c816_dis.py (Phase 1 Step 1.2)",
            "note": "every entry's 'bytes' field is the actual ROM byte prefix at its pc; "
                    "addresses cross-checked against ChronoRET comments",
        },
        "subsystems": {
            "main_loop_and_state_dispatcher": main_loop,
            "dma_hdma_transfer_queues": dma,
            "global_decompression": decomp,
            "location_event_bytecode_interpreter": evt,
            "spc700_communication_driver": spc,
        },
        "discrepancies": [
            {
                "claim": "Phase-1 spec / AGENT_CONTEXT: 'emulation boot at $00:8000' and seed "
                         "'$C0:8000 (boot)'; test spec calls it 'the 20-byte boot prologue'.",
                "verified": "$C0:8000 is mid-function: it lies 0x66 bytes inside Sub_C07F9A / "
                            "Field_CalcScrollEdgeVramAddrs ($7F9A-$813C, a tilemap VRAM-address helper). "
                            "The byte-verified boot is the emulation RESET vector $FFFC -> $C0:FF00 "
                            "(SEI/CLC/XCE/JML MainInit, $FD:C0D3 JML $C0:000E). $C0:8000 is still seeded "
                            "and decodes cleanly with M=0.",
                "resolution": "kept the $C0:8000 seed for spec compliance; true Reset seeded too and "
                              "listed first in main_loop_and_state_dispatcher.",
            },
            {
                "claim": "Phase-1 spec: 'GameLoop_NotBankC2 $C0:007A'.",
                "verified": "ChronoRET's label GameLoop_NotBankC2 is at $C0:0072 (CPX.w #$01FF, bytes "
                            "e0 ff 01 verified at 0x72). $C0:007A is the BRL $2E1E Sys_HaltWithColor "
                            "instruction inside it (bytes 82 a1 2d verified) — the form ChronoRET's "
                            "caller notes cite ('$C0:007A').",
                "resolution": "both addresses listed as separate entries.",
            },
            {
                "claim": "AGENT_CONTEXT: 'hardware vectors ($FF:FFE0-$FFFF) all zero -> the 65c816 boots "
                         "in emulation mode with PC=$0000 and starts executing at $00:8000'.",
                "verified": "$FF:FFE0-$FFFF (PC 0x3FFE0) is indeed all zero, but an emulation-mode reset "
                            "fetches its vectors from bank $00 space ($FFFA/$FFFC = PC 0xFFFA/0xFFFC), "
                            "which hold $FF00 — so control starts at $C0:FF00 (Reset), not $C0:8000.",
                "resolution": "Reset entry listed in main_loop_and_state_dispatcher.",
            },
            {
                "claim": "dscotton ct_disassembly vs ChronoRET naming at $C0:7F9A/$C0:8000.",
                "verified": "same code, different labels (Sub_C07F9A vs Field_CalcScrollEdgeVramAddrs); "
                            "instruction stream identical — not an address disagreement.",
                "resolution": "no action.",
            },
        ],
        "unverified": [
            "NMI/IRQ WRAM trampolines ($0500/$0504) are runtime-written; the static walk cannot follow "
            "them, so NmiHandler/IRQ code is reached via explicit seeds, not through the vectors.",
        ],
    }


def build_coverage(dis: Disassembler) -> dict:
    cov = dis.coverage()
    rom = dis.rom
    checks = []

    def check(name, expected, actual):
        checks.append({"name": name, "expected": expected, "actual": actual,
                       "pass": expected == actual})

    # 1. per-bank byte sums equal the total
    check("per_bank_bytes_sum", cov["total_code_bytes"],
          sum(b["code_bytes"] for b in cov["per_bank"].values()))
    # 2. every traced instruction's size matches 1 + vendored operand_size
    bad = sum(1 for i in dis.insts.values()
              if i.size != 1 + opc816.operand_size(i.mode, i.m, i.x))
    check("sizes_match_operand_size", 0, bad)
    # 3. no traced instruction lies in the static data-asset blocklist
    static_bl = load_data_asset_blocklist(rom)
    bl_hits = sum(1 for i in dis.insts.values() if i.pc in static_bl)
    check("traced_inside_data_assets", 0, bl_hits)
    # 4. all 42 JSL $C3:0002 sites enumerated from ROM bytes; every one that
    #    the control-flow walk reaches decodes as a 4-byte jsl.  7 sites are
    #    byte coincidences inside data (4x $C6:E0xx sprite data, 2x $C4, 1x
    #    $FF — dscotton's linear dump decodes them as JSL but no control flow
    #    from the engine reaches them), so the expected traced count is 35.
    sites = jsl_decomp_sites(rom)
    traced_jsl = sum(1 for pc in sites
                     if pc in dis.insts and dis.insts[pc].mnemonic == "jsl" and dis.insts[pc].size == 4)
    misdecoded = sum(1 for pc in sites
                     if pc in dis.insts and dis.insts[pc].mnemonic != "jsl")
    check("jsl_decomp_enumerated", 42, len(sites))
    check("jsl_decomp_traced", 35, traced_jsl)
    check("jsl_decomp_misdecoded", 0, misdecoded)
    # 5. all 225 distinct Evt_OpcodeTable targets traced as code entries
    targets = evt_opcode_targets(rom)
    traced_tgt = sum(1 for w in targets if w in dis.insts)
    check("evt_targets_traced", 225, traced_tgt)
    check("evt_targets_distinct", 225, len(targets))
    # 6. boot prologue layout at $C0:8000 (M=0 seed)
    sizes = []
    pc = 0x8000
    while pc < 0x8015:
        i = dis.insts.get(pc)
        if i is None:
            break
        sizes.append(i.size)
        pc += i.size
    check("boot_prologue_sizes", [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 1, 3], sizes)
    return {
        "meta": {"rom": "ct_clean.sfc", "generated_by": "tools/c816_dis.py"},
        "per_bank": cov["per_bank"],
        "total_instructions": cov["total_instructions"],
        "total_code_bytes": cov["total_code_bytes"],
        "functions": cov["functions"],
        "blocks": cov["blocks"],
        "jump_tables": cov["jump_tables"],
        "entry_state_distribution": cov["entry_state_distribution"],
        "stats": cov["stats"],
        "notes": {
            "jsl_decomp_unreached_sites": [
                snes_str(*Rom.linear_to_snes(pc)) for pc in jsl_decomp_sites(rom)
                if pc not in dis.insts],
            "domain": [f"{lo:06X}-{hi:06X}" for lo, hi in Disassembler.DEFAULT_DOMAIN],
        },
        "self_check": {"checks": checks, "all_pass": all(c["pass"] for c in checks)},
    }


def main() -> int:
    rom = load_rom(ROM_PATH)
    dis = build(rom)
    os.makedirs(os.path.join(_ROOT, "manifests"), exist_ok=True)
    vectors = build_engine_vectors(dis)
    with open(os.path.join(_ROOT, "manifests", "engine_vectors.json"), "w") as f:
        json.dump(vectors, f, indent=2)
    with open(os.path.join(_ROOT, "manifests", "disasm_coverage.json"), "w") as f:
        json.dump(build_coverage(dis), f, indent=2)
    cov = dis.coverage()
    print(f"instructions={cov['total_instructions']} code_bytes={cov['total_code_bytes']} "
          f"functions={cov['functions']} blocks={cov['blocks']}")
    print("per_bank:", {k: v["instructions"] for k, v in cov["per_bank"].items()})
    return 0


if __name__ == "__main__":
    sys.exit(main())
