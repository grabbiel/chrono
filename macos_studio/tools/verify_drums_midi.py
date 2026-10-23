#!/usr/bin/env python3
"""Import a MIDI file and edit a drum kit with the real CLI, build, and check the driver against the file.

A MIDI file is written here, independently of the Swift writer: a melody
(program 5) with a chord and an off-grid note, a bass (program 33) across
octaves, and channel 10 with three drum keys, at 120 BPM and then 96 BPM.
`music import-midi` converts it into song $02 of a copy of the fixture
project (programs 5 and 33 to samples 1 and 2, the drum keys to pads on
samples 3 and 4), and `rom build` writes it. The expected key-ons are worked
out here from the MIDI events alone: 24 steps a quarter, starts rounded to
the 3-step grid, the highest note of a chord, the driver's note = key (and a
pad's note in drum mode), the sample the song's list puts in that slot. The
S-SMP driver, booted from the clean ROM, loads the built song as the game
does (`music drum-check`) and must key on exactly those notes, voice by
voice and step by step. The built ROM's kit row ($C7:1871 + 36 x song) must
be the pads' bytes, and the tempo bytes the driver's formula computed here.
re_workspace/tools/ct_rom_check.py checks the build independently. Then
`music kit ... set` edits a pad, the song is built again, and the
driver must play the edited pad. The CLI must refuse a 9-channel file, an
unmapped program and a song over its sample budget, and write nothing.
Needs the user's ROM and the venv.
"""
import json
import math
import shutil
import struct
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
import ct_samples as cs  # noqa: E402

SONG = 2
Q = 96                       # ticks a quarter in the file
STEPS_PER_QUARTER = 24       # Spc_DurationTable: 96 a whole note
GRID = 3
DRUMS_PC = 0x071871          # AudioRom_SongExtra
PROGRAMS = {5: 1, 33: 2}
PADS = [(36, 3, 60, 0x40), (38, 4, 62, 0x80), (42, 3, 72, 0x10)]   # key, sample, note, pan


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=1200)
    if result.returncode != 0:
        raise SystemExit(f'FAIL: {" ".join(map(str, args[:3]))}…\n{result.stdout}{result.stderr}')
    return result.stdout


def fail(message):
    raise SystemExit(f'FAIL: {message}')


def varlen(v):
    out = [v & 0x7F]
    v >>= 7
    while v:
        out.insert(0, v & 0x7F | 0x80)
        v >>= 7
    return bytes(out)


def midi(tracks):
    """A format 1 file; each track is a list of (tick, status bytes)."""
    data = b'MThd' + struct.pack('>IHHH', 6, 1, len(tracks), Q)
    for events in tracks:
        body, now = b'', 0
        for tick, raw in sorted(events, key=lambda e: e[0]):
            body += varlen(tick - now) + bytes(raw)
            now = tick
        body += b'\x00\xff\x2f\x00'
        data += b'MTrk' + struct.pack('>I', len(body)) + body
    return data


def note(channel, key, start, length):
    return [(start, [0x90 | channel, key, 100]), (start + length, [0x80 | channel, key, 0])]


def tempo(tick, us):
    return (tick, [0xFF, 0x51, 3, us >> 16, us >> 8 & 0xFF, us & 0xFF])


