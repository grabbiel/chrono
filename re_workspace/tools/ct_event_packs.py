#!/usr/bin/env python3
"""Location event packs (Evt_PackPtrs) and a table-driven decoder for them.

`derive` (slow, minutes) traces every opcode handler in the user's ROM with
ChronoRET's abstract interpreter (refs/ChronoRET/tools/absint.py + events.py,
MIT, Copyright (c) 2026 Akill) to learn each opcode's length, control flow
and jump encoding. The matched source is only used for opcode names; the code
traced is the ROM's own (no assembler needed). Opcodes whose shape depends on
an operand ($2E, $4E, $88, $F1, $FF) are swept over every value of the byte
that decides it. The result is a decode table (manifests/event_decode_table.json)
and a generated Swift twin (CTEventISA.swift).

Every one of the 462 event packs is then disassembled two ways, by the
handler traces and by the table alone, and both must reach the same opcodes;
re-encoding every jump from its target must give back the ROM bytes.
manifests/event_pack_verification.json keeps metadata only (hashes, counts).

`check` (fast) re-runs the table-driven half against the committed outputs.
"""

import argparse
import csv
import hashlib
import json
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
REF = WS / "refs" / "ChronoRET"
ROM_SHA256 = "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9"
PTRS_PC, PTR_COUNT = 0x3CF9F0, 513          # Evt_PackPtrs ($FC:F9F0), 513 x 24-bit
OPTABLE_PC = 0x5D6E                         # Evt_OpcodeTable ($C0:5D6E)
FUNCS = 16
TABLE = WS / "manifests" / "event_decode_table.json"
PACKS = WS / "manifests" / "event_pack_verification.json"
SWIFT = WS.parent / "macos_studio" / "Sources" / "ChronoForgeCore" / "CTEventISA.swift"
VARIABLE = (0x2E, 0x4E, 0x88, 0xF1, 0xFF)
sys.path.insert(0, str(WS / "tools"))


class PackError(ValueError):
    pass


def sha(data):
    return hashlib.sha256(bytes(data)).hexdigest()


def read_rom(path=WS / "ct_clean.sfc"):
    data = Path(path).read_bytes()
    if len(data) != 0x400000 or sha(data) != ROM_SHA256:
        raise PackError("Expected the pinned 4 MiB unheadered Chrono Trigger US ROM")
    return data


def pointer_entries(rom):
    return [int.from_bytes(rom[PTRS_PC + 3 * i:PTRS_PC + 3 * i + 3], "little") for i in range(PTR_COUNT)]


def to_pc(snes):
    return ((snes >> 16) & 0x3F) << 16 | (snes & 0xFFFF)


def event_pieces():
    """(label, pc, surveyed end pc, mode, size) of every events piece."""
    rows = csv.reader(line for line in (REF / "symbols" / "data_assets.csv").open() if not line.startswith("#"))
    out = []
    for row in rows:
        if len(row) > 6 and row[4] == "events":
            mode, size = row[6].split(" -> ")
            bank, low = row[1][1:].split(":")
            bank2, low2 = row[2][1:].split(":")
            out.append((row[0], (int(bank, 16) & 0x3F) << 16 | int(low, 16),
                        (int(bank2, 16) & 0x3F) << 16 | int(low2, 16), mode, int(size.split()[0])))
    return out


# ── Table-driven decoding (the same algorithm as CTEventPack.swift) ─────────

def resolve(entry, data, at):
    """(length, flow) of the opcode at data[at], or None."""
    shape = entry["shape"]
    while True:
        if "halt" in shape or "unknown" in shape:
            return None
        if "length" in shape:
            return shape["length"], shape["flow"]
        if "counted" in shape:
            k, add = shape["counted"]["operand"], shape["counted"]["add"]
            if at + k + 1 >= len(data):
                return None
            return add + (data[at + k] | data[at + k + 1] << 8), shape["flow"]
        k = shape["kind"]
        if at + k >= len(data):
            return None
        shape = shape["cases"][data[at + k]]


