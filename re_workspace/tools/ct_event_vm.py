#!/usr/bin/env python3
"""Evidence for CTEventVM (macos_studio/Sources/ChronoForgeCore/CTEventVM.swift):
each opcode it models is run two ways on the same concrete WRAM and compared.

  * the ROM's own handler (Evt_OpcodeTable, $C0:5D6E) in ChronoRET's 65816
    interpreter (refs/ChronoRET/tools/absint.py, MIT, Copyright (c) 2026
    Akill), entered as Evt_RunObjScriptSteps enters it (M=1, X=0, DP=$0100,
    DB=$00, Y = the opcode's offset), with every WRAM byte known: the bytes
    given, zero elsewhere, and the multiplier ($4202 x $4203 -> $4216) as the
    hardware computes it;
  * `chronoforge runtime vectors`, CTEventVM's model of the same opcode.

The operand sets are the ones the ROM's packs use (every distinct instruction,
or a seeded sample of them), each over seeded random states of the object
tables, the story bytes and event words, the call-level save table, the
field's direct page, the pad latches and the tile attributes. A case agrees
when both give the same X (where the script goes on), the same carry (on in
this run or not) and the same final value at every WRAM byte either wrote,
leaving out the handlers' DP scratch ($01C1-$01EA, $01EE-$01F7). A handler
that never returns (Sys_HaltWithColor, a loop with no end) must be `halted`
in the model. The interpreter is run with the entry carry clear and set; a
handler whose results differ by it is reported, not compared.

Nothing from the ROM is written out: the report holds counts, opcodes and
offsets. The packs and states pass to the CLI through a temporary file.

  ct_event_vm.py check [--cli PATH] [--per-op N] [--states K] [--ops 12,13]
                       [--json report.json]
  ct_event_vm.py unmodelled [--cli PATH]
"""

import argparse
import json
import random
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
import ct_event_packs as packs  # noqa: E402
import ct_story as story  # noqa: E402

CLI = WS.parent / "macos_studio" / ".build" / "debug" / "chronoforge"
SEED = 0x7F2000
SCRATCH = (range(0x7E01C1, 0x7E01EB), range(0x7E01EE, 0x7E01F8),
           range(0x7E0309, 0x7E0317),     # Decomp_ToWram's own working bytes (Decomp_OutLen is compared)
           range(0x7F3800, 0x7F4400))     # SprBuf: Spr_LoadLargeObj's tile buffer (presentation)
STEP_LIMIT = 3_000_000
EXTERNAL_PCS = (0x070004,                  # $C7:0004 Audio_DriverCommand (the APU handshake)
                0x009E29, 0x00A26B, 0x00A2CE,  # Party_Unk9E29/A26B/A2CE: the field's party routines
                0x003154)                  # Evt_StartTargetFunc2: the touch start the field runs
OBJ_TABLES = (0x0C00, 0x0F00, 0x0F80, 0x1000, 0x1080, 0x1100, 0x1180, 0x1300, 0x1600, 0x1680, 0x1780,
              0x1800, 0x1880, 0x1900, 0x1980, 0x1A00, 0x1A80, 0x1B00, 0x1B80, 0x1C00, 0x1C80)
TILE_OPS = (0x8B, 0x8C, 0x8D, 0x8E, 0x92, 0x96, 0x9C, 0xA0)

