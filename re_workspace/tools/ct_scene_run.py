#!/usr/bin/env python3
"""Evidence for the Scene Director's VM timeline (CTSceneRun, docs/scene_director.md):

  trace-check   the timeline `chronoforge scene vm` draws equals the one this tool
                derives on its own from `chronoforge runtime run --trace-frames` of
                the same location, frames and input: per object, each bar's offset,
                first and last frame and runs.
  durations     for the movement, animation and wait opcodes, one instruction over
                consecutive frames, run two ways on the same WRAM: the ROM's handler,
                Obj_MoveStep ($C0:AA07) and Obj_AnimTickAndQueue ($C0:C98A) in
                ChronoRET's 65816 interpreter (refs/ChronoRET/tools/absint.py, MIT),
                and `chronoforge scene vm-vectors` (CTEventVM + CTFieldRuntime). Each
                frame: the script timer (Obj_Unk1001 down to Obj_Unk1000) runs the
                handler when it runs out, then the step and the animation tick (the
                frame-build queue empty, as the runtime drains it). A case agrees when
                every frame's X, carry, position, Obj_MoveFrames and animation bytes
                and the frame X moves on are equal.
  formations    Field_Unk0617 ($C0:0617) and FieldBtl_SaveObjs ($C0:04ED) in the
                interpreter against CTSceneFormation.compute on random object tables:
                the battle object list, FieldBtl_ObjSlots and the 8 FieldBtlObj records
                (whose +5 is the enemy id the battle reads, BattleEnemyInit.Id).

Nothing from the ROM is written out: reports hold counts, opcodes and offsets.

  ct_scene_run.py trace-check [--cli PATH] [--locations 29,7] [--frames 600] [--input SCRIPT]
  ct_scene_run.py durations [--cli PATH] [--per-op 4] [--states 2] [--frames 160] [--ops 96,A0]
  ct_scene_run.py formations [--cli PATH] [--cases 200]
"""

import argparse
import json
import random
import re
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
import ct_event_packs as packs  # noqa: E402
import ct_event_vm as evm  # noqa: E402

CLI = WS.parent / "macos_studio" / ".build" / "debug" / "chronoforge"
ROM = WS / "ct_clean.sfc"
SEED = 0x5CE2
LOCATIONS = (29, 7, 1, 6, 19, 49, 71, 100, 200, 300)
MOVE_STEP, ANIM_TICK = 0xC0AA07, 0xC0C98A
FIELD_0617, SAVE_OBJS = 0xC00617, 0xC004ED
DURATION_OPS = {"movement": (0x92, 0x9C, 0x96, 0xA0, 0x94, 0x95, 0x8F),
                "animation": (0xAB, 0xB7),
                "wait": (0xAD, 0xB9, 0xBA, 0xBC, 0xBD)}
DP = 0x7E0100
OBJ_CUR = DP + 0x6D
Q_HEAD, Q_TAIL = DP + 0x76, DP + 0x77
UNK1000, UNK1001, QNEXT, KIND = 0x7E1000, 0x7E1001, 0x7E1081, 0x7E1100
POSX, POSY, MOVEFRAMES, UNK1A80, ARC = 0x7E1800, 0x7E1880, 0x7E1A01, 0x7E1A80, 0x7E1B80
ANIMTIMER, ANIMCOL, ANIMMODE, LOOPS, EVTWAIT, CROSS = 0x7E1601, 0x7E1681, 0x7E1780, 0x7F0B01, 0x7F0A01, 0x7F0B00
ANIMTIMETBL, ANIMROW = 0x7E1580, 0x7E1680

# The last runs (2026-10-22): see the hand-over; test_scene_run.py checks the structure.
EVIDENCE = {
    "trace": {"locations": 10, "agree": 10},
}


def run_cli(*args, timeout=600):
    r = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise SystemExit(f"{' '.join(map(str, args[:3]))} failed: {r.stdout[-400:]}{r.stderr[-400:]}")
    return r.stdout


# MARK: trace-check

TRACE = re.compile(r"^(load|f\d+)\s+obj\s+(\d+) \$([0-9A-F]{4}) ([0-9A-F]{2}) (.*)$")


def trace_steps(text):
    """[(frame, object, offset, opcode, next or None, carry, stop)] from --trace-frames lines."""
    out = []
    for line in text.splitlines():
        m = TRACE.match(line)
        if not m:
            continue
        frame = -1 if m.group(1) == "load" else int(m.group(1)[1:])
        rest = m.group(5)
        nxt, carry, stop = None, False, None
        g = re.match(r"-> \$([0-9A-F]{4})( \(yield\))?", rest)
        if g:
            nxt, carry = int(g.group(1), 16), g.group(2) is None
        else:
            stop = rest.split("  [")[0]
        out.append((frame, int(m.group(2)), int(m.group(3), 16), int(m.group(4), 16), nxt, carry, stop))
    return out


