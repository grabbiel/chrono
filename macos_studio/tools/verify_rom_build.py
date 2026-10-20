#!/usr/bin/env python3
"""Build a ROM with the real CLI and check it with re_workspace/tools/ct_rom_check.py.

A copy of the fixture project gets the ROM's text profile, CT-text dialogue,
its intro scene without the cross-map call, and a `rom` section that writes
two packs: entry 23 (location 0) lowered from the scene, with its message
table, and entry 30 assembled from its own listing with 96 extra data bytes,
which no longer fit its old place; and two songs from ct-song/1 listings:
song 2 unchanged (it stays where it was) and song 1 with 40 more rests
(it moves) and a new echo word and sample list. Needs the user's ROM and the venv.
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


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise SystemExit(f'FAIL: {" ".join(map(str, args[:3]))}…\n{result.stdout}{result.stderr}')
    return result.stdout


with tempfile.TemporaryDirectory(prefix='chronoforge-rom-') as directory:
    directory = Path(directory)
    project = directory / 'MyGame.ctproj'
    shutil.copytree(fixture, project)
    dsl = project / 'scenes/intro.event.dsl'
    dsl.write_text('\n'.join(line for line in dsl.read_text().splitlines() if 'call ' not in line) + '\n')
    run(cli, 'text', 'profile', rom, '--out', project / 'strings/ct-text-profile.json')
    (project / 'strings/dialogue.json').write_text(json.dumps({'strings': {
        'greeting': 'Hello there!\nWelcome to the Tyrano Dome.{page}Everyone, say hi!',
        'shop': 'Welcome! Buy something!',
        'intro': 'A giant robot whirs quietly.'}}))
    (project / 'events').mkdir()
    listing = run(cli, 'event', 'disasm', rom, '30')
    (project / 'events/entry030.ctevents').write_text(listing + '@bytes ' + ' '.join(['5A'] * 96) + '\n')
    (project / 'audio/songs').mkdir(parents=True)
    song = run(cli, 'music', 'disasm', rom, '1')
    first = song.index('\n    rest ')
    song = song[:first] + '\n    rest 96' * 40 + song[first:]
    lines = song.split('\n')
    lines = [('@echo $04 $C0' if line.startswith('@echo') else line) for line in lines]
    samples = next(line for line in lines if line.startswith('@samples'))
    lines[lines.index(samples)] = samples + ' 62'
    (project / 'audio/songs/song01.ctsong').write_text('\n'.join(lines))
    (project / 'audio/songs/song02.ctsong').write_text(run(cli, 'music', 'disasm', rom, '2'))
    meta = json.loads((project / 'project.json').read_text())
    meta['rom'] = {'eventPacks': [{'entry': 23, 'scenes': ['intro']},
                                  {'entry': 30, 'listing': 'events/entry030.ctevents'}],
                   'songs': [{'song': 1, 'listing': 'audio/songs/song01.ctsong'},
                             {'song': 2, 'listing': 'audio/songs/song02.ctsong'}]}
    (project / 'project.json').write_text(json.dumps(meta, indent=2))

    out, report = directory / 'built.sfc', directory / 'report.json'
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    lowered = directory / 'lowered.json'
    run(cli, 'event', 'lower', project, 'intro', '--out', lowered)
    placements = {p['entry']: p['placement'] for p in json.loads(report.read_text())['packs']}
    if placements[23] != 'original' or placements[30] not in ('reclaimed', 'free'):
        raise SystemExit(f'FAIL: placements {placements}')
    songs = {s['song']: s['placement'] for s in json.loads(report.read_text())['songs']}
    if songs != {1: songs[1], 2: 'original'} or songs[1] not in ('reclaimed', 'free'):
        raise SystemExit(f'FAIL: song placements {songs}')
    written = {w['what'] for w in json.loads(report.read_text())['writes']}
    if not {'AudioRom_SongEcho[$01]', 'AudioRom_SongSamples[$01]'} <= written or any('[$02]' in w for w in written):
        raise SystemExit(f'FAIL: song table writes {sorted(written)}')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report, '--lowered', lowered, '--entry', '23'), end='')
    # The checker must notice damage that keeps the header and report consistent.
    sys.path.insert(0, str(workspace / 'tools'))
    import ct_event_packs as packs  # noqa: E402
    import ct_rom_layout as layout  # noqa: E402
    doc = json.loads(report.read_text())
    table = doc['messageTables'][0]
    string = layout.pc(table['messages'][1]['address'])
    for where, expect in ((0x200000, 'not in a report write'), (string + 1, 'bytes are not the encoded text'),
                          (table['pc'], 'pointer'), (doc['packs'][1]['pc'] + 40, 'entry 30'),
                          (doc['songs'][0]['pc'] + 2 + 0x30, 'song 1: data'),
                          (0x07241D + 2 + 1, 'song 1: table row')):
        damaged = bytearray(out.read_bytes())
        damaged[where] ^= 0x01
        total = layout.checksum(damaged)
        damaged[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
        bad, bad_report = directory / 'damaged.sfc', directory / 'damaged.json'
        bad.write_bytes(damaged)
        bad_report.write_text(json.dumps(dict(doc, outputSHA256=packs.sha(damaged), checksum=total)))
        result = subprocess.run([str(python), str(workspace / 'tools/ct_rom_check.py'), str(bad), str(bad_report)],
                                capture_output=True, text=True, timeout=600)
        if result.returncode == 0 or expect not in result.stdout + result.stderr:
            raise SystemExit(f'FAIL: damage at ${where:06X} not reported as "{expect}": {result.stdout}{result.stderr}')
    print('rom build: 6 damaged copies rejected by the checker')
    info = run(cli, 'rom', 'info', out)
    if 'complement ok' not in info:
        raise SystemExit(f'FAIL: rom info\n{info}')
    # Unchanged input: the CLI refuses a base that is not the clean ROM.
    refused = subprocess.run([str(cli), 'rom', 'build', str(project), '--base', str(out), '--out', str(directory / 'x.sfc')],
                             capture_output=True, text=True, timeout=600)
    if refused.returncode == 0 or (directory / 'x.sfc').exists():
        raise SystemExit('FAIL: a built ROM was accepted as the base')
print('rom build: CLI build checked independently')
