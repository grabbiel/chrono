#!/usr/bin/env python3
"""Import the tech system with the real CLI, build, and check it independently.

A copy of the fixture project imports the ROM's characters and techs
(`chronoforge characters import`, `characters techs import`); tech_system.json
must equal re_workspace/tools/ct_techs.py's decode, and `characters techs tp
--json` (from the project and from the ROM) its tech-point rule. Building
the unmodified import must give the clean ROM byte for byte with no writes.
Then edits (a target mode, an area, an element, the unlock bit, an animation,
a part's MP and power, tech-point costs, a combination's requirements, the
new-game state) are built and checked by re_workspace/tools/ct_rom_check.py;
the game's own AwardTechPoints, run in ChronoRET's interpreter over the built
ROM, must learn as the rule says on the edited tables. The checker must
reject damaged copies and the CLI must refuse out-of-range and read-only
edits. Needs the user's ROM, the venv and refs/ChronoRET.
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
import ct_event_packs as packs  # noqa: E402
import ct_rom_layout as layout  # noqa: E402
import ct_techs as ct  # noqa: E402


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise SystemExit(f'FAIL: {" ".join(map(str, args[:4]))}…\n{result.stdout}{result.stderr}')
    return result.stdout


def fail(message):
    raise SystemExit(f'FAIL: {message}')


def check_rom(built, report):
    return subprocess.run([str(python), str(workspace / 'tools/ct_rom_check.py'), str(built), str(report)],
                          capture_output=True, text=True, timeout=600)


def swift_tech(v):
    """ct_techs.decode_tech in tech_system.json's names (the fields both decode)."""
    return {'id': v['id'], 'kind': v['kind'], 'targetMode': v['target_mode'], 'fieldMenu': v['field_menu'],
            'area': v['area'], 'userSet': v['user_set'], 'needsUnlock': v['needs_unlock'], 'flags': v['flags'],
            'element': ct.element_of(v['element_bits'] << 4), 'attr': v['attr'], 'parts': v['parts'],
            'modifiers': v['modifiers'],
            'anim': {'script': v['anim']['script'], 'gfxA': v['anim']['gfx_a'], 'gfxB': v['anim']['gfx_b'],
                     'frames': v['anim']['frames'], 'pal': v['anim']['pal'], 'obj': v['anim']['obj'],
                     'arg': v['anim']['arg']}}


def rule_states(states):
    """Rule states in the CLI's names; of +$02 only bit 4, the bit the rule reads and sets
    (a project's character record does not keep the rest of the byte)."""
    out = [ct.swift_state(s) for s in states]
    for s in out:
        for slot in filter(None, s['slots']):
            slot['flags'] &= ct.ALL_TECHS
    return out


def party_arg(party):
    return ','.join('-' if c is None else ct.NAMES[c] for c in party)


