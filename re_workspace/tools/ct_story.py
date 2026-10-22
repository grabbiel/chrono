#!/usr/bin/env python3
"""Story flags and the world graph, from the event packs and the ROM's code.

`xref` walks every location's event pack with the handler-derived decode
table (ct_event_packs.py) and records each instruction that reads, writes or
tests the story memory at $7F:0000-$7F:01FF (Menu_FlagBlock7F, the 512 bytes
a new game zeroes): bit sets and clears ($65/$66), byte tests ($16, $18),
byte and word reads and writes ($1C, $53-$5A, the long-pointer $48-$4D) and
block copies ($4E). Each record names the locations using the pack, the
object, the functions reaching the instruction, its offset and opcode. The
operand meaning of every opcode is the handler's (event_vm_isa.json; the
ChronoRET handler line is cited per opcode).

Code outside the event VM is found two ways: ChronoRET's matched source
(every instruction naming a $7F:0000-$01FF symbol: code-proven), and a scan
of the ROM for absolute-long instructions addressing $7F:0000-$01FF
(pattern-matched, upgraded to code-proven when the hit lies in a matched
routine whose source has that instruction).

`graph` records every location change an event script performs ($E0 Warp,
$E1/$DF WarpNow, $DD/$DE SetLoc; $E2 takes its destination from variables),
with the flag tests that must hold on every path from the function's entry
to it. Locations $1F0 and up go to bank $C2 (GameLoop_Main's Loc_FirstBankC2):
they seed era groups, which spread to the nearest location over event edges;
the grouping is inferred, never named from game knowledge.

`check --run` re-decodes and reconciles the totals, cites the ISA rows and
ChronoRET lines, and executes the ROM's own $65/$66/$56 handlers on every
distinct operand pair the packs use, with concrete WRAM, to confirm that the
recorded byte and bit change. Outputs hold offsets, counts and numbers only,
never script bytes or text.
"""

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
import ct_event_packs as packs  # noqa: E402

REF = WS / "refs" / "ChronoRET"
LOC_PC, LOC_COUNT, LOC_STRIDE, LOC_EVENTS = 0x360000, 512, 14, 8     # LocRom ($F6:0000), field +8
LOC_FIRST_C2 = 0x1F0                       # Loc_FirstBankC2: GameLoop_Main sends $01F0+ to bank $C2
LOC_ID_MASK = 0x1FF                        # Loc_IdMask
BITSET_PC = 0xFF20                         # BitSet ($00:FF20), the masks $65/$16 use
STORY_END = 0x200                          # Menu_FlagBlock7F: $7F:0000-$01FF
SCHEMA = "ct-story/1"

# Opcode -> how it touches $7F memory. Operand positions count from the opcode byte.
#   bit:   (bitOperand, mOperand)       set/clear, page = bit 7 of the bit operand
#   test:  (mOperand, valueOperand, cmpOperand)  page = bit 7 of cmp
#   fixed: a fixed address (Eng_Unk7F0000)
#   mem:   (mWordOperand, width)        Evt_Mem7F + m
#   long:  (ptrOperand, width)          a 24-bit pointer (only $7F:0000-$01FF kept)
ACCESS = {
    0x65: ("set", "bit", (1, 2)),
    0x66: ("clear", "bit", (1, 2)),
    0x16: ("test", "test", (1, 2, 3)),
    0x18: ("test", "fixed", (0, 1)),
    0x1C: ("read", "mem", (1, 2)),
    0x53: ("read", "mem", (1, 1)),
    0x54: ("read", "mem", (1, 2)),
    0x55: ("read", "fixed", (0, 1)),
    0x56: ("write", "mem", (2, 1)),
    0x58: ("write", "mem", (2, 1)),
    0x59: ("write", "mem", (2, 2)),
    0x5A: ("write", "fixed", (0, 1)),
    0x48: ("read", "long", (1, 1)),
    0x49: ("read", "long", (1, 2)),
    0x4A: ("write", "long", (1, 1)),
    0x4B: ("write", "long", (1, 2)),
    0x4C: ("write", "long", (1, 1)),
    0x4D: ("write", "long", (1, 2)),
    0x4E: ("write", "copy", None),
}
CMP_NAMES = ["=", "!=", ">", "<", ">=", "<=", "and", "or"]   # Evt_CmpTable8
WARPS = {0xE0: "warp", 0xE1: "warpNow", 0xDF: "warpNow", 0xDD: "setLoc", 0xDE: "setLoc", 0xDC: "setPrevLoc",
         0xE2: "warpVars"}
