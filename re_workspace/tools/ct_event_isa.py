#!/usr/bin/env python3
"""Extract the complete instruction-set architecture of Chrono Trigger's
Location Event bytecode VM (Phase 3 item 4).

Ground truth sources (all byte/line level, nothing invented):
  * re_workspace/ct_clean.sfc          — the ROM; Evt_OpcodeTable is read from it.
  * refs/ChronoRET/asm/bankC0/bankC0.asm — byte-exact decompilation of THIS ROM;
    its Evt_OpXX_Name labels + comment blocks are the opcode documentation.
  * refs/ChronoRET/asm/include/ram_engine.inc, constants_engine.inc —
    the WRAM variable map (Evt_*/Obj_* defines) behind the VM architecture.
  * refs/mos65xx-python/mos65xx/opcodes65816.py — MIT-licensed verified 65816
    opcode table, vendored by source-load (attribution below).

Output: manifests/event_vm_isa.json (+ a human-readable .md twin).
"""

from __future__ import annotations

import json
import os
import re
import sys
from typing import Optional

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REWORKSPACE = os.path.dirname(TOOLS_DIR)
sys.path.insert(0, TOOLS_DIR)

from address_map import Rom, load as load_rom  # noqa: E402

ROM_PATH = os.path.join(REWORKSPACE, "ct_clean.sfc")
CHRONORET = os.path.join(REWORKSPACE, "refs", "ChronoRET")
ASM_C0 = os.path.join(CHRONORET, "asm", "bankC0", "bankC0.asm")
RAM_ENGINE_INC = os.path.join(CHRONORET, "asm", "include", "ram_engine.inc")
CONSTANTS_ENGINE_INC = os.path.join(CHRONORET, "asm", "include", "constants_engine.inc")
MOS65816_SRC = os.path.join(REWORKSPACE, "refs", "mos65xx-python", "mos65xx", "opcodes65816.py")

# ---------------------------------------------------------------------------
# Vendored 65816 opcode table.
# Source: mos65xx-python (https://github.com/mndrix/mos65xx-python), MIT
# licensed. Copyright (c) the mos65xx-python authors. We load only the data
# tables (OPCODES / MODE_SIZE / FLAG_DEPENDENT) by exec'ing the module source
# with its single relative import stubbed, so the package itself (which needs
# Python >= 3.12) is not required.
# ---------------------------------------------------------------------------


def load_mos65816_table(path: str = MOS65816_SRC) -> dict:
    src = open(path, "r", encoding="utf-8").read()
    src = src.replace("from .errors import Truncated", "Truncated = Exception")
    ns: dict = {}
    exec(compile(src, path, "exec"), ns)
    return {
        "OPCODES": ns["OPCODES"],
        "MODE_SIZE": ns["MODE_SIZE"],
        "FLAG_DEPENDENT": ns["FLAG_DEPENDENT"],
    }


# ---------------------------------------------------------------------------
# Constants verified against ROM bytes (AGENT_CONTEXT "facts already verified")
# ---------------------------------------------------------------------------

TABLE_BANK, TABLE_ADDR = 0xC0, 0x5D6E  # Evt_OpcodeTable (512 bytes, $5D6E-$5F6D)
HALT_BANK, HALT_ADDR = 0xC0, 0x5F6E    # Evt_UnusedOpcode -> Sys_HaltWithColor

# The 32 unused opcodes (verified: all table words == $5F6E).
KNOWN_HALT_OPCODES = {
    0x01, 0x3A, 0x3D, 0x3E, 0x45, 0x46, 0x6E, 0x70, 0x74, 0x78, 0x79,
    0x85, 0x86, 0x93, 0x9B, 0xA2, 0xA3, 0xA4, 0xA5, 0xBE, 0xBF, 0xC5,
    0xC6, 0xDB, 0xE9, 0xEF, 0xF5, 0xF6, 0xF7, 0xFB, 0xFC, 0xFD,
}