def bars_from_steps(steps):
    """{object: [(offset, start, end or None, runs)]}: an instruction from its first
    run to the run that moved past it; leaving it unfinished ends it there too."""
    lanes = defaultdict(list)
    for frame, obj, off, _op, nxt, _c, stop in steps:
        lane = lanes[obj]
        if lane and lane[-1][2] is None and lane[-1][0] == off:
            o, s, _, runs = lane[-1]
            end = frame if stop is not None or (nxt is not None and nxt != off) else None
            lane[-1] = (o, s, end, runs + 1)
            continue
        if lane and lane[-1][2] is None:
            o, s, _, runs = lane[-1]
            lane[-1] = (o, s, frame, runs)
        end = frame if stop is not None or (nxt is not None and nxt != off) else None
        lane.append((off, frame, end, 1))
    return lanes


def trace_check(args):
    cli = Path(args.cli)
    locs = [int(x) for x in args.locations.split(",")] if args.locations else list(LOCATIONS)
    extra = ["--input", args.input] if args.input else []
    agree, total_bars = 0, 0
    for loc in locs:
        trace = run_cli(cli, "runtime", "run", ROM, loc, "--frames", args.frames, "--trace-frames", *extra)
        derived = bars_from_steps(trace_steps(trace))
        with tempfile.TemporaryDirectory(prefix="ct-scene-run-") as tmp:
            out = Path(tmp) / "vm.json"
            run_cli(cli, "scene", "vm", ROM, loc, "--frames", args.frames, "--no-scroll", "--keep-battles",
                    "--model-anim-loops", "--json",
                    "--out", out, *extra)
            vm = json.loads(out.read_text())
        mine = {lane["object"]: [(b["offset"], b["start"], b.get("end"), b["runs"]) for b in lane["bars"]]
                for lane in vm["lanes"]}
        bad = None
        for obj in sorted(set(mine) | set(derived)):
            a, b = mine.get(obj, []), derived.get(obj, [])
            if a != b:
                k = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
                bad = f"obj {obj} bar {k}: timeline {a[k] if k < len(a) else None} vs trace {b[k] if k < len(b) else None}"
                break
        n = sum(len(v) for v in derived.values())
        total_bars += n
        if bad is None and vm["frames"] == int(args.frames):
            agree += 1
            print(f"location {loc:3d}: {n:5d} bars over {vm['frames']} frames equal the runtime trace")
        else:
            print(f"location {loc:3d}: DIFFERS — {bad or 'frame count'}")
    print(f"{agree} of {len(locs)} locations: the VM timeline equals the runtime trace ({total_bars} bars)")
    return 0 if agree == len(locs) else 1


# MARK: the interpreter on concrete states

def run_routine(conc, pc, known, a=0, x=0, y=0, index8=False, carry=False):
    """('go', x, carry, writes) / ('halted',) / ('unknown', why): one JSR routine or
    handler with every WRAM byte in `known` (zero elsewhere)."""
    absint = conc.absint
    s = absint.State()
    s.pc = pc
    s.a, s.b = a & 0xFF, (a >> 8) & 0xFF
    s.x, s.y = x, y
    s.d, s.db, s.m, s.xf = 0x0100, 0x00, True, index8
    s.z = s.n = s.v = None
    s.c = carry
    s.sp, s.spt, s.mem, s.memt = [], [], {}, {}
    s.at = s.xt = s.yt = s.ft = absint.E
    s.depth = 0
    try:
        st = conc.execute(s, known)
    except absint.Unresolved as e:
        return ("unknown", f"interpreter: {e}")
    if st is None:
        return ("halted",)
    mem = {k: v for k, v in st.mem.items() if k >> 16 in (0x7E, 0x7F)}
    if st.x is None or st.c is None or any(v is None for v in mem.values()):
        return ("unknown", "an unknown (hardware) value")
    return ("go", st.x, st.c, mem)


def word(known, a):
    return known.get(a, 0) | known.get(a + 1, 0) << 8


def setup(rom):
    interp, _ = packs.interpreter(rom)
    import absint
    return evm.Concrete(interp, absint), interp


# MARK: durations

