"""spc700_dis.py — SPC700 disassembler with recursive-descent code following.

Opcode + operand-format tables are VENDORED (verbatim) from:

    gufranco/sony-spc700-python  (https://github.com/gufranco/sony-spc700-python)
    spc700/opcodes.py — "Sony SPC700 interpreter in Python ... All 256
    opcodes, validated against all 256,000 SingleStepTests cases"
    MIT License, Copyright (c) 2026 Gustavo Franco
    (retrieved 2026-10-18 from raw.githubusercontent.com, branch main)

The MIT license text is reproduced at the bottom of this file. The
recursive-descent engine below (walk/seed/jump-table following) is original
work for the Chrono-Forge project.

SPC700 notes: registers are fixed 8-bit (no M/X flag state to track); the
direct page follows the P flag (bit 0 of PSW) — this disassembler assumes
P=0 (the Chrono Trigger driver runs with P=0 throughout; Spc_Start does
`clrp`-style init and never sets P except transiently via `sei`-free code).
"""

OPCODES = (
    ("nop", "implied", 1),
    ("tcall", "tcall", 1),
    ("set1", "dp_bit", 2),
    ("bbs", "dp_bit_rel", 3),
    ("or", "a_dp", 2),
    ("or", "a_abs", 3),
    ("or", "a_ix", 1),
    ("or", "a_idx", 2),
    ("or", "a_imm", 2),
    ("or", "dp_dp", 3),
    ("or1", "c_membit", 3),
    ("asl", "dp", 2),
    ("asl", "abs", 3),
    ("push", "p", 1),
    ("tset", "abs_a", 3),
    ("brk", "implied", 1),
    ("bpl", "rel", 2),
    ("tcall", "tcall", 1),
    ("clr1", "dp_bit", 2),
    ("bbc", "dp_bit_rel", 3),
    ("or", "a_dpx", 2),
    ("or", "a_absx", 3),
    ("or", "a_absy", 3),
    ("or", "a_idy", 2),
    ("or", "dp_imm", 3),
    ("or", "ix_iy", 1),
    ("decw", "dp", 2),
    ("asl", "dpx", 2),
    ("asl", "a", 1),
    ("dec", "x", 1),
    ("cmp", "x_abs", 3),
    ("jmp", "abs_indirect_x", 3),
    ("clrp", "implied", 1),
    ("tcall", "tcall", 1),
    ("set1", "dp_bit", 2),
    ("bbs", "dp_bit_rel", 3),
    ("and", "a_dp", 2),
    ("and", "a_abs", 3),
    ("and", "a_ix", 1),
    ("and", "a_idx", 2),
    ("and", "a_imm", 2),
    ("and", "dp_dp", 3),
    ("or1", "c_notmembit", 3),
    ("rol", "dp", 2),
    ("rol", "abs", 3),
    ("push", "a", 1),
    ("cbne", "dp_rel", 3),
    ("bra", "rel", 2),
    ("bmi", "rel", 2),
    ("tcall", "tcall", 1),
    ("clr1", "dp_bit", 2),
    ("bbc", "dp_bit_rel", 3),
    ("and", "a_dpx", 2),
    ("and", "a_absx", 3),
    ("and", "a_absy", 3),
    ("and", "a_idy", 2),
    ("and", "dp_imm", 3),
    ("and", "ix_iy", 1),
    ("incw", "dp", 2),
    ("rol", "dpx", 2),
    ("rol", "a", 1),
    ("inc", "x", 1),
    ("cmp", "x_dp", 2),
    ("call", "abs", 3),
    ("setp", "implied", 1),
    ("tcall", "tcall", 1),
    ("set1", "dp_bit", 2),
    ("bbs", "dp_bit_rel", 3),
    ("eor", "a_dp", 2),
    ("eor", "a_abs", 3),
    ("eor", "a_ix", 1),
    ("eor", "a_idx", 2),
    ("eor", "a_imm", 2),
    ("eor", "dp_dp", 3),
    ("and1", "c_membit", 3),
    ("lsr", "dp", 2),
    ("lsr", "abs", 3),
    ("push", "x", 1),
    ("tclr", "abs_a", 3),
    ("pcall", "pcall", 2),
    ("bvc", "rel", 2),
    ("tcall", "tcall", 1),
    ("clr1", "dp_bit", 2),
    ("bbc", "dp_bit_rel", 3),
    ("eor", "a_dpx", 2),
    ("eor", "a_absx", 3),
    ("eor", "a_absy", 3),
    ("eor", "a_idy", 2),
    ("eor", "dp_imm", 3),
    ("eor", "ix_iy", 1),
    ("cmpw", "ya_dp", 2),
    ("lsr", "dpx", 2),
    ("lsr", "a", 1),
    ("mov", "x_a", 1),
    ("cmp", "y_abs", 3),
    ("jmp", "abs", 3),
    ("clrc", "implied", 1),
    ("tcall", "tcall", 1),
    ("set1", "dp_bit", 2),
    ("bbs", "dp_bit_rel", 3),
    ("cmp", "a_dp", 2),
    ("cmp", "a_abs", 3),
    ("cmp", "a_ix", 1),
    ("cmp", "a_idx", 2),
    ("cmp", "a_imm", 2),
    ("cmp", "dp_dp", 3),
    ("and1", "c_notmembit", 3),
    ("ror", "dp", 2),
    ("ror", "abs", 3),
    ("push", "y", 1),
    ("dbnz", "dp_rel", 3),
    ("ret", "implied", 1),
    ("bvs", "rel", 2),
    ("tcall", "tcall", 1),
    ("clr1", "dp_bit", 2),
    ("bbc", "dp_bit_rel", 3),
    ("cmp", "a_dpx", 2),
    ("cmp", "a_absx", 3),
    ("cmp", "a_absy", 3),
    ("cmp", "a_idy", 2),
    ("cmp", "dp_imm", 3),
    ("cmp", "ix_iy", 1),
    ("addw", "ya_dp", 2),
    ("ror", "dpx", 2),
    ("ror", "a", 1),
    ("mov", "a_x", 1),
    ("cmp", "y_dp", 2),
    ("reti", "implied", 1),
    ("setc", "implied", 1),
    ("tcall", "tcall", 1),
    ("set1", "dp_bit", 2),
    ("bbs", "dp_bit_rel", 3),
    ("adc", "a_dp", 2),
    ("adc", "a_abs", 3),
    ("adc", "a_ix", 1),
    ("adc", "a_idx", 2),
    ("adc", "a_imm", 2),
    ("adc", "dp_dp", 3),
    ("eor1", "c_membit", 3),
    ("dec", "dp", 2),
    ("dec", "abs", 3),
    ("mov", "y_imm", 2),
    ("pop", "p", 1),
    ("mov", "dp_imm", 3),
    ("bcc", "rel", 2),
    ("tcall", "tcall", 1),
    ("clr1", "dp_bit", 2),
    ("bbc", "dp_bit_rel", 3),
    ("adc", "a_dpx", 2),
    ("adc", "a_absx", 3),
    ("adc", "a_absy", 3),
    ("adc", "a_idy", 2),
    ("adc", "dp_imm", 3),
    ("adc", "ix_iy", 1),
    ("subw", "ya_dp", 2),
    ("dec", "dpx", 2),
    ("dec", "a", 1),
    ("mov", "x_sp", 1),
    ("div", "ya_x", 1),
    ("xcn", "a", 1),
    ("ei", "implied", 1),
    ("tcall", "tcall", 1),
    ("set1", "dp_bit", 2),
    ("bbs", "dp_bit_rel", 3),
    ("sbc", "a_dp", 2),
    ("sbc", "a_abs", 3),
    ("sbc", "a_ix", 1),
    ("sbc", "a_idx", 2),
    ("sbc", "a_imm", 2),
    ("sbc", "dp_dp", 3),
    ("mov1", "c_membit", 3),
    ("inc", "dp", 2),
    ("inc", "abs", 3),
    ("cmp", "y_imm", 2),
    ("pop", "a", 1),
    ("mov", "ixinc_a", 1),
    ("bcs", "rel", 2),
    ("tcall", "tcall", 1),
    ("clr1", "dp_bit", 2),
    ("bbc", "dp_bit_rel", 3),
    ("sbc", "a_dpx", 2),
    ("sbc", "a_absx", 3),
    ("sbc", "a_absy", 3),
    ("sbc", "a_idy", 2),
    ("sbc", "dp_imm", 3),
    ("sbc", "ix_iy", 1),
    ("movw", "ya_dp", 2),
    ("inc", "dpx", 2),
    ("inc", "a", 1),
    ("mov", "sp_x", 1),
    ("das", "a", 1),
    ("mov", "a_ixinc", 1),
    ("di", "implied", 1),
    ("tcall", "tcall", 1),
    ("set1", "dp_bit", 2),
    ("bbs", "dp_bit_rel", 3),
    ("mov", "dp_a", 2),
    ("mov", "abs_a", 3),
    ("mov", "ix_a", 1),
    ("mov", "idx_a", 2),
    ("cmp", "x_imm", 2),
    ("mov", "abs_x", 3),
    ("mov1", "membit_c", 3),
    ("mov", "dp_y", 2),
    ("mov", "abs_y", 3),
    ("mov", "x_imm", 2),
    ("pop", "x", 1),
    ("mul", "ya", 1),
    ("bne", "rel", 2),
    ("tcall", "tcall", 1),
    ("clr1", "dp_bit", 2),
    ("bbc", "dp_bit_rel", 3),
    ("mov", "dpx_a", 2),
    ("mov", "absx_a", 3),
    ("mov", "absy_a", 3),
    ("mov", "idy_a", 2),
    ("mov", "dp_x", 2),
    ("mov", "dpy_x", 2),
    ("movw", "dp_ya", 2),
    ("mov", "dpx_y", 2),
    ("dec", "y", 1),
    ("mov", "a_y", 1),
    ("cbne", "dpx_rel", 3),
    ("daa", "a", 1),
    ("clrv", "implied", 1),
    ("tcall", "tcall", 1),
    ("set1", "dp_bit", 2),
    ("bbs", "dp_bit_rel", 3),
    ("mov", "a_dp", 2),
    ("mov", "a_abs", 3),
    ("mov", "a_ix", 1),
    ("mov", "a_idx", 2),
    ("mov", "a_imm", 2),
    ("mov", "x_abs", 3),
    ("not1", "c_membit", 3),
    ("mov", "y_dp", 2),
    ("mov", "y_abs", 3),
    ("notc", "implied", 1),
    ("pop", "y", 1),
    ("sleep", "implied", 1),
    ("beq", "rel", 2),
    ("tcall", "tcall", 1),
    ("clr1", "dp_bit", 2),
    ("bbc", "dp_bit_rel", 3),
    ("mov", "a_dpx", 2),
    ("mov", "a_absx", 3),
    ("mov", "a_absy", 3),
    ("mov", "a_idy", 2),
    ("mov", "x_dp", 2),
    ("mov", "x_dpy", 2),
    ("mov", "dp_dp", 3),
    ("mov", "y_dpx", 2),
    ("inc", "y", 1),
    ("mov", "y_a", 1),
    ("dbnz", "y_rel", 2),
    ("stop", "implied", 1),
)

