#!/usr/bin/env python3
"""Import the field NPCs' sprites with the real CLI, edit and build them, and check it independently.

A copy of the fixture project imports the ROM's sprites (`chronoforge sprites
import --family pc --family enemy --family npc`: the seven playable sets, the
252 enemies of layouts 0-2 and the 191 NPC records the event packs load).
Building the unmodified import with all 450 in `rom.sprites` must give the
clean ROM byte for byte with no writes. Then, built together:
- NPC record 12 (no part shared with any record): a cleared tile (its pack
  re-encoded in place), a mirrored cell and an OBJ offset, a frame id and a
  row's durations, and a colour;
- NPC record 23: noise painted into its tiles, so its pack outgrows its span
  and moves into confirmed free space with its $E4:2000 entry rewritten;
- NPC records 14 and 18, which share a pack: the same pixel painted in both;
- NPC record 9 and enemy 244, which share a pack: the same pixel in both
  (one sharer pass covers the two families);
- Ayla (PC set 5), whose palette NPC records 13 and 101 show: a colour, with
  the report warning that those records' files are stale.
The result is checked by re_workspace/tools/ct_rom_check.py, decoded again
here against the edited project, and run through the field's own code in
ChronoRET's 65816 interpreter on the built ROM: Evt_Op82_InitWramSprite
($C0:4590, which unpacks the record's graphics with Decomp_ToWram), the frame
builders, the frame lookup and the tick for every edited NPC
(ct_npc_sprites.run_claims), each against the decode of the built ROM, which
must be the edited project. The checker must reject damaged copies, and the
CLI refuses edits the format or the sharing rule cannot carry and writes
nothing. Needs the user's ROM, the ChronoRET checkout and the venv.
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
import ct_npc_sprites as ns  # noqa: E402
import ct_rom_layout as layout  # noqa: E402
import ct_sprites as cs  # noqa: E402
from PIL import Image  # noqa: E402

SOLO, MOVED, SHARED, CROSS, CROSS_ENEMY, PC_SET = 12, 23, (14, 18), 9, 244, 5
PC_VIEWS = (13, 101)                       # NPC records showing PC set 5's palette


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


def nid(r):
    return ns.npc_id(r)


def eid(i):
    return f'enemy_{i:03d}'


clean = cs.read_rom(rom)
sharing = ns.sharing(clean)
for r in (SOLO, MOVED):
    if any(sharing[r][p][k] for p in ('tiles', 'frames', 'palette', 'animations') for k in ('npc', 'enemy', 'pc')):
        fail(f'NPC record {r} shares a part')
for a, b in (SHARED, (CROSS, None)):
    t = sharing[a]['tiles']
    if t['npc'] != ([b] if b else []) or t['pc'] or t['enemy'] != ([] if b else [CROSS_ENEMY]):
        fail(f'NPC record {a}: tiles shared with {t}')
for r in PC_VIEWS:
    if sharing[r]['palette']['pc'] != [PC_SET]:
        fail(f'NPC record {r} does not show PC set {PC_SET}\'s palette')

with tempfile.TemporaryDirectory(prefix='chronoforge-npc-sprites-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    print(run(cli, 'sprites', 'import', rom, '--project', project, '--family', 'pc', '--family', 'enemy',
              '--family', 'npc').splitlines()[-2])

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
    npcs = [n for n in every if n.startswith('npc_')]
    if len(npcs) != 191 or len(every) != 450:
        fail(f'{len(npcs)} NPC sprites and {len(every)} sprites imported')

    # Unmodified import: the clean ROM, no writes.
    set_sprites(every)
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != rom.read_bytes()[-len(clean):] or doc['writes'] or len(doc['npcSprites']) != 191:
        fail('the unmodified import does not build to the clean ROM')
    result = check_rom(out, report)
    if result.returncode != 0:
        fail(result.stdout + result.stderr)
    print(result.stdout, end='')
    print('npc sprites: import of all 191 NPC records, 252 enemies and 7 sets then build is byte-identical to the clean ROM')

    # Sheet helpers.
    def sheet_of(name):
        return project / load(name)['sheet']

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

    def first_tile(name):
        return next(w & cs.TILE_MASK for w in load(name)['frames'][0]['cells'] if w & cs.TILE_MASK)

    touched = [nid(SOLO), nid(MOVED), nid(SHARED[0]), nid(SHARED[1]), nid(CROSS), eid(CROSS_ENEMY), cs.NAMES[PC_SET]]
    originals = {n: path_of(n).read_text() for n in every}
    sheets = {n: sheet_of(n).read_bytes() for n in touched}

    # Record 12: a tile cleared, frame, animation and colour.
    solo = load(nid(SOLO))
    cleared = first_tile(nid(SOLO))
    cell = next(k for k, w in enumerate(solo['frames'][0]['cells']) if w & cs.TILE_MASK)
    x0, y0 = tile_xy(sheet_of(nid(SOLO)), cleared)
    paint(nid(SOLO), {(x0 + i % 8, y0 + i // 8): 0 for i in range(64)})
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
    edit(nid(SOLO), edit_solo)

    # Record 23: noise in every tile but 0 (the pack outgrows its span).
    moved = load(nid(MOVED))
    rng = random.Random(23)
    noise = {}
    for t in range(1, moved['rom']['tileCount']):
        x0, y0 = tile_xy(sheet_of(nid(MOVED)), t)
        for i in range(64):
            noise[(x0 + i % 8, y0 + i // 8)] = rng.randrange(1, 13)
    paint(nid(MOVED), noise)

    # Records 14 and 18 (one pack), and record 9 with enemy 244 (one pack): the same pixel in each pair.
    for names in ((nid(SHARED[0]), nid(SHARED[1])), (nid(CROSS), eid(CROSS_ENEMY))):
        t = first_tile(names[0])
        x0, y0 = tile_xy(sheet_of(names[0]), t)
        old = Image.open(sheet_of(names[0])).load()[x0 + 3, y0 + 3]
        for n in names:
            x1, y1 = tile_xy(sheet_of(n), t)
            paint(n, {(x1 + 3, y1 + 3): (old + 5) % 12 + 1})

    # Ayla: a colour NPC records 13 and 101 show.
    edit(cs.NAMES[PC_SET], lambda d: d['palettes'][0].__setitem__(4, '%04X' % (int(d['palettes'][0][4], 16) ^ 0x0842)))

    set_sprites(touched)
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    built = out.read_bytes()
    by_id = {s['id']: s for s in doc['npcSprites']}
    gfx = {r: ns.record(clean, r)['gfx'] for r in (SOLO, MOVED, SHARED[0], CROSS)}
    written = sorted(w['what'] for w in doc['writes'] if w['what'] != 'checksum')
    facing = cs.FACINGS[down['facing']]
    expect = sorted([f'sprite {nid(SOLO)} graphics {gfx[SOLO]} pack', f'sprite {nid(SOLO)} frame 0',
                     f'sprite {nid(SOLO)} frame ids r00.{facing}', f'sprite {nid(SOLO)} durations r00',
                     f'sprite {nid(SOLO)} palette',
                     f'sprite {nid(MOVED)} graphics {gfx[MOVED]} pack', f'sprite {nid(MOVED)} $E4:2000[{gfx[MOVED]}]',
                     f'sprite {nid(SHARED[0])} graphics {gfx[SHARED[0]]} pack',
                     f'sprite {eid(CROSS_ENEMY)} graphics {gfx[CROSS]} pack']
                    + [w for w in written if w.startswith(f'sprite {cs.NAMES[PC_SET]} ')])
    for name, g in ((nid(SHARED[0]), gfx[SHARED[0]]), (eid(CROSS_ENEMY), gfx[CROSS])):
        if f'sprite {name} $E4:2000[{g}]' in written:
            expect = sorted(expect + [f'sprite {name} $E4:2000[{g}]'])
    if written != expect or not any(w.startswith(f'sprite {cs.NAMES[PC_SET]} ') for w in written):
        fail(f'writes {written}, expected {expect}')
    solo_pack, moved_pack = by_id[nid(SOLO)]['pack'], by_id[nid(MOVED)]['pack']
    if solo_pack['placement'] != 'original' or moved_pack['placement'] != 'free' or moved_pack['packedBytes'] <= moved_pack['budget']:
        fail(f'pack placements {solo_pack} {moved_pack}')
    if sorted(by_id[nid(SOLO)]['changed']) != ['animations', 'frames', 'palette', 'tiles']:
        fail(f'NPC record {SOLO} changed {by_id[nid(SOLO)]["changed"]}')
    if (by_id[nid(SHARED[0])].get('sharedWith') != [f'NPC record {SHARED[1]} ({nid(SHARED[1])}): tiles']
            or by_id[nid(CROSS)].get('sharedWith') != [f'enemy record {CROSS_ENEMY} ({eid(CROSS_ENEMY)}): tiles']):
        fail(f'sharedWith {by_id[nid(SHARED[0])].get("sharedWith")} {by_id[nid(CROSS)].get("sharedWith")}')
    enemy_report = {s['id']: s for s in doc['enemySprites']}
    if enemy_report[eid(CROSS_ENEMY)].get('sharedWith') != [f'NPC record {CROSS} ({nid(CROSS)}): tiles']:
        fail(f'enemy sharedWith {enemy_report[eid(CROSS_ENEMY)].get("sharedWith")}')
    warnings = [w for w in doc.get('spriteWarnings') or [] if 'NPC record' in w]
    if [int(w.split('NPC record ')[1].split(' ')[0]) for w in warnings] != list(PC_VIEWS):
        fail(f'warnings {warnings}')
    print(f'npc sprites: pack of {SOLO} in place ({solo_pack["packedBytes"]} of {solo_pack["budget"]} B); pack of {MOVED} '
          f'moved {moved_pack["from"]} -> {moved_pack["address"]} ({moved_pack["packedBytes"]} B over a {moved_pack["budget"]}-B span); '
          f'shared packs written once for {SHARED} and for NPC {CROSS} with enemy {CROSS_ENEMY}; '
          f'{len(warnings)} stale-view warnings for Ayla\'s palette')
    result = check_rom(out, report)
    if result.returncode != 0:
        fail(result.stdout + result.stderr)
    print(result.stdout, end='')

    # The built ROM decodes to the edited project.
    edited = [SOLO, MOVED, SHARED[0], SHARED[1], CROSS]
    claims = 0
    for r in edited:
        name = nid(r)
        d = load(name)
        dec = ns.decode_npc(built, r)
        tb = ns.pack(built, dec['fields']['gfx'])[0]
        frames = [{'cells': f['cells'], 'pieces': [[t['x'], t['y']] for t in f['tiles']]} for f in d['frames']]
        keys = ('row', 'facing', 'frames', 'durations')
        anims = sorted(({k: a[k] for k in keys} for a in dec['animationList']), key=lambda a: (a['row'], a['facing']))
        want_anims = sorted(({k: a[k] for k in keys} for a in d['animations']), key=lambda a: (a['row'], a['facing']))
        colours = [int(h, 16) for h in d['palettes'][0][1:13]]
        for ok, what in ((tb == sheet_tiles(name), 'tiles'), (dec['frameList'] == frames, 'frames'),
                         (anims == want_anims, 'animations'), (ns.palette(built, r) == colours, 'palette')):
            if not ok:
                fail(f'{name}: the built ROM does not decode to its {what}')
            claims += 1
    print(f'npc sprites: {claims} of {claims} decode claims: the built ROM gives the edited NPCs back')

    # The field's own loader, frame builders, lookup and tick on the built ROM.
    runs = ns.run_claims(built, records=edited)
    bad = [c for c in runs if not c[1]]
    if bad:
        fail(f'the field\'s routines on the built ROM: {bad}')
    for name, _, *_ in runs:
        print(f'ok   built ROM: {name}')
    print(f'npc sprites: {len(runs)} of {len(runs)} interpreter claims hold on the built ROM for records {edited}')

    # The checker must notice damage that keeps the header and report consistent.
    spans = ns.npc_spans(clean, SOLO)
    moved_at = moved_pack['pc']
    other = ns.npc_spans(clean, 11)

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

    stride_solo = ns.decode_npc(clean, SOLO)['animations']['stride']
    gfx_entry = cs.pc(cs.TILES_PTR + 3 * gfx[MOVED])
    cases = ((dict(where=spans['frames'].start + 2 * cell), 'the frame records are not the reported frames'),
             (dict(where=moved_at + 40), 'not the reported'),
             (dict(where=spans['palette'].start + 1, value=built[spans['palette'].start + 1] | 0x80), 'colours 1-12'),
             (dict(where=spans['frameIds'].start + down['facing'] * stride_solo), 'the animation rows are not the reported animations'),
             (dict(where=other['frames'].start, extra_write=other['frames'].start), 'outside free space'),
             (dict(where=gfx_entry, value=built[gfx_entry] + 1), 'does not point at the reported pack'),
             (dict(where=spans['durations'].start, value=0), 'the animation rows are not the reported animations'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage at ${kwargs["where"]:06X} not reported as "{message}": {result.stdout}{result.stderr}')
    print(f'npc sprites: {len(cases)} damaged copies rejected by the checker')

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
            x, y = tile_xy(sheet_of(name), first_tile(name))
            paint(name, {(x, y): value})
        return change

    def recolour(name):
        return lambda: edit(name, lambda d: d['palettes'][0].__setitem__(2, '%04X' % (int(d['palettes'][0][2], 16) ^ 0x0001)))

    solo_cells = len(load(nid(SOLO))['frames'][0]['cells'])
    stride = load(nid(SOLO))['rom'].get('stride') or 4 * load(nid(SOLO))['rom']['rows']
    refusals = (
        ([nid(SHARED[0])], repaint(nid(SHARED[0]), 3), f'also shown by $E4:F000 records {SHARED[1]} (NPCs)'),
        ([nid(CROSS)], repaint(nid(CROSS), 3), f'also shown by enemy records {CROSS_ENEMY}'),
        ([eid(CROSS_ENEMY)], repaint(eid(CROSS_ENEMY), 3), f'$E4:F000 records {CROSS} (NPCs)'),
        ([nid(SHARED[0]), nid(SHARED[1])], lambda: (repaint(nid(SHARED[0]), 3)(), repaint(nid(SHARED[1]), 4)()),
         'a shared part has one content'),
        ([nid(PC_VIEWS[0])], recolour(nid(PC_VIEWS[0])), f'belong to playable set {PC_SET}'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d['frames'][1]['cells'].__setitem__(0, d['rom']['tileCount'])), 'is not below'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d['frames'][1]['cells'].__setitem__(0, 0x0801)), 'bits 11-13'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d['frames'][1]['tiles'][1].update(tile=4)), 'must be 16x16 at slot tile 2'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d['frames'][1]['cells'].pop()), f'a frame of this layout has {solo_cells}'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d['frames'].pop()), 'frames are written in place'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d['rom'].update(tiles='$D0:0000')), 're-import the sprites'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d['rom'].update(layout=2)), 'size class 2'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d.update(stream=dict(d['stream'], baseTile=64))), 'stream must be'),
        ([nid(SOLO)], lambda: edit(nid(SOLO), lambda d: d['animations'][0].update(
            frames=d['animations'][0]['frames'] + [0] * stride, durations=d['animations'][0]['durations'] + [1] * stride)),
         'run past the facing'),
        ([nid(SOLO)], lambda: paint(nid(SOLO), {(3, 3): 7}), 'blank cell'),
    )
    for ids, change, message in refusals:
        set_sprites(ids)
        change()
        refused = refused_build()
        if refused.returncode == 0 or target.exists() or message not in refused.stdout + refused.stderr:
            fail(f'a bad edit was accepted or refused otherwise ({message}): {refused.stdout}{refused.stderr}')
        shutil.rmtree(project / 'sprites')
        shutil.copytree(backup, project / 'sprites')
    print(f'npc sprites: {len(refusals)} of {len(refusals)} edits the format or the sharing rule cannot carry refused by the CLI')
print(f'npc sprites: CLI import, write-back and the field\'s loader, builders, lookup and tick checked independently '
      f'({len(runs)} of {len(runs)} field-routine claims on the built ROM)')
