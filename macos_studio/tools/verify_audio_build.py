#!/usr/bin/env python3
"""Put project samples and a composed song into the ROM with the real CLI, and check it independently.

A copy of the fixture project imports the ROM's 62 samples (`chronoforge sfx
import-rom`) and 83 songs (`music import`); building that unedited import
with all of them in `rom.samples` and `rom.songs` must give the clean ROM
byte for byte with no writes. A second copy encodes two synthetic WAVs: one
replaces sample 7, the other is appended as sample 63 (the four sample
tables move to free space and the twelve operands that read them follow),
each tuned from its rate and root note. `music new` starts song $02 from the
template on both samples and `music edit insert` adds a note per track. The
built ROM is checked by re_workspace/tools/ct_rom_check.py; then
re_workspace/tools/ct_samples.py reads the tables the way the code does, and
runs the ROM's own Audio_CmdLoadSong ($C7:01A1, ChronoRET's 65816
interpreter) on the built ROM: its transfers must be the ones the S-SMP
driver received in `music sample-check` (the driver booted from the clean
ROM, the built ROM's song load, then the song run until a voice keys on the
sample), and must carry the sample bytes, its directory entry and its
tuning and ADSR words. The voice's decoded samples must equal an independent
S-DSP decode of the bytes in the built ROM, and its pitch register the
driver's formula (computed here) at the sidecar's rate. The checker must
reject damaged copies; the CLI refuses edits over a song's budgets and
writes nothing. Needs the user's ROM, the ChronoRET checkout and the venv.
"""
import hashlib
import json
import math
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
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
import ct_samples as cs  # noqa: E402

SONG = 2
ADSR = 0xE0FF


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


def note_pitch(note, tuning, fine=0):
    """Spc_NotePitch ($06BD) as docs/sfx_lab.md writes it: the octave-4
    semitone, scaled by the tuning word, shifted by the octave."""
    p = math.floor(4096 * 2 ** ((note % 12 - 11) / 12))
    t, h = (tuning + fine) & 0xFF, tuning >> 8 & 0xFF
    q = ((p >> 8) * t + ((p & 0xFF) * t >> 8)) & 0xFFFF
    if h:
        q = (q + ((q >> 8) * h >> 8)) & 0xFFFF
    if t < 0x80:
        q = (q + p) & 0xFFFF
    octave = note // 12
    return (q << (octave - 4) if octave >= 4 else q >> (4 - octave)) & 0x3FFF


def write_wav(path, rate, freq, count):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b''.join(struct.pack('<h', int(12000 * (math.sin(2 * math.pi * freq * i / rate)
                                                               + 0.3 * math.sin(6 * math.pi * freq * i / rate))))
                               for i in range(count)))


def new_project(directory, name):
    project = directory / name
    shutil.copytree(fixture, project)
    return project


def edit_meta(project, change):
    path = project / 'project.json'
    meta = json.loads(path.read_text())
    change(meta.setdefault('rom', {'eventPacks': []}))
    path.write_text(json.dumps(meta, indent=2))