TEXT = (
    "nop",
    "tcall 0",
    "set0 ${dp0}",
    "bbs0 ${dp0},${rel3}",
    "or a,${dp0}",
    "or a,${abs}",
    "or a,(x)",
    "or a,(${dp0}+x)",
    "or a,#${op0}",
    "or ${dp1},${dp0}",
    "or1 c,${mem}:{bit}",
    "asl ${dp0}",
    "asl ${abs}",
    "push p",
    "tset ${abs},a",
    "brk",
    "bpl ${rel2}",
    "tcall 1",
    "clr0 ${dp0}",
    "bbc0 ${dp0},${rel3}",
    "or a,${dp0}+x",
    "or a,${abs}+x",
    "or a,${abs}+y",
    "or a,(${dp0})+y",
    "or ${dp1},#${op0}",
    "or (x),(y)",
    "decw ${dp0}",
    "asl ${dp0}+x",
    "asl a",
    "dec x",
    "cmp x,${abs}",
    "jmp (${abs}+x)",
    "clrp",
    "tcall 2",
    "set1 ${dp0}",
    "bbs1 ${dp0},${rel3}",
    "and a,${dp0}",
    "and a,${abs}",
    "and a,(x)",
    "and a,(${dp0}+x)",
    "and a,#${op0}",
    "and ${dp1},${dp0}",
    "or1 c,!${mem}:{bit}",
    "rol ${dp0}",
    "rol ${abs}",
    "push a",
    "cbne ${dp0},${rel3}",
    "bra ${rel2}",
    "bmi ${rel2}",
    "tcall 3",
    "clr1 ${dp0}",
    "bbc1 ${dp0},${rel3}",
    "and a,${dp0}+x",
    "and a,${abs}+x",
    "and a,${abs}+y",
    "and a,(${dp0})+y",
    "and ${dp1},#${op0}",
    "and (x),(y)",
    "incw ${dp0}",
    "rol ${dp0}+x",
    "rol a",
    "inc x",
    "cmp x,${dp0}",
    "call ${abs}",
    "setp",
    "tcall 4",
    "set2 ${dp0}",
    "bbs2 ${dp0},${rel3}",
    "eor a,${dp0}",
    "eor a,${abs}",
    "eor a,(x)",
    "eor a,(${dp0}+x)",
    "eor a,#${op0}",
    "eor ${dp1},${dp0}",
    "and1 c,${mem}:{bit}",
    "lsr ${dp0}",
    "lsr ${abs}",
    "push x",
    "tclr ${abs},a",
    "pcall $ff{op0}",
    "bvc ${rel2}",
    "tcall 5",
    "clr2 ${dp0}",
    "bbc2 ${dp0},${rel3}",
    "eor a,${dp0}+x",
    "eor a,${abs}+x",
    "eor a,${abs}+y",
    "eor a,(${dp0})+y",
    "eor ${dp1},#${op0}",
    "eor (x),(y)",
    "cmpw ya,${dp0}",
    "lsr ${dp0}+x",
    "lsr a",
    "mov x,a",
    "cmp y,${abs}",
    "jmp ${abs}",
    "clrc",
    "tcall 6",
    "set3 ${dp0}",
    "bbs3 ${dp0},${rel3}",
    "cmp a,${dp0}",
    "cmp a,${abs}",
    "cmp a,(x)",
    "cmp a,(${dp0}+x)",
    "cmp a,#${op0}",
    "cmp ${dp1},${dp0}",
    "and1 c,!${mem}:{bit}",
    "ror ${dp0}",
    "ror ${abs}",
    "push y",
    "dbnz ${dp0},${rel3}",
    "ret",
    "bvs ${rel2}",
    "tcall 7",
    "clr3 ${dp0}",
    "bbc3 ${dp0},${rel3}",
    "cmp a,${dp0}+x",
    "cmp a,${abs}+x",
    "cmp a,${abs}+y",
    "cmp a,(${dp0})+y",
    "cmp ${dp1},#${op0}",
    "cmp (x),(y)",
    "addw ya,${dp0}",
    "ror ${dp0}+x",
    "ror a",
    "mov a,x",
    "cmp y,${dp0}",
    "reti",
    "setc",
    "tcall 8",
    "set4 ${dp0}",
    "bbs4 ${dp0},${rel3}",
    "adc a,${dp0}",
    "adc a,${abs}",
    "adc a,(x)",
    "adc a,(${dp0}+x)",
    "adc a,#${op0}",
    "adc ${dp1},${dp0}",
    "eor1 c,${mem}:{bit}",
    "dec ${dp0}",
    "dec ${abs}",
    "mov y,#${op0}",
    "pop p",
    "mov ${dp1},#${op0}",
    "bcc ${rel2}",
    "tcall 9",
    "clr4 ${dp0}",
    "bbc4 ${dp0},${rel3}",
    "adc a,${dp0}+x",
    "adc a,${abs}+x",
    "adc a,${abs}+y",
    "adc a,(${dp0})+y",
    "adc ${dp1},#${op0}",
    "adc (x),(y)",
    "subw ya,${dp0}",
    "dec ${dp0}+x",
    "dec a",
    "mov x,sp",
    "div ya,x",
    "xcn a",
    "ei",
    "tcall 10",
    "set5 ${dp0}",
    "bbs5 ${dp0},${rel3}",
    "sbc a,${dp0}",
    "sbc a,${abs}",
    "sbc a,(x)",
    "sbc a,(${dp0}+x)",
    "sbc a,#${op0}",
    "sbc ${dp1},${dp0}",
    "mov1 c,${mem}:{bit}",
    "inc ${dp0}",
    "inc ${abs}",
    "cmp y,#${op0}",
    "pop a",
    "mov (x)+,a",
    "bcs ${rel2}",
    "tcall 11",
    "clr5 ${dp0}",
    "bbc5 ${dp0},${rel3}",
    "sbc a,${dp0}+x",
    "sbc a,${abs}+x",
    "sbc a,${abs}+y",
    "sbc a,(${dp0})+y",
    "sbc ${dp1},#${op0}",
    "sbc (x),(y)",
    "movw ya,${dp0}",
    "inc ${dp0}+x",
    "inc a",
    "mov sp,x",
    "das a",
    "mov a,(x)+",
    "di",
    "tcall 12",
    "set6 ${dp0}",
    "bbs6 ${dp0},${rel3}",
    "mov ${dp0},a",
    "mov ${abs},a",
    "mov (x),a",
    "mov (${dp0}+x),a",
    "cmp x,#${op0}",
    "mov ${abs},x",
    "mov1 ${mem}:{bit},c",
    "mov ${dp0},y",
    "mov ${abs},y",
    "mov x,#${op0}",
    "pop x",
    "mul ya",
    "bne ${rel2}",
    "tcall 13",
    "clr6 ${dp0}",
    "bbc6 ${dp0},${rel3}",
    "mov ${dp0}+x,a",
    "mov ${abs}+x,a",
    "mov ${abs}+y,a",
    "mov (${dp0})+y,a",
    "mov ${dp0},x",
    "mov ${dp0}+y,x",
    "movw ${dp0},ya",
    "mov ${dp0}+x,y",
    "dec y",
    "mov a,y",
    "cbne ${dp0}+x,${rel3}",
    "daa a",
    "clrv",
    "tcall 14",
    "set7 ${dp0}",
    "bbs7 ${dp0},${rel3}",
    "mov a,${dp0}",
    "mov a,${abs}",
    "mov a,(x)",
    "mov a,(${dp0}+x)",
    "mov a,#${op0}",
    "mov x,${abs}",
    "not1 c,${mem}:{bit}",
    "mov y,${dp0}",
    "mov y,${abs}",
    "notc",
    "pop y",
    "sleep",
    "beq ${rel2}",
    "tcall 15",
    "clr7 ${dp0}",
    "bbc7 ${dp0},${rel3}",
    "mov a,${dp0}+x",
    "mov a,${abs}+x",
    "mov a,${abs}+y",
    "mov a,(${dp0})+y",
    "mov x,${dp0}",
    "mov x,${dp0}+y",
    "mov ${dp1},${dp0}",
    "mov y,${dp0}+x",
    "inc y",
    "mov y,a",
    "dbnz y,${rel2}",
    "stop",
)


