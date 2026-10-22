#!/usr/bin/env python3
"""Import the maps and tilesets with the real CLI, build them back, and check it independently.

A copy of the fixture project imports every location (`chronoforge maps
import`) and every tileset (`chronoforge tilesets import`); listing all 512
maps and every tileset in rom.maps / rom.tilesets and building must give the
clean ROM byte for byte with no writes. Then edits are built:

- maps: a cell of a map whose MapProps entry is shared (it takes a free
  Map_PropsPtrs slot), the same edit to both users of another shared entry
  (rewritten for both), tile properties that make a map's pack grow (it
  moves), an added exit (ExitRom grows into its padding), a treasure's
  contents and a location's music;
- tilesets: a palette colour, a palette cycle's delay, a metatile, a
  character in a pack only its tileset uses (in place), a character in a pack
  two tilesets share (forked to a free pack number), a layer-3 character and a
  tile animation's steps.

The built ROM is checked by re_workspace/tools/ct_rom_check.py, re-decoded
against the project by `ct_maps.py verify-import --content` and
`ct_tilesets.py verify-import` (and `chronoforge tilesets verify`), and the
ROM's own LocLoad_UnkA33B (with Decomp_ToWram, Map_UnpackTilePlanes and
Map_LoadExitTiles inside), Map_LoadTreasureTiles, Decomp_ToWram on the new
metatile tables and packs, FieldFD_LoadAnimSetA/B and PalAnim_TickAll run in
ChronoRET's interpreter on the built ROM must agree with the decode. The
checker must reject damaged copies and the CLI must refuse bad edits. Needs
the user's ROM, the venv and refs/ChronoRET.
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
import ct_maps as cm  # noqa: E402
import ct_rom_layout as layout  # noqa: E402
import ct_tilesets as cts  # noqa: E402
from PIL import Image  # noqa: E402


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=1800)
    if result.returncode != 0:
        raise SystemExit(f'FAIL: {" ".join(map(str, args[:4]))}…\n{result.stdout}{result.stderr}')
    return result.stdout


def fail(message):
    raise SystemExit(f'FAIL: {message}')


def check_rom(built, report):
    return subprocess.run([str(python), str(workspace / 'tools/ct_rom_check.py'), str(built), str(report)],
                          capture_output=True, text=True, timeout=1800)


def load(path):
    return json.loads(Path(path).read_text())


def save(path, doc):
    Path(path).write_text(json.dumps(doc, indent=2))


def set_pixel(project, sheet, tile, value):
    """Pixel (0, 0) of sheet tile `tile` (16 tiles per row) set to `value`."""
    path = project / sheet
    img = Image.open(path)
    img.putpixel(((tile % 16) * 8, (tile // 16) * 8), value)
    img.save(path)


clean = cts.read_rom(rom)
heads = [cm.header(clean, i) for i in range(cm.LOC_COUNT)]
entry_users = {}
for i, h in enumerate(heads):
    entry_users.setdefault(h['mapProps'], []).append(i)
users = {}
for t in cts.used_t12(clean):
    for k, n in enumerate(cts.pack_list(clean, t)):
        if n is not None:
            users.setdefault(n, []).append(('t12', t, k))
battle = set(clean[cts.pc(0xD1ECDB):cts.pc(0xD1ECDB) + 24]) - {cts.NONE}

with tempfile.TemporaryDirectory(prefix='chronoforge-maps-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    print(run(cli, 'maps', 'import', rom, '--project', project).splitlines()[-1])
    print(run(cli, 'tilesets', 'import', rom, '--project', project).splitlines()[-1])
    doc = load(project / 'project.json')
    map_ids = sorted(p.name[:-len('.map.json')] for p in (project / 'maps').glob('loc_*.map.json'))
    tileset_ids = sorted(p.name[:-len('.tileset.json')] for p in (project / 'tilesets').glob('*.tileset.json')
                         if 'rom' in load(p))
    doc['rom'] = {'eventPacks': [], 'maps': map_ids, 'tilesets': tileset_ids}
    save(project / 'project.json', doc)

    # Unmodified import: the clean ROM, no writes.
    out, report = directory / 'built.sfc', directory / 'report.json'
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    r = load(report)
    if out.read_bytes() != bytes(clean) or r['writes'] or len(r['maps']) != 512 or len(r['tilesets']) != len(tileset_ids):
        fail('the unmodified import does not build to the clean ROM')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    print(f'maps/tilesets: import then build of {len(map_ids)} maps and {len(tileset_ids)} tilesets is byte-identical')

    # --- Map edits ---------------------------------------------------------------------------
    def map_path(i):
        return project / 'maps' / f'loc_{i:03d}.map.json'

    def edit_map(i, change):
        m = load(map_path(i))
        change(m)
        save(map_path(i), m)
        return m

    def bump_cell(m):                                  # layer 1 cell 0: another metatile, the same bit 8
        layer = next(l for l in m['layers'] if l['bg'] == 1)
        v = layer['metatiles'][0]
        layer['metatiles'][0] = (v & 0x100) | ((v + 1) & 0xFF)

    shared = next(e for e, us in sorted(entry_users.items()) if len(us) > 2 and e != 0 and heads[us[0]]['tileset12'] != cts.NONE)
    lone_edit = entry_users[shared][0]
    edit_map(lone_edit, bump_cell)
    pair = next(us for e, us in sorted(entry_users.items()) if len(us) == 2 and e != shared)
    for i in pair:
        edit_map(i, bump_cell)
    # A map with its own entry whose pack grows: AttrA no longer runs.
    grow = next(us[0] for e, us in sorted(entry_users.items(), key=lambda kv: -cm.decode_props(clean, kv[0])['packedBytes'])
                if len(us) == 1 and us[0] not in pair)

    def unrun(m):
        a = bytearray(bytes.fromhex(m['tileProps']['attrA']))
        for k in range(len(a)):
            a[k] = a[k] & 0xA0 | (k * 7) & 0x0F
        m['tileProps']['attrA'] = a.hex()
    edit_map(grow, unrun)
    exit_loc = next(i for i in range(1, 40) if heads[i]['tileset12'] != cts.NONE and i not in (lone_edit, grow, *pair))
    edit_map(exit_loc, lambda m: m['exits'].append({'x': 1, 'y': 1, 'map': 'loc_000', 'toX': 2, 'toY': 3,
                                                    'span': 2, 'vertical': True, 'facing': 1, 'facingBit7': False}))
    treasure_loc = next(i for i in range(1, cm.LOC_COUNT) if cm.treasure_list(clean, i)[0] == i
                        and cm.treasure_list(clean, i)[1] and i not in (lone_edit, grow, exit_loc, *pair))

    def contents(m):
        t = m['treasure'][0]
        t['contents'] = 0x8000 | 50 if t['contents'] != (0x8000 | 50) else 0x8000 | 60
    edit_map(treasure_loc, contents)
    music_loc = exit_loc
    edit_map(music_loc, lambda m: m['location'].update(music=(m['location']['music'] + 1) & 0x7F))
    edited_maps = sorted({lone_edit, grow, exit_loc, treasure_loc, *pair})

    # --- Tileset edits -----------------------------------------------------------------------
    def ts_path(name):
        return project / 'tilesets' / f'{name}.tileset.json'

    def edit_ts(name, change):
        d = load(ts_path(name))
        change(d)
        save(ts_path(name), d)
        return d

    edit_ts('pal_00', lambda d: d['palettes'][1].__setitem__(1, f"0x{int(d['palettes'][1][1], 16) ^ 0x0421:04X}"))
    offsets = [cts.u16(clean, cts.ANIM_B_PTRS + 2 * p) for p in range(cts.PAL_COUNT)]
    used_pal = cts.used_pal(clean)
    cycle_pal = next(p for p in used_pal if any(cts.anim_list_b(clean, p)[0])
                     and sum(offsets[q] == offsets[p] for q in used_pal) == 1)
    edit_ts(f'pal_{cycle_pal:02d}', lambda d: d['paletteCycles'][0].update(delay=(d['paletteCycles'][0]['delay'] % 200) + 1))
    edit_ts('t12_02', lambda d: d['metatiles'][5]['chips'][0].update(pal=d['metatiles'][5]['chips'][0]['pal'] ^ 1))

    def own_tile(t, k):
        """A character of slot k of t12_t (the first one its own pack sets)."""
        return (cts.VRAM0 + cts.VRAM_STEP * k - cts.BG12_CHAR) // 16

    alone = next((n, us[0]) for n, us in sorted(users.items())
                 if len(us) == 1 and us[0][2] < 6 and n not in battle and cts.u8(clean, cts.LISTS + 8 * us[0][1]) != cts.NONE)
    _, (_, alone_t, alone_k) = alone
    alone_d = load(ts_path(f't12_{alone_t:02d}'))
    set_pixel(project, alone_d['sheet'], own_tile(alone_t, alone_k) + 1, 7)
    fork = next((n, us) for n, us in sorted(users.items())
                if len(us) >= 2 and all(u[2] < 6 for u in us) and n not in battle
                and len({u[1] for u in us}) == len(us) and alone_t not in {u[1] for u in us})
    fork_n, (_, fork_t, fork_k) = fork[0], fork[1][0]
    fork_d = load(ts_path(f't12_{fork_t:02d}'))
    set_pixel(project, fork_d['sheet'], own_tile(fork_t, fork_k) + 2, 9)
    set_pixel(project, load(ts_path('t3_00'))['sheet'], 3, 2)
    anim_offsets = {t: cts.u16(clean, cts.ANIM_A_PTRS + 2 * t) for t in cts.used_t12(clean)}
    anim_t = next(t for t in cts.used_t12(clean) if any(cts.anim_list_a(clean, t)[0])
                  and list(anim_offsets.values()).count(anim_offsets[t]) == 1 and t not in (alone_t, fork_t, 2))
    edit_ts(f't12_{anim_t:02d}', lambda d: d['tileAnimations'][0].update(steps=[(s % 250) + 1 for s in d['tileAnimations'][0]['steps']]))
    edited_t12 = sorted({2, alone_t, fork_t, anim_t})

    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    r = load(report)
    built = out.read_bytes()

    def by_entry(loc):
        return next(m['entry'] for m in r['maps'] if m['location'] == loc)
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    written = {w['what'] for w in r['writes']}
    want = {f'LocRom[{exit_loc}]', 'ExitRom', f'TreasureRom[{treasure_loc}]', 'pal_00 palette',
            f'pal_{cycle_pal:02d} cycle list', 't12_02 metatiles',
            f't12_{anim_t:02d} tile animations', f't12_{alone_t:02d} pack {alone[0]}', 't3_00 pack 0',
            f't12_{fork_t:02d} pack list', f'LocRom[{lone_edit}]', f'MapProps entry {by_entry(pair[0])}'}
    if not want <= written:
        fail(f'writes missing: {sorted(want - written)}')
    by_loc = {m['location']: m for m in r['maps']}
    if not by_loc[lone_edit]['newEntry'] or by_loc[pair[0]]['entry'] != by_loc[pair[1]]['entry'] \
            or by_loc[pair[0]]['newEntry'] or by_loc[grow]['placement'] not in ('reclaimed', 'free'):
        fail(f'map placements: {[(m["id"], m["entry"], m["newEntry"], m["placement"]) for m in r["maps"] if m["location"] in edited_maps]}')
    forks = [b for t in r['tilesets'] for b in t['blocks'] if 'fork of' in b['what']]
    if not forks or f'fork of {fork_n})' not in forks[0]['what']:
        fail(f'no fork of pack {fork_n}: {[b["what"] for t in r["tilesets"] for b in t["blocks"]]}')
    print(f'maps/tilesets: {len(r["writes"])} writes and {len(r.get("relocations") or [])} relocations '
          f'(a new Map_PropsPtrs slot, a moved MapProps, {forks[0]["what"]}) checked by ct_rom_check.py')

    # The built ROM re-decodes to the project.
    print(run(python, workspace / 'tools/ct_maps.py', 'verify-import', project, '--rom', out, '--content').splitlines()[-1])
    print(run(python, workspace / 'tools/ct_tilesets.py', 'verify-import', project, '--rom', out).splitlines()[-1])
    print(run(cli, 'tilesets', 'verify', out, '--project', project).splitlines()[-1])
    after = cm.decode(built, lone_edit)
    if after['planes']['1'][0] == cm.decode(clean, lone_edit)['planes']['1'][0] \
            or cm.decode(built, entry_users[shared][1])['planes']['1'][0] != cm.decode(clean, entry_users[shared][1])['planes']['1'][0]:
        fail('the shared-entry edit did not stay with its own location')
    print(f'maps/tilesets: the built ROM decodes to the project ({len(edited_maps)} edited maps, '
          f'{len(edited_t12)} edited Tileset12 sets, t3_00, 2 palettes)')

    # The ROM's own routines on the built ROM.
    near = sorted(set(edited_maps) | set(entry_users[shared]) | set(cm.LOC_COUNT - 1 - k for k in range(3)))
    claims = cm.run_claims(built, locations=near)
    edited_packs = sorted({int(b['what'].split()[1]) for t in r['tilesets'] for b in t['blocks'] if b['what'].startswith('pack ')})
    tables = [(cts.META12_PTRS, t) for t in edited_t12] + [(cts.META3_PTRS, 0)]
    claims += cts.run_claims(built, tables=tables, packs=edited_packs, sets_a=edited_t12, sets_b=[0, cycle_pal])
    bad = [(name, detail) for name, ok, *detail in claims if not ok]
    if bad:
        fail(f'the ROM routines on the built ROM disagree with the decode: {bad}')
    print(f'maps/tilesets: {len(claims)} of {len(claims)} run claims hold on the built ROM (LocLoad_UnkA33B and Map_LoadTreasureTiles on '
          f'{len(near)} locations; Decomp_ToWram on {len(tables)} tables and packs {edited_packs}; both list loaders, PalAnim_TickAll)')

    # --- The checker notices damage that keeps the header and report consistent ---------------
    def damaged(patch=None, change=None):
        data = bytearray(built)
        for at, value in (patch or {}).items():
            data[at] = value
        total = layout.checksum(data)
        data[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
        bad_doc = json.loads(json.dumps(dict(r, outputSHA256=packs.sha(data), checksum=total)))
        if change:
            change(bad_doc)
        bad_rom, bad_report = directory / 'damaged.sfc', directory / 'damaged.json'
        bad_rom.write_bytes(data)
        bad_report.write_text(json.dumps(bad_doc))
        return check_rom(bad_rom, bad_report)

    def rep_map(d, loc):
        return next(m for m in d['maps'] if m['location'] == loc)

    grow_pc = by_loc[grow]['pc']
    exit_at = cts.pc(cm.EXIT_OFS + cts.u16(built, cm.EXIT_OFS + 2 * exit_loc))
    t_at = cts.pc(cm.TREASURE_BANK + cts.u16(built, cm.TREASURE_OFS + 2 * treasure_loc)) + 2
    cycle_at = cts.pc(cts.ANIM_B + cts.u16(built, cts.ANIM_B_PTRS + 2 * cycle_pal)) + 1
    fork_block = forks[0]
    list_at = cts.pc(cts.LISTS) + 8 * fork_t + fork_k
    pal_at = cts.pc(cts.LOC_PAL + cts.PAL_SET_BYTES * 1)
    cases = ((dict(patch={grow_pc + 20: built[grow_pc + 20] ^ 0x55}), f'map loc_{grow:03d}: MapProps'),
             (dict(patch={exit_at: built[exit_at] ^ 1}), f'map loc_{exit_loc:03d}: exits are not the reported ones'),
             (dict(patch={t_at: built[t_at] ^ 1}), f'map loc_{treasure_loc:03d}: treasure is not the reported list'),
             (dict(change=lambda d: rep_map(d, lone_edit)['record'].__setitem__(0, rep_map(d, lone_edit)['record'][0] ^ 1)),
              f'map loc_{lone_edit:03d}: LocRom record is not the reported one'),
             (dict(change=lambda d: (d['maps'].remove(rep_map(d, grow)))), 'is outside free space'),
             (dict(patch={fork_block['pc'] + 9: built[fork_block['pc'] + 9] ^ 0x11}), 'does not unpack to the reported bytes'),
             (dict(patch={list_at: fork_n}), 'pack list is not the reported one'),
             (dict(patch={pal_at: built[pal_at] ^ 1},
                   change=lambda d: d['writes'].append({'pc': pal_at, 'length': 1, 'what': 'stray'})),
              'pal_01: palette changed but is not reported'),
             (dict(patch={cycle_at: 5}), f'pal_{cycle_pal:02d}: a cycle leaves rows 1-7'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage not reported as "{message}": {result.stdout[-400:]}{result.stderr[-400:]}')
    print(f'maps/tilesets: {len(cases)} damaged copies rejected by the checker')

    # --- The CLI refuses bad edits and writes nothing ------------------------------------------
    def refused(path, change, message, png=None):
        bad_project = directory / 'refused.ctproj'
        shutil.rmtree(bad_project, ignore_errors=True)
        shutil.copytree(project, bad_project)
        target = bad_project / path
        if png:
            png(bad_project)
        else:
            d = load(target)
            change(d)
            save(target, d)
        out_rom = directory / 'x.sfc'
        result = subprocess.run([str(cli), 'rom', 'build', str(bad_project), '--base', str(rom), '--out', str(out_rom)],
                                capture_output=True, text=True, timeout=1800)
        if result.returncode == 0 or out_rom.exists() or message not in result.stdout + result.stderr:
            fail(f'an edit was accepted ("{message}"): {result.stdout[-400:]}{result.stderr[-400:]}')

    plain = next(i for i in range(1, cm.LOC_COUNT) if i not in edited_maps and heads[i]['tileset12'] != cts.NONE)
    mp = f'maps/loc_{plain:03d}.map.json'
    tp = f'maps/loc_{treasure_loc:03d}.map.json'

    def bad_hibits(m):
        h = bytearray(bytes.fromhex(m['tileProps']['hiBits']))
        h[0] |= 0x80
        m['tileProps']['hiBits'] = h.hex()

    def bad_bit8(m):
        layer = next(l for l in m['layers'] if l['bg'] == 1)
        layer['metatiles'][0] ^= 0x100

    unknown = next(k for k in range(cts.WINDOW) if not any(s['firstTile'] <= k < s['firstTile'] + s['tiles']
                                                          for s in alone_d['vram']['known']))
    refusals = ((tp, lambda m: m['treasure'].pop(), 'renumbers every later chest'),
                (mp, bad_hibits, 'starts a run'),
                (mp, lambda m: m['layers'][0].update(width=20), 'each side is 16, 32, 48 or 64'),
                (mp, bad_bit8, 'disagree'),
                (mp, lambda m: m['exits'].append({'x': 0, 'y': 0, 'map': 'loc_600', 'toX': 0, 'toY': 0}), 'is not loc_000-loc_511'),
                (mp, lambda m: m['location'].update(tileset12=(m['location']['tileset12'] + 1) % 50), 'is not the one its location record loads'),
                (f'tilesets/t12_{alone_t:02d}.tileset.json', None, 'is not what the game would load',
                 lambda p: set_pixel(p, alone_d['sheet'], unknown, 5)),
                ('tilesets/t12_02.tileset.json', lambda d: d['metatiles'][1]['chips'][2].update(tile=1024), 'out of range'),
                ('tilesets/pal_01.tileset.json', lambda d: d['palettes'][2].__setitem__(3, '0x8000'), 'is not a BGR555 word'),
                (f'tilesets/t12_{anim_t:02d}.tileset.json', lambda d: d['tileAnimations'].pop(), 'tile animations instead of'))
    for path, change, message, *png in refusals:
        refused(path, change, message, png[0] if png else None)
    print(f'maps/tilesets: {len(refusals)} bad edits refused')
print('maps/tilesets: CLI import, identical rebuild, edits, the ROM\'s own loaders and damage checked independently')