# The last full `check` (2026-10-22, default --per-op 24 --states 2): per family the opcodes
# modelled and verified, the operand sets the packs use, and the cases (agree, disagree).
# $3B, $3C and $5D are modelled but no pack uses them. One $83 case (EvtPack_284 $08B6) is
# unverifiable: the ROM handler runs past the interpreter's step limit. test_event_vm.py checks
# these against CTEventVM.families.
EVIDENCE = {
    "animation": {"opcodes": 7, "verified": 7, "operandSets": 99, "cases": 336, "agree": 336, "disagree": 0},
    "calls": {"opcodes": 6, "verified": 6, "operandSets": 144, "cases": 288, "agree": 288, "disagree": 0},
    "characters": {"opcodes": 11, "verified": 11, "operandSets": 69, "cases": 530, "agree": 529, "disagree": 0},
    "conditions": {"opcodes": 26, "verified": 24, "operandSets": 233, "cases": 1161, "agree": 1161, "disagree": 0},
    "field": {"opcodes": 9, "verified": 9, "operandSets": 126, "cases": 432, "agree": 432, "disagree": 0},
    "flow": {"opcodes": 18, "verified": 18, "operandSets": 177, "cases": 864, "agree": 864, "disagree": 0},
    "memory": {"opcodes": 47, "verified": 46, "operandSets": 730, "cases": 2331, "agree": 2331, "disagree": 0},
    "messages": {"opcodes": 7, "verified": 7, "operandSets": 151, "cases": 337, "agree": 337, "disagree": 0},
    "movement": {"opcodes": 11, "verified": 11, "operandSets": 161, "cases": 555, "agree": 555, "disagree": 0},
    "objects": {"opcodes": 22, "verified": 22, "operandSets": 218, "cases": 1083, "agree": 1083, "disagree": 0},
    "party": {"opcodes": 2, "verified": 2, "operandSets": 2, "cases": 96, "agree": 96, "disagree": 0},
    "sound": {"opcodes": 4, "verified": 4, "operandSets": 96, "cases": 192, "agree": 192, "disagree": 0},
    "warps": {"opcodes": 5, "verified": 5, "operandSets": 61, "cases": 246, "agree": 246, "disagree": 0},
}
EVIDENCE_UNMODELLED = {"opcodes": 48, "instructions": 7684, "instructionsInPacks": 142702}


def scratch(a):
    return any(a in r for r in SCRATCH)


def biased(rng):
    r = rng.random()
    if r < 0.35:
        return 0
    if r < 0.45:
        return 1
    if r < 0.55:
        return 0x80
    if r < 0.62:
        return 0xFF
    return rng.randrange(256)


def state(rng, objects, op, e4):
    """[(address, bytes)]: one random WRAM state for a handler of `op`."""
    n = max(1, min(16, objects))
    slot = lambda: 2 * rng.randrange(n)  # noqa: E731
    out = []
    dp = bytearray(biased(rng) for _ in range(0xC0))      # $7E:0100-$01BF (DP_Field)
    dp[0x6D], dp[0x6E] = slot(), 0                          # Obj_Cur
    for p in (0, 2, 4):                                     # Party_ObjSlot words
        dp[0x97 + p], dp[0x98 + p] = (0x80 if rng.random() < 0.3 else slot()), 0
    if True:  # noqa: SIM108                                # Field_E4Ptr0-3 as the location load sets them
        for k in range(4):
            dp[0xAF + 3 * k:0xB2 + 3 * k] = bytes((e4[2 * k], e4[2 * k + 1], 0xE4))
    unk71 = 0x8000 + rng.randrange(0x6000)                  # ObjQ_Unk71: the next free graphics offset
    dp[0x71], dp[0x72] = unk71 & 0xFF, unk71 >> 8
    out.append((0x7E0100, dp))
    lst = bytearray(0xFF if rng.random() < 0.5 else rng.randrange(256) for _ in range(16))
    out.append((0x7E0920, lst + bytearray(slot() for _ in range(16))))    # Evt_Unk0920 / Evt_Unk0930
    out.append((0x7E00F0, bytearray(biased(rng) for _ in range(0x10))))
    for base in OBJ_TABLES:
        t = bytearray(biased(rng) for _ in range(32))
        if base == 0x1C00:                                  # call levels 0-7, Obj_Unk1C01 mostly clear
            for k in range(0, 32, 2):
                t[k] = rng.randrange(8)
                t[k + 1] = 0 if rng.random() < 0.75 else 1
        if base == 0x1600:                                  # Obj_Facing 0-3 (an index into Evt_InFrontTests)
            for k in range(0, 32, 2):
                t[k] = rng.randrange(4)
        if base == 0x1100 and op in (0xAF, 0xB0):            # party kinds 0-2 and one other
            for k in range(0, 32, 2):
                t[k] = rng.randrange(4)
        if base in (0x1800, 0x1880) and op in TILE_OPS:     # tiles inside the attribute block
            for k in range(1, 32, 2):
                t[k] = rng.randrange(16)
        out.append((0x7E0000 | base, t))
    out.append((0x7E1D00, bytearray(biased(rng) for _ in range(0x50))))   # Map_* scroll, origin, drift
    party = bytearray(biased(rng) for _ in range(0x10))  # Party_Members: characters 0-6 or none
    party[0:3] = bytes(rng.choice((0, 1, 2, 3, 4, 5, 6, 0x80)) for _ in range(3))
    out.append((0x7E2980, party))
    out.append((0x7E2A10, bytearray(biased(rng) for _ in range(0x10))))
    out.append((0x7F0000, bytearray(biased(rng) for _ in range(0x400))))  # story bytes, event words
    save = bytearray(0x400)                                 # ObjX_Unk7F0580 + level x $80
    for k in range(0, 0x400, 2):
        if rng.random() < 0.25:
            save[k], save[k + 1] = rng.randrange(256), rng.randrange(256)
    out.append((0x7F0580, save))
    out.append((0x7F0980, bytearray(biased(rng) for _ in range(0x280))))  # ObjX_* $0980-$0BFF
    if op in TILE_OPS:
        out.append((0x7E7000, bytearray(rng.randrange(256) for _ in range(0x1000))))
    return out


