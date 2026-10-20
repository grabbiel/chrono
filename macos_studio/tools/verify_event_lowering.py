#!/usr/bin/env python3
"""Check `chronoforge event lower` against the ROM's own event handlers.

Lowers a fixture scene with the real CLI, then (1) disassembles the pack by
tracing the ROM's handlers (re_workspace/tools/ct_event_packs.py) and requires
exactly the opcodes the Swift decode table reaches, every byte reached; and
(2) executes each lowered bit, test, jump and message-pointer opcode through
its ROM handler with concrete WRAM, checking the memory written and where
the script goes on. Needs the user's ROM and the workspace venv.
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

package = Path(__file__).resolve().parents[1]
workspace = package.parent / 're_workspace'
sys.path.insert(0, str(workspace / 'tools'))
import ct_event_packs as packs  # noqa: E402

cli = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else package / '.build/debug/chronoforge'
fixture = package / 'Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj'
EVT = 0x7F2000
checks = 0


def check(condition, message):
    global checks
    if not condition:
        raise SystemExit(f'FAIL: {message}')
    checks += 1


def execute(interp, absint, data, y, memory):
    """Run the handler of the opcode at Evt_Data offset y with the pack and
    `memory` known: [(X after it, carry, {address: byte written})]. The entry
    carry is not part of the opcode's contract, so both values are run and
    must agree."""
    results = [execute_with_carry(interp, absint, data, y, memory, carry) for carry in (False, True)]
    check(results[0] == results[1], f'opcode at ${y:04X} depends on the entry carry')
    return results[0]


def execute_with_carry(interp, absint, data, y, memory, carry):
    op = data[1 + y]
    s = absint.State()
    s.pc = interp.handlers[op][0]
    s.a, s.b = (op * 2) & 0xFF, (op * 2) >> 8
    s.x, s.y = op * 2, y
    s.d, s.db, s.m, s.xf = 0x0100, 0x00, True, False     # DP=$0100, DB=$00 as the handlers' headers require
    s.z = s.n = s.v = None
    s.c = carry
    s.sp, s.spt, s.mem, s.memt = [], [], {}, {}
    s.at = s.xt = s.yt = s.ft = absint.E
    s.depth = 0
    known = {EVT + i: b for i, b in enumerate(data)}
    known.update(memory)
    return [(st.x, st.c, dict(st.mem)) for st, how in interp.machine.run(s, known) if how == 'rts']


with tempfile.TemporaryDirectory(prefix='chronoforge-lower-') as directory:
    project = Path(directory) / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    dsl = project / 'scenes/intro.event.dsl'
    calls = ['    call_obj npc#1 start level 3', '    call_pc 0#1 start level 5', '    ct Op94_WalkToObj $02']
    dsl.write_text('\n'.join(sum(([*calls] if 'call ' in line else [line] for line in dsl.read_text().splitlines()), [])) + '\n')
    npc = {'id': 'npc', 'scene': {'object': 1, 'layout': [], 'funcs': [
        {'index': 0, 'stmts': [{'op': 'nop'}]}, {'index': 1, 'stmts': [{'op': 'wait', 'frames': 1}]}]}}
    (project / 'scenes/npc.event.json').write_text(json.dumps(npc))
    out = Path(directory) / 'lowered.json'
    result = subprocess.run([str(cli), 'event', 'lower', str(project), 'intro', 'npc', '--out', str(out)],
                            capture_output=True, text=True, timeout=30)
    check(result.returncode == 0, f'lower failed: {result.stdout}{result.stderr}')
    refused = subprocess.run([str(cli), 'event', 'lower', str(fixture), 'intro', '--out', str(out) + '.x'],
                             capture_output=True, text=True, timeout=30)
    check(refused.returncode == 1 and 'cross-map' in refused.stdout, 'map call must be refused')
    check(json.loads(out.read_text())['bytes'][0] == 2, 'intro and npc lower into a two-object pack')
    check(not Path(str(out) + '.x').exists(), 'refused lowering wrote output')
    lowered = json.loads(out.read_text())

data = bytes(lowered['bytes'])
rom = packs.read_rom()
interp, events = packs.interpreter(rom)
import absint  # noqa: E402  (on sys.path once interpreter() has run)

table = json.loads(packs.TABLE.read_text())['opcodes']
ops, _, _ = packs.decode(table, data)
traced = events.disassemble(interp, data)
check(set(traced['ops']) == set(ops), 'handler traces reach different opcodes than the table')
check(all(traced['ops'][y].length == ops[y][1] for y in ops), 'lengths differ from the handlers')
covered = set()
for y, o in ops.items():
    covered.update(range(y, y + o[1]))
unreached = [y for y in range(data[0] * 32, len(data) - 1) if y not in covered]
check(all(data[1 + y] in (0x00, 0xB2) for y in unreached),
      'only dead $00/$B2 epilogue bytes may be unreached')
check(lowered['messages'] == ['greeting', 'shop', 'intro'], f'messages {lowered["messages"]}')

flag_addr, flag_bit = 0x7F0003, 2          # MET_LAYLA in the fixture project
OBJ_SCRIPT_POS, OBJ_LEVEL, PARTY_OBJ_SLOT = 0x7E1180, 0x7E1C00, 0x7E0197   # Obj_ScriptPos, Obj_Unk1C00, Party_ObjSlot


def function_offset(obj, index):
    return data[1 + obj * 32 + index * 2] | data[2 + obj * 32 + index * 2] << 8


def target_idle(slot):
    """An object resting at level 7 after its init, not blocked."""
    return {0x7E1C01 + slot: 0, 0x7E1100 + slot: 0, 0x7E1000 + slot: 0, OBJ_LEVEL + slot: 7,
            OBJ_SCRIPT_POS + slot: 0x34, OBJ_SCRIPT_POS + slot + 1: 0x12}
seen = set()
for y, (op, length, flow, target) in sorted(ops.items()):
    seen.add(op)
    if op in (0x65, 0x66):
        for before in (0x00, 0xFF, 0x5A):
            ends = execute(interp, absint, data, y, {flag_addr: before})
            want = before | 1 << flag_bit if op == 0x65 else before & ~(1 << flag_bit) & 0xFF
            check(len(ends) == 1 and ends[0][0] == y + 3, f'${op:02X} at ${y:04X} does not go on')
            check(ends[0][2].get(flag_addr) == want, f'${op:02X} wrote {ends[0][2].get(flag_addr)} not {want}')
    elif op == 0x16:
        for before, expect in ((1 << flag_bit, y + 5), (0xFF ^ (1 << flag_bit), target), (0, target)):
            ends = execute(interp, absint, data, y, {flag_addr: before})
            check([e[0] for e in ends] == [expect], f'$16 at ${y:04X} with {before:02X} went to {ends}')
    elif op in (0x10, 0x11):
        ends = execute(interp, absint, data, y, {})
        check([e[0] for e in ends] == [target], f'${op:02X} at ${y:04X} went to {ends}')
    elif op in (0x02, 0x05):
        # Start function f of object slot (object x 2) at the level: the target's
        # Obj_ScriptPos becomes that function's offset and its level the new one.
        operand, arg = data[1 + y + 1], data[1 + y + 2]
        memory = {PARTY_OBJ_SLOT + operand: 2, PARTY_OBJ_SLOT + operand + 1: 0} if op == 0x05 else {}
        slot = 2 if op == 0x05 else operand
        memory.update(target_idle(slot))
        # The multiplier is not modelled: RDMPYL ($4216) holds level 7 x Evt_PrioStride $80.
        # The 16-bit read of EvtCall_Arg takes a scratch byte along; it must not matter.
        memory.update({0x4216: 0x80, 0x4217: 0x03})
        runs = [execute(interp, absint, data, y, {**memory, 0x7E01DE: scratch}) for scratch in (0x00, 0xFF)]
        check(runs[0] == runs[1], f'${op:02X} at ${y:04X} depends on scratch')
        ends = runs[0]
        check(len(ends) == 1 and ends[0][0] == y + 3, f'${op:02X} at ${y:04X} does not go on')
        saved = 7 * 0x80 + slot
        check([ends[0][2].get(0x7F0580 + saved), ends[0][2].get(0x7F0581 + saved)] == [0x34, 0x12],
              f'${op:02X} at ${y:04X} did not save the target\'s position at level 7')
        written, offset = ends[0][2], function_offset(slot // 2, arg & 15)
        check([written.get(OBJ_SCRIPT_POS + slot), written.get(OBJ_SCRIPT_POS + slot + 1)] == [offset & 255, offset >> 8],
              f'${op:02X} at ${y:04X} did not point object {slot // 2} at its function {arg & 15}')
        check(written.get(OBJ_LEVEL + slot) == arg >> 4, f'${op:02X} at ${y:04X} did not set level {arg >> 4}')
    elif op == 0xB8:
        reloc = lowered['relocations']
        check(reloc == [{'offset': 2 + y, 'size': 3, 'kind': 'messageTable'}], f'relocation {reloc}')
        patched = bytearray(data)
        patched[2 + y:5 + y] = bytes([0x34, 0x12, 0xFD])
        ends = execute(interp, absint, bytes(patched), y, {})
        written = ends[0][2] if len(ends) == 1 else {}
        check([written.get(0x7E012B), written.get(0x7E012C), written.get(0x7E012D)] == [0x34, 0x12, 0xFD],
              'relocated pointer is not what OpB8 stores in Field_Unk2B/2D')
        check(ends[0][0] == y + 4, 'OpB8 does not go on')
check({0x65, 0x16, 0x10, 0x11, 0xB8, 0xBB, 0xAD, 0x00, 0xB2, 0x02, 0x05, 0x94} <= seen, f'fixture lowering misses opcodes: {sorted(seen)}')
print(f'event lowering: {checks} checks passed against ROM handlers')
