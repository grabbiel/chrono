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
SCRATCH = (range(0x7E01C1, 0x7E01EB), range(0x7E01EE, 0x7E01F8))
OBJ_TABLES = (0x0C00, 0x0F00, 0x0F80, 0x1000, 0x1080, 0x1100, 0x1180, 0x1300, 0x1600, 0x1680, 0x1780,
              0x1800, 0x1880, 0x1900, 0x1980, 0x1A00, 0x1A80, 0x1B00, 0x1B80, 0x1C00, 0x1C80)
TILE_OPS = (0x8B, 0x8C, 0x8D, 0x8E)


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


def state(rng, objects, op):
    """[(address, bytes)]: one random WRAM state for a handler of `op`."""
    n = max(1, min(16, objects))
    slot = lambda: 2 * rng.randrange(n)  # noqa: E731
    out = []
    dp = bytearray(biased(rng) for _ in range(0xC0))      # $7E:0100-$01BF (DP_Field)
    dp[0x6D], dp[0x6E] = slot(), 0                          # Obj_Cur
    for p in range(9):                                      # Party_ObjSlot
        dp[0x97 + p] = 0x80 if rng.random() < 0.3 else slot()
    out.append((0x7E0100, dp))
    out.append((0x7E00F0, bytearray(biased(rng) for _ in range(0x10))))
    for base in OBJ_TABLES:
        t = bytearray(biased(rng) for _ in range(32))
        if base == 0x1C00:                                  # call levels 0-7, Obj_Unk1C01 mostly clear
            for k in range(0, 32, 2):
                t[k] = rng.randrange(8)
                t[k + 1] = 0 if rng.random() < 0.75 else 1
        if base in (0x1800, 0x1880) and op in TILE_OPS:     # tiles inside the attribute block
            for k in range(1, 32, 2):
                t[k] = rng.randrange(16)
        out.append((0x7E0000 | base, t))
    out.append((0x7E1D00, bytearray(biased(rng) for _ in range(0x50))))   # Map_* scroll, origin, drift
    out.append((0x7E2980, bytearray(biased(rng) for _ in range(0x10))))   # Party_Members
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

        m = Machine(machine.image, machine.code, max_steps=200000, callee_steps=100000)
        m.widen_after = 10 ** 9
        interp.machine = m
        self.interp, self.absint, self.machine = interp, absint, m

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
            ends = self.machine.run(s, known)
        except absint.Unresolved as e:
            return ("unknown", f"interpreter: {e}")
        ends = [st for st, how in ends if how == "rts"]
        if not ends:
            return ("halted",)
        outs = {(st.x, st.c, tuple(sorted(st.mem.items()))) for st in ends}
        if len(outs) > 1:
            return ("unknown", "the handler forks on an unknown (hardware) value")
        x, c, mem = outs.pop()
        if x is None or c is None or any(v is None for _, v in mem):
            return ("unknown", "the handler returns an unknown (hardware) value")
        return ("go", x, c, dict(mem), known)


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
    interp, _ = packs.interpreter(rom)
    import absint
    conc = Concrete(interp, absint)
    cases, meta = [], {}
    for op in sorted(sites):
        for label, y in sites[op]:
            for _ in range(args.states):
                objects = by_label[label][0]
                regions = state(rng, objects, op)
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
            "cases": sum(sum(per_op[op].values()) for op in ops),
            "agree": sum(per_op[op]["agree"] for op in ops),
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
