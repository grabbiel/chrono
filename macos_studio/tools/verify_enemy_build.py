#!/usr/bin/env python3
"""Import the enemies with the real CLI, build, and check it independently.

A copy of the fixture project imports the ROM's enemies
(`chronoforge enemies import`); each imported stat record, reward, name and
AI script text must equal re_workspace/tools/ct_enemies.py's decode, and
`enemies verify` must accept the clean ROM. Building the unmodified import
must give the clean ROM byte for byte with no writes. Then a few edits
(HP, a stat, an affinity, rewards, a level, a name) are built and checked by
re_workspace/tools/ct_rom_check.py; the ROM's own loader BattleFD_UnkB438
and reward routine BattleFD_AddEnemyRewards run (ChronoRET's 65816
interpreter) on the built ROM for every edited enemy must give the edited
values; `enemies verify` accepts the built ROM. The checker must reject
damaged copies, and the CLI refuses out-of-range edits and writes nothing.
Needs the user's ROM, the ChronoRET checkout and the venv.
"""
import json
import shutil
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
import ct_rom_check  # noqa: E402
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


clean = ce.read_rom(rom)
glyphs = ce._glyphs()
lengths = ce.act_lengths(clean)
with tempfile.TemporaryDirectory(prefix='chronoforge-enemies-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    print(run(cli, 'enemies', 'import', rom, '--project', project), end='')

    # The import is the Python decode.
    meta = json.loads((project / 'project.json').read_text())
    ids = meta['rom']['enemies']
    if len(ids) != ce.EMPTY_ID:
        fail(f'rom.enemies has {len(ids)} files')
    scripts = 0
    for e, eid in enumerate(ids):
        doc = json.loads((project / f'characters/{eid}.json').read_text())
        if doc['kind'] != 'enemy' or doc['enemy']['enemyId'] != e:
            fail(f'{eid}: kind or enemy id')
        stats, reward = ct_rom_check.report_enemy(doc)
        if stats != ce.decode_stats(ce.stats_record(clean, e)) or reward != ce.decode_reward(ce.reward_record(clean, e)):
            fail(f'{eid}: the imported record is not the Python decode')
        name = ce.decode_name(ce.name_record(clean, e), glyphs) if e < ce.NAMED else ''
        if doc['name'] != (name or f'Enemy {e:03d}'):
            fail(f'{eid}: the imported name is not the Python decode')
        want = ce.decode_script(clean, e, lengths)
        got = doc['enemy']['ai']
        if got['address'] != want['address'] or got.get('text') != want.get('text') or ('error' in got) != ('error' in want):
            fail(f'{eid}: the imported AI script is not the Python decode')
        scripts += 'text' in got
    print(f'enemies: {len(ids)} imports equal the Python decode ({scripts} AI scripts as text)')
    print(run(cli, 'enemies', 'verify', project, rom), end='')

    # Unmodified import: the clean ROM, no writes.
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != rom.read_bytes()[-len(clean):] or doc['writes'] or len(doc['enemies']) != len(ids):
        fail('the unmodified import does not build to the clean ROM')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    print('enemies: import then build is byte-identical to the clean ROM')

    # Edits.
    def edit(e, change):
        path = project / f'characters/{ids[e]}.json'
        d = json.loads(path.read_text())
        change(d)
        path.write_text(json.dumps(d, indent=2))
        return d

    def first(d):
        r = d['enemy']
        r['hp'] = r['hp'] - 1 if r['hp'] > 1 else 2
        r['stats']['magic'] ^= 1
        r['affinity']['fire'] = 0x88 if r['affinity']['fire'] != 0x88 else 4
        r['reward']['gold'] ^= 0x100
        r['reward']['exp'] ^= 0x01
        d['name'] = 'Edited'
    edit(5, first)
    item = next(i for i in range(1, ce.ITEM_COUNT) if i != ce.decode_reward(ce.reward_record(clean, 9))['drop'])

    def second(d):
        d['enemy']['level'] = (d['enemy']['level'] + 1) % 100
        d['enemy']['reward']['drop'] = item
        d['enemy']['reward']['charm'] = item
    edit(9, second)
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    written = sorted(w['what'] for w in doc['writes'] if w['what'] != 'checksum')
    a, b = ids[5], ids[9]
    expect = sorted([f'enemy {a} hp', f'enemy {a} magic', f'enemy {a} affinity', f'enemy {a} exp',
                     f'enemy {a} gold', f'enemy {a} name', f'enemy {b} level', f'enemy {b} drop', f'enemy {b} charm'])
    if written != expect:
        fail(f'writes {written}')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    print(run(cli, 'enemies', 'verify', project, out), end='')

    # The game's own loader and reward routine on the built ROM give the edited values.
    built = out.read_bytes()
    runner = ce.RomEnemy(built)
    runs = 0
    for e in (5, 9):
        d = json.loads((project / f'characters/{ids[e]}.json').read_text())
        stats, reward = ct_rom_check.report_enemy(d)
        raw = ce.encode_stats(stats)
        for entry in (0, 7):
            if runner.load(e, entry) != ce.expected_block(raw, e):
                fail(f'{ids[e]}: BattleFD_UnkB438 on the built ROM does not load the edited record')
            got = runner.reward(e, entry, (0, 0, 0), [0] * 6)
            if got != ce.expected_reward(reward, (0, 0, 0), [0] * 6, e):
                fail(f'{ids[e]}: BattleFD_AddEnemyRewards on the built ROM does not add the edited rewards')
            runs += 2
    print(f'enemies: {runs} of {runs} loader and reward runs on the built ROM give the edited values')

    # The checker must notice damage that keeps the header and report consistent.
    stats_a = ce.STATS_PC + ce.STATS_SIZE * 5
    reward_b = ce.REWARDS_PC + ce.REWARDS_SIZE * 9
    other = ce.STATS_PC + ce.STATS_SIZE * 40
    pointer = ce.AI_PTRS_PC + 2 * 5

    def damaged(where, value=None, extra_write=None, change=None):
        data = bytearray(out.read_bytes())
        data[where] = data[where] ^ 0x01 if value is None else value
        total = layout.checksum(data)
        data[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
        bad_doc = dict(doc, outputSHA256=packs.sha(data), checksum=total)
        if extra_write:
            bad_doc['writes'] = doc['writes'] + [{'pc': extra_write, 'length': 1, 'what': 'damage'}]
        if change:
            bad_doc = json.loads(json.dumps(bad_doc))
            change(bad_doc)
        bad, bad_report = directory / 'damaged.sfc', directory / 'damaged.json'
        bad.write_bytes(data)
        bad_report.write_text(json.dumps(bad_doc))
        return check_rom(bad, bad_report)

    def claim_charm(d):
        next(e for e in d['enemies'] if e['enemyId'] == 9)['enemy']['reward']['charm'] = 0xF5
    cases = ((dict(where=stats_a + 0x0A), 'the stat record is not the reported values'),
             (dict(where=reward_b + 4), 'the reward record is not the reported values'),
             (dict(where=other + 2), 'not in a report write'),
             (dict(where=pointer, extra_write=pointer), 'outside free space'),
             (dict(where=reward_b + 5, value=0xF5, change=claim_charm), 'drop or charm'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage at ${kwargs["where"]:06X} not reported as "{message}": {result.stdout}{result.stderr}')
    print(f'enemies: {len(cases)} damaged copies rejected by the checker')

    # The CLI refuses out-of-range edits and writes nothing.
    refusals = ((lambda d: d['enemy'].update(hp=40000), '0-32767'),
                (lambda d: d['enemy']['reward'].update(charm=0xF5), 'below $F2'),
                (lambda d: d.update(name='A name too long'), 'the most is 11'),
                (lambda d: d['enemy'].update(attackId=23), 'not 0-22'))
    path = project / f'characters/{ids[12]}.json'
    original = path.read_text()
    for change, message in refusals:
        edit(12, change)
        target = directory / 'x.sfc'
        refused = subprocess.run([str(cli), 'rom', 'build', str(project), '--base', str(rom), '--out', str(target)],
                                 capture_output=True, text=True, timeout=600)
        if refused.returncode == 0 or target.exists() or message not in refused.stdout + refused.stderr:
            fail(f'a bad edit was accepted ({message}): {refused.stdout}{refused.stderr}')
        path.write_text(original)
    print(f'enemies: {len(refusals)} out-of-range edits refused by the CLI')
print('enemies: CLI import, build and the ROM loader checked independently')
