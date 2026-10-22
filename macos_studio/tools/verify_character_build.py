#!/usr/bin/env python3
"""Import the playable characters with the real CLI, build, and check it independently.

A copy of the fixture project imports the ROM's characters
(`chronoforge characters import`); each imported record and its growth rows
must equal re_workspace/tools/ct_characters.py's decode, and each character's
level curve (`characters curve --json`, from the project and from the ROM)
its Python rule. Building the unmodified import must give the clean ROM
byte for byte with no writes. Then a few edits (stats, HP, a growth row,
equipment from the party catalog, a level with its experience) are built
and checked by re_workspace/tools/ct_rom_check.py, which must also reject
damaged copies and a report that claims equipment the character cannot use;
the CLI refuses an out-of-range edit. Needs the user's ROM and the venv.
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
import ct_characters as cc  # noqa: E402
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


clean = cc.read_rom(rom)
table = cc.exp_to_level(clean)
with tempfile.TemporaryDirectory(prefix='chronoforge-characters-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    print(run(cli, 'characters', 'import', rom, '--project', project), end='')

    # The import is the Python decode; the curves are the Python rule.
    meta = json.loads((project / 'project.json').read_text())
    ids = meta['rom']['characters']
    if len(ids) != cc.CHARACTERS:
        fail(f'rom.characters {ids}')
    party = json.loads((project / 'party.json').read_text())
    if party['expToLevel'] != table:
        fail('party.json expToLevel is not the ROM table')
    for i, cid in enumerate(ids):
        doc = json.loads((project / f'characters/{cid}.json').read_text())
        if ct_rom_check.report_value({'record': doc['pc']}) != cc.decode_record(cc.record(clean, i)):
            fail(f'{cid}: the imported record is not the Python decode')
        if ct_rom_check.report_growth(doc['growth']) != cc.decode_growth(clean, i):
            fail(f'{cid}: the imported growth rows are not the Python decode')
        want = cc.curve_rows(cc.level_curve(cc.decode_record(cc.record(clean, i)), cc.decode_growth(clean, i), table))
        for source, key in ((project, cid), (rom, str(i))):
            got = json.loads(run(cli, 'characters', 'curve', source, key, '--json'))
            if got['columns'] != list(cc.CURVE_COLUMNS) or got['rows'] != want:
                fail(f'{cid}: the CLI curve from {source.name} differs from ct_characters.py')
    print(f'characters: 7 imports and 14 CLI curves equal the Python decode and rule')

    # Unmodified import: the clean ROM, no writes.
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != rom.read_bytes()[-len(clean):] or doc['writes'] or len(doc['characters']) != 7:
        fail('the unmodified import does not build to the clean ROM')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    print('characters: import then build is byte-identical to the clean ROM')

    # Edits.
    def edit(cid, change):
        path = project / f'characters/{cid}.json'
        doc = json.loads(path.read_text())
        change(doc)
        path.write_text(json.dumps(doc, indent=2))
        return doc

    def robo(d):
        d['pc']['stats']['power'] += 1
        d['pc']['maxHp'] += 5
        d['growth']['hp'][0]['gain'] += 1
    edit('robo', robo)
    crono_bit = 0x80 >> 0
    current = json.loads((project / 'characters/crono.json').read_text())['pc']['equipment']['weapon']
    sword = next(e['id'] for e in party['equipment']
                 if e['slot'] == 'weapon' and e['equipMask'] & crono_bit and e['id'] != current)
    edit('crono', lambda d: d['pc']['equipment'].update(weapon=sword))

    def lucca(d):
        d['pc']['level'] = 5
        d['pc']['exp'] = sum(table[1:5])
        d['pc']['expToNext'] = table[5]
        d['pc']['growthBase']['magic'] += 1
    edit('lucca', lucca)
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    written = sorted(w['what'] for w in doc['writes'] if w['what'] != 'checksum')
    expect = sorted(['character robo power', 'character robo max HP', 'character robo HP growth',
                     'character crono weapon', 'character lucca level', 'character lucca exp',
                     'character lucca exp to next', 'character lucca growth base'])
    if written != expect:
        fail(f'writes {written}')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')

    # The checker must notice damage that keeps the header and report consistent.
    robo_pc = cc.RECORDS_PC + cc.RECORD_SIZE * 3
    hp_row = cc.HP_GROWTH_PC + cc.GROWTH_ROW * 3
    crono_pc = cc.RECORDS_PC
    marle_weapon = cc.decode_record(cc.record(clean, 1))['equipment']['weapon']

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

    def claim_bow(d):
        next(c for c in d['characters'] if c['id'] == 'crono')['record']['equipment']['weapon'] = marle_weapon
    cases = ((dict(where=robo_pc + 0x0B), 'the record is not the reported values'),
             (dict(where=hp_row + 1), 'growth rows are not the reported ones'),
             (dict(where=robo_pc + 0x19, extra_write=robo_pc + 0x19), 'outside free space'),
             (dict(where=cc.EXP_TO_LEVEL_PC + 10), 'not in a report write'),
             (dict(where=crono_pc + 0x29, value=marle_weapon, change=claim_bow), 'character crono: weapon'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage at ${kwargs["where"]:06X} not reported as "{message}": {result.stdout}{result.stderr}')
    print(f'characters: {len(cases)} damaged copies rejected by the checker')

    # The CLI refuses an out-of-range edit and writes nothing.
    edit('frog', lambda d: d['pc'].update(level=0))
    refused = subprocess.run([str(cli), 'rom', 'build', str(project), '--base', str(rom), '--out', str(directory / 'x.sfc')],
                             capture_output=True, text=True, timeout=600)
    if refused.returncode == 0 or (directory / 'x.sfc').exists() or 'not 1-99' not in refused.stdout + refused.stderr:
        fail(f'level 0 was accepted: {refused.stdout}{refused.stderr}')
print('characters: CLI import, curves and build checked independently')