BRANCH_TESTS = (0x16, 0x18)                # flag guards: the memory tests


class StoryError(ValueError):
    pass


def hexaddr(addr):
    return f"7F:{addr:04X}"


# ── Locations and packs ─────────────────────────────────────────────────────

def location_events(rom):
    """Evt_PackPtrs entry of each of the 512 locations (LocRom +8)."""
    return [rom[LOC_PC + LOC_STRIDE * i + LOC_EVENTS] | rom[LOC_PC + LOC_STRIDE * i + LOC_EVENTS + 1] << 8
            for i in range(LOC_COUNT)]


def load_packs(rom):
    """[{label, pointerIndices, data, locations}] for every non-empty pack."""
    unpacked, _ = packs.unpack_all(rom)
    by_entry = defaultdict(list)
    for loc, entry in enumerate(location_events(rom)):
        by_entry[entry].append(loc)
    out = []
    for p in unpacked:
        if not p["data"]:
            continue
        locs = sorted(loc for i in p["pointerIndices"] for loc in by_entry.get(i, []))
        out.append({"label": p["label"], "pointerIndices": p["pointerIndices"], "data": p["data"], "locations": locs})
    return out


def function_edges(data, ops, f, y, phase):
    """Successors of instruction y in function f as [(offset, phase, outcome)].
    Phase 0 runs to the first $00; in function 0 (Evt_RunObjInit) the object then
    goes on at the next byte, phase 1, where a $00 stops it. outcome is (y, True)
    for a memory test's fall-through (it held), (y, False) for its jump."""
    op, length, flow, target = ops[y]
    if op == 0:
        return [(y + 1, 1, None)] if f == 0 and phase == 0 and y + 1 < len(data) - 1 else []
    test = op in BRANCH_TESTS
    out = [(y + length, phase, (y, True) if test else None)] if "n" in flow else []
    return out + ([(target, phase, (y, False) if test else None)] if target is not None else [])


def function_nodes(data, ops, f, start):
    nodes, todo = set(), [(start, 0)]
    while todo:
        node = todo.pop()
        if node in nodes or node[0] not in ops:
            continue
        nodes.add(node)
        todo += [(t, ph) for t, ph, _ in function_edges(data, ops, f, *node)]
    return nodes


def function_reach(data, ops, funcs):
    """{offset: [(object, function)]} of the functions reaching each instruction
    (function 0 includes the part after its first $00)."""
    reach = defaultdict(set)
    for o, obj in enumerate(funcs):
        for f, start in enumerate(obj):
            if start in ops:
                for y, _ in function_nodes(data, ops, f, start):
                    reach[y].add((o, f))
    return {y: sorted(v) for y, v in reach.items()}


def decode_access(data, y, op, bitset):
    """[(kind, addr, bit, width, detail)] of the $7F:0000-$01FF bytes `op` at
    Evt_Data offset y touches (empty when it addresses other memory)."""
    kind, mode, args = ACCESS[op]
    b = lambda k: data[1 + y + k]                       # noqa: E731
    w = lambda k: b(k) | b(k + 1) << 8                  # noqa: E731
    if mode == "bit":
        bit_operand, m = b(args[0]), b(args[1])
        addr, number = m + (0x100 if bit_operand & 0x80 else 0), bit_operand & 0x0F
        mask = bitset[number]
        bits = [i for i in range(8) if mask >> i & 1]
        detail = {"bitOperand": bit_operand}
        if number > 7:
            detail["bitNumberPastBitSet"] = number
        return [(kind, addr, bits[0] if len(bits) == 1 else None, 1, {**detail, "mask": mask})]
    if mode == "test":
        m, value, cmp = b(args[0]), b(args[1]), b(args[2])
        addr, c = m + (0x100 if cmp & 0x80 else 0), cmp & 0x7F
        bit = value.bit_length() - 1 if c == 6 and value and value & (value - 1) == 0 else None
        return [(kind, addr, bit, 1, {"cmp": CMP_NAMES[c] if c < 8 else c, "value": value})]
    if mode == "fixed":
        detail = {"cmp": "<", "value": b(1)} if op == 0x18 else {}
        return [(kind, 0, None, 1, detail)]
    if mode == "mem":
        addr, width = w(args[0]), args[1]
        return [(kind, addr, None, width, {})] if addr < STORY_END else []
    if mode == "long":
        ptr, width = b(args[0]) | b(args[0] + 1) << 8 | b(args[0] + 2) << 16, args[1]
        return [(kind, ptr & 0xFFFF, None, width, {"long": True})] if ptr >> 16 == 0x7F and ptr & 0xFFFF < STORY_END else []
    # $4E CopyData: dst (word), bank, len (word) counting itself and the data.
    dst, bank, length = w(1), b(3), w(4)
    if bank == 0x7E or dst >= STORY_END:
        return []
    return [(kind, dst, None, max(0, length - 2), {"copy": True})]