# JSR (Evt_OpcodeTable,X) dispatch sites (opcode $FC, bytes fc 6e 5d).
DISPATCH_SITES = [
    (0xC0, 0x5910, "Evt_InitObjects (init function, opcode $00-terminated)"),
    (0xC0, 0x5977, "Evt_RunObj0Func1 (object 0 function 1)"),
    (0xC0, 0x59A0, "Evt_RunObjInit (per-object startup run)"),
    (0xC0, 0x5AB1, "Evt_RunObjScriptSteps (per-frame stepped run)"),
]


def read_opcode_table(rom: Rom) -> list[tuple[int, int]]:
    """256 (bank, addr) handler entries read straight from the ROM bytes."""
    return [(0xC0, rom.u16(TABLE_BANK, TABLE_ADDR + 2 * op)) for op in range(256)]


# ---------------------------------------------------------------------------
# ChronoRET label / comment-block parser
# ---------------------------------------------------------------------------

LABEL_RE = re.compile(r"^Evt_Op([0-9A-F]{2,4})_(\w+):\s*$")
HEADER_RE = re.compile(r"^; \$C0:([0-9A-F]{4}) — (\w+)(?: \((.*))?$")
ORG_RE = re.compile(r"^org \$C0([0-9A-F]{4})\s*$")
SEP_RE = re.compile(r"^; -{10,}\s*$")


def parse_chronoret_labels(asm_path: str = ASM_C0) -> dict:
    """Map every documented routine start address in bankC0.asm.

    Returns {addr16: {"label", "description", "header_tail", "end_addr"}} where
    description is the comment block between the '; ----' fences above the
    label (up to 40 lines), and the routine span [addr, end_addr) comes from
    the sorted list of all documented headers (used for the code-region check).
    """
    lines = open(asm_path, "r", encoding="utf-8").read().splitlines()

    # All documented routine headers (any label, not just Evt_Op*): these
    # partition bank $C0 into spans for the "inside a code region" check.
    headers: list[tuple[int, str]] = []  # (addr, label) in file order
    header_tail: dict[int, str] = {}
    for i, ln in enumerate(lines):
        m = HEADER_RE.match(ln)
        if m:
            addr = int(m.group(1), 16)
            headers.append((addr, m.group(2)))
            header_tail[addr] = m.group(3) or ""
    headers.sort()
    span_end: dict[int, int] = {}
    for j, (addr, _lab) in enumerate(headers):
        span_end[addr] = headers[j + 1][0] if j + 1 < len(headers) else 0x8000

    # Comment-block descriptions for Evt_OpXX_ labels.
    labels: dict[int, dict] = {}
    for i, ln in enumerate(lines):
        m = LABEL_RE.match(ln)
        if not m:
            continue
        # Walk up: expect the closing fence, then collect until opening fence.
        j = i - 1
        if j < 0 or not SEP_RE.match(lines[j]):
            continue
        j -= 1
        block: list[str] = []
        while j >= 0 and lines[j].startswith(";") and not SEP_RE.match(lines[j]):
            block.append(lines[j][1:].strip())
            j -= 1
            if len(block) >= 40:
                break
        block.reverse()
        # The header line '; $C0:ADDR — LABEL' is the first line of the block.
        hm = HEADER_RE.match("; " + block[0]) if block else None
        addr = int(hm.group(1), 16) if hm else None
        if addr is None:
            continue
        labels[addr] = {
            "label": hm.group(2),
            "opcode_hint": m.group(1),
            "header_tail": hm.group(3) or "",
            "description": " ".join(block),
            "end_addr": span_end.get(addr, addr),
        }
    return {"labels": labels, "span_end": span_end,
            "header_addrs": [a for a, _ in headers]}


# ---------------------------------------------------------------------------
# Handler byte verification
# ---------------------------------------------------------------------------