# ---------------------------------------------------------------- decode --

def _signed(value):
    return value - 0x100 if value >= 0x80 else value


def _fields(data, offset, address, p):
    first = data[offset + 1] if offset + 1 < len(data) else 0
    second = data[offset + 2] if offset + 2 < len(data) else 0
    absolute = first | (second << 8)
    return {
        "op0": f"{first:02x}",
        "op1": f"{second:02x}",
        "dp0": f"{(p << 8) | first:03x}",
        "dp1": f"{(p << 8) | second:03x}",
        "abs": f"{absolute:04x}",
        "mem": f"{absolute & 0x1FFF:04x}",
        "bit": f"{absolute >> 13:d}",
        "rel2": f"{(address + 2 + _signed(first)) & 0xFFFF:04x}",
        "rel3": f"{(address + 3 + _signed(second)) & 0xFFFF:04x}",
    }


RETURNS = frozenset({"ret", "reti"})

# control-flow classes
JCC = {"bbs", "bbc", "bpl", "bmi", "bvc", "bvs", "bcc", "bcs", "bne", "beq",
       "cbne", "dbnz", "bra"}


def decode(data, offset, address, p=0):
    """Decode one instruction at byte `offset` (loaded at ARAM `address`).

    Returns (address, size, opcode, mnemonic, mode, text, targets) where
    `targets` is the list of branch/call/jump target addresses (ARAM).
    """
    opcode = data[offset]
    mnemonic, mode, size = OPCODES[opcode]
    if offset + size > len(data):
        raise ValueError("truncated instruction at 0x%04X" % address)
    text = TEXT[opcode].format(**_fields(data, offset, address, p))
    first = data[offset + 1] if offset + 1 < len(data) else 0
    second = data[offset + 2] if offset + 2 < len(data) else 0
    targets = []
    if mode in ("rel", "dp_bit_rel"):
        rel = second if mode == "dp_bit_rel" else first
        targets.append((address + size + _signed(rel)) & 0xFFFF)
    elif mode == "dp_rel":            # cbne / dbnz: rel is third byte
        targets.append((address + size + _signed(second)) & 0xFFFF)
    elif mode in ("pcall",):          # pcall $ffNN
        targets.append(0xFF00 | first)
    elif mnemonic == "call":
        targets.append(first | (second << 8))
    elif mnemonic == "jmp":
        if mode == "abs":
            targets.append(first | (second << 8))
        # abs_indirect_x: table base known statically; caller may follow
    elif mnemonic == "tcall":
        targets.append(0xFFC0 + 4 * (opcode >> 4))
    return (address, size, opcode, mnemonic, mode, text, targets)