def duration_state(rng, objects, op, e4, period):
    regions = evm.state(rng, objects, op, e4)
    known = {}
    for at, block in regions:
        known.update((at + i, b) for i, b in enumerate(block))
    c = known[OBJ_CUR]
    fix = {KIND + c: 4, UNK1001 + c: 0, UNK1000 + c: period, MOVEFRAMES + c: 0, UNK1A80 + c: 0, ARC + c: 0,
           LOOPS + c: 0, EVTWAIT + c: 0, CROSS + c: 0, ANIMMODE + c: rng.choice((0, 1)), ANIMTIMER + c: rng.randrange(1, 4)}
    if op in DURATION_OPS["animation"]:
        # A real animation set: Obj_AnimTimeTbl from the E4 time-table pointers
        # (Field_E4Ptr3), rows 0-7, so rows end and loops count down.
        rom, ptr3 = e4.rom, e4[6] | e4[7] << 8
        k = rng.randrange(64)
        t = rom[0x240000 + ptr3 + 2 * k] | rom[0x240000 + ptr3 + 2 * k + 1] << 8
        fix.update({ANIMTIMETBL + c: t & 0xFF, ANIMTIMETBL + c + 1: t >> 8, ANIMROW + c: rng.randrange(8)})
    for addr, v in fix.items():
        regions.append((addr, bytearray((v,))))
    return regions, c


class E4(bytes):
    """RomE4_PtrInit's eight bytes, with the ROM they point into."""
    rom = b""