def xref(rom, table=None):
    """Every $7F:0000-$01FF access in the event packs, and the warps."""
    table = table or json.loads(packs.TABLE.read_text())["opcodes"]
    bitset = rom[BITSET_PC:BITSET_PC + 16]
    refs, warps, totals = [], [], Counter()
    for p in load_packs(rom):
        data = p["data"]
        ops, _, funcs = packs.decode(table, data)
        reach = function_reach(data, ops, funcs)
        totals["instructions"] += len(ops)
        guards = guard_sets(data, ops, funcs) if any(ops[y][0] in WARPS for y in ops) else {}
        for y in sorted(ops):
            op = ops[y][0]
            where = {"pack": p["label"], "locations": p["locations"], "offset": y, "opcode": op,
                     "functions": [list(of) for of in reach.get(y, [])]}
            if op in ACCESS:
                for kind, addr, bit, width, detail in decode_access(data, y, op, bitset):
                    refs.append({**where, "kind": kind, "addr": addr, "bit": bit, "width": width, **detail})
                    totals[f"op{op:02X}"] += 1
            if op in WARPS:
                warps.append({**where, **warp_operands(data, y, op), "guards": guards.get(y, [])})
    totals["refs"] = len(refs)
    totals["warps"] = len(warps)
    return refs, warps, dict(totals)


# ── Warps and their guards ──────────────────────────────────────────────────

def warp_operands(data, y, op):
    b = lambda k: data[1 + y + k]                       # noqa: E731
    if op == 0xE2:                                      # destination in event words
        return {"kind": WARPS[op], "dest": None, "vars": [b(1), b(2), b(3), b(4)]}
    word = b(1) | b(2) << 8
    return {"kind": WARPS[op], "dest": word & LOC_ID_MASK, "x": b(3), "y": b(4),
            "facing": (word >> 9) & 0x0F, "facingBit7": bool(word & 0x8000)}


def guard_sets(data, ops, funcs):
    """{offset: [guard]}: the memory tests whose outcome holds on every path
    from a function entry to the warp at offset (a forward must-analysis per
    function, intersected over the functions reaching it). A guard is
    {offset, opcode, addr, bit, cmp, value, holds}: holds = the fall-through
    (the condition held), else its jump was taken."""
    result = {}
    for obj in funcs:
        for f, start in enumerate(obj):
            if start not in ops:
                continue
            nodes = function_nodes(data, ops, f, start)
            facts = dict.fromkeys(nodes)                 # None: not reached yet (the universe)
            facts[(start, 0)] = frozenset()
            work = [(start, 0)]
            while work:
                node = work.pop()
                for t, ph, cond in function_edges(data, ops, f, *node):
                    nxt = (t, ph)
                    if nxt not in facts:
                        continue
                    out = facts[node] | {cond} if cond else facts[node]
                    new = frozenset() if nxt == (start, 0) else out if facts[nxt] is None else facts[nxt] & out
                    if new != facts[nxt]:
                        facts[nxt] = new
                        work.append(nxt)
            for (y, _), fact in facts.items():
                if ops[y][0] in WARPS and fact is not None:
                    result[y] = fact if y not in result else result[y] & fact
    out = {}
    for y, conds in result.items():
        rows = []
        for t, holds in sorted(conds):
            op = ops[t][0]
            _, addr, bit, _, detail = decode_access(data, t, op, None)[0]   # tests need no BitSet
            rows.append({"offset": t, "opcode": op, "addr": addr, "bit": bit, **detail, "holds": holds})
        out[y] = rows
    return out