def verify_handler_bytes(rom: Rom, mos: dict, bank: int, addr: int) -> dict:
    """First-bytes sanity: real 65816 code, not $00/$FF filler.

    Checks (all byte-level):
      * the 8 bytes at the handler are not all $00 and not all $FF;
      * the first byte names a real 65816 instruction (vendored table);
      * the address falls inside a documented code span of bankC0.asm.
    """
    data = rom.read(bank, addr, 8)
    all00 = all(b == 0x00 for b in data)
    allFF = all(b == 0xFF for b in data)
    mnemonic = mos["OPCODES"][data[0]][0]
    return {
        "first_bytes": data.hex(),
        "first_mnemonic": mnemonic,
        "is_fill": all00 or allFF,
    }


# ---------------------------------------------------------------------------
# WRAM architecture from ram_engine.inc / constants_engine.inc defines
# ---------------------------------------------------------------------------

DEFINE_RE = re.compile(r"^!(\w+) = (\$[0-9A-Fa-f]+)\s*(?:;\s*(.*))?\s*$")
CONT_RE = re.compile(r"^\s+;\s?(.*)$")


def parse_defines(paths: list[str]) -> dict:
    """Parse '!NAME = $VALUE ; comment' (with continuation comment lines)."""
    out: dict[str, dict] = {}
    for path in paths:
        lines = open(path, "r", encoding="utf-8").read().splitlines()
        cur: Optional[str] = None
        for ln in lines:
            m = DEFINE_RE.match(ln)
            if m:
                cur = m.group(1)
                out[cur] = {"value": int(m.group(2)[1:], 16),
                            "comment": (m.group(3) or "").strip()}
                continue
            c = CONT_RE.match(ln)
            if c and cur is not None:
                out[cur]["comment"] = (out[cur]["comment"] + " " + c.group(1)).strip()
            elif ln and not ln.startswith((" ", ";", "\t")):
                cur = None
    return out


ARCH_DEFINES = [
    # ($7E:0000-page / DP=$0100 interpreter state)
    ("Evt_StepsLeft", "ram_engine.inc"), ("Field_Unk68", "ram_engine.inc"),
    ("Evt_ObjSlotEnd", "ram_engine.inc"), ("Obj_Cur", "ram_engine.inc"),
    ("Obj_CurHi", "ram_engine.inc"),
    # ($7E:xxxx per-object arrays)
    ("Obj_ScriptPos", "ram_engine.inc"), ("Obj_Facing", "ram_engine.inc"),
    ("Obj_PosX", "ram_engine.inc"), ("Obj_PosY", "ram_engine.inc"),
    ("Obj_Unk1C00", "ram_engine.inc"), ("Obj_Unk1C80", "ram_engine.inc"),
    # (bank $7F: story flags, priority save tables, event data)
    ("Evt_Mem7F", "ram_engine.inc"), ("Eng_Unk7F0000", "ram_engine.inc"),
    ("Treasure_Flags", "ram_engine.inc"), ("Evt_Unk7F0200", "ram_engine.inc"),
    ("ObjX_Unk7F0580", "ram_engine.inc"), ("ObjX_Unk7F0600", "ram_engine.inc"),
    ("ObjX_Unk7F0680", "ram_engine.inc"), ("ObjX_Unk7F0700", "ram_engine.inc"),
    ("ObjX_Unk7F0780", "ram_engine.inc"), ("ObjX_Unk7F0800", "ram_engine.inc"),
    ("ObjX_Unk7F0880", "ram_engine.inc"), ("ObjX_Unk7F0900", "ram_engine.inc"),
    ("Evt_ObjCount", "ram_engine.inc"), ("Evt_Data", "ram_engine.inc"),
]


def build_memory_map(defines: dict) -> dict:
    """WRAM variable map keyed by SNES address. Several symbols share an
    address (Evt_Mem7F aliases Eng_Unk7F0000 at $7F:0000), so entries carry a
    symbol list instead of overwriting."""
    mem = {}
    for name, _src in ARCH_DEFINES:
        d = defines.get(name)
        if d is None:
            continue
        val = d["value"]
        key = f"$7F:{val & 0xFFFF:04X}" if val > 0xFFFF else f"$7E:{val:04X}"
        entry = mem.setdefault(key, {"symbols": [], "comments": []})
        entry["symbols"].append(f"!{name}")
        entry["comments"].append(d["comment"])
    for entry in mem.values():
        entry["comment"] = " | ".join(c for c in entry.pop("comments") if c)
    return mem