class Disassembly:
    """Recursive-descent disassembly of a linear image loaded at `base`.

    Seeds are entry points; walk() follows branches/calls/jumps.  Jump
    tables of the form  `jmp (abs,x)` / `call (abs,x)` are followed by
    reading 16-bit handler addresses from `abs` when that region is
    declared a jump table via add_jump_table() (the SPC700 has no way to
    know the table bounds otherwise; the Chrono Trigger driver's tables
    are located by their `sbc #base; asl a; mov y,a; mov.w a,TABLE+y;
    push` dispatch idiom).
    """

    def __init__(self, image, base=0x0200):
        self.image = image
        self.base = base
        self.insn = {}          # aram addr -> decoded tuple
        self.code = set()       # aram addrs known to be instruction starts
        self.jump_tables = {}   # table base aram -> (count, kind)
        self.unreachable = []

    def addr_ok(self, a):
        return self.base <= a < self.base + len(self.image)

    def off(self, a):
        return a - self.base

    def add_jump_table(self, table, count, kind="call"):
        self.jump_tables[table] = (count, kind)
        out = []
        for i in range(count):
            o = self.off(table) + 2 * i
            if o + 2 <= len(self.image):
                out.append(self.image[o] | (self.image[o + 1] << 8))
        return out

    def walk(self, seeds, limit=20000):
        """Recursive descent from seeds; returns number of instructions."""
        todo = [s for s in seeds if self.addr_ok(s)]
        seen = set(todo)
        n = 0
        while todo and n < limit:
            a = todo.pop()
            while self.addr_ok(a) and a not in self.code:
                try:
                    d = decode(self.image, self.off(a), a, p=0)
                except (ValueError, IndexError, KeyError):
                    break
                self.code.add(a)
                self.insn[a] = d
                n += 1
                _a, size, opcode, mnemonic, mode, text, targets = d
                nxt = (a + size) & 0xFFFF
                if mnemonic in RETURNS or mnemonic in ("brk", "stop"):
                    break
                if mnemonic == "jmp" and mode == "abs":
                    todo.extend(targets)
                    break
                if mnemonic in ("jmp", "call") and mode in ("abs_indirect_x", "abs_indirect"):
                    base_t = self.image[self.off(a) + 1] | (self.image[self.off(a) + 2] << 8)
                    if base_t in self.jump_tables:
                        todo.extend(self.add_jump_table(base_t, *self.jump_tables[base_t]))
                    if mnemonic == "call":
                        todo.append(nxt)
                    break
                if mnemonic == "call":
                    todo.append(nxt)
                    todo.extend(targets)
                    break
                if mnemonic in JCC:
                    todo.extend(targets)
                    a = nxt
                    continue
                if mnemonic == "tcall":
                    todo.append(nxt)
                    todo.extend(targets)
                    break
                a = nxt
        return n

    def linear(self, start, end):
        """Decode every byte range as code (for coverage dumps)."""
        a = start
        while a < end:
            if a in self.insn:
                a = self.insn[a][0] + self.insn[a][1]
            else:
                yield a
                a += 1

    def listing(self, start, end):
        out = []
        a = start
        while a < end:
            if a in self.insn:
                d = self.insn[a]
                hexb = self.image[self.off(a):self.off(a) + d[1]].hex()
                out.append("%04X  %-8s %s" % (a, hexb, d[5]))
                a += d[1]
            else:
                out.append("%04X  %02x            ; data?" % (a, self.image[self.off(a)]))
                a += 1
        return out