# ── The world graph ─────────────────────────────────────────────────────────

def world_graph(warps):
    """Nodes (locations), edges (one per warp with a known destination) and
    inferred era groups: each bank-$C2 location ($1F0+) seeds a group; other
    locations join the nearest seed over undirected event edges (ties and
    unreached locations stay ungrouped). Edges between groups are marked
    cross-group (candidate time travel, inferred)."""
    edges = []
    for w in warps:
        if w["dest"] is None or w["kind"] == "setPrevLoc":
            continue
        for src in w["locations"]:
            edges.append({"from": src, "to": w["dest"], "kind": w["kind"], "pack": w["pack"],
                          "offset": w["offset"], "x": w["x"], "y": w["y"], "guards": w["guards"]})
    adj = defaultdict(set)
    for e in edges:
        if e["from"] != e["to"]:
            adj[e["from"]].add(e["to"])
            adj[e["to"]].add(e["from"])
    seeds = sorted({n for e in edges for n in (e["from"], e["to"]) if n >= LOC_FIRST_C2})
    dist = {}
    for s in seeds:                                      # one BFS per seed
        d, frontier = {s: 0}, [s]
        while frontier:
            nxt = []
            for n in frontier:
                for m in adj[n]:
                    if m not in d and m < LOC_FIRST_C2:
                        d[m] = d[n] + 1
                        nxt.append(m)
            frontier = nxt
        dist[s] = d
    group = {}
    for n in sorted({x for e in edges for x in (e["from"], e["to"])} | set(range(LOC_COUNT))):
        if n >= LOC_FIRST_C2:
            group[n] = n if n in seeds else None
            continue
        best = sorted((dist[s][n], s) for s in seeds if n in dist[s])
        group[n] = best[0][1] if best and (len(best) == 1 or best[0][0] < best[1][0]) else None
    for e in edges:
        a, b = group.get(e["from"]), group.get(e["to"])
        e["crossGroup"] = a is not None and b is not None and a != b
    hubs = sorted(n for n in adj if len({group.get(m) for m in adj[n]} - {None}) >= 3)
    return {"edges": edges, "groups": {str(k): v for k, v in group.items()}, "seeds": seeds, "hubs": hubs}


# ── Code outside the event VM ───────────────────────────────────────────────

LONG_OPS = {0x0F: "ORA", 0x1F: "ORA", 0x2F: "AND", 0x3F: "AND", 0x4F: "EOR", 0x5F: "EOR", 0x6F: "ADC",
            0x7F: "ADC", 0x8F: "STA", 0x9F: "STA", 0xAF: "LDA", 0xBF: "LDA", 0xCF: "CMP", 0xDF: "CMP",
            0xEF: "SBC", 0xFF: "SBC"}
READS = {"LDA", "LDX", "LDY", "CMP", "CPX", "CPY", "BIT", "ORA", "AND", "EOR", "ADC", "SBC", "PEI"}
WRITES = {"STA", "STX", "STY", "STZ"}
RMW = {"TSB", "TRB", "INC", "DEC", "ASL", "LSR", "ROL", "ROR"}
DEFINE = re.compile(r"^!(\w+)\s*=\s*\$7F(0[01][0-9A-Fa-f]{2})\b")
HEADER = re.compile(r"^; \$([0-9A-F]{2}):([0-9A-F]{4}) — (\w+) \((\d+) bytes")
INSN = re.compile(r"^\s+([A-Z]{3})(?:\.([bwl]))?\s+([^;]+)")
GLOBAL = re.compile(r"^([A-Za-z_]\w*):")


def chronoret_defines(ref=REF):
    """{symbol: address} of every ChronoRET define in $7F:0000-$01FF."""
    out = {}
    for path in sorted((ref / "asm").rglob("*")):
        if path.suffix not in (".inc", ".asm"):
            continue
        for line in path.read_text(errors="replace").splitlines():
            m = DEFINE.match(line)
            if m:
                out[m.group(1)] = int(m.group(2), 16)
    return out