# The file: (channel, key, start tick, length) per note.
melody = [(0, 60, 0, Q), (0, 64, Q, Q // 2), (0, 67, Q + Q // 2 + 2, Q // 2 - 2), (0, 72, 2 * Q, Q), (0, 55, 2 * Q, Q),
          (0, 74, 3 * Q, 5 * Q), (0, 76, 8 * Q, Q)]
bass = [(1, 36, 0, 2 * Q), (1, 43, 2 * Q, 2 * Q), (1, 48, 4 * Q, 4 * Q), (1, 31, 8 * Q, 2 * Q)]
drums = [(9, PADS[b % 3][0], b * Q, Q // 4) for b in range(10)]
TEMPI = [(0, 500_000), (6 * Q, 625_000)]


def write_file(path, extra_channels=0, program_33=33):
    tracks = [[tempo(t, us) for t, us in TEMPI],
              [(0, [0xC0, 5])] + [e for n in melody for e in note(*n)],
              [(0, [0xC1, program_33])] + [e for n in bass for e in note(*n)],
              [e for n in drums for e in note(*n)]]
    tracks += [note(2 + k, 60, 0, Q) for k in range(extra_channels)]
    path.write_bytes(midi(tracks))


def snap(tick):
    return math.floor(tick * STEPS_PER_QUARTER / Q / GRID + 0.5) * GRID


def driver_tempo(t):
    """Spc_SeqTempo: t + t x 20 / 256 (driver.asm $1722)."""
    return (t + t * 20 // 256) & 0xFF


def expected_tempo_byte(bpm):
    # A pass is 5.25 ms (timer 0); each adds the tempo to an 8-bit accumulator and the song steps on the carry.
    want = bpm * STEPS_PER_QUARTER / 60 * 256 * 0.00525
    return min(range(1, 256), key=lambda t: (abs(driver_tempo(t) - want), t))


def expected_key_ons(samples):
    """(voice, step) -> (SRCN, note): voices in channel order, the highest of notes that start together."""
    out = {}
    for voice, notes in enumerate([melody, bass, drums]):
        starts = {}
        for channel, key, start, _ in notes:
            s = snap(start)
            starts[s] = max(starts.get(s, -1), key)
        for s, key in starts.items():
            if voice == 2:
                pad = next(k for k, p in enumerate(PADS) if p[0] == key)
                out[(voice, s)] = (0x20 + samples.index(PADS[pad][1]), PADS[pad][2])
            else:
                out[(voice, s)] = (0x20 + samples.index(PROGRAMS[[5, 33][voice]]), key)
    return out


clean = rom.read_bytes()
with tempfile.TemporaryDirectory(prefix='chronoforge-midi-') as directory:
    directory = Path(directory)
    project = directory / 'Midi.ctproj'
    shutil.copytree(fixture, project)
    out, report, check = directory / 'built.sfc', directory / 'report.json', directory / 'check.json'
    mid, imported = directory / 'song.mid', directory / 'import.json'
    write_file(mid)
    programs = ','.join(f'{p}:{s}' for p, s in PROGRAMS.items())
    pads = ','.join(f'{k}:{s}:{n}:{p}' for k, s, n, p in PADS)
    print(run(cli, 'music', 'import-midi', mid, '--song', str(SONG), '--project', project, '--rom', rom,
              '--programs', programs, '--drums', pads, '--report', imported), end='')
    doc = json.loads(imported.read_text())
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    built = out.read_bytes()
    samples = cs.song_list(built, SONG)
    if samples != [1, 2, 3, 4]:
        fail(f'song {SONG} loads {samples}')
    kit = bytearray(36)
    for k, (_, sample, n, pan) in enumerate(PADS):
        kit[3 * k:3 * k + 3] = bytes([0x20 + samples.index(sample), n, pan])
    if built[DRUMS_PC + 36 * SONG:DRUMS_PC + 36 * SONG + 36] != bytes(kit):
        fail('the built ROM\'s kit row is not the pads\' bytes')
    bpms = [60_000_000 / us for _, us in TEMPI]
    if [t['byte'] for t in doc['tempo']] != [expected_tempo_byte(b) for b in bpms] or \
       [t['step'] for t in doc['tempo']] != [snap(t) for t, _ in TEMPI]:
        fail(f'tempo {doc["tempo"]}')
    total = doc['steps']

    def driver_run(listing):
        run(cli, 'music', 'drum-check', rom, out, str(SONG), '--listing', listing, '--steps', str(total), '--out', check)
        result = json.loads(check.read_text())
        return result, {(k['voice'], k['step']): (k['sample'], k['number'], k['pan']) for k in result['keyOns'] if k['step'] < total}

    listing = project / f'audio/songs/song{SONG:02X}.ctsong'
    result, got = driver_run(listing)
    want = expected_key_ons(samples)
    matched = sum(1 for k, v in want.items() if got.get(k, (None, None))[:2] == v)
    if matched != len(want) or len(got) != len(want):
        missing = sorted(set(want) ^ set(got))[:6]
        fail(f'the driver keyed on {len(got)}, the file plays {len(want)}, {matched} agree; first differences {missing}')
    print(f'midi: {len(want)} notes from the file; the driver on the built ROM keys on {len(got)}, '
          f'{matched} at the file\'s step with its note and sample; drum mode {result["matched"]} of {result["drumNotes"]} pads; '
          f'tempo bytes {[f"${t["byte"]:02X}" for t in doc["tempo"]]}, rounding at most {doc["maxErrorSteps"]:.2f} steps')

    # An edited pad: the CLI rewrites the @drum rows, the build writes them, the driver plays them.
    print(run(cli, 'music', 'kit', listing, 'set', '1', '$20', '$50', '$10'), end='')
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    built = out.read_bytes()
    if built[DRUMS_PC + 36 * SONG + 3:DRUMS_PC + 36 * SONG + 6] != bytes([0x20, 0x50, 0x10]):
        fail('the edited pad is not in the built ROM\'s kit row')
    result, got = driver_run(listing)
    pad1 = [v for (voice, step), v in sorted(got.items()) if voice == 2 and step in (snap(Q), snap(4 * Q), snap(7 * Q))]
    if not result['matched'] == result['drumNotes'] or pad1 != [(0x20, 0x50, 0x20)] * 3:
        fail(f'the edited pad plays {pad1}')
    print(f'midi: pad 1 edited to sample $20 note $50 pan $10; the driver keys it on {len(pad1)} times with SRCN $20, '
          f'note $50 and pan byte $20; {result["matched"]} of {result["drumNotes"]} drum notes as the kit says')

    # Refusals: nothing is written.
    meta = (project / 'project.json').read_text()
    before = sorted(p.name for p in (project / 'audio/songs').iterdir())

    def refused(path, message, *extra):
        r = subprocess.run([str(a) for a in [cli, 'music', 'import-midi', path, '--song', '5', '--project', project, '--rom', rom,
                                             '--programs', programs, '--drums', pads, *extra]], capture_output=True, text=True, timeout=600)
        if r.returncode == 0 or message not in r.stdout + r.stderr:
            fail(f'not refused ({message}): {r.stdout}{r.stderr}')
        if (project / 'project.json').read_text() != meta or sorted(p.name for p in (project / 'audio/songs').iterdir()) != before:
            fail(f'a refused import ({message}) wrote files')
    write_file(directory / 'nine.mid', extra_channels=6)
    refused(directory / 'nine.mid', 'notes on 9 channels: 1, 2, 3, 4, 5, 6, 7, 8, 10')
    write_file(directory / 'program.mid', program_33=40)
    refused(directory / 'program.mid', 'programs 40 have no sample')
    # The five largest ROM samples, on a song with the longest echo buffer (EDL 15).
    t0 = cs.tables(clean, cs.find_sites(clean))
    big = sorted(range(1, 63), key=lambda n: -cs.entry(clean, t0, n)['length'])[:5]
    room = cs.ECHO_TOP - 0x800 * 15 - ((0x4700 + cs.word(clean, cs.BLOCK_4700_LEN_PC)) & 0xFFFF)
    if sum(cs.entry(clean, t0, n)['length'] for n in big) <= room:
        fail('the five largest samples fit below an EDL 15 echo buffer; the refusal case needs others')
    r = subprocess.run([str(a) for a in [cli, 'music', 'import-midi', mid, '--song', '5', '--project', project, '--rom', rom,
                                         '--programs', f'5:{big[0]},33:{big[1]}', '--edl', '15',
                                         '--drums', ','.join(f'{k}:{n}' for (k, _, _, _), n in zip(PADS, big[2:]))]],
                       capture_output=True, text=True, timeout=600)
    if r.returncode == 0 or 'into the echo buffer' not in r.stdout:
        fail(f'an import over its sample budget was not refused: {r.stdout}{r.stderr}')
    if (project / 'project.json').read_text() != meta:
        fail('the refused over-budget import wrote project.json')
    print('midi: refused a 9-channel file, an unmapped program and a song over its sample budget; nothing written')
    print(f'midi import: {matched} of {len(want)} MIDI notes keyed on by the driver as the file plays them')