def load(rom, table):
    """[(label, data, ops)] for the non-empty packs, and the opcode use counts."""
    out, uses = [], Counter()
    for p in story.load_packs(rom):
        ops, _, _ = packs.decode(table, p["data"])
        uses.update(o[0] for o in ops.values())
        out.append((p["label"], bytes(p["data"]), ops))
    return out, uses


def operand_sets(loaded, wanted, per_op, rng):
    """{op: [(label, y)]}: one instruction per distinct operand bytes, at most per_op."""
    seen = defaultdict(dict)
    for label, data, ops in loaded:
        for y, (op, length, _, _) in sorted(ops.items()):
            if op in wanted:
                seen[op].setdefault(bytes(data[1 + y:1 + y + length]), (label, y))
    out = {}
    for op, by in seen.items():
        sites = list(by.values())
        out[op] = sites if len(sites) <= per_op else rng.sample(sites, per_op)
    return out


class Concrete:
    """absint.Machine with every WRAM byte known (zero unless given) and the
    multiplier modelled; loops are not widened (a concrete state that comes
    back is a loop with no end)."""

    def __init__(self, interp, absint):
        machine = interp.machine
        base = type(machine)

        class Machine(base):
            def read8(self, s, addr):
                if addr is None:
                    return None
                a = absint._wram(addr & 0xFFFFFF)
                if a in s.mem or a in self.known:
                    return base.read8(self, s, addr)
                bank, low = a >> 16, a & 0xFFFF
                if bank in (0x7E, 0x7F):
                    return 0
                if (bank < 0x40 or 0x80 <= bank < 0xC0) and low in (0x4216, 0x4217):
                    f = [v for k, v in s.mem.items() if k & 0xFFFF in (0x4202, 0x4203) and (k >> 16) not in (0x7E, 0x7F)]
                    m = {k & 0xFFFF: v for k, v in s.mem.items() if (k >> 16) not in (0x7E, 0x7F)}
                    if len(f) >= 2 and None not in (m.get(0x4202), m.get(0x4203)) and 0x4206 not in m:
                        p = m[0x4202] * m[0x4203]
                        return p & 0xFF if low == 0x4216 else p >> 8
                    return None
                return base.read8(self, s, addr)

            def write8(self, s, addr, v):
                if addr is not None:
                    a = addr & 0xFFFFFF
                    bank, low = a >> 16, a & 0xFFFF
                    if (bank < 0x40 or 0x80 <= bank < 0xC0) and 0x2180 <= low <= 0x2183:
                        self.wram_port(s, low, v)
                        return
                self.writes += 1
                base.write8(self, s, addr, v)

            def wram_port(self, s, low, v):
                """WMDATA ($2180) writes WRAM at WMADD ($2181-$2183), which then steps on."""
                if v is None or self.wmadd is None:
                    self.wmadd = None
                    if low == 0x2180:
                        raise absint.Unresolved("a WRAM port write with an unknown address or value")
                    return
                if low == 0x2180:
                    self.writes += 1
                    base.write8(self, s, 0x7E0000 + self.wmadd, v)
                    self.wmadd = (self.wmadd + 1) & 0x1FFFF
                elif low == 0x2181:
                    self.wmadd = self.wmadd & 0x1FF00 | v
                elif low == 0x2182:
                    self.wmadd = self.wmadd & 0x100FF | v << 8
                else:
                    self.wmadd = self.wmadd & 0xFFFF | (v & 1) << 16

        code = bytearray(machine.code)
        for pc in EXTERNAL_PCS:             # outside the handler models: run as external calls
            code[pc] = 0
        m = Machine(machine.image, code, max_steps=STEP_LIMIT, callee_steps=STEP_LIMIT)
        interp.machine = m
        self.interp, self.absint, self.machine = interp, absint, m

    def execute(self, s, known):
        """Machine.run for one concrete state: no forks, and a loop is a branch
        reached again with the same registers and no write since (a halt)."""
        m, absint = self.machine, self.absint
        m.known, m.reads, m.control, m.opaque = known, set(), set(), set()
        m.writes, m.wmadd = 0, 0
        s.frames = []
        base, seen = len(s.sp), set()
        for steps in range(1, STEP_LIMIT + 1):
            m._steps = steps
            if m._branchy(s.pc):
                sig = (s.pc, s.a, s.b, s.x, s.y, s.c, s.z, s.n, s.v, s.m, s.xf, s.d, s.db, len(s.sp), m.writes)
                if sig in seen:
                    return None
                seen.add(sig)
            r = m.step(s, base)
            if r is None:
                continue
            if r[0] == "fork":
                raise absint.Unresolved("the handler forks on an unknown (hardware) value")
            if r[0] != "rts":
                raise absint.Unresolved(f"the handler ends with {r[0]}")
            return s
        raise absint.Unresolved("too many steps")

    def run(self, data, y, regions, carry):
        """('go', x, carry, {addr: byte}) / ('halted',) / ('unknown', why)."""
        absint = self.absint
        op = data[1 + y]
        s = absint.State()
        s.pc = self.interp.handlers[op][0]
        s.a, s.b = (op * 2) & 0xFF, (op * 2) >> 8
        s.x, s.y = op * 2, y
        s.d, s.db, s.m, s.xf = 0x0100, 0x00, True, False
        s.z = s.n = s.v = None
        s.c = carry
        s.sp, s.spt, s.mem, s.memt = [], [], {}, {}
        s.at = s.xt = s.yt = s.ft = absint.E
        s.depth = 0
        known = {0x7F2000 + i: b for i, b in enumerate(data)}
        for at, block in regions:
            known.update((at + i, b) for i, b in enumerate(block))
        try:
            st = self.execute(s, known)
        except absint.Unresolved as e:
            return ("unknown", f"interpreter: {e}")
        if st is None:
            return ("halted",)
        mem = {a: v for a, v in st.mem.items() if a >> 16 in (0x7E, 0x7F)}
        if st.x is None or st.c is None or any(v is None for v in mem.values()):
            return ("unknown", "the handler returns an unknown (hardware) value")
        return ("go", st.x, st.c, mem, known)


