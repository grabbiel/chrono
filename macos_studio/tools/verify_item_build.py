#!/usr/bin/env python3
"""Import the item tables with the real CLI, build, and check it independently.

A copy of the fixture project imports the ROM's items (`chronoforge items
import`); every items/<id>.json and item_tables.json must equal
re_workspace/tools/ct_items.py's decode, and `items show --json` must give
the same items from the project and from the ROM. Building the unmodified
import must give the clean ROM byte for byte with no writes. Then edits (a
price, attack, defence, element bonus, a name, an accessory's boost, a
description, an ItemBoosts amount) are built and checked by
re_workspace/tools/ct_rom_check.py; the game's own Menu_BuildItemTables and
Menu_RefreshAllChars, run in ChronoRET's interpreter over the built ROM,
must agree with the menu-stat rule on the edited tables. The checker must
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
import ct_items as ci  # noqa: E402
import ct_rom_layout as layout  # noqa: E402

FIELDS = {'attack': 'attack', 'byte1': 'byte1', 'critical': 'critical', 'modifier': 'modifier',
          'modifier_arg': 'modifierArg', 'defence': 'defence', 'modifier_on': 'modifierOn',
          'battle_flags': 'battleFlags', 'special': 'special', 'special_arg': 'specialArg',
          'special_bits': 'specialBits', 'use_kind': 'useKind', 'restores': 'restores', 'amount': 'amount',
          'byte3': 'byte3'}
STAT = {'magic_defense': 'magicDefense'}


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


def swift_item(v):
    """ct_items.decode_item (with its description) in the item file's names."""
    record = {'itemId': v['id'], 'icon': v['icon'], 'flags': v['flags']}
    for k, swift in (('equip', 'equip'), ('boost', 'boost'), ('element_bonus', 'elementBonus'), ('target_mode', 'targetMode')):
        if k in v:
            record[swift] = v[k]
    stats = {FIELDS[f]: v[f] for f, _ in ci.FIELDS_B[v['category']]}
    return {'name': v['name'], 'kind': v['category'], 'price': v['price'], 'stats': stats, 'rom': record,
            'description': v['description']}


def load_items(project):
    out = {}
    for path in (project / 'items').glob('*.json'):
        doc = json.loads(path.read_text())
        if 'rom' in doc:
            out[doc['rom']['itemId']] = (path, doc)
    return out