def chronoret_uses(ref=REF):
    """Instructions in the matched source naming a $7F:0000-$01FF symbol:
    [{file, line, routine, mnemonic, size, addr, indexed, access}], and the
    routines' address ranges from their headers."""
    defines = chronoret_defines(ref)
    names = sorted(defines, key=len, reverse=True)
    pattern = re.compile(r"!(" + "|".join(map(re.escape, names)) + r")\b(\+\$?[0-9A-Fa-f]+)?") if names else None
    uses, routines = [], []
    for path in sorted((ref / "asm").rglob("*.asm")):
        rel = str(path.relative_to(ref))
        routine = None
        for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            h = HEADER.match(line)
            if h:
                start = int(h.group(1), 16) << 16 | int(h.group(2), 16)
                routines.append({"name": h.group(3), "start": start, "end": start + int(h.group(4)),
                                 "file": rel, "line": n})
            g = GLOBAL.match(line)
            if g:
                routine = g.group(1)
            i = INSN.match(line)
            if not i or not pattern:
                continue
            m = pattern.search(i.group(3))
            if not m:
                continue
            offset = m.group(2) or "+0"
            offset = int(offset[2:], 16) if offset.startswith("+$") else int(offset[1:], 10 if offset[1:].isdigit() else 16)
            mnemonic = i.group(1)
            access = "read" if mnemonic in READS else "write" if mnemonic in WRITES else "rmw" if mnemonic in RMW \
                else "other"
            uses.append({"file": rel, "line": n, "routine": routine, "mnemonic": mnemonic, "size": i.group(2),
                         "symbol": m.group(1), "addr": defines[m.group(1)] + offset,
                         "indexed": bool(re.search(r",\s*[XY]\b", i.group(3))), "access": access})
    return uses, routines


def rom_long_hits(rom):
    """Absolute-long instructions with operand $7F:0000-$01FF anywhere in the ROM
    (a byte pattern: it also matches data)."""
    hits = []
    for pc in range(len(rom) - 3):
        op = rom[pc]
        if op in LONG_OPS and rom[pc + 3] == 0x7F and rom[pc + 2] < 2:
            hits.append({"pc": pc, "snes": 0xC00000 | pc, "mnemonic": LONG_OPS[op], "indexed": bool(op & 0x10),
                         "addr": rom[pc + 1] | rom[pc + 2] << 8})
    return hits


def code_refs(rom, ref=REF):
    """Non-event code touching the story memory: the source's instructions
    (code-proven) and the ROM's long-address patterns, each pattern marked
    code-proven when it lies in a matched routine whose source has the same
    mnemonic on the same address, else pattern-matched."""
    uses, routines = chronoret_uses(ref)
    routines.sort(key=lambda r: r["start"])
    starts = [r["start"] for r in routines]
    import bisect
    by_routine = defaultdict(set)
    for u in uses:
        by_routine[u["routine"]].add((u["mnemonic"], u["addr"]))
    hits = []
    for h in rom_long_hits(rom):
        i = bisect.bisect_right(starts, h["snes"]) - 1
        r = routines[i] if i >= 0 and routines[i]["start"] <= h["snes"] < routines[i]["end"] else None
        h["routine"] = r["name"] if r else None
        h["status"] = "code-proven" if r and (h["mnemonic"], h["addr"]) in by_routine[r["name"]] else \
            "in-routine" if r else "pattern-matched"
        hits.append(h)
    return {"source": uses, "romPatterns": hits}


# ── Evidence: ISA rows, ChronoRET lines, handler execution ─────────────────

def isa_citations(ref=REF):
    """{opcode: {isa, handler, chronoret}}: the event_vm_isa.json row and the
    handler's label line in ChronoRET for every opcode the scan uses."""
    isa = json.loads((WS / "manifests" / "event_vm_isa.json").read_text())["opcodes"]
    src = (ref / "asm" / "bankC0" / "bankC0.asm").read_text().splitlines()
    lines = {line[:-1]: n for n, line in enumerate(src, 1) if line.endswith(":") and not line.startswith(" ")}
    out = {}
    for op in sorted(set(ACCESS) | set(WARPS)):
        row = isa[op]
        out[op] = {"isa": f"event_vm_isa.json opcodes[{op}] {row['opcode_hex']} {row['label']}",
                   "handler": row["handler_snes"],
                   "chronoret": f"asm/bankC0/bankC0.asm:{lines[row['label']]}" if row["label"] in lines else None}
    return out