def decode(table, data):
    """{offset: (opcode, length, flow, target)}, entries, functions."""
    if not data:
        raise PackError("an empty pack")
    n = data[0]
    head, size = n * 2 * FUNCS, len(data) - 1
    if 1 + head > len(data):
        raise PackError(f"{n} objects need {head} header bytes")
    funcs = [[data[1 + o * 32 + 2 * f] | data[2 + o * 32 + 2 * f] << 8 for f in range(FUNCS)] for o in range(n)]
    ops, entries, done = {}, {f for obj in funcs for f in obj if head <= f < size}, set()
    while True:
        work = sorted(entries - set(ops))
        while work:
            y = work.pop()
            if y in ops:
                continue
            if not head <= y < size:
                raise PackError(f"an opcode at ${y:04X}, outside the scripts")
            entry = table[data[1 + y]]
            shape = resolve(entry, data, 1 + y)
            if shape is None:
                raise PackError(f"${y:04X}: opcode ${data[1 + y]:02X} cannot be decoded")
            length, flow = shape
            if y + length > size:
                raise PackError(f"${y:04X}: opcode runs past the pack")
            target = None
            if "j" in flow:
                j = entry["jump"]
                target = y + j["base"] + j["sign"] * data[1 + y + j["operand"]]
            ops[y] = (data[1 + y], length, flow, target)
            succ = ([y + length] if "n" in flow else []) + ([target] if target is not None else [])
            work += [t for t in succ if t not in ops]
        more = set()
        for obj in funcs:
            start = obj[0]
            if start in done or start not in ops:
                continue
            done.add(start)
            seen, todo = set(), [start]
            while todo:
                y = todo.pop()
                if y in seen or y not in ops:
                    continue
                seen.add(y)
                op, length, flow, target = ops[y]
                if op == 0:
                    if y + 1 < size:
                        more.add(y + 1)
                    continue
                todo += ([y + length] if "n" in flow else []) + ([target] if target is not None else [])
        if more <= set(ops):
            return ops, entries, funcs
        entries |= more


def reencode(table, data, ops):
    """The pack with every jump operand recomputed from its target."""
    out = bytearray(data)
    for y, (op, _, flow, target) in ops.items():
        if target is not None:
            j = table[op]["jump"]
            distance = (target - y - j["base"]) * j["sign"]
            if not 0 <= distance <= 255:
                raise PackError(f"${y:04X}: jump distance {distance}")
            out[1 + y + j["operand"]] = distance
    return bytes(out)


def pack_record(table, data):
    ops, entries, funcs = decode(table, data)
    if reencode(table, data, ops) != data:
        raise PackError("jump re-encoding does not reproduce the pack")
    head, size = data[0] * 32, len(data) - 1
    covered = bytearray(size)
    covered[:head] = b"\x01" * head
    end, inner = -1, 0
    for y in sorted(ops):
        if y >= end:
            covered[y:y + ops[y][1]] = b"\x01" * ops[y][1]
            end = y + ops[y][1]
        else:
            inner += 1
    digest = sha(b"".join(y.to_bytes(2, "little") for y in sorted(ops)))
    return {"objects": data[0], "unpackedBytes": len(data), "sha256": sha(data),
            "instructions": len(ops), "innerInstructions": inner,
            "dataBytes": size - sum(covered), "instructionDigest": digest}


def unpack_all(rom):
    import ct_lzss
    pieces = event_pieces()
    by_pc = {pc: piece for piece in pieces for pc in [piece[1]]}
    entries = pointer_entries(rom)
    packs = []
    for label, pc, stop, mode, size in pieces:
        data = ct_lzss.decompress(rom[pc:stop + 1], mode)
        if len(data) != size:
            raise PackError(f"{label}: unpacked {len(data)} bytes, surveyed {size}")
        indices = [i for i, p in enumerate(entries) if to_pc(p) == pc]
        if not indices:
            raise PackError(f"{label}: no Evt_PackPtrs entry")
        packs.append({"label": label, "pc": pc, "pointerIndices": indices, "mode": mode, "data": data})
    other = sorted({i for i, p in enumerate(entries) if to_pc(p) not in by_pc})
    return packs, other


# ── Derivation from the ROM's handlers ──────────────────────────────────────