clean = ct.read_rom(rom)
with tempfile.TemporaryDirectory(prefix='chronoforge-techs-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    run(cli, 'characters', 'import', rom, '--project', project)
    print(run(cli, 'characters', 'techs', 'import', rom, '--project', project), end='')

    # The import is the Python decode.
    system = json.loads((project / 'tech_system.json').read_text())
    decoded = ct.decode_all(clean)
    for got, want in zip(system['techs'], decoded['techs'], strict=True):
        if {k: got.get(k) for k in swift_tech(want)} != swift_tech(want):
            fail(f'tech ${want["id"]:02X}: the import is not the Python decode')
        if got['name'] != want['name'].strip() or got.get('icon') != want['icon']:
            fail(f'tech ${want["id"]:02X}: name {got["name"]!r} / {want["name"]!r}')
    for got, want in zip(system['parts'], decoded['parts'], strict=True):
        if got['mp'] != want['mp'] or [got['effect'][k] for k in ct.SWIFT_EFFECT_FIELDS] != list(want['effect'].values()):
            fail(f'part {want["id"]}: the import is not the Python decode')
    if system['tpCost'] != decoded['tp_cost'] or system['userSets'] != decoded['user_sets']:
        fail('tpCost or userSets differ from the Python decode')
    if [(c['mask'], c['first'], c['requirements']) for c in system['combos']] != \
            [(c['mask'], c['first'], c['requirements']) for c in decoded['combos']]:
        fail('the combination records differ from the Python decode')
    learned = decoded['learned']
    if system['learned'] != {'counts': learned['counts'], 'bits1': learned['bits1'], 'comboBits': learned['combo_bits']}:
        fail('the new-game state differs from the Python decode')
    if [[[a['shape'], a['param'], a['size']] for a in area] for area in system['areas']] != decoded['areas']:
        fail('the areas differ from the Python decode')
    print(f'techs: the import equals the Python decode ({ct.TECHS} techs, {ct.PARTS} parts, '
          f'{len(system["combos"])} combination records)')

    # The CLI's tech-point runs are the Python rule, from the project and from the ROM.
    def rule_run(image, party, awards, unlock):
        t, s = ct.tables(image), ct.starting_state(image, party, unlock)
        states = [s]
        for a in awards:
            states.append(ct.award_tech_points(t, states[-1], a))
        return states

    runs = (((0, 1, 2), 0), ((3, 4, 5), 0x7F), ((6, None, 4), 0x40), ((None, 5, 1), 0x02))
    awards = (7, 30, 99, 400, 1000, 65535)
    for party, unlock in runs:
        want = rule_states(rule_run(clean, party, awards, unlock))
        for source in (project, rom):
            got = json.loads(run(cli, 'characters', 'techs', 'tp', source, '--party', party_arg(party),
                                 '--award', ','.join(map(str, awards)), '--unlock', hex(unlock), '--json'))
            if got['awards'] != list(awards) or got['states'] != want:
                fail(f'tp {party_arg(party)} from {source.name} differs from ct_techs.py')
    print(f'techs: {2 * len(runs)} CLI tech-point runs equal the Python rule')

    # Unmodified import: the clean ROM, no writes.
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != rom.read_bytes()[-len(clean):] or doc['writes'] or not doc.get('techs'):
        fail('the unmodified import does not build to the clean ROM')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    print('techs: import then build is byte-identical to the clean ROM')

    # Edits.
    path = project / 'tech_system.json'
    s = json.loads(path.read_text())
    techs = s['techs']
    cyclone, slash = 1, 2
    techs[slash]['targetMode'] = (techs[slash]['targetMode'] + 1) % ct.TARGET_MODES
    with_area = next(t for t in techs if t['area'])
    other_area = next(a for a in range(1, ct.AREAS) if a != with_area['area'] and s['areas'][a])
    with_area['area'] = other_area
    plain = next(t for t in techs[1:ct.FIRST_DOUBLE] if t.get('element') is None)
    plain['element'] = 'fire'
    locked = next(t for t in techs[1:ct.FIRST_DOUBLE] if t['needsUnlock'])
    locked['needsUnlock'] = False
    techs[cyclone]['anim']['frames'] = (techs[cyclone]['anim']['frames'] + 1) % ct.ANIM_FRAMES
    part = techs[cyclone]['parts'][0] & 0x7F
    s['parts'][part]['mp'] = (s['parts'][part]['mp'] + 1) % 100
    s['parts'][part]['effect']['power'] = (s['parts'][part]['effect']['power'] + 1) & 0xFF
    s['tpCost'][0][1] += 10                             # crono's second single
    combo = s['combos'][0]
    combo['requirements'][0][0] = combo['requirements'][0][0] % 8 + 1
    s['learned']['counts'][4] = 8                       # frog starts with every single
    s['learned']['bits1'][4] = 0xFF
    path.write_text(json.dumps(s, indent=2))
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    written = sorted(w['what'] for w in doc['writes'] if w['what'] != 'checksum')
    expect = sorted([f'tech ${slash:02X} target', f'tech ${with_area["id"]:02X} target',
                     f'tech ${plain["id"]:02X} element', f'tech ${locked["id"]:02X} unlock',
                     f'tech ${cyclone:02X} animation frames', f'part {part} MP', f'part {part} effect',
                     'TechTpCost', f'combination ${combo["first"]:02X} requirements', 'new-game tech state',
                     'record 4 all-singles bit'])
    if written != expect:
        fail(f'writes {written}')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    built = out.read_bytes()
    after = ct.decode_tech(built, slash)
    if after['target_mode'] != techs[slash]['targetMode'] or ct.decode_part(built, part)['mp'] != s['parts'][part]['mp']:
        fail('the built ROM does not decode to the edits')
    print(f'techs: {len(expect)} edits written where the report says and checked by ct_rom_check.py')

    # The game's own routine learns from the edited tables as the rule does.
    runner = ct.RomTechPoints(built)
    for party, unlock in runs[:2]:
        states = rule_run(built, party, awards, unlock)
        cli_states = json.loads(run(cli, 'characters', 'techs', 'tp', project, '--party', party_arg(party),
                                    '--award', ','.join(map(str, awards)), '--unlock', hex(unlock), '--json'))['states']
        if cli_states != rule_states(states):
            fail(f'tp {party_arg(party)} on the edited project differs from the rule on the built ROM')
        for before, award, want in zip(states, awards, states[1:]):
            if runner.award(before, award) != want:
                fail(f'AwardTechPoints on the built ROM ({party_arg(party)}, award {award}) is not the rule')
    edited = rule_run(built, (0, 1, 2), awards, 0)
    if edited == rule_run(clean, (0, 1, 2), awards, 0):
        fail('the edited TP cost changed nothing')
    print(f'techs: AwardTechPoints on the built ROM equals the rule and the CLI ({2 * len(awards)} awards)')

    # The checker must notice damage that keeps the header and report consistent.
    rec = lambda t: ct.TECH_REC_PC + ct.TECH_REC_SIZE * t  # noqa: E731

    def damaged(where, bit=0x01, change=None):
        data = bytearray(built)
        if where is not None:
            data[where] ^= bit
        total = layout.checksum(data)
        data[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
        bad_doc = json.loads(json.dumps(dict(doc, outputSHA256=packs.sha(data), checksum=total)))
        if change:
            change(bad_doc)
        bad, bad_report = directory / 'damaged.sfc', directory / 'damaged.json'
        bad.write_bytes(data)
        bad_report.write_text(json.dumps(bad_doc))
        return check_rom(bad, bad_report)

    def claim_old_mode(d):
        d['techs']['techs'][slash]['targetMode'] = decoded['techs'][slash]['target_mode']

    def claim_lightning(d):
        d['techs']['techs'][plain['id']]['element'] = 'lightning'
    # Each damaged byte but the second and third is inside a write the report names.
    cases = ((dict(where=rec(locked['id'])), f'tech ${locked["id"]:02X}: user_set is read-only'),
             (dict(where=rec(5) + 2), 'not in a report write'),
             (dict(where=ct.CHAR_TECHS_PC + 1), 'not in a report write'),
             (dict(where=rec(plain['id']) + 3), f'tech ${plain["id"]:02X}: attr is read-only'),
             (dict(where=rec(plain['id']) + 3, bit=0x80, change=claim_lightning), 'more than one element bit'),
             (dict(where=ct.MP_COST_PC + part), f'part {part}: not the reported values'),
             (dict(where=ct.TP_COST_PC + 17), 'TechTpCost is not the reported table'),
             (dict(where=ct.TECH_STATE_PC + 2), 'the new-game tech state is not the reported one'),
             (dict(where=ct.RECORDS_PC + ct.RECORD_SIZE * 4 + 2), 'record 4 +$02'),
             (dict(where=None, change=claim_old_mode), f'tech ${slash:02X}: not the reported values'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage {kwargs} not reported as "{message}": {result.stdout}{result.stderr}')
    print(f'techs: {len(cases)} damaged copies rejected by the checker')

    # The CLI refuses out-of-range and read-only edits and writes nothing.
    def refused(change, message):
        s = json.loads(path.read_text())
        change(s)
        bad_project = directory / 'refused.ctproj'
        shutil.rmtree(bad_project, ignore_errors=True)
        shutil.copytree(project, bad_project)
        (bad_project / 'tech_system.json').write_text(json.dumps(s))
        target = directory / 'x.sfc'
        result = subprocess.run([str(cli), 'rom', 'build', str(bad_project), '--base', str(rom), '--out', str(target)],
                                capture_output=True, text=True, timeout=600)
        if result.returncode == 0 or target.exists() or message not in result.stdout + result.stderr:
            fail(f'an edit was accepted ("{message}"): {result.stdout}{result.stderr}')
    refusals = ((lambda s: s['techs'][3].update(targetMode=ct.TARGET_MODES), 'target mode 33 is not 0-$20'),
                (lambda s: s['parts'][0].update(mp=100), 'part 0: MP 100 is not 0-99'),
                (lambda s: s['combos'][0]['requirements'][0].__setitem__(0, 9), 'need 1-8 per member'),
                (lambda s: s['learned']['bits1'].__setitem__(0, 0x01), 'must be each count\'s top bits'),
                (lambda s: s['techs'][3].update(userSet=s['techs'][3]['userSet'] ^ 1), 'kind and user set are read-only'),
                (lambda s: s['techs'][3]['anim'].update(pal=s['techs'][3]['anim']['pal'] ^ 1), 'only the animation'))
    for change, message in refusals:
        refused(change, message)
    print(f'techs: {len(refusals)} out-of-range or read-only edits refused')
print('techs: CLI import, tech-point runs and build checked independently')