clean = rom.read_bytes()
sites = cs.find_sites(clean)
t0 = cs.tables(clean, sites)
with tempfile.TemporaryDirectory(prefix='chronoforge-audio-') as directory:
    directory = Path(directory)
    out, report = directory / 'built.sfc', directory / 'report.json'

    # Unedited import of every sample and song: the clean ROM, no writes.
    project = new_project(directory, 'Import.ctproj')
    print(run(cli, 'sfx', 'import-rom', rom, '--project', project).strip())
    print(run(cli, 'music', 'import', rom, '--project', project).strip())
    run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report)
    doc = json.loads(report.read_text())
    if out.read_bytes() != clean or doc['writes'] or len(doc['samples']) != cs.ROM_COUNT or len(doc['songs']) != clean[cs.SONG_COUNT_PC]:
        fail('the unedited import does not build to the clean ROM')
    for s in doc['samples']:
        e = cs.entry(clean, t0, s['number'])
        if not s['asIs'] or s['brrSHA256'] != cs.sha(e['brr']) or (s['tuning'], s['adsr'], s['loopOffset']) != (e['tuning'], e['adsr'], e['loopOffset']):
            fail(f'imported sample {s["number"]} is not the ROM\'s')
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')
    print(f'audio: import of all {cs.ROM_COUNT} samples and {len(doc["songs"])} songs then build is byte-identical to the clean ROM')

    # A replaced and an appended sample in a song started from the template.
    project = new_project(directory, 'Compose.ctproj')
    rates = {'lead': 32000, 'bass': 16000}
    write_wav(directory / 'lead.wav', 32000, 523.25, 9600)
    write_wav(directory / 'bass.wav', 16000, 130.81, 6400)
    run(cli, 'sfx', 'encode', directory / 'lead.wav', '--project', project, '--id', 'lead', '--loop', '3200:9600')
    run(cli, 'sfx', 'encode', directory / 'bass.wav', '--project', project, '--id', 'bass', '--rate', '16000', '--loop', '1600:6400')
    print(run(cli, 'sfx', 'use', project, 'lead', '--replace', '7', '--adsr', f'${ADSR:04X}').strip())
    print(run(cli, 'sfx', 'use', project, 'bass', '--root', '48', '--adsr', f'${ADSR:04X}').strip())
    print(run(cli, 'music', 'new', '--project', project, '--song', str(SONG), '--samples', '7,63', '--tracks', '0:5,1:4',
              '--steps', '384').strip())
    listing = project / f'audio/songs/song{SONG:02X}.ctsong'
    run(cli, 'music', 'edit', listing, 'insert', '0', '0', 'C5', '96', '--out', listing)
    run(cli, 'music', 'edit', listing, 'insert', '1', '0', 'C4', '96', '--out', listing)
    print(run(cli, 'rom', 'build', project, '--base', rom, '--out', out, '--report', report), end='')
    doc = json.loads(report.read_text())
    built = out.read_bytes()
    print(run(python, workspace / 'tools/ct_rom_check.py', out, report), end='')

    t1 = cs.tables(built, sites, clean)
    reported = {s['number']: s for s in doc['samples']}
    if t1['count'] != 63 or sorted(reported) != [7, 63] or cs.pc_of(t1['pointers']) != doc['sampleTables']['pc']:
        fail(f'the built ROM\'s tables: {t1} {sorted(reported)}')
    for n in range(1, 63):
        if n != 7 and any(cs.entry(built, t1, n)[k] != cs.entry(clean, t0, n)[k] for k in ('pointer', 'brr', 'loopOffset', 'tuning', 'adsr')):
            fail(f'unedited sample {n} changed')
    if cs.song_list(built, SONG) != [7, 63]:
        fail(f'song {SONG} loads {cs.song_list(built, SONG)}')
    start, end, echo, edl = cs.budget(built, SONG, t1)
    budget = next(b for b in doc['budgets'] if b['song'] == SONG)
    if (budget['sampleStart'], budget['sampleEnd'], budget['echoStart'], budget['edl']) != (start, end, echo, edl) or end > echo:
        fail(f'song {SONG} budget {budget} is not ${start:04X}-${end:04X} below ${echo:04X}')
    print(f'audio: sample 7 replaced, sample 63 appended (tables moved to ${t1["pointers"]:06X}, '
          f'{len(sites)} operands); song ${SONG:02X} samples ${start:04X}-${end:04X}, echo at ${echo:04X}')

    # The ROM's own song load on the built ROM, and the driver run on it.
    command, transfers, _ = cs.load_transfers(built, SONG)
    at = {d: (m, b) for d, m, b in transfers}

    def word(data, offset):
        return data[offset] | data[offset + 1] << 8
    for name, number in (('lead', 7), ('bass', 63)):
        probe_path = directory / f'probe{number}.json'
        run(cli, 'music', 'sample-check', rom, out, str(SONG), str(number), '--frames', '2048', '--out', probe_path)
        probe = json.loads(probe_path.read_text())
        e = cs.entry(built, t1, number)
        sent = [(t['destination'], t['mode'], t['byteCount'], t['sha256']) for t in probe['transfer']['transfers']]
        mine = [(d, m, len(b), cs.sha(b)) for d, m, b in transfers]
        if not probe['passed'] or sent != mine:
            fail(f'sample {number}: the driver run or its transfers differ from the ROM\'s sender: {probe["checks"]}')
        slot, aram = probe['slot'], probe['aram']
        directory_bytes, words_a, words_b = at[0x1E80][1], at[0x1F40][1], at[0x1FC0][1]
        if at.get(aram, (0, b''))[1][:len(e['brr'])] != e['brr']:
            fail(f'sample {number}: the ROM\'s sender does not send its bytes to ${aram:04X}')
        if (word(directory_bytes, 4 * slot), word(directory_bytes, 4 * slot + 2)) != (aram, aram + e['loopOffset']):
            fail(f'sample {number}: directory entry ${0x20 + slot:02X}')
        if (word(words_a, 2 * slot), word(words_b, 2 * slot)) != (e['tuning'], e['adsr']):
            fail(f'sample {number}: parameter words')
        decoded = cs.dsp_decode(e['brr'], *probe['history'])[:probe['decodedSamples']]
        digest = hashlib.sha256(b''.join(struct.pack('<h', x) for x in decoded)).hexdigest()
        if probe['decodedSamples'] != min(2048, len(e['brr']) // 9 * 16) or digest != probe['decodedSHA256']:
            fail(f'sample {number}: the voice\'s samples are not the S-DSP decode of the built ROM\'s bytes')
        pitch = note_pitch(probe['note'], e['tuning'], probe['fine'])
        rate = 32000 * pitch / 0x1000
        if probe['pitch'] != pitch or abs(rate - rates[name]) > rates[name] * 0.002:
            fail(f'sample {number}: pitch ${probe["pitch"]:04X}, formula ${pitch:04X}, {rate:.1f} Hz for {rates[name]} Hz')
        print(f'audio: sample {number} ({name}) at ARAM ${aram:04X}, directory ${0x20 + slot:02X}, tuning ${e["tuning"]:04X}: '
              f'voice {probe["voice"]} keyed on note {probe["note"]}, pitch ${pitch:04X} = {rate:.0f} Hz '
              f'(sidecar {rates[name]}), {probe["decodedSamples"]} decoded samples equal')
    print(f'audio: the ROM\'s Audio_CmdLoadSong sends {len(transfers)} transfers equal to the driver run\'s; '
          f'2 of 2 written samples keyed on and decoded by the S-SMP driver')

    # The checker must notice damage that keeps the header and report consistent.
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

    tables_pc = cs.pc_of(t1['pointers'])
    bass = reported[63]
    cases = ((dict(where=bass['pc'] + 2 + 20), 'sample 63: BRR bytes'),
             (dict(where=tables_pc + 3 * 63 + 2 * 62), 'sample 63: table words'),
             (dict(where=tables_pc + 5 * 63 + 2 * 7, extra_write=tables_pc + 5 * 63 + 2 * 7), 'sample 8 changed'),
             (dict(where=cs.SAMPLES_PC + 32 * SONG + 2), f'song {SONG}: sample list'),
             (dict(where=tables_pc + 3 * 62), 'sample 63: BRR bytes'),
             (dict(where=sites[0], value=built[sites[0]] ^ 0x10, extra_write=sites[0]), 'two places'))
    for kwargs, message in cases:
        result = damaged(**kwargs)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            fail(f'damage at ${kwargs["where"]:06X} not reported as "{message}": {result.stdout}{result.stderr[-400:]}')
    print(f'audio: {len(cases)} damaged copies rejected by the checker')

    # The CLI refuses what the game cannot load and writes nothing.
    target = directory / 'x.sfc'
    meta_path = project / 'project.json'
    good_meta = meta_path.read_text()

    def refused(args, message):
        result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=600)
        if result.returncode == 0 or target.exists() or message not in result.stdout + result.stderr:
            fail(f'not refused ({message}): {result.stdout}{result.stderr}')

    def refused_build(message):
        refused([cli, 'rom', 'build', project, '--base', rom, '--out', target], message)
        meta_path.write_text(good_meta)

    # Song $27 leaves 16 bytes for samples below its echo buffer.
    edit_meta(project, lambda r: next(s for s in r['samples'] if s['id'] == 'bass').update(songs=[0x27]))
    refused_build('into the echo buffer')
    # A song whose own row loads 16 samples takes no more.
    run(cli, 'music', 'new', '--project', project, '--song', '4', '--samples', ','.join(map(str, range(1, 17))),
        '--steps', '96', '--out', 'audio/songs/full.ctsong')
    edit_meta(project, lambda r: next(s for s in r['samples'] if s['id'] == 'bass').update(songs=[4]))
    refused_build('already loads 16 samples')
    # A composed sequence longer than the space below $4700.
    composed = listing.read_text()
    listing.write_text(composed.replace('LOOP0:\n', 'LOOP0:\n' + '    note C 96\n' * 12000, 1))
    refused_build('its transfer would reach $4700')
    listing.write_text(composed)
    # A GAIN-only sidecar without an ADSR word, a root no tuning word reaches,
    # a slot past the ROM's samples (refused by `sfx use`, which writes nothing).
    side = json.loads((project / 'audio/samples/bass.json').read_text())
    side.pop('adsr', None)
    shutil.copy(project / 'audio/samples/bass.brr', project / 'audio/samples/gain.brr')
    (project / 'audio/samples/gain.json').write_text(json.dumps(dict(side, brr='audio/samples/gain.brr', gain=0x7F)))
    cases = (([cli, 'sfx', 'use', project, 'gain'], 'the driver plays ADSR envelopes only'),
             ([cli, 'sfx', 'use', project, 'bass', '--root', '100'], 'no tuning word plays a 16000 Hz sample at root note 100'),
             ([cli, 'sfx', 'use', project, 'bass', '--replace', '63'], '--replace takes 1-62'))
    for args, message in cases:
        refused(args, message)
        if meta_path.read_text() != good_meta:
            fail(f'a refused `sfx use` changed project.json ({message})')
    print(f'audio: {3 + len(cases)} edits over a budget or that the driver cannot play refused by the CLI')
print('audio: CLI import, sample write-back, the ROM\'s song load and the S-SMP driver checked independently')