def interpreter(rom):
    sys.path.insert(0, str(REF / "tools"))
    import absint
    import events

    class RomInterpreter(events.Interpreter):
        """events.Interpreter over the ROM itself: every byte is known, so
        handler code and the tables it reads are the ROM's."""

        def __init__(self):
            self.image, self.mask = rom, bytearray(b"\x01") * len(rom)
            self.labels = {"Evt_OpcodeTable": 0xC00000 | OPTABLE_PC}
            self.code_key, self.dirty = sha(rom), False
            names = events.opcode_names()
            self.handlers = [(0xC00000 | rom[OPTABLE_PC + 2 * op] | rom[OPTABLE_PC + 2 * op + 1] << 8,
                              "Evt_" + names[op]) for op in range(256)]
            self.machine = absint.Machine(rom, self.mask, max_steps=400000)
            self.cache, self.specs = {}, {}
    return RomInterpreter(), events


def synthetic(op, operands, objects=1, pad=96):
    data = bytes([objects]) + (32 * objects).to_bytes(2, "little") * (FUNCS * objects)
    return data + bytes([op]) + bytes(operands) + bytes(pad), 32 * objects


def classify(interp, events, data, y):
    try:
        o = events.classify(interp, data, y)
    except events.EventsError:
        # interp.run caches by the bytes that decided the result; an
        # unresolved trace must not answer later probes of the opcode.
        interp.cache.pop(data[1 + y], None)
        raise
    flow = "".join(c for c, f in (("n", o.next), ("s", o.stay), ("e", o.end), ("j", bool(o.jumps))) if f)
    return o, flow


def shape_flows(shape):
    """Every flow code a shape can produce."""
    if "cases" in shape:
        return set().union(*(shape_flows(c) for c in shape["cases"]))
    return set(shape.get("flow", ""))


def fit_counted(interp, events, op, k, prefix=()):
    """{"counted"} when length - (word at operand k) is constant, else None."""
    results = set()
    for word in (3, 5, 8, 0x40, 0x123):     # counts below 3 wrap the handlers' MVN sizes
        operands = list(prefix) + [0] * (k - 1 - len(prefix)) + [word & 255, word >> 8]
        data, y = synthetic(op, operands, pad=0x200)
        o, flow = classify(interp, events, data, y)
        results.add((o.length - word, flow))
    if len(results) != 1:
        return None
    add, flow = results.pop()
    return {"counted": {"operand": k, "add": add}, "flow": flow}


def derive_shape(interp, events, op, prefix=(), jump_operand=None, objects=1):
    """Shape of `op` after leading operand bytes `prefix` (the rest zero),
    checked against other fills of every later byte the handler reads (the
    jump operand excepted: its value only moves the target). 's' and 'e'
    add no successor, so flows are united; length and n/j must agree."""
    data, y = synthetic(op, prefix, objects)
    try:
        o, flow = classify(interp, events, data, y)
    except Exception:
        # Zero operands can be degenerate (a zero count wraps a block move);
        # retry with moderate operand bytes to learn which bytes matter.
        data, y = synthetic(op, list(prefix) + [0x10] * 8, objects, pad=0x1100)
        o, flow = classify(interp, events, data, y)
    res = interp.run(data, y)
    later = sorted(k for k in res["control"] if len(prefix) < k < 64)
    for k in later:
        if k + 1 in later:
            fitted = fit_counted(interp, events, op, k, prefix)
            if fitted:
                return fitted, res
    flows = set(flow)
    extra = [k for k in res["reads"] if len(prefix) < k < 64 and k != jump_operand]
    if extra:
        for fill in (0xFF, 0x80, 0x01):
            operands = [fill if k + 1 != jump_operand else 0 for k in range(len(prefix), max(extra))]
            d2, _ = synthetic(op, list(prefix) + operands, objects)
            o2, f2 = classify(interp, events, d2, y)
            if o2.length != o.length:
                raise PackError(f"opcode ${op:02X} {bytes(prefix).hex()}: length changes with operand fill "
                                f"{fill:02X}: {o2.length} vs {o.length}")
            if ("n" in f2, "j" in f2) != ("n" in flow, "j" in flow):
                # Where it goes on depends on an operand (e.g. $C9 item 0 is never
                # held): sweep the byte that decided it into a kind table.
                deciding = [k for k in sorted(res["control"]) if len(prefix) < k < 64 and k != jump_operand]
                if not deciding:
                    raise PackError(f"opcode ${op:02X}: flow changes with operands no byte decides")
                k = deciding[0]
                lead = tuple(prefix) + (0,) * (k - 1 - len(prefix))
                cases = [derive_shape(interp, events, op, lead + (v,), jump_operand, objects)[0] for v in range(256)]
                return {"kind": k, "cases": cases}, res
            flows |= set(f2)
    return {"length": o.length, "flow": "".join(c for c in "nsej" if c in flows)}, res


