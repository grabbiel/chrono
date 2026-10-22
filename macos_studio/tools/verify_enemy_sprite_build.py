#!/usr/bin/env python3
"""Import the enemies' battle sprites with the real CLI, edit and build them, and check it independently.

A copy of the fixture project imports the ROM's sprites (`chronoforge sprites
import`: the seven playable sets and the 252 enemies of layouts 0-2). Building
the unmodified import with all 259 in `rom.sprites` must give the clean ROM
byte for byte with no writes. Then, built together:
- enemy 59 (parts it shares with no record): a cleared tile (its pack
  re-encoded in place), a mirrored cell and an OBJ offset, a frame id and a
  row's durations, a colour, and its battle fields (half width, move speed,
  flag bit 2);
- enemy 209: noise painted into its tiles, so its pack outgrows its span and
  moves into confirmed free space with its $E4:2000 entry rewritten;
- enemies 51 and 52, which share pack 94: the same pixel painted in both;
- Magus (PC set 6), whose frames enemy records 249-251 show: a frame's OBJ
  offset, with the report warning that those records' files are stale.
The result is checked by re_workspace/tools/ct_rom_check.py, decoded again here
against the edited project, and run through the ROM's own code in ChronoRET's
65816 interpreter: Decomp_ToWram ($C3:0557) on every written pack must give
the tiles encoded here from the edited sheets, and the battle's frame decoder
($C1:1C55) on every frame of the edited enemies must give the edited frames.
The checker must reject damaged copies, and the CLI refuses edits the format
or the sharing rule cannot carry and writes nothing. Needs the user's ROM, the
ChronoRET checkout and the venv.
"""
import json
import random
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
import ct_sprites as cs  # noqa: E402
import ct_tilesets  # noqa: E402
from PIL import Image  # noqa: E402

SOLO, MOVED, SHARED, PC_VIEW = 59, 209, (51, 52), 249


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=1200)
    if result.returncode != 0:
        raise SystemExit(f'FAIL: {" ".join(map(str, args[:3]))}…\n{result.stdout}{result.stderr}')
    return result.stdout


def fail(message):
    raise SystemExit(f'FAIL: {message}')


def check_rom(built, report):
    return subprocess.run([str(python), str(workspace / 'tools/ct_rom_check.py'), str(built), str(report)],
                          capture_output=True, text=True, timeout=600)


def eid(i):
    return f'enemy_{i:03d}'