clean = ci.read_rom(rom)
with tempfile.TemporaryDirectory(prefix='chronoforge-items-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    print(run(cli, 'items', 'import', rom, '--project', project), end='')

    # The import is the Python decode.
    decoded = ci.decode_all(clean)
    files = load_items(project)
    if sorted(files) != list(range(ci.ITEMS)):
        fail(f'{len(files)} ROM item files')
    for v in decoded['items']:
        path, doc = files[v['id']]
        want = swift_item(v)
        if {k: doc.get(k) for k in want} != want:
            fail(f'item ${v["id"]:02X} ({path.name}): the import is not the Python decode')
        if not path.name.startswith(f'{v["id"]:02x}_'):
            fail(f'item ${v["id"]:02X}: file {path.name}')
    tables = json.loads((project / 'item_tables.json').read_text())
    if tables['boosts'] != [{'stats': [STAT.get(s, s) for s in b['stats']], 'amount': b['amount']} for b in decoded['boosts']] \
            or tables['statOrder'] != [STAT.get(s, s) for s in decoded['stat_order']] \
            or tables['statCaps'] != decoded['stat_caps'] or tables['char5Attack'] != ci.char5_attack(clean):
        fail('item_tables.json is not the Python decode')
    print(f'items: the import equals the Python decode ({ci.ITEMS} items, names and descriptions; {ci.BOOSTS} boosts)')
    shown = json.loads(run(cli, 'items', 'show', project, '--json'))
    if shown != json.loads(run(cli, 'items', 'show', rom, '--json')) or len(shown) != ci.ITEMS:
        fail('items show --json differs between the project and the ROM')
    print('items: `items show --json` gives the same items from the project and the ROM')

    # Unmodified import: the clean ROM, no writes.
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != rom.read_bytes()[-len(clean):] or doc['writes'] or len(doc.get('items') or []) != ci.ITEMS:
        fail('the unmodified import does not build to the clean ROM')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    print('items: import then build is byte-identical to the clean ROM')

    # Edits.
    def edit(item, change):
        path, d = files[item]
        change(d)
        path.write_text(json.dumps(d, indent=2))
        return d
    weapon, armor, helmet, potion = 0x02, ci.FIRST[1] + 2, ci.FIRST[2] + 1, ci.FIRST[4] + 1
    accessory = next(v['id'] for v in decoded['items'][ci.FIRST[3]:ci.FIRST[4]] if v['special'] & ci.ACCESSORY_BOOST)
    w = edit(weapon, lambda d: (d.update(price=(d['price'] + 1) & 0xFFFF), d['stats'].update(attack=(d['stats']['attack'] + 1) & 0xFF)))
    a = edit(armor, lambda d: (d['stats'].update(defence=(d['stats']['defence'] + 1) & 0xFF),
                               d['rom'].update(elementBonus=d['rom']['elementBonus'] ^ 0x80)))
    edit(helmet, lambda d: d.update(name='Test Cap'))
    x = edit(accessory, lambda d: d['stats'].update(specialArg=d['stats']['specialArg'] % (ci.BOOSTS - 1) + 1))
    edit(potion, lambda d: d.update(description='Restores lots of HP.'))
    tables['boosts'][1]['amount'] = (tables['boosts'][1]['amount'] + 1) & 0xFF
    (project / 'item_tables.json').write_text(json.dumps(tables, indent=2))
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    written = [w_['what'] for w_ in doc['writes'] if w_['what'] != 'checksum']
    expect = [f'item ${weapon:02X} record A', f'item ${weapon:02X} record B', f'item ${armor:02X} record A',
              f'item ${armor:02X} record B', f'item ${helmet:02X} name', f'item ${accessory:02X} record B',
              'ItemBoosts', 'item descriptions']
    if written != expect:
        fail(f'writes {written}')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    built = out.read_bytes()
    after = ci.decode_all(built)['items']
    if after[weapon]['price'] != w['price'] or after[armor]['defence'] != a['stats']['defence'] \
            or after[helmet]['name'] != 'Test Cap' or after[accessory]['special_arg'] != x['stats']['specialArg'] \
            or after[potion]['description'] != 'Restores lots of HP.' \
            or any(after[n]['description'] != decoded['items'][n]['description'] for n in range(ci.ITEMS) if n != potion):
        fail('the built ROM does not decode to the edits')
    print(f'items: {len(expect)} edits written where the report says and checked by ct_rom_check.py')

    # The game's own menu code builds its tables from the edited items as the rule says.
    bad = [name for name, ok, detail in ci.run_claims(built) if not ok]
    if bad:
        fail(f'the ROM routines on the built ROM disagree with the rule: {bad}')
    t = ci.item_tables(built)
    if t['sort'][armor] != a['stats']['defence'] or t['info4'][accessory] != x['stats']['specialArg'] \
            or t['info1'][weapon] != w['price']:
        fail('the built ROM\'s menu tables do not hold the edits')
    print('items: Menu_BuildItemTables and Menu_RefreshAllChars on the built ROM equal the rule')

    # The checker must notice damage that keeps the header and report consistent.
    def damaged(patch=None, change=None):
        data = bytearray(built)
        for at, value in (patch or {}).items():
            data[at] = value
        total = layout.checksum(data)
        data[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
        bad_doc = json.loads(json.dumps(dict(doc, outputSHA256=packs.sha(data), checksum=total)))
        if change:
            change(bad_doc)
        bad_rom, bad_report = directory / 'damaged.sfc', directory / 'damaged.json'
        bad_rom.write_bytes(data)
        bad_report.write_text(json.dumps(bad_doc))
        return check_rom(bad_rom, bad_report)

    def reported(d, item):
        return next(i for i in d['items'] if i['rom']['itemId'] == item)

    price_at = ci.record_a_pc(built, weapon) + 1
    armor_b = ci.record_b_pc(built, armor)
    pointer = ci.DESC_PC + 2 * potion + 1
    potion_text = ci.pc(0xCC, int.from_bytes(built[ci.DESC_PC + 2 * potion:ci.DESC_PC + 2 * potion + 2], 'little'))
    icon_at = ci.NAMES_PC + ci.NAME_SIZE * helmet
    # Every damaged byte but the icon's is inside a write the report names.
    cases = ((dict(patch={price_at: built[price_at] ^ 1}), f'item ${weapon:02X}: not the reported values'),
             (dict(patch={icon_at: built[icon_at] ^ 1}), 'not in a report write'),
             (dict(change=lambda d: reported(d, helmet)['rom'].update(icon=reported(d, helmet)['rom']['icon'] ^ 1)),
              f'item ${helmet:02X}: kind or icon is not the item\'s'),
             (dict(patch={armor_b + 1: ci.MODIFIERS},
                   change=lambda d: reported(d, armor)['stats'].update(modifier=ci.MODIFIERS)),
              f'item ${armor:02X}: modifier past BattleRom_UnkCC2A05'),
             (dict(patch={ci.BOOSTS_PC + 3: built[ci.BOOSTS_PC + 3] ^ 1}), 'ItemBoosts is not the reported table'),
             (dict(patch={pointer: built[pointer] ^ 0x40}), f'item ${potion:02X}: description pointer'),
             (dict(patch={potion_text: built[potion_text] ^ 1}), f'item ${potion:02X}: description bytes are not the encoded text'),
             (dict(change=lambda d: d.update(itemTables=dict(d['itemTables'], statCaps=[1] * 7))),
              'the read-only stat tables are not the ROM\'s'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage not reported as "{message}": {result.stdout}{result.stderr}')
    print(f'items: {len(cases)} damaged copies rejected by the checker')

    # The CLI refuses out-of-range and read-only edits and writes nothing.
    def refused(item, change, message, file='item'):
        bad_project = directory / 'refused.ctproj'
        shutil.rmtree(bad_project, ignore_errors=True)
        shutil.copytree(project, bad_project)
        if file == 'item':
            path = bad_project / 'items' / files[item][0].name
        else:
            path = bad_project / 'item_tables.json'
        d = json.loads(path.read_text())
        change(d)
        path.write_text(json.dumps(d))
        target = directory / 'x.sfc'
        result = subprocess.run([str(cli), 'rom', 'build', str(bad_project), '--base', str(rom), '--out', str(target)],
                                capture_output=True, text=True, timeout=600)
        if result.returncode == 0 or target.exists() or message not in result.stdout + result.stderr:
            fail(f'an edit was accepted ("{message}"): {result.stdout}{result.stderr}')
    refusals = ((weapon, lambda d: d['rom'].update(icon=d['rom']['icon'] ^ 1), 'the icon byte is read-only'),
                (weapon, lambda d: d.update(price=0x10000), 'is not 0-65535'),
                (armor, lambda d: d['rom'].update(boost=ci.BOOSTS), 'boost 23 is not 0-22'),
                (armor, lambda d: d['stats'].update(modifierOn=2), 'modifierOn is 0 or 1'),
                (weapon, lambda d: d['rom'].update(equip=0x01), 'names a character past 6'),
                (helmet, lambda d: d.update(name='Much Too Long'), 'the most is 10'),
                (potion, lambda d: d.update(description='A long description. ' * 200), 'the descriptions take'),
                (None, lambda d: d['statCaps'].__setitem__(0, 1), 'read-only', 'tables'),
                (None, lambda d: d['boosts'][2]['stats'].append('luck'), 'distinct stat names', 'tables'))
    for args in refusals:
        refused(*args)
    print(f'items: {len(refusals)} out-of-range or read-only edits refused')
print('items: CLI import, build and the menu\'s own tables checked independently')