def derive(rom, log=print):
    interp, events = interpreter(rom)
    names = events.opcode_names()
    isa = json.loads((WS / "manifests" / "event_vm_isa.json").read_text())
    halts = {o["opcode"] for o in isa["opcodes"] if o["status"] == "halt"}
    packs, other = unpack_all(rom)

    # 1. Trace-driven disassembly of every pack (the reference result).
    traced, specs, seen = {}, {}, {}
    for p in packs:
        if not p["data"]:
            continue
        d = events.disassemble(interp, p["data"])
        traced[p["label"]] = d
        for op, spec in d["specs"].items():
            if specs.setdefault(op, spec) != spec:
                raise PackError(f"opcode ${op:02X}: two jump encodings")
        for o in d["ops"].values():
            seen.setdefault(o.op, set()).add((o.length, o.next, o.stay, o.end, bool(o.jumps)))
    log(f"traced {len(traced)} packs; {len(seen)} opcodes in use")

    # 2. The decode table.
    table = []
    for op in range(256):
        entry = {"op": op, "name": names[op],
                 "handler": f"$C0:{rom[OPTABLE_PC + 2 * op + 1]:02X}{rom[OPTABLE_PC + 2 * op]:02X}",
                 "inCorpus": op in seen, "jump": None}
        if op in halts:
            entry["shape"] = {"halt": True}
        elif op == 0x4E:
            entry["shape"] = fit_counted(interp, events, op, 4)
            if entry["shape"] is None:
                raise PackError("$4E: length is not a constant plus its length word")
            for bank in range(256):
                if fit_counted(interp, events, op, 4, (0, 0, bank)) != entry["shape"]:
                    raise PackError(f"$4E: shape depends on bank byte {bank:02X}")
        elif op in VARIABLE:
            cases = []
            for value in range(256):
                try:
                    shape, res = derive_shape(interp, events, op, (value,))
                except events.EventsError as e:
                    # The handler cannot be followed (e.g. it exceeds the step
                    # budget): the decoders refuse this value rather than guess.
                    cases.append({"unknown": str(e).split(": ", 1)[-1]})
                    log(f"${op:02X} {value:02X}: unknown ({e})")
                    continue
                if any(k < 0 for k in res["control"]):          # decided by header bytes
                    if derive_shape(interp, events, op, (value,), objects=16)[0] != shape:
                        raise PackError(f"${op:02X} {value:02X}: shape depends on the object count")
                cases.append(shape)
            entry["shape"] = {"kind": 1, "cases": cases}
        else:
            spec = specs.get(op)
            if spec is None:                        # not in the corpus: find its jump first
                data, y = synthetic(op, [])
                o, _ = classify(interp, events, data, y)
                if o.jumps:
                    specs[op] = spec = events.jump_spec(interp, data, o)
            entry["shape"], _ = derive_shape(interp, events, op, jump_operand=spec[0] if spec else None)
        if op in specs:
            if "j" not in shape_flows(entry["shape"]):
                raise PackError(f"${op:02X}: corpus jumps but the table shape does not")
            i, s, c = specs[op]
            entry["jump"] = {"operand": i, "sign": s, "base": c}
        table.append(entry)
        if op in VARIABLE:
            log(f"swept ${op:02X}")

    # 3. Corpus instances must agree with the table; both disassemblies must match.
    records = []
    for p in packs:
        rec = {"label": p["label"], "pc": p["pc"], "pointerIndices": p["pointerIndices"], "mode": p["mode"]}
        if not p["data"]:
            rec.update({"objects": None, "unpackedBytes": 0, "sha256": sha(b""), "note": "empty pack"})
            records.append(rec)
            continue
        ops, _, _ = decode(table, p["data"])
        d = traced[p["label"]]
        if set(ops) != set(d["ops"]):
            raise PackError(f"{p['label']}: table and traces reach different opcodes")
        for y, o in d["ops"].items():
            if ops[y][1] != o.length:
                raise PackError(f"{p['label']} ${y:04X}: length {ops[y][1]} vs traced {o.length}")
        rec.update(pack_record(table, p["data"]))
        records.append(rec)
    log(f"{len(records)} packs: table-driven == traced, jumps re-encode byte-exact")
    table_doc = {"schema": "ct-event-decode/1", "romSHA256": ROM_SHA256,
                 "opcodeTablePC": OPTABLE_PC, "method": __doc__.split("\n\n")[1].replace("\n", " "),
                 "flowCodes": {"n": "goes on after its operands", "s": "stays (runs again)",
                               "e": "ends the run at an unknown position (return / leave)",
                               "j": "jumps: target = offset + base + sign x operand byte"},
                 "opcodes": table}
    packs_doc = {"schema": "ct-event-packs/1", "romSHA256": ROM_SHA256,
                 "pointerTablePC": PTRS_PC, "pointerCount": PTR_COUNT,
                 "nonEventPointerIndices": other,
                 "packs": records,
                 "totals": {"packs": len(records), "nonEmpty": sum(1 for r in records if r.get("objects")),
                            "instructions": sum(r.get("instructions", 0) for r in records),
                            "dataBytes": sum(r.get("dataBytes", 0) for r in records)},
                 "limitations": [
                     "Static decoding: reachability follows handler control flow, not a runtime trace.",
                     "Flows are what the handler can do with unknown game state; 'e' hides the target.",
                     "Opcode names come from the matched source; semantics are in event_vm_isa.json."]}
    return table_doc, packs_doc