# ---------------------------------------------------------------------------
# Manifest assembly
# ---------------------------------------------------------------------------

ARG_HEAD_RE = re.compile(r"Event opcode \$[0-9A-F]{2} \(")


def _scan_balanced(s: str, open_idx: int) -> Optional[str]:
    """Inner text of the balanced parentheses starting at s[open_idx] == '('."""
    depth = 0
    for i in range(open_idx, len(s)):
        if s[i] == "(":
            depth += 1
        elif s[i] == ")":
            depth -= 1
            if depth == 0:
                return s[open_idx + 1:i]
    return None


def _split_operands(ops: str) -> list[str]:
    """Split an operand list on top-level commas (keeps 'dst (word)' intact)."""
    parts, depth, cur = [], 0, ""
    for ch in ops:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    parts = [p for p in parts if p]
    if parts and parts[0].startswith("$"):  # the opcode byte itself
        parts = parts[1:]
    return parts


def extract_args(description: str, opcode: int) -> Optional[dict]:
    """Best-effort operand encoding from the description's 'Event opcode $XX
    (...)' header sentence. Handles fixed '(N bytes: ops)', variable
    '(variable: ops)' / '(N bytes or more: ops)', bare '($XX, ops...)' lists,
    and '(N bytes, as $YY)' aliases (operands resolved in a second pass)."""
    m = ARG_HEAD_RE.search(description)
    if not m:
        return None
    inner = _scan_balanced(description, m.end() - 1)
    if inner is None:
        return None
    am = re.fullmatch(r"(\d+) bytes?, as \$([0-9A-F]{2})", inner.strip())
    if am:
        return {"total_bytes": int(am.group(1)), "operands": [],
                "alias_of": f"${am.group(2)}"}
    if ":" in inner:
        prefix, ops = inner.split(":", 1)
    elif re.fullmatch(r"\d+ bytes?", inner.strip()):
        prefix, ops = inner, ""
    else:
        prefix, ops = "", inner
    prefix = prefix.strip()
    total: Optional[int] = None
    variable = False
    pm = re.fullmatch(r"(\d+) bytes?(?: or more)?", prefix)
    if pm:
        total = int(pm.group(1))
        variable = "or more" in prefix
    elif prefix == "variable":
        variable = True
    args = {"total_bytes": total, "operands": _split_operands(ops)}
    if variable:
        args["variable_length"] = True
    return args


