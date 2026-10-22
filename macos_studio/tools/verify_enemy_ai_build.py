#!/usr/bin/env python3
"""Write enemy AI scripts back with the real CLI, and check it three ways.

A copy of the fixture project imports the ROM's enemies (`chronoforge
enemies import`). Building the unmodified import, with every enemy's
script listed as text, must give the clean ROM byte for byte with no
writes. Then three invented scripts are built:

  - one in place: an enemy whose script is not shared and is long enough;
  - one relocated from a shared script: enemy 98, whose script's head is
    enemy 97's tail;
  - one relocated because it grows past its span.

re_workspace/tools/ct_rom_check.py must accept the built ROM: only those
pointers and spans change, each script re-decodes to the report and every
other script is unchanged. The ROM's own BattleAi_RunMainPart and
BattleAi_FindReactPart run (ChronoRET's 65816 interpreter) on the built
ROM for each edited enemy: the test records read, the block, the action
and the target chosen, and the reaction part found must be the project
script's; enemy 97 (the sharer) and the other neighbours must behave on
the built ROM exactly as on the clean ROM. The checker must reject
damaged copies, and the CLI refuses scripts the game cannot step, scripts
that do not fit and an enemy id out of range, and writes nothing.
Needs the user's ROM, the ChronoRET checkout and the venv.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

package = Path(__file__).resolve().parents[1]
workspace = package.parent / 're_workspace'
cli = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else package / '.build/debug/chronoforge'
python = workspace / '.venv/bin/python'
rom = workspace / 'ct_clean.sfc'
fixture = package / 'Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj'
sys.path.insert(0, str(workspace / 'tools'))
import ct_enemies as ce  # noqa: E402
import ct_event_packs as packs  # noqa: E402
import ct_rom_layout as layout  # noqa: E402


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise SystemExit(f'FAIL: {" ".join(map(str, args[:3]))}…\n{result.stdout}{result.stderr}')
    return result.stdout


def fail(message):
    raise SystemExit(f'FAIL: {message}')


def check_rom(built, report):
    return subprocess.run([str(python), str(workspace / 'tools/ct_rom_check.py'), str(built), str(report)],
                          capture_output=True, text=True, timeout=600)


def block(test, act):
    return f'  block\n    test {test}\n    act {act}\n'


FAILS = '$04 EnemyIdPresent b1=$00 id=$EE absent=$00'          # enemy $EE is not in the battle
ALWAYS = '$00 Always b1=$00 b2=$00 b3=$00'


def present(e):
    return f'$04 EnemyIdPresent b1=$00 id=${e:02X} absent=$00'  # the enemy itself: holds


def script(main, reaction=''):
    return 'main\n' + ''.join(main) + 'reaction\n' + reaction + 'end\n'


clean = ce.read_rom(rom)
lengths = ce.act_lengths(clean)
spans = ce.script_spans(clean, lengths)
shared = ce.sharers(spans)
SHARED, SHARER = 98, 97
if shared.get(SHARED) != [SHARER]:
    fail(f'enemy {SHARED} does not share its script with {SHARER} alone: {shared.get(SHARED)}')

# Invented scripts (no ROM data): a failing block, then one that holds.
def in_place(e):
    return script([block(FAILS, '$01 Attack id=$01 target=$03 arg=$00'),
                   block(present(e), '$02 Tech tech=$05 target=$03 helper1=$00 helper2=$00 message=$00')],
                  block(ALWAYS, '$0F Message byte=$01'))


relocated = script([block(FAILS, '$01 Attack id=$01 target=$03 arg=$00'),
                    block(ALWAYS, '$01 Attack id=$01 target=$03 arg=$00')],
                   block(ALWAYS, '$09 Leave action=$01'))


def grown(n):
    return script([block(FAILS, '$0F Message byte=$02')] * n + [block(ALWAYS, '$01 Attack id=$02 target=$03 arg=$00')])


skip = {127, SHARED, SHARER, 0xEE} | set(shared)
size = lambda text: len(ce.ai_assemble(text, lengths))
IN_PLACE = next(e for e in range(1, ce.EMPTY_ID) if e not in skip and e in spans and len(spans[e]) >= size(in_place(e)))
GROWN = next(e for e in range(1, ce.EMPTY_ID) if e not in skip | {IN_PLACE} and e in spans and len(spans[e]) < 60)
GROWN_TEXT = next(grown(n) for n in range(1, 20) if size(grown(n)) > len(spans[GROWN]))
EDITS = {IN_PLACE: in_place(IN_PLACE), SHARED: relocated, GROWN: GROWN_TEXT}

with tempfile.TemporaryDirectory(prefix='chronoforge-enemy-ai-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    run('cp', '-R', fixture, project)
    print(run(cli, 'enemies', 'import', rom, '--project', project), end='')
    meta = json.loads((project / 'project.json').read_text())
    ids = meta['rom']['enemies']
    texts = sum('text' in json.loads((project / f'characters/{i}.json').read_text())['enemy']['ai'] for i in ids)
    doc98 = json.loads((project / f'characters/{ids[SHARED]}.json').read_text())['enemy']['ai']
    if doc98.get('shared') != [SHARER] or doc98.get('size') != len(spans[SHARED]):
        fail(f'the import does not record enemy {SHARED}\'s span and sharer: {doc98}')

    # Unmodified import, every script listed as text: the clean ROM, no writes.
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != rom.read_bytes()[-len(clean):] or doc['writes'] or doc.get('enemyScripts'):
        fail('the unmodified import does not build to the clean ROM')
    print(f'enemy AI: import then build is byte-identical ({texts} scripts listed as text; enemy 127 kept)')

    # Edits.
    def edit(e, text):
        path = project / f'characters/{ids[e]}.json'
        d = json.loads(path.read_text())
        d['enemy']['ai']['text'] = text
        path.write_text(json.dumps(d, indent=2))

    for e, text in EDITS.items():
        edit(e, text)
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    got = {s['enemyId']: s for s in doc.get('enemyScripts') or []}
    if sorted(got) != sorted(EDITS):
        fail(f'scripts written for {sorted(got)}')
    placement = {e: got[e]['placement'] for e in got}
    if placement != {IN_PLACE: 'original', SHARED: 'free', GROWN: 'free'}:
        fail(f'placements {placement}')
    if got[IN_PLACE]['pc'] != spans[IN_PLACE].start:
        fail('the in-place script moved')
    written = sorted(w['what'] for w in doc['writes'] if w['what'] != 'checksum')
    expect = sorted([f'enemy {ids[e]} AI script' for e in EDITS]
                    + [f'BattleRom_AiScriptPtrs[{e}]' for e in (SHARED, GROWN)])
    if written != expect:
        fail(f'writes {written}')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    for e in sorted(EDITS):
        s = got[e]
        print(f'enemy AI: {ids[e]} {s["placement"]:8} {s["from"]} -> {s["address"]} ({s["bytes"]} bytes)')

    # The ROM's own script reader on the built ROM.
    built = out.read_bytes()
    after, before = ce.RomAi(built), ce.RomAi(clean)
    data = ce.bank(built)
    runs = 0
    for e in sorted(EDITS):
        at = ce.script_pointer(built, e)
        parts, end = ce.parse_script(data, at, lengths)
        want = ce.expected_main(parts, at, {e})
        for entry in (0, 5):
            outcome, reads, _ = after.main(e, entry)
            want_entry = dict(want, target=None if want['target'] is None else want['target'] + entry)
            if outcome != want_entry:
                fail(f'{ids[e]} entry {entry}: RunMainPart chose {outcome}, the project script says {want_entry}')
            span = set(range(ce.pc(ce.AI_BANK, at), ce.pc(ce.AI_BANK, end)))
            pointer = {ce.AI_PTRS_PC + 2 * e, ce.AI_PTRS_PC + 2 * e + 1}
            if not set(reads) <= span | pointer:
                fail(f'{ids[e]}: RunMainPart read outside the script: {sorted(set(reads) - span - pointer)[:4]}')
            starts, x = [], at
            for tests, actions in parts[0][:want['block'] + 1]:
                starts.append(ce.pc(ce.AI_BANK, x))
                x += 4 * len(tests) + 1 + sum(map(len, actions)) + 1
            if not set(starts) <= set(reads):
                fail(f'{ids[e]}: RunMainPart did not read the test of every block up to the chosen one')
            runs += 1
        react, _ = after.reaction(e)
        if react != at + len(ce.assemble_parts(parts[:1])):
            fail(f'{ids[e]}: FindReactPart found ${react:04X}')
        runs += 1
        changed = before.main(e)[0] != after.main(e)[0]
        print(f'enemy AI: {ids[e]} on the built ROM: block {want["block"]}, act ${want["act"]:02X} at '
              f'${want["action"]:04X}, target slot {want["target"]}, reaction at ${react:04X}'
              + ('' if changed else ' (the clean script happens to choose the same)'))
    # The sharer and the edited scripts' neighbours behave as on the clean ROM.
    neighbours = sorted({SHARER, IN_PLACE - 1, IN_PLACE + 1, GROWN - 1, GROWN + 1, 244, 245} - set(EDITS) - {127})
    for e in neighbours:
        for entry in (0, 5):
            if after.main(e, entry) != before.main(e, entry):
                fail(f'enemy {e}: RunMainPart behaves differently on the built ROM')
            runs += 1
        if after.reaction(e) != before.reaction(e):
            fail(f'enemy {e}: FindReactPart behaves differently on the built ROM')
        runs += 1
    print(f'enemy AI: {runs} of {runs} interpreter runs on the built ROM match the project scripts '
          f'(edited {sorted(EDITS)}; unchanged {neighbours}, the sharer {SHARER} among them)')

    # The checker must notice damage that keeps the header and report consistent.
    new98 = got[SHARED]['pc']
    old97 = spans[SHARER].start
    pointer98 = ce.AI_PTRS_PC + 2 * SHARED

    def damaged(where=None, value=None, extra_write=None, change=None):
        data = bytearray(out.read_bytes())
        if where is not None:
            data[where] = data[where] ^ 0x01 if value is None else value
        total = layout.checksum(data)
        data[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
        bad_doc = json.loads(json.dumps(dict(doc, outputSHA256=packs.sha(data), checksum=total)))
        if extra_write:
            bad_doc['writes'].append({'pc': extra_write, 'length': 1, 'what': 'damage'})
        if change:
            change(bad_doc)
        bad, bad_report = directory / 'damaged.sfc', directory / 'damaged.json'
        bad.write_bytes(data)
        bad_report.write_text(json.dumps(bad_doc))
        return check_rom(bad, bad_report)

    def script_of(d, e):
        return next(s for s in d['enemyScripts'] if s['enemyId'] == e)

    cases = ((dict(where=new98 + 1), 'script bytes'),
             (dict(where=pointer98, value=spans[SHARED].start & 0xFF), 'AI pointer is'),
             (dict(where=old97 + 1, extra_write=old97 + 1), 'outside free space'),
             (dict(change=lambda d: script_of(d, SHARED).update(placement='original')), 'outside free space'),
             (dict(change=lambda d: script_of(d, IN_PLACE).update(text=relocated)), 'does not re-decode'),
             (dict(change=lambda d: d['enemyScripts'].remove(script_of(d, GROWN))), 'outside free space'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage {kwargs} not reported as "{message}": {result.stdout}{result.stderr}')
    print(f'enemy AI: {len(cases)} damaged copies rejected by the checker')

    # The CLI refuses scripts the game cannot step or that do not fit, and writes nothing.
    act = '$01 Attack id=$01 target=$03 arg=$00'
    refusals = ((script([block(ALWAYS, '$09 Leave action=$FE')]), 'holds $FE or $FF'),
                (script([block(ALWAYS, '$03 Nop03')]), 'no act $03'),
                (script([block(ALWAYS, '$05 ChooseRepeat')]), 'no act $05'),
                (script([block('$29 Unknown b1=$00 b2=$00 b3=$00', act)]), 'no test $29'),
                (script([block(ALWAYS, '$17 Unknown $00')]), 'no act $17'),
                (script([block(ALWAYS, '$01 Attack id=$01 target=$39 arg=$00')]), 'past BattleAi_TargetTable'),
                (script([block('$17 Chance percent=$FF b2=$00 b3=$00', act)]), 'holds $FF'),
                (script([block(ALWAYS, act)])[:-len('end\n')], 'no end line'),
                (script([block(FAILS, act)] * 100), 'no room'),
                (None, 'the enemy id must be 0-254'))
    path = project / f'characters/{ids[12]}.json'
    original = path.read_text()
    for text, message in refusals:
        d = json.loads(original)
        if text is None:
            d['enemy']['enemyId'] = 255
        else:
            d['enemy']['ai']['text'] = text
        path.write_text(json.dumps(d))
        target = directory / 'x.sfc'
        refused = subprocess.run([str(cli), 'rom', 'build', str(project), '--base', str(rom), '--out', str(target)],
                                 capture_output=True, text=True, timeout=600)
        if refused.returncode == 0 or target.exists() or message not in refused.stdout + refused.stderr:
            fail(f'a bad script was accepted ({message}): {refused.stdout}{refused.stderr}')
        path.write_text(original)
    print(f'enemy AI: {len(refusals)} bad scripts refused by the CLI')
print('enemy AI: CLI write-back, the independent check and the ROM\'s script reader agree')