clean = cs.read_rom(rom)
with tempfile.TemporaryDirectory(prefix='chronoforge-enemy-sprites-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    print(run(cli, 'sprites', 'import', rom, '--project', project).splitlines()[-1])

    def set_sprites(ids):
        meta_path = project / 'project.json'
        meta = json.loads(meta_path.read_text())
        meta.setdefault('rom', {'eventPacks': []})['sprites'] = ids
        meta_path.write_text(json.dumps(meta, indent=2))

    def path_of(name):
        return project / f'sprites/{name}.sprite.json'

    def load(name):
        return json.loads(path_of(name).read_text())

    def edit(name, change):
        d = load(name)
        change(d)
        path_of(name).write_text(json.dumps(d, indent=2))
        return d

    every = sorted(p.name[:-len('.sprite.json')] for p in (project / 'sprites').glob('*.sprite.json'))
    enemies = [n for n in every if n.startswith('enemy_')]
    if len(enemies) != 252:
        fail(f'{len(enemies)} enemy sprites imported')

    # Unmodified import: the clean ROM, no writes.
    set_sprites(every)
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != rom.read_bytes()[-len(clean):] or doc['writes'] or len(doc['enemySprites']) != 252:
        fail('the unmodified import does not build to the clean ROM')
    print(check_rom(out, report).stdout, end='')
    print('enemy sprites: import of all 252 enemies and 7 sets then build is byte-identical to the clean ROM')

    # Sheet helpers.
    def sheet_of(name):
        d = load(name)
        return project / d['sheet']

    def paint(name, pixels):
        path = sheet_of(name)
        img = Image.open(path)
        px = img.load()
        for (x, y), v in pixels.items():
            px[x, y] = v
        img.save(path)

    def tile_xy(path, t):
        cols = Image.open(path).width // 8
        return (t % cols) * 8, (t // cols) * 8

    def sheet_tiles(name):
        d = load(name)
        img = Image.open(project / d['sheet'])
        sp, cols = img.load(), img.width // 8
        return [cs.encode_tile([sp[(t % cols) * 8 + i % 8, (t // cols) * 8 + i // 8] for i in range(64)])
                for t in range(d['rom']['tileCount'])]

    originals = {n: path_of(n).read_text() for n in every}
    sheets = {n: sheet_of(n).read_bytes() for n in (eid(SOLO), eid(MOVED), eid(SHARED[0]), eid(SHARED[1]))}

    # Enemy 59: a tile cleared, frame, animation, colour and battle fields.
    solo = load(eid(SOLO))
    cleared = next(w & cs.TILE_MASK for w in solo['frames'][0]['cells'] if w & cs.TILE_MASK)
    cell = next(k for k, w in enumerate(solo['frames'][0]['cells']) if w & cs.TILE_MASK)
    x0, y0 = tile_xy(sheet_of(eid(SOLO)), cleared)
    paint(eid(SOLO), {(x0 + i % 8, y0 + i // 8): 0 for i in range(64)})
    down = next(a for a in solo['animations'] if a['row'] == 0)
    new_id = (down['frames'][0] + 1) % len(solo['frames'])
    new_duration = 1 + down['durations'][0] % 200

    def edit_solo(d):
        d['frames'][0]['cells'][cell] ^= cs.HFLIP
        d['frames'][0]['tiles'][1]['x'] += 3
        for a in d['animations']:
            if a['id'] == down['id']:
                a['frames'][0] = new_id
            if a['row'] == 0:
                a['durations'][0] = new_duration
        d['palettes'][0][3] = '%04X' % (int(d['palettes'][0][3], 16) ^ 0x0421)
        d['battle']['halfWidth'] += 2
        d['battle']['moveSpeed'] = (d['battle']['moveSpeed'] + 3) % 8
        d['battle']['flags'] ^= 0x04
    edit(eid(SOLO), edit_solo)

    # Enemy 209: noise in tiles 1-12 (the pack outgrows its span).
    moved = load(eid(MOVED))
    rng = random.Random(209)
    noise = {}
    for t in range(1, moved['rom']['tileCount']):
        x0, y0 = tile_xy(sheet_of(eid(MOVED)), t)
        for i in range(64):
            noise[(x0 + i % 8, y0 + i // 8)] = rng.randrange(1, 13)
    paint(eid(MOVED), noise)

    # Enemies 51 and 52 (pack 94): the same pixel.
    shared_tile = next(w & cs.TILE_MASK for w in load(eid(SHARED[0]))['frames'][0]['cells'] if w & cs.TILE_MASK)
    x0, y0 = tile_xy(sheet_of(eid(SHARED[0])), shared_tile)
    old_px = Image.open(sheet_of(eid(SHARED[0]))).load()[x0 + 3, y0 + 3]
    for i in SHARED:
        paint(eid(i), {(x0 + 3, y0 + 3): (old_px + 5) % 13 + 1})

    # Magus: an OBJ offset of a frame enemy records 249-251 show.
    magus_last = len(load('magus')['frames']) - 1
    magus_original = path_of('magus').read_text()
    edit('magus', lambda d: d['frames'][magus_last]['tiles'][2].update(y=d['frames'][magus_last]['tiles'][2]['y'] - 2))

    listed = [eid(SOLO), eid(MOVED), eid(SHARED[0]), eid(SHARED[1]), 'magus']
    set_sprites(listed)
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    built = out.read_bytes()
    by_id = {s['id']: s for s in doc['enemySprites']}
    written = sorted(w['what'] for w in doc['writes'] if w['what'] != 'checksum')
    rows = cs.anim_rows(clean, cs.enemy_record(clean, SOLO)['anim'])
    expect = sorted([f'sprite {eid(SOLO)} graphics {cs.enemy_record(clean, SOLO)["gfx"]} pack', f'sprite {eid(SOLO)} frame 0',
                     f'sprite {eid(SOLO)} frame ids r00.{cs.FACINGS[down["facing"]]}', f'sprite {eid(SOLO)} durations r00',
                     f'sprite {eid(SOLO)} palette', f'sprite {eid(SOLO)} record',
                     f'sprite {eid(MOVED)} graphics {cs.enemy_record(clean, MOVED)["gfx"]} pack',
                     f'sprite {eid(MOVED)} $E4:2000[{cs.enemy_record(clean, MOVED)["gfx"]}]',
                     f'sprite {eid(SHARED[0])} graphics 94 pack', f'sprite magus frame {magus_last}']
                    + ([f'sprite {eid(SHARED[0])} $E4:2000[94]'] if by_id[eid(SHARED[0])]['pack']['placement'] == 'free' else []))
    if written != expect:
        fail(f'writes {written}, expected {expect}')
    solo_pack, moved_pack = by_id[eid(SOLO)]['pack'], by_id[eid(MOVED)]['pack']
    if solo_pack['placement'] != 'original' or moved_pack['placement'] != 'free' or moved_pack['packedBytes'] <= moved_pack['budget']:
        fail(f'pack placements {solo_pack} {moved_pack}')
    if sorted(by_id[eid(SOLO)]['changed']) != ['animations', 'frames', 'palette', 'record', 'tiles']:
        fail(f'enemy {SOLO} changed {by_id[eid(SOLO)]["changed"]}')
    shared_with = by_id[eid(SHARED[0])].get('sharedWith') or []
    if shared_with != [f'enemy record {SHARED[1]} ({eid(SHARED[1])}): tiles']:
        fail(f'sharedWith {shared_with}')
    warnings = doc.get('spriteWarnings') or []
    if [w.split('enemy record ')[1].split(' ')[0] for w in warnings] != ['249', '250', '251']:
        fail(f'warnings {warnings}')
    print(f'enemy sprites: pack of {SOLO} in place ({solo_pack["packedBytes"]} of {solo_pack["budget"]} B); pack of {MOVED} '
          f'moved {moved_pack["from"]} -> {moved_pack["address"]} ({moved_pack["packedBytes"]} B over a {moved_pack["budget"]}-B span); '
          f'{len(warnings)} stale-view warnings for Magus')
    result = check_rom(out, report)
    if result.returncode != 0:
        fail(result.stdout + result.stderr)
    print(result.stdout, end='')

    # The built ROM decodes to the edited project.
    claims = 0
    for name in listed[:4]:
        d = load(name)
        i = d['rom']['set']
        dec = cs.decode_enemy(built, i)
        tb, _ = cs.enemy_tile_bytes(built, i)
        frames = [{'cells': f['cells'], 'pieces': [[t['x'], t['y']] for t in f['tiles']]} for f in d['frames']]
        anims = [{k: a[k] for k in ('row', 'facing', 'frames', 'durations')} for a in dec['animationList']
                 if all(f < dec['frames']['count'] for f in a['frames'])]
        want_anims = sorted(({k: a[k] for k in ('row', 'facing', 'frames', 'durations')} for a in d['animations']),
                            key=lambda a: (a['row'], a['facing']))
        colours = [int(h, 16) for h in d['palettes'][0][1:13]]
        record = {k: dec['record'][k] for k in d['battle']}
        for ok, what in ((tb == sheet_tiles(name), 'tiles'), (dec['frameList'] == frames, 'frames'),
                         (anims == want_anims, 'animations'), (cs.enemy_palette(built, i) == colours, 'palette'),
                         (record == d['battle'], 'record')):
            if not ok:
                fail(f'{name}: the built ROM does not decode to its {what}')
            claims += 1
    print(f'enemy sprites: {claims} of {claims} decode claims: the built ROM gives the edited enemies back')

    # The ROM's own Decomp_ToWram and frame decoder on the built ROM.
    decomp, decoder = ct_tilesets.RomRunner(built), cs.RomFrameDecoder(built)
    unpacks = 0
    for name in (eid(SOLO), eid(MOVED), eid(SHARED[0])):
        i = load(name)['rom']['set']
        got, _ = decomp.decomp(cs.u24(built, cs.TILES_PTR + 3 * cs.enemy_record(built, i)['gfx']), 0x7F2000)
        if got != b''.join(sheet_tiles(name)):
            fail(f'{name}: Decomp_ToWram on the built ROM does not give the edited tiles')
        unpacks += 1
    runs = 0
    for name in listed[:4]:
        d = load(name)
        i = d['rom']['set']
        r = cs.enemy_record(built, i)
        tb = sheet_tiles(name)
        wram = {0x7F2000 + k: v for k, v in enumerate(b''.join(tb))}
        slots = (cs.FIRST_ENEMY_SLOT, 6) if r['size'] == cs.LAYOUT_TALL else (cs.FIRST_ENEMY_SLOT,)
        for slot in slots:
            for f, fr in enumerate(d['frames']):
                frame = {'cells': fr['cells'], 'pieces': [[t['x'], t['y']] for t in fr['tiles']]}
                got = decoder.decode(slot, 0x7F2000, cs.u24(built, cs.FRAMES_PTR + 3 * r['frames']), f, layout=r['size'],
                                     extra_known=wram)
                if got != cs.expected_enemy_buffer(built, frame, tb, r['size'], slot):
                    fail(f'{name} frame {f} slot {slot}: the ROM\'s frame decoder does not give the edited frame')
                runs += 1
    print(f'enemy sprites: Decomp_ToWram on the built ROM gives the edited tiles for {unpacks} of {unpacks} written packs; '
          f'the frame decoder gives the edited frames in {runs} of {runs} runs')

    # The checker must notice damage that keeps the header and report consistent.
    spans = cs.enemy_spans(clean, SOLO)
    moved_at = moved_pack['pc']
    other = cs.enemy_spans(clean, 60)

    def damaged(where, value=None, extra_write=None):
        data = bytearray(built)
        data[where] = data[where] ^ 0x01 if value is None else value
        total = layout.checksum(data)
        data[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
        bad_doc = dict(doc, outputSHA256=packs.sha(data), checksum=total)
        if extra_write is not None:
            bad_doc['writes'] = doc['writes'] + [{'pc': extra_write, 'length': 1, 'what': 'damage'}]
        bad, bad_report = directory / 'damaged.sfc', directory / 'damaged.json'
        bad.write_bytes(data)
        bad_report.write_text(json.dumps(bad_doc))
        return check_rom(bad, bad_report)

    rec59 = spans['record'].start - 4
    gfx_entry = cs.pc(cs.TILES_PTR + 3 * cs.enemy_record(clean, MOVED)['gfx'])
    cases = ((dict(where=spans['frames'].start + 2 * cell), 'the frame records are not the reported frames'),
             (dict(where=moved_at + 40), 'not the reported'),
             (dict(where=spans['palette'].start + 1, value=built[spans['palette'].start + 1] | 0x80), 'colours 1-12'),
             (dict(where=rec59 + 4, value=built[rec59 + 4] ^ 0x40), 'an unread bit changed'),
             (dict(where=rec59 + 7), 'the record fields are not the reported ones'),
             (dict(where=other['record'].start, extra_write=other['record'].start), 'outside free space'),
             (dict(where=gfx_entry, value=built[gfx_entry] + 1), 'does not point at the reported pack'),
             (dict(where=spans['durations'].start, value=0), 'the animation rows are not the reported animations'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage at ${kwargs["where"]:06X} not reported as "{message}": {result.stdout}{result.stderr}')
    print(f'enemy sprites: {len(cases)} damaged copies rejected by the checker')

    # The CLI refuses edits the format or the sharing rule cannot carry, and writes nothing.
    for n, text in originals.items():
        path_of(n).write_text(text)
    for n, data in sheets.items():
        sheet_of(n).write_bytes(data)
    backup = directory / 'sprites-backup'
    shutil.copytree(project / 'sprites', backup)
    target = directory / 'x.sfc'

    def refused_build():
        return subprocess.run([str(cli), 'rom', 'build', str(project), '--base', str(rom), '--out', str(target)],
                              capture_output=True, text=True, timeout=600)

    def repaint(name, value):
        def change():
            t = next(w & cs.TILE_MASK for w in load(name)['frames'][0]['cells'] if w & cs.TILE_MASK)
            x, y = tile_xy(sheet_of(name), t)
            paint(name, {(x, y): value})
        return change

    solo_cell_count = len(load(eid(SOLO))['frames'][0]['cells'])
    def recolour(names):
        def change():
            for n in names:
                edit(n, lambda d: d['palettes'][0].__setitem__(2, '%04X' % (int(d['palettes'][0][2], 16) ^ 0x0001)))
        return change
    npc_gfx = next(g for g in range(cs.POINTERS) if cs.enemy_users(clean, 0, g)[1]
                   and any(i < cs.ROM_GFX_MIN and cs.enemy_record(clean, i)['size'] < 3 for i in cs.enemy_users(clean, 0, g)[0]))
    npc_enemy = next(i for i in cs.enemy_users(clean, 0, npc_gfx)[0] if i < cs.ROM_GFX_MIN and cs.enemy_record(clean, i)['size'] < 3)
    refusals = (
        ([eid(SHARED[0])], repaint(eid(SHARED[0]), 3), f'also shown by enemy records {SHARED[1]}'),
        ([eid(110), eid(216)], recolour([eid(110), eid(216)]), 'enemy records 111, 215'),   # palette 208 (layout 3)
        ([eid(npc_enemy)] + [eid(i) for i in cs.enemy_users(clean, 0, npc_gfx)[0] if i != npc_enemy and cs.enemy_record(clean, i)['size'] < 3],
         repaint(eid(npc_enemy), 3), '$E4:F000 records'),
        ([eid(PC_VIEW)], lambda: edit(eid(PC_VIEW), lambda d: d['frames'][0]['tiles'][0].update(x=d['frames'][0]['tiles'][0]['x'] + 1)),
         'belong to playable set 6'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['battle'].update(flags=d['battle']['flags'] ^ 0x40)), 'bits 4 and 6'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['battle'].update(moveSpeed=8)), 'is not 0-7'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['battle'].update(flags=1)), 'bits 2-7 only'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['frames'][1]['cells'].__setitem__(0, d['rom']['tileCount'])), 'is not below'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['frames'][1]['cells'].__setitem__(0, 0x0801)), 'bits 11-13'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['frames'][1]['tiles'][1].update(tile=4)), 'must be 16x16 at slot tile 2'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['frames'][1]['cells'].pop()), f'a frame of this layout has {solo_cell_count}'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['frames'].pop()), 'frames are written in place'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['rom'].update(tiles='$D0:0000')), 're-import the sprites'),
        ([eid(SOLO)], lambda: edit(eid(SOLO), lambda d: d['rom'].update(layout=3)), 'only frame layouts 0-2'),
        ([eid(SOLO)], lambda: paint(eid(SOLO), {(3, 3): 7}), 'blank cell'),
    )
    for ids, change, message in refusals:
        set_sprites(ids)
        change()
        refused = refused_build()
        if refused.returncode == 0 or target.exists() or message not in refused.stdout + refused.stderr:
            fail(f'a bad edit was accepted or refused otherwise ({message}): {refused.stdout}{refused.stderr}')
        shutil.rmtree(project / 'sprites')
        shutil.copytree(backup, project / 'sprites')
    print(f'enemy sprites: {len(refusals)} edits the format or the sharing rule cannot carry refused by the CLI')
print('enemy sprites: CLI import, write-back, Decomp_ToWram and the frame decoder checked independently')
