#!/usr/bin/env python3
"""Import the playable characters' sprites with the real CLI, build, and check it independently.

A copy of the fixture project imports the ROM's seven sprite sets
(`chronoforge sprites import`), checked against re_workspace/tools/ct_sprites.py's
decode (`verify-import`). Building the unmodified import with all seven in
`rom.sprites` must give the clean ROM byte for byte with no writes. Then a
tile's pixels, a frame's cell and OBJ offset, an animation's frame id and a
row's duration, and palette colours are edited and built; the result is checked by
re_workspace/tools/ct_rom_check.py, decoded again by `ct_sprites.py
verify-import --rom <built>` (it must give the edited project back), and the
ROM's own frame decoder Battle_DrawBattlerFrameAnyLayout ($C1:1C55, run in
ChronoRET's 65816 interpreter) on the built ROM must produce the edited
frames from tiles encoded independently from the edited sheet. The checker
must reject damaged copies, and the CLI refuses edits the format cannot carry
and writes nothing. Needs the user's ROM, the ChronoRET checkout and the venv.
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
import ct_sprites as cs  # noqa: E402
from PIL import Image  # noqa: E402


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


clean = cs.read_rom(rom)
with tempfile.TemporaryDirectory(prefix='chronoforge-sprites-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    print(run(cli, 'sprites', 'import', rom, '--project', project).splitlines()[-1])
    print(run(python, workspace / 'tools/ct_sprites.py', 'verify-import', project).splitlines()[-1])

    def set_sprites(ids):
        meta_path = project / 'project.json'
        meta = json.loads(meta_path.read_text())
        meta.setdefault('rom', {'eventPacks': []})['sprites'] = ids
        meta_path.write_text(json.dumps(meta, indent=2))

    # Unmodified import: the clean ROM, no writes.
    set_sprites(list(cs.NAMES))
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != rom.read_bytes()[-len(clean):] or doc['writes'] or len(doc['sprites']) != cs.SETS:
        fail('the unmodified import does not build to the clean ROM')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    print(f'sprites: import of all {cs.SETS} sets then build is byte-identical to the clean ROM')

    # Edits.
    def path_of(name):
        return project / f'sprites/{name}.sprite.json'

    def edit(name, change):
        d = json.loads(path_of(name).read_text())
        change(d)
        path_of(name).write_text(json.dumps(d, indent=2))
        return d

    crono = json.loads(path_of('crono').read_text())
    tile = next(w & cs.TILE_MASK for w in crono['frames'][0]['cells'] if w & cs.TILE_MASK)
    cell = next(k for k, w in enumerate(crono['frames'][0]['cells']) if w & cs.TILE_MASK)
    sheet_path = project / crono['sheet']
    sheet = Image.open(sheet_path)
    px = sheet.load()
    cols = sheet.width // 8
    x0, y0 = (tile % cols) * 8, (tile // cols) * 8
    for i in range(8):
        px[x0 + i, y0] = (px[x0 + i, y0] + 1 + i) % 13      # top row of the tile: new indices
    sheet.save(sheet_path)
    down = next(a for a in crono['animations'] if a['row'] == 0 and a['facing'] == 1)
    new_id = (down['frames'][0] + 1) % len(crono['frames'])
    new_duration = 1 + down['durations'][0] % 200

    def edit_crono(d):
        d['frames'][0]['cells'][cell] ^= cs.HFLIP
        d['frames'][0]['tiles'][1]['x'] += 1
        for a in d['animations']:
            if a['row'] == 0 and a['facing'] == 1:
                a['frames'][0] = new_id
            if a['row'] == 0:
                a['durations'][0] = new_duration        # the 4 facings share a row's durations
        d['palettes'][0][5] = '%04X' % (int(d['palettes'][0][5], 16) ^ 0x0421)
    edit('crono', edit_crono)
    magus_last = len(json.loads(path_of('magus').read_text())['frames']) - 1

    def edit_magus(d):
        d['frames'][magus_last]['tiles'][3]['y'] -= 2
        d['palettes'][0][12] = '%04X' % (int(d['palettes'][0][12], 16) ^ 0x7C00)
    edit('magus', edit_magus)
    set_sprites(['crono', 'magus', 'lucca'])
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    written = sorted(w['what'] for w in doc['writes'] if w['what'] != 'checksum')
    expect = sorted([f'sprite crono tile {tile}', 'sprite crono frame 0', 'sprite crono frame ids r00.down',
                     'sprite crono durations r00', 'sprite crono palette', f'sprite magus frame {magus_last}',
                     'sprite magus palette'])
    if written != expect:
        fail(f'writes {written}')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    # The built ROM decodes to the edited project (frames, animations, palettes, sheets).
    print(run(python, workspace / 'tools/ct_sprites.py', 'verify-import', project, '--rom', out).splitlines()[-1],
          '(the built ROM decodes to the edited project)')

    # The ROM's own frame decoder on the built ROM gives the edited frames,
    # with tiles encoded here from the edited sheets.
    built = out.read_bytes()
    runner = cs.RomFrameDecoder(built)
    runs = 0
    for name, c, frames in (('crono', 0, sorted({0} | {i for i, f in enumerate(crono['frames'])
                                                      if any(w & cs.TILE_MASK == tile for w in f['cells'])})[:6]),
                            ('magus', 6, [magus_last])):
        d = json.loads(path_of(name).read_text())
        img = Image.open(project / d['sheet'])
        sp, cols = img.load(), img.width // 8
        count = d['rom']['tileCount']
        tile_bytes = [cs.encode_tile([sp[(t % cols) * 8 + i % 8, (t // cols) * 8 + i // 8] for i in range(64)])
                      for t in range(count)]
        for f in frames:
            frame = {'cells': d['frames'][f]['cells'], 'pieces': [[t['x'], t['y']] for t in d['frames'][f]['tiles']]}
            got = runner.decode(0, cs.u24(built, cs.TILES_PTR + 3 * c), cs.u24(built, cs.FRAMES_PTR + 3 * c), f)
            if got != cs.expected_buffer(frame, tile_bytes):
                fail(f'{name} frame {f}: the ROM\'s frame decoder on the built ROM does not give the edited frame')
            runs += 1
    print(f'sprites: {runs} of {runs} frame decoder runs on the built ROM give the edited frames')

    # The checker must notice damage that keeps the header and report consistent.
    spans = {c: cs.set_spans(clean, c) for c in range(cs.SETS)}

    def damaged(where, value=None, extra_write=None):
        data = bytearray(out.read_bytes())
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

    crono_frame0 = spans[0]['frames'].start
    lucca_tile = spans[2]['tiles'].start + 7 * cs.TILE_BYTES + 3
    marle_tile = spans[1]['tiles'].start + 9 * cs.TILE_BYTES
    crono_dur = spans[0]['durations'].start
    crono_pal = spans[0]['palette'].start + 2 * 4 + 1           # colour 5's high byte
    cases = ((dict(where=crono_frame0 + 2 * cell), 'the frame records are not the reported frames'),
             (dict(where=lucca_tile, extra_write=lucca_tile), 'the tile block is not the reported one'),
             (dict(where=marle_tile), 'not in a report write'),
             (dict(where=marle_tile, extra_write=marle_tile), 'outside free space'),
             (dict(where=crono_dur, value=0), 'the animation rows are not the reported animations'),
             (dict(where=crono_pal, value=built[crono_pal] | 0x80), 'colours 1-12 are not the reported colours'),
             (dict(where=cs.pc(cs.TILES_PTR), extra_write=cs.pc(cs.TILES_PTR)), 'outside free space'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage at ${kwargs["where"]:06X} not reported as "{message}": {result.stdout}{result.stderr}')
    print(f'sprites: {len(cases)} damaged copies rejected by the checker')

    # The CLI refuses edits the format cannot carry and writes nothing.
    count = crono['rom']['tileCount']
    two = next(a for a in crono['animations'] if len(a['frames']) >= 2)

    def set_cell(value):
        return lambda d: d['frames'][1]['cells'].__setitem__(0, value)

    def shorten(d):
        a = next(x for x in d['animations'] if x['id'] == two['id'])
        a['frames'].pop()
        a['durations'].pop()
    refusals = ((set_cell(count), 'is not below the set'),
                (set_cell(0x0801), 'bits 11-13'),
                (lambda d: d['frames'][2]['tiles'][0].update(hflip=True), 'no OAM flips'),
                (lambda d: d['frames'][2]['tiles'][2].update(x=200), 'signed byte pair'),
                (lambda d: d['animations'][0]['durations'].__setitem__(0, 300), 'is not 1-255'),
                (lambda d: d['animations'][0]['frames'].__setitem__(0, 255), 'is not below'),
                (lambda d: d['palettes'][0].__setitem__(14, '001F'), 'only colours 1-12'),
                (shorten, 'would not read back as given'),
                (lambda d: d['frames'].pop(), 'frames are written in place'),
                (lambda d: d['rom'].update(set=7), 'is not 0-6'),
                (lambda d: d['rom'].update(tiles='$D0:0000'), 're-import the sprites'))
    original = path_of('crono').read_text()
    target = directory / 'x.sfc'

    def refused_build():
        return subprocess.run([str(cli), 'rom', 'build', str(project), '--base', str(rom), '--out', str(target)],
                              capture_output=True, text=True, timeout=600)
    for change, message in refusals:
        edit('crono', change)
        refused = refused_build()
        if refused.returncode == 0 or target.exists() or message not in refused.stdout + refused.stderr:
            fail(f'a bad edit was accepted ({message}): {refused.stdout}{refused.stderr}')
        path_of('crono').write_text(original)
    # A painted tile 0 (the blank cell).
    saved = sheet_path.read_bytes()
    img = Image.open(sheet_path)
    img.load()[3, 3] = 7
    img.save(sheet_path)
    refused = refused_build()
    if refused.returncode == 0 or target.exists() or 'blank cell' not in refused.stdout + refused.stderr:
        fail(f'a painted tile 0 was accepted: {refused.stdout}{refused.stderr}')
    sheet_path.write_bytes(saved)
    print(f'sprites: {len(refusals) + 1} edits the format cannot carry refused by the CLI')
print('sprites: CLI import, write-back and the ROM frame decoder checked independently')