def durations(args):
    rom = packs.read_rom()
    table = json.loads(packs.TABLE.read_text())["opcodes"]
    loaded, _ = evm.load(rom, table)
    by_label = {label: data for label, data, _ in loaded}
    rng = random.Random(SEED)
    wanted_by_family = {f: set(ops) for f, ops in DURATION_OPS.items()}
    if args.ops:
        keep = {int(o, 16) for o in args.ops.split(",")}
        wanted_by_family = {f: ops & keep for f, ops in wanted_by_family.items()}
    wanted = set().union(*wanted_by_family.values())
    sites = evm.operand_sets(loaded, wanted, args.per_op, rng)
    e4 = E4(rom[0x24FFE0:0x24FFE8])
    e4.rom = rom
    cases, meta = [], {}
    for op in sorted(sites):
        for label, y in sites[op]:
            for _ in range(args.states):
                period = rng.choice((1, 2, 4, 4))
                regions, slot = duration_state(rng, by_label[label][0], op, e4, period)
                cid = len(cases)
                cases.append({"id": cid, "pack": label, "y": y, "slot": slot, "frames": args.frames,
                              "regions": [[at, bytes(b).hex()] for at, b in regions if b]})
                meta[cid] = (op, label, y, slot, regions)
    used = {c["pack"] for c in cases}
    with tempfile.TemporaryDirectory(prefix="ct-scene-run-") as tmp:
        cin, cout = Path(tmp) / "cases.json", Path(tmp) / "results.json"
        cin.write_text(json.dumps({"packs": {k: by_label[k].hex() for k in sorted(used)}, "durations": cases,
                                   "formations": []}))
        run_cli(args.cli, "scene", "vm-vectors", ROM, cin, "--out", cout,
                *(["--model-anim-loops"] if args.model_anim_loops else []), timeout=3600)
        out = json.loads(cout.read_text())
    results = {r["id"]: r for r in out["durations"]}
    conc, interp = setup(rom)
    per_op = defaultdict(Counter)
    lengths = defaultdict(list)
    failures = defaultdict(list)
    for cid, (op, label, y, slot, regions) in meta.items():
        swift = results[cid]
        data = by_label[label]
        known = {0x7F2000 + i: b for i, b in enumerate(data)}
        for at, block in regions:
            known.update((at + i, b) for i, b in enumerate(block))
        rows, done, why, x = [], None, None, y
        for f in range(args.frames):
            carry, runs = 0, False
            if known.get(UNK1001 + slot, 0):
                known[UNK1001 + slot] = (known[UNK1001 + slot] - 1) & 0xFF
                runs = known[UNK1001 + slot] == 0
            else:
                runs = True
            if runs:
                known[OBJ_CUR], known[OBJ_CUR + 1] = slot, 0
                opx = data[1 + x] if 1 + x < len(data) else 0
                r = run_routine(conc, interp.handlers[opx][0], known, a=opx * 2, x=opx * 2, y=x)
                if r[0] != "go":
                    why = r[1] if r[0] == "unknown" else "halted"
                    break
                known.update(r[3])
                carry = int(r[2])
                if r[1] != x:
                    done = f
                x = r[1]
                known[UNK1001 + slot] = known.get(UNK1000 + slot, 0)
            known[OBJ_CUR], known[OBJ_CUR + 1] = slot, 0
            r = run_routine(conc, MOVE_STEP, known, x=slot, index8=True)
            if r[0] != "go":
                why = "Obj_MoveStep: " + (r[1] if r[0] == "unknown" else "halted")
                break
            known.update(r[3])
            known[Q_HEAD], known[Q_TAIL], known[QNEXT + slot] = 0x80, 0x80, 0x80
            r = run_routine(conc, ANIM_TICK, known, x=slot, index8=True)
            if r[0] != "go":
                why = "Obj_AnimTickAndQueue: " + (r[1] if r[0] == "unknown" else "halted")
                break
            known.update(r[3])
            rows.append([x, carry, word(known, POSX + slot), word(known, POSY + slot), known.get(MOVEFRAMES + slot, 0),
                         known.get(ANIMTIMER + slot, 0), known.get(ANIMCOL + slot, 0), known.get(LOOPS + slot, 0),
                         known.get(ANIMMODE + slot, 0)])
            if done is not None:
                break
        if why is not None:
            per_op[op]["unverifiable"] += 1
            failures[op].append(f"{label} ${y:04X}: {why}")
            continue
        if "stop" in swift:
            per_op[op]["declined"] += 1
            continue
        if rows == swift["frames"] and done == swift.get("done"):
            per_op[op]["agree"] += 1
            if done is not None:
                per_op[op]["finished"] += 1
                lengths[op].append(done)
        else:
            per_op[op]["disagree"] += 1
            k = next((i for i, (p, q) in enumerate(zip(rows, swift["frames"])) if p != q), min(len(rows), len(swift["frames"])))
            failures[op].append(f"{label} ${y:04X}: frame {k}: ROM {rows[k] if k < len(rows) else None} "
                                f"vs model {swift['frames'][k] if k < len(swift['frames']) else None}")
    report = {}
    for fam, ops in DURATION_OPS.items():
        rows = {f"{op:02X}": dict(per_op[op]) for op in ops if op in per_op}
        report[fam] = {"opcodes": sum(1 for op in ops if per_op[op]["agree"] and not per_op[op]["disagree"]),
                       "of": sum(1 for op in ops if op in sites),
                       "cases": sum(sum(v for k, v in per_op[op].items() if k != "finished") for op in ops),
                       "agree": sum(per_op[op]["agree"] for op in ops),
                       "finished": sum(per_op[op]["finished"] for op in ops),
                       "disagree": sum(per_op[op]["disagree"] for op in ops), "byOpcode": rows}
        print(f"{fam:<10} {report[fam]['opcodes']:2d} of {report[fam]['of']:2d} opcodes  {report[fam]['agree']:4d} of "
              f"{report[fam]['cases']:4d} cases agree frame by frame ({report[fam]['finished']} ran to their end)  "
              f"{report[fam]['disagree']} disagree")
        for op in ops:
            if lengths[op]:
                ls = sorted(lengths[op])
                print(f"   ${op:02X}: {len(ls)} finished, {ls[0]}-{ls[-1]} frames")
    for op, msgs in sorted(failures.items()):
        for m in msgs[:3]:
            print(f"  ${op:02X} {m}")
    agree = sum(f["agree"] for f in report.values())
    cases_n = sum(f["cases"] for f in report.values())
    print(f"{agree} of {cases_n} duration cases agree")
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    return 1 if any(f["disagree"] for f in report.values()) else 0


# MARK: formations

def formation_state(rng):
    n = rng.randrange(1, 17)
    regions = [(0x7F2000, bytearray((n,)))]
    origin_x, origin_y = rng.randrange(0, 0x60), rng.randrange(0, 0x60)
    regions.append((0x7E1D0A, bytearray((origin_x, 0))))
    regions.append((0x7E1D0E, bytearray((origin_y, 0))))
    ox, oy = origin_x >> 1, origin_y >> 1
    tables = {}
    for base in (0x0A00, 0x0A80, 0x0D00, 0x0F00, 0x0F80, 0x1100, 0x1200, 0x1280, 0x1800, 0x1880, 0x1A80):
        tables[base] = bytearray(evm.biased(rng) for _ in range(0x80))
    for s in range(0, 0x80, 2):
        tables[0x1100][s] = rng.choice((5, 5, 6, 6, 4, 7, 0x80))
        tables[0x1800][s + 1] = (ox + rng.randrange(-2, 18)) & 0xFF
        tables[0x1880][s + 1] = (oy + rng.randrange(-2, 16)) & 0xFF
        tables[0x0D00][s] = rng.choice((0x40, 0x48, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xB8, 0xC0, 0x20)) \
            if rng.random() < 0.9 else rng.randrange(256)
        tables[0x0D00][s + 1] = 0
        tables[0x0F00][s] = rng.choice((0, 0, 1, 0x80))
        tables[0x1A80][s + 1] = rng.choice((0, 0, 0x80, 1))
    for base, t in tables.items():
        regions.append((0x7E0000 | base, t))
    return regions