def run_handlers(rom, refs, table=None):
    """Execute the ROM's $65/$66/$56 handler on every distinct operand set the
    packs use (in a one-instruction synthetic pack, concrete WRAM): the byte
    written must be the recorded address, changed as recorded. Returns the
    number of operand sets confirmed."""
    interp, events = packs.interpreter(rom)
    import absint
    seen, confirmed = set(), 0
    for r in refs:
        op = r["opcode"]
        if op not in (0x65, 0x66, 0x56):
            continue
        key = (op, r["addr"], r.get("bitOperand"), r.get("mask"))
        if key in seen:
            continue
        seen.add(key)
        if op == 0x56:
            operands = [0x5A, r["addr"] & 255, r["addr"] >> 8]
        else:
            operands = [r["bitOperand"], r["addr"] & 0xFF]
        data, y = packs.synthetic(op, operands)
        addr = 0x7F0000 + r["addr"]
        for before in (0x00, 0xFF, 0xA5):
            ends = execute(interp, absint, data, y, {addr: before})
            if len(ends) != 1 or ends[0][0] != y + (4 if op == 0x56 else 3):
                raise StoryError(f"${op:02X} {operands}: does not go on ({ends})")
            written = {k: v for k, v in ends[0][2].items() if k >> 16 == 0x7F and k & 0xFFFF < STORY_END}
            want = 0x5A if op == 0x56 else before | r["mask"] if op == 0x65 else before & ~r["mask"] & 0xFF
            if written != {addr: want}:
                raise StoryError(f"${op:02X} {operands} before {before:02X}: wrote {written}, recorded {hexaddr(r['addr'])}"
                                 f" -> {want:02X}")
        confirmed += 1
    return confirmed


def execute(interp, absint, data, y, memory):
    """[(X after the handler, carry, {address: byte written})] of the opcode at
    Evt_Data offset y (as macos_studio/tools/verify_event_lowering.py)."""
    op = data[1 + y]
    s = absint.State()
    s.pc = interp.handlers[op][0]
    s.a, s.b = (op * 2) & 0xFF, (op * 2) >> 8
    s.x, s.y = op * 2, y
    s.d, s.db, s.m, s.xf = 0x0100, 0x00, True, False
    s.z = s.n = s.v = None
    s.c = True
    s.sp, s.spt, s.mem, s.memt = [], [], {}, {}
    s.at = s.xt = s.yt = s.ft = absint.E
    s.depth = 0
    known = {0x7F2000 + i: b for i, b in enumerate(data)}
    known.update(memory)
    return [(st.x, st.c, dict(st.mem)) for st, how in interp.machine.run(s, known) if how == "rts"]


# ── Summaries ───────────────────────────────────────────────────────────────

def flag_table(refs):
    """{(addr, bit)}: kinds and counts. bit None = the byte as a whole."""
    out = defaultdict(Counter)
    for r in refs:
        width = r["width"] if r["kind"] != "write" or not r.get("copy") else r["width"]
        for a in range(r["addr"], min(STORY_END, r["addr"] + max(1, width))):
            out[(a, r["bit"] if a == r["addr"] else None)][r["kind"]] += 1
    return out


def summary(refs, warps, totals, graph=None, code=None):
    table = flag_table(refs)
    bits = sorted(k for k in table if k[1] is not None)
    bytes_used = sorted({a for a, _ in table})
    out = {"schema": SCHEMA, "totals": totals,
           "bitFlags": len(bits), "bytesTouched": len(bytes_used), "bytesUnused": STORY_END - len(bytes_used),
           "setOnly": sum(1 for k in bits if set(table[k]) == {"set"}),
           "testedNeverWritten": sum(1 for k in bits if set(table[k]) <= {"test"}),
           "byKind": dict(Counter(r["kind"] for r in refs))}
    if graph:
        out["graph"] = {"edges": len(graph["edges"]), "seeds": len(graph["seeds"]), "hubs": len(graph["hubs"]),
                        "grouped": sum(1 for v in graph["groups"].values() if v is not None),
                        "crossGroupEdges": sum(1 for e in graph["edges"] if e["crossGroup"]),
                        "guardedEdges": sum(1 for e in graph["edges"] if e["guards"])}
    if code:
        out["code"] = {"sourceInstructions": len(code["source"]),
                       "romPatterns": dict(Counter(h["status"] for h in code["romPatterns"]))}
    return out