def compare(rom_out, swift, known):
    """None when they agree, else a short reason (addresses, never bytes of the ROM)."""
    kind = swift["kind"]
    if rom_out[0] == "halted":
        return None if kind == "halted" else f"ROM handler never returns; model says {kind}"
    if kind != "go":
        return f"model says {kind}: {swift.get('reason')}"
    _, x, c, mem, _ = rom_out
    if x != swift["x"]:
        return f"X ${x:04X} vs model ${swift['x']:04X}"
    if c != swift["carry"]:
        return f"carry {int(c)} vs model {int(swift['carry'])}"
    smem = {int(k): v for k, v in swift["mem"].items()}
    for a in sorted(set(mem) | set(smem)):
        if a >> 16 not in (0x7E, 0x7F) or scratch(a):
            continue
        init = known.get(a, 0)
        r, s = mem.get(a, init), smem.get(a, init)
        if r != s:
            return f"WRAM ${a:06X}: ROM {r:#04x} vs model {s:#04x}"
    return None


def check(args):
    rom = packs.read_rom()
    table = json.loads(packs.TABLE.read_text())["opcodes"]
    loaded, uses = load(rom, table)
    by_label = {label: data for label, data, _ in loaded}
    cli = Path(args.cli)
    rng = random.Random(SEED)
    wanted = set(range(256)) if not args.ops else {int(o, 16) for o in args.ops.split(",")}
    sites = operand_sets(loaded, wanted, args.per_op, rng)
    e4 = rom[0x24FFE0:0x24FFE8]                         # RomE4_PtrInit: Field_E4Ptr0-3 low words
    interp, _ = packs.interpreter(rom)
    import absint
    conc = Concrete(interp, absint)
    cases, meta = [], {}
    for op in sorted(sites):
        states = max(args.states, -(-args.per_op * args.states // len(sites[op])))   # few operand sets: more states
        for label, y in sites[op]:
            for _ in range(states):
                objects = by_label[label][0]
                regions = state(rng, objects, op, e4)
                cid = len(cases)
                cases.append({"id": cid, "pack": label, "y": y,
                              "regions": [[at, bytes(b).hex()] for at, b in regions]})
                meta[cid] = (op, label, y, regions)
    used = {c["pack"] for c in cases}
    with tempfile.TemporaryDirectory(prefix="ct-event-vm-") as tmp:
        cin, cout = Path(tmp) / "cases.json", Path(tmp) / "results.json"
        cin.write_text(json.dumps({"packs": {k: by_label[k].hex() for k in sorted(used)}, "cases": cases}))
        r = subprocess.run([str(cli), "runtime", "vectors", str(packs.WS / "ct_clean.sfc"), str(cin), "--out", str(cout)],
                           capture_output=True, text=True, timeout=1800)
        if r.returncode != 0:
            raise SystemExit(f"runtime vectors failed: {r.stdout}{r.stderr}")
        out = json.loads(cout.read_text())
    families, results = out["families"], {r["id"]: r for r in out["results"]}
    family_of = {int(op): f for f, ops in families.items() for op in ops}
    per_op = defaultdict(Counter)
    failures = defaultdict(list)
    for cid, (op, label, y, regions) in meta.items():
        swift = results[cid]
        if op not in family_of:
            per_op[op]["unmodelled"] += 1
            continue
        if swift["kind"] == "unmodelled":
            per_op[op]["declined"] += 1                 # the model stops (e.g. a comparison past the table)
            continue
        data = by_label[label]
        outs = [conc.run(data, y, regions, carry) for carry in (False, True)]
        if outs[0][0] == "unknown":
            per_op[op]["unverifiable"] += 1
            failures[op].append(f"{label} ${y:04X}: {outs[0][1]}")
            continue
        if outs[0][:4] != outs[1][:4]:
            per_op[op]["carry-dependent"] += 1
            continue
        why = compare(outs[0], swift, outs[0][4] if outs[0][0] == "go" else {})
        if why is None:
            per_op[op]["agree"] += 1
            if str(0x7E0306) in swift["mem"]:
                per_op[op]["unpacked"] += 1             # agreed through Decomp_ToWram
            if outs[0][0] == "halted":
                per_op[op]["halts"] += 1
        else:
            per_op[op]["disagree"] += 1
            failures[op].append(f"{label} ${y:04X}: {why}")
    report = {"families": {}, "unmodelled": {}, "failures": {f"{op:02X}": v[:5] for op, v in failures.items()}}
    for fam, ops in sorted(families.items()):
        rows = {f"{op:02X}": dict(per_op[op]) for op in ops if op in per_op}
        report["families"][fam] = {
            "opcodes": len(ops), "opcodesUsed": sum(1 for op in ops if uses[op]),
            "opcodesVerified": sum(1 for op in ops if per_op[op]["agree"] and not per_op[op]["disagree"]),
            "operandSets": sum(len(sites.get(op, [])) for op in ops),
            "cases": sum(sum(n for k, n in per_op[op].items() if k not in ("unpacked", "halts")) for op in ops),
            "agree": sum(per_op[op]["agree"] for op in ops),
            "unpacked": sum(per_op[op]["unpacked"] for op in ops), "halts": sum(per_op[op]["halts"] for op in ops),
            "disagree": sum(per_op[op]["disagree"] for op in ops), "byOpcode": rows}
    modelled = {int(op) for ops in families.values() for op in ops}
    report["unmodelled"] = {f"{op:02X}": n for op, n in uses.most_common() if op not in modelled}
    report["totals"] = {k: sum(f[k] for f in report["families"].values())
                        for k in ("opcodes", "opcodesVerified", "operandSets", "cases", "agree", "disagree")}
    report["totals"]["instructionsInPacks"] = sum(uses.values())
    report["totals"]["instructionsModelled"] = sum(n for op, n in uses.items() if op in modelled)
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    for fam, f in report["families"].items():
        print(f"{fam:<11} {f['opcodesVerified']:3d} of {f['opcodes']:3d} opcodes verified  "
              f"{f['operandSets']:5d} operand sets  {f['agree']:6d} of {f['cases']:6d} cases agree  {f['disagree']} disagree")
    for op, msgs in sorted(failures.items()):
        for m in msgs[:3]:
            print(f"  ${op:02X} {m}")
    t = report["totals"]
    print(f"{t['agree']} of {t['cases']} cases agree; {t['opcodesVerified']} of {t['opcodes']} modelled opcodes verified; "
          f"{t['instructionsModelled']} of {t['instructionsInPacks']} pack instructions are modelled opcodes")
    return 1 if t["disagree"] else 0


def unmodelled(args):
    rom = packs.read_rom()
    table = json.loads(packs.TABLE.read_text())["opcodes"]
    _, uses = load(rom, table)
    with tempfile.TemporaryDirectory(prefix="ct-event-vm-") as tmp:
        cin, cout = Path(tmp) / "cases.json", Path(tmp) / "results.json"
        cin.write_text(json.dumps({"packs": {}, "cases": []}))
        subprocess.run([str(args.cli), "runtime", "vectors", str(packs.WS / "ct_clean.sfc"), str(cin), "--out", str(cout)],
                       check=True, capture_output=True, timeout=120)
        families = json.loads(cout.read_text())["families"]
    modelled = {int(op) for ops in families.values() for op in ops}
    names = {o["opcode"]: o["label"] for o in json.loads((WS / "manifests" / "event_vm_isa.json").read_text())["opcodes"]}
    for op, n in uses.most_common():
        if op not in modelled:
            print(f"${op:02X} {n:6d}  {names.get(op, '')}")
    left = sum(n for op, n in uses.items() if op not in modelled)
    print(f"{sum(1 for op in uses if op not in modelled)} of {len(uses)} opcodes the packs use are unmodelled "
          f"({left} of {sum(uses.values())} instructions)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--cli", default=str(CLI))
    c.add_argument("--per-op", type=int, default=24)
    c.add_argument("--states", type=int, default=2)
    c.add_argument("--ops")
    c.add_argument("--json")
    u = sub.add_parser("unmodelled")
    u.add_argument("--cli", default=str(CLI))
    args = ap.parse_args()
    return check(args) if args.cmd == "check" else unmodelled(args)


if __name__ == "__main__":
    sys.exit(main())