def build_manifest(rom_path: str = ROM_PATH) -> dict:
    rom = load_rom(rom_path)
    mos = load_mos65816_table()
    asm = parse_chronoret_labels()
    defines = parse_defines([RAM_ENGINE_INC, CONSTANTS_ENGINE_INC])

    # Sanity: dispatch bytes fc 6e 5d at all four JSR (abs,X) sites.
    dispatch = []
    for bank, addr, what in DISPATCH_SITES:
        b = rom.read(bank, addr, 3)
        dispatch.append({"site": f"$C0:{addr:04X}", "bytes": b.hex(),
                         "verified": b.hex() == "fc6e5d",  # JSR (Evt_OpcodeTable,X)
                         "role": what})

    table = read_opcode_table(rom)
    halt_found = {op for op, (bk, ad) in enumerate(table) if (bk, ad) == (HALT_BANK, HALT_ADDR)}

    opcodes = []
    counts = {"documented": 0, "halt": 0, "undocumented": 0}
    for op, (bk, ad) in enumerate(table):
        entry = {
            "opcode": op,
            "opcode_hex": f"$ {op:02X}".replace(" ", ""),
            "handler_snes": f"$C0:{ad:04X}",
            "handler_pc": rom.snes_to_pc(bk, ad),
            "label": None,
            "name": None,
            "description": "",
            "args": None,
            "status": "undocumented",
            "verify": None,
        }
        info = asm["labels"].get(ad)
        v = verify_handler_bytes(rom, mos, bk, ad)
        # code-region check: address inside a documented bankC0.asm span
        in_code = any(a <= ad < asm["span_end"][a] for a in asm["header_addrs"]
                      if a <= ad) and not v["is_fill"]
        v["in_code_region"] = bool(in_code)
        entry["verify"] = v
        if (bk, ad) == (HALT_BANK, HALT_ADDR):
            entry["status"] = "halt"
            entry["label"] = "Evt_UnusedOpcode"
            entry["name"] = "UnusedOpcode_halt"
            entry["description"] = ("Unused opcode: halts the game on "
                                    "!Halt_ColorBadOpcode through "
                                    "Sys_HaltWithColor (LDX.w #color / BRL).")
            entry["args"] = {"total_bytes": 1, "operands": []}
        elif info is not None:
            entry["status"] = "documented"
            entry["label"] = info["label"]
            nm = re.match(r"Evt_Op(?:[0-9A-F]{2,4})_(.+)", info["label"])
            entry["name"] = nm.group(1) if nm else info["label"]
            entry["description"] = info["description"]
            entry["args"] = extract_args(info["description"], op)
            # flag label/opcode-number mismatches (shared handlers) in the
            # description tail so nothing is silently renamed
            hint = info["opcode_hint"]
            if hint and hint[-2:] != f"{op:02X}":
                entry["shared_with_opcode"] = f"$ {hint}".replace(" ", "")
        counts[entry["status"]] += 1
        opcodes.append(entry)

    # Second pass: resolve '(N bytes, as $YY)' aliases to the referenced
    # opcode's operand list.
    by_op = {e["opcode"]: e for e in opcodes}
    for e in opcodes:
        a = e["args"]
        if a and a.get("alias_of"):
            target = by_op.get(int(a["alias_of"][1:], 16))
            if target and target["args"] and target["args"]["operands"]:
                a["operands"] = list(target["args"]["operands"])
                a["operands_source"] = f"as {a['alias_of']}"

    assert halt_found == KNOWN_HALT_OPCODES, (
        f"halt set mismatch: extra={sorted(halt_found - KNOWN_HALT_OPCODES)} "
        f"missing={sorted(KNOWN_HALT_OPCODES - halt_found)}")

    manifest = {
        "source": {
            "rom": os.path.basename(rom_path),
            "reference_decompilation": "refs/ChronoRET (byte-exact for this ROM)",
            "opcode_table_source": "refs/mos65xx-python opcodes65816.py (MIT)",
            "table_snes": f"$C0:{TABLE_ADDR:04X}",
            "table_pc": TABLE_ADDR,
            "dispatch": dispatch,
        },
        "architecture": {
            "objects": 16,
            "object_slots_note": (
                "Up to 16 location objects (Obj_Cur = slot*2 indexes the "
                "Obj_* tables; Evt_ObjSlotEnd = Evt_ObjCount*2 bounds the "
                "slot loops)."),
            "functions": {
                "table": "Evt_Data + slot*16 (16 word function offsets per object, 32 bytes, offsets relative to Evt_Data)",
                "0": "startup/init (Evt_InitObjects seeds Obj_ScriptPos with it; Evt_RunObjInit runs it to opcode $00)",
                "1": "activate (Evt_StartTargetFunc1: action-button target; saves interrupted Obj_ScriptPos into the current level's ObjX_Unk7F0580 table, sets Obj_Unk1C00=1)",
                "2": "touch",
                "3+": "cutscene / script entry points",
            },
            "priorities": {
                "levels": "Obj_Unk1C00 = priority level per object, 0-7; 7 (Obj_Unk1C00Init) after init; lower = more urgent (a call only interrupts an object running at a higher level number)",
                "save_tables": "ObjX_Unk7F0580 + level*Evt_PrioStride($80) + slot: saved Obj_ScriptPos per interrupted level (8 tables, $7F:0580-$7F:0980)",
                "return": "opcode $00 (Evt_Op00_Return) zeroes the current level's entry and steps Obj_Unk1C00 up to the next nonzero saved position",
            },
            "step_budget": {
                "per_object_per_frame": "!Field_Unk68 ($7E:0068, 8-bit; set to 5 by Field_InitLoadState)",
                "counter": "!Evt_StepsLeft ($7E:0067, 8-bit; Evt_RunObjScriptSteps counts it down, DEC/BEQ between dispatches)",
            },
            "coroutine_yield_semantics": (
                "Cooperative coroutines: Evt_RunObjScriptSteps dispatches "
                "opcode@Evt_Data+Obj_ScriptPos via JSR (Evt_OpcodeTable,X) "
                "(opcode $FC abs,X at $C0:5910/$5977/$59A0/$5AB1). Handler "
                "returns C=1 = continue with X = next script offset in this "
                "run; C=0 = yield this object to a later frame. X is stored "
                "back into Obj_ScriptPos after every dispatch."),
            "memory_map": build_memory_map(defines),
            "story_flags_note": (
                "Evt_Mem7F = $7F:0000 is the story/global-flag window the "
                "memory opcodes address as $7F:0000+operand: Eng_Unk7F0000 "
                "($7F:0000, scene-progress byte; bank-$C2 scene change needs "
                ">= $49), Treasure_Flags ($7F:0001, 64 bytes, one bit per "
                "treasure), Evt_Unk7F0200 ($7F:0200, 512 bytes cleared per "
                "location load, starts with Treasure_ItemId)."),
        },
        "opcodes": opcodes,
        "coverage": {
            "documented": counts["documented"],
            "halt": counts["halt"],
            "undocumented": counts["undocumented"],
            "total": 256,
            "distinct_handlers": len({(e["handler_snes"]) for e in opcodes}),
            "with_args_decoded": sum(1 for e in opcodes if e["args"]),
            "with_description": sum(1 for e in opcodes if e["description"]),
        },
        "unverified": [
            "operands of opcodes whose description has no '(N bytes: ...)' sentence are left as null",
        ],
    }
    return manifest