# ── Swift twin ──────────────────────────────────────────────────────────────

def swift_shape(shape):
    if "halt" in shape or "unknown" in shape:
        return ".halt"
    if "length" in shape:
        return f'.fixed(length: {shape["length"]}, flow: CTEventFlow("{shape["flow"]}"))'
    if "counted" in shape:
        c = shape["counted"]
        return f'.counted(operand: {c["operand"]}, add: {c["add"]}, flow: CTEventFlow("{shape["flow"]}"))'
    cases = "".join(f"\n            {swift_shape(s)}," for s in shape["cases"])
    return f'.byKind(operand: {shape["kind"]}, cases: [{cases}\n        ])'


def swift_source(table_doc):
    lines = ["// Generated by re_workspace/tools/ct_event_packs.py from manifests/event_decode_table.json.",
             "// Do not edit: shapes were traced from the ROM's own event handlers.",
             "",
             "public enum CTEventISA {",
             "    public static let opcodes: [CTEventOpcode] = ["]
    for e in table_doc["opcodes"]:
        j = e["jump"]
        jump = f'CTEventJump(operand: {j["operand"]}, sign: {j["sign"]}, base: {j["base"]})' if j else "nil"
        lines.append(f'        CTEventOpcode(name: "{e["name"]}", shape: {swift_shape(e["shape"])}, jump: {jump}),')
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def serialize(value):
    return json.dumps(value, indent=1) + "\n"


def check(rom):
    """Fast: the committed table decodes every pack to the committed records."""
    table_doc = json.loads(TABLE.read_text())
    packs_doc = json.loads(PACKS.read_text())
    if SWIFT.read_text() != swift_source(table_doc):
        raise PackError("CTEventISA.swift is out of date with event_decode_table.json")
    table = table_doc["opcodes"]
    packs, other = unpack_all(rom)
    if other != packs_doc["nonEventPointerIndices"]:
        raise PackError("non-event pointer entries changed")
    by_label = {r["label"]: r for r in packs_doc["packs"]}
    for p in packs:
        want = by_label[p["label"]]
        if not p["data"]:
            if want["unpackedBytes"]:
                raise PackError(f"{p['label']}: empty")
            continue
        got = pack_record(table, p["data"])
        for key, value in got.items():
            if want[key] != value:
                raise PackError(f"{p['label']}: {key} {value} != recorded {want[key]}")
    return len(packs)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=("derive", "check"))
    args = parser.parse_args()
    rom = read_rom()
    if args.command == "derive":
        table_doc, packs_doc = derive(rom)
        TABLE.write_text(serialize(table_doc))
        PACKS.write_text(serialize(packs_doc))
        SWIFT.write_text(swift_source(table_doc))
        print(f"wrote {TABLE.name}, {PACKS.name}, {SWIFT.name}")
    n = check(rom)
    print(f"OK: {n} event packs decode from the table; every jump re-encodes byte-exact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