def check(rom, run=False, log=print):
    """Reconcile the cross-reference with an independent re-count, cite the
    evidence and (with run) execute the handlers."""
    table = json.loads(packs.TABLE.read_text())["opcodes"]
    records = {r["label"]: r for r in json.loads(packs.PACKS.read_text())["packs"]}
    refs, warps, totals = xref(rom, table)
    # 1. Instructions decoded == the verified per-pack counts.
    want = sum(r.get("instructions", 0) for r in records.values())
    if totals["instructions"] != want:
        raise StoryError(f"decoded {totals['instructions']} instructions, verification records {want}")
    # 2. An independent count: every reachable instruction whose opcode is a
    #    memory or warp opcode, from the pack bytes (no access decoding).
    raw = Counter()
    for p in load_packs(rom):
        ops, _, _ = packs.decode(table, p["data"])
        for y, (op, *_rest) in ops.items():
            if op in ACCESS or op in WARPS:
                raw[op] += 1
    per_op = Counter(r["opcode"] for r in refs)
    for op in (0x65, 0x66, 0x16, 0x18, 0x55, 0x5A):    # always within $7F:0000-$01FF
        if per_op[op] != raw[op]:
            raise StoryError(f"${op:02X}: {per_op[op]} references vs {raw[op]} instructions")
    if sum(raw[op] for op in WARPS) != len(warps):
        raise StoryError("warp count mismatch")
    # 3. The BitSet masks are single bits for 0-7 (the ROM's table).
    bitset = rom[BITSET_PC:BITSET_PC + 8]
    if list(bitset) != [1 << i for i in range(8)]:
        raise StoryError("BitSet at $00:FF20 is not 01 02 .. 80")
    cites = isa_citations()
    missing = [op for op, c in cites.items() if not c["chronoret"]]
    if missing:
        raise StoryError(f"no ChronoRET handler line for {missing}")
    log(f"xref: {totals['refs']} references in {totals['instructions']} instructions; {len(warps)} location changes")
    log(f"ISA rows and ChronoRET handler lines cited for {len(cites)} opcodes")
    code = code_refs(rom)
    log(f"code: {len(code['source'])} source instructions; ROM patterns "
        f"{dict(Counter(h['status'] for h in code['romPatterns']))}")
    confirmed = run_handlers(rom, refs, table) if run else 0
    if run:
        log(f"handlers: {confirmed} of {confirmed} distinct $65/$66/$56 operand sets change the recorded byte")
    return {"refs": refs, "warps": warps, "totals": totals, "code": code, "cites": cites, "confirmed": confirmed}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("xref", "graph", "code", "check"):
        p = sub.add_parser(name)
        p.add_argument("--rom", default=str(WS / "ct_clean.sfc"))
        p.add_argument("--out", help="write the full JSON here (game metadata: keep it local)")
        if name == "check":
            p.add_argument("--run", action="store_true", help="execute the ROM's handlers too")
    args = parser.parse_args()
    rom = packs.read_rom(args.rom)
    if args.command == "check":
        result = check(rom, run=args.run)
        doc = {"summary": summary(result["refs"], result["warps"], result["totals"], world_graph(result["warps"]),
                                  result["code"]),
               "citations": {f"${k:02X}": v for k, v in result["cites"].items()},
               "handlerOperandSetsConfirmed": result["confirmed"]}
        print(json.dumps(doc["summary"], indent=1))
        if args.out:
            Path(args.out).write_text(json.dumps(doc, indent=1) + "\n")
        print("OK")
        return 0
    refs, warps, totals = xref(rom)
    if args.command == "xref":
        doc = {"schema": SCHEMA, "summary": summary(refs, warps, totals), "refs": refs}
    elif args.command == "graph":
        g = world_graph(warps)
        doc = {"schema": SCHEMA, "summary": summary(refs, warps, totals, g), "warps": warps, **g}
    else:
        doc = {"schema": SCHEMA, **code_refs(rom)}
    if args.out:
        Path(args.out).write_text(json.dumps(doc, indent=1) + "\n")
    print(json.dumps(doc.get("summary", {k: len(v) for k, v in doc.items() if isinstance(v, list)}), indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