def write_markdown(manifest: dict, path: str) -> None:
    lines = [
        "# Chrono Trigger Location Event VM — instruction set (256 opcodes)",
        "",
        f"Table: {manifest['source']['table_snes']} (PC {manifest['source']['table_pc']:#x}), "
        f"256 little-endian words, handler = $C0:<word>, index = opcode*2.",
        f"Coverage: {manifest['coverage']}",
        "",
        "| op | handler | status | label | encoding | description |",
        "|----|---------|--------|-------|----------|-------------|",
    ]
    for e in manifest["opcodes"]:
        desc = re.sub(r"\s+", " ", e["description"]).replace("|", "\\|")
        if len(desc) > 220:
            desc = desc[:217] + "..."
        args = ""
        if e["args"]:
            args = f"{e['args']['total_bytes']}B: " + ", ".join(e["args"]["operands"])
        label = e["label"] or ""
        if "shared_with_opcode" in e:
            label += f" (shared w/ {e['shared_with_opcode']})"
        lines.append(f"| {e['opcode_hex']} | {e['handler_snes']} | {e['status']} | "
                     f"{label} | {args} | {desc} |")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    manifest = build_manifest()
    out_dir = os.path.join(REWORKSPACE, "manifests")
    os.makedirs(out_dir, exist_ok=True)
    jpath = os.path.join(out_dir, "event_vm_isa.json")
    with open(jpath, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1)
    write_markdown(manifest, os.path.join(out_dir, "event_vm_isa.md"))
    c = manifest["coverage"]
    print(f"wrote {jpath}")
    print(f"coverage: documented={c['documented']} halt={c['halt']} "
          f"undocumented={c['undocumented']} distinct_handlers={c['distinct_handlers']} "
          f"descriptions={c['with_description']} args={c['with_args_decoded']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