MIT_LICENSE = """MIT License

Copyright (c) 2026 Gustavo Franco

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


def load_driver_from_rom(rom_path):
    """Return (program_bytes, rom_pc) for the Chrono Trigger SPC driver.

    The block lives at $C7:24C3 as [u16 length][bytes], uploaded to ARAM
    $0200 by Audio_Boot (refs/ChronoRET asm/include/constants_engine.inc
    !AudioRom_SpcDriver / !AudioAram_Driver).
    """
    rom = open(rom_path, "rb").read()
    pc = ((0xC7 & 0x3F) << 16) | 0x24C3
    length = rom[pc] | (rom[pc + 1] << 8)
    return rom[pc + 2:pc + 2 + length], pc


if __name__ == "__main__":
    import sys
    from pathlib import Path
    rom = sys.argv[1] if len(sys.argv) > 1 else \
        str(Path(__file__).resolve().parents[1] / "ct_clean.sfc")
    prog, pc = load_driver_from_rom(rom)
    d = Disassembly(prog, 0x0200)
    # the driver's known dynamic dispatch tables (found by the walk below;
    # see manifests/spc_driver.json for evidence)
    d.add_jump_table(0x1544, 8, "xfer")
    d.add_jump_table(0x1554, 60, "seq")
    d.add_jump_table(0x1608, 60, "peek")
    d.add_jump_table(0x1680, 16, "cmd10")
    d.add_jump_table(0x16A0, 16, "cmdfirst")
    d.add_jump_table(0x16C0, 32, "cmd80")
    n = d.walk([0x0200])
    print("decoded %d instructions, %d bytes of code" %
          (n, sum(d.insn[a][1] for a in d.insn)))
    for line in d.listing(0x073D, 0x075E):
        print(line)