def formations(args):
    rom = packs.read_rom()
    rng = random.Random(SEED + 1)
    cases = [{"id": k, "regions": [[at, bytes(b).hex()] for at, b in formation_state(rng)]} for k in range(args.cases)]
    with tempfile.TemporaryDirectory(prefix="ct-scene-run-") as tmp:
        cin, cout = Path(tmp) / "cases.json", Path(tmp) / "results.json"
        cin.write_text(json.dumps({"packs": {}, "durations": [], "formations": cases}))
        run_cli(args.cli, "scene", "vm-vectors", ROM, cin, "--out", cout)
        out = {r["id"]: r for r in json.loads(cout.read_text())["formations"]}
    conc, _ = setup(rom)
    tally, failures, enemies = Counter(), [], 0
    for c in cases:
        known = {}
        for at, h in c["regions"]:
            known.update((at + i, b) for i, b in enumerate(bytes.fromhex(h)))
        r = run_routine(conc, FIELD_0617, known, index8=True)
        rom_list = []
        if r[0] == "go":
            known.update(r[3])
            for i in range(13):                     # the list before FieldBtl_SaveObjs fills the slots over it
                rom_list.append(known.get(0x7E019D + i, 0))
                if rom_list[-1] & 0x80:
                    break
            r = run_routine(conc, SAVE_OBJS, known)
        if r[0] != "go":
            tally["unverifiable"] += 1
            failures.append(f"case {c['id']}: {r[1] if r[0] == 'unknown' else 'halted'}")
            continue
        known.update(r[3])
        model = out[c["id"]]
        rom_slots = [known.get(0x7E01A3 + i, 0) for i in range(8)]
        rom_records = [known.get(0x7E29BF + i, 0) for i in range(96)]
        model_list = model["list"]
        why = None
        if rom_list != model_list:
            why = f"list {rom_list} vs model {model_list}"
        elif rom_slots != model["slots"]:
            why = f"FieldBtl_ObjSlots {rom_slots} vs model {model['slots']}"
        else:
            # Obj_Unk72B4 (the battle palette-slot claim, not modelled) rewrites Obj_OamAttr
            # before FieldBtl_SaveObj stores it: a participant's Attr byte is left out.
            skip = {12 * r + 8 for r in range(8) if rom_records[12 * r + 7] & 0x80}
            k = next((i for i in range(96) if i not in skip and rom_records[i] != model["records"][i]), None)
            if k is not None:
                why = f"FieldBtlObj byte {k}: ROM {rom_records[k]:#04x} vs model {model['records'][k]:#04x}"
        if why:
            tally["disagree"] += 1
            failures.append(f"case {c['id']}: {why}")
        else:
            tally["agree"] += 1
            enemies += len(model["enemies"])
    for f in failures[:5]:
        print(" ", f)
    print(f"{tally['agree']} of {len(cases)} formation cases agree ({enemies} enemy records); "
          f"{tally['disagree']} disagree, {tally['unverifiable']} unverifiable")
    return 1 if tally["disagree"] else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("trace-check")
    t.add_argument("--cli", default=str(CLI))
    t.add_argument("--locations")
    t.add_argument("--frames", default="600")
    t.add_argument("--input")
    d = sub.add_parser("durations")
    d.add_argument("--cli", default=str(CLI))
    d.add_argument("--per-op", type=int, default=4)
    d.add_argument("--states", type=int, default=2)
    d.add_argument("--frames", type=int, default=160)
    d.add_argument("--ops")
    d.add_argument("--json")
    d.add_argument("--model-anim-loops", action="store_true",
                   help="CTFieldRuntime's default loop count (one a row) instead of the ROM's")
    f = sub.add_parser("formations")
    f.add_argument("--cli", default=str(CLI))
    f.add_argument("--cases", type=int, default=200)
    args = ap.parse_args()
    return {"trace-check": trace_check, "durations": durations, "formations": formations}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
