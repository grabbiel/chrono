#!/usr/bin/env python3
"""Independent ROM/CLI acceptance checks for the native S-SMP milestone.

Lanes: `direct` (boot blocks copied to ARAM), `ipl` (blocks uploaded through
the local S-SMP IPL image named by CHRONOFORGE_IPL_ROM) and `transfer` (a song
and its samples sent to the running driver, `music song-load`). With the
variable unset the IPL lane and the transfer lane's IPL comparison print
UNVERIFIED and are not run; a set but bad path fails. `--all-songs` extends the
transfer lane from its representative songs to every ROM song (not gated).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ROM = ROOT / "re_workspace/ct_clean.sfc"
CLI = Path(os.environ.get("CHRONOFORGE_CLI", ROOT / "macos_studio/.build/debug/chronoforge"))
IPL_SHA256 = "c95f88b299030d5afa55b1031e2b5ef2dff650c4b4e6bb6f8b1359436521278f"
# Transcribed independently from matched ChronoRET C7 tables and SPC code.
EXPECTED_BLOCKS = [(0x724C3, 0x0200, 0x1BEF), (0x74309, 0x2F00, 0x1800),
                   (0x740B4, 0x4700, 0x0201), (0x742B7, 0x1E00, 0x0024),
                   (0x742DD, 0x1F80, 0x0014), (0x742F3, 0x1F00, 0x0014)]
DIRECT_CHECKS = {
    "driver reached main loop after minimum timer1 wait", "stack initialized",
    "no current, saved or pending song", "three group volumes initialized",
    "DSP sample directory set", "eight voice gains initialized", "main volume initialized",
    "echo delay and base initialized", "builtin sample parameters initialized",
    "command arguments captured", "DSP command executed through ROM handler",
    "CPU, bus and DSP endpoint clocks agree",
}
IPL_CHECKS = DIRECT_CHECKS | {"IPL start echo held until the driver's first port report"}
SONG_LOAD_CHECKS = {
    "song command answered with the new song", "end header acknowledged with CPUIO1 = 0",
    "ARAM matched every ROM payload at the end acknowledgement", "payloads unchanged at the first port report",
    "current and requested song recorded", "song tracks started from the command's header set",
    "first port report lists the song's voices", "echo delay and buffer taken from the song",
    "CPU, bus and DSP endpoint clocks agree",
}
# Empty song, sample 12 across a bank ($04), song data across a bank with an
# echo change ($18), longest song reaching the $2F00 block ($3F).
TRANSFER_SONGS = [0x00, 0x04, 0x18, 0x3F]


def run(*args, operation="driver-check"):
    return subprocess.run([str(CLI), "music", operation, *map(str, args)],
                          capture_output=True, text=True, timeout=60)


def song_load(*args):
    return run(*args, operation="song-load")


def hirom(long):
    """File offset of a HiROM $C0-$FF long address."""
    assert 0xC0 <= long >> 16 <= 0xFF, hex(long)
    return long - 0xC00000


def expected_song_load(rom, song):
    """CT's first load of `song` after Audio_Boot, transcribed from ChronoRET
    asm/bankC7/bankC7.asm independently of CTSPCTransfer.swift."""
    word = lambda pc: int.from_bytes(rom[pc:pc + 2], "little")
    long = lambda pc: int.from_bytes(rom[pc:pc + 3], "little")
    assert song < rom[0x070AE9]                                   # Audio_SongCount
    # Audio_AdjustSongCmd (1394-1414): bit 2 for songs on Audio_SongBit2List ($C7:0AD8).
    bit2, pc = set(), 0x070AD8
    while rom[pc] < 0x80:
        bit2.add(rom[pc]); pc += 1
    command = 0x10 | (4 if song in bit2 else 0)
    # Audio_StartSong (1951-1975): the song, AudioRom_SongEcho byte 1, delay = byte 0 & $0F.
    echo = 0x07241D + 2 * (song & 0x7F)
    arguments = [song, rom[echo + 1], rom[echo] & 0x0F]
    # Audio_CmdLoadSong .copy_list (504-526): AudioRom_SongSamples, 16 words, 0-ended.
    numbers = []
    for k in range(16):
        n = word(0x070E11 + 32 * song + 2 * k)
        if n == 0:
            break
        assert 1 <= n <= 62
        numbers.append(n)
    # Slots start after boot block 2 ($4700 + its length); every slot is free after boot.
    address = 0x4700 + EXPECTED_BLOCKS[2][2]
    samples, transfers = [], []
    for slot, n in enumerate(numbers):
        # Audio_UploadSample (1247-1359): length word, then length / 3 triples.
        source = hirom(long(0x070AEA + 3 * (n - 1)))
        length = word(source)
        assert length and length % 3 == 0
        y = (source + 2) & 0xFFFF
        samples.append(dict(number=n, slot=slot, destination=address, length=length,
                            loopOffset=word(0x070BA4 + 2 * (n - 1)), sourcePC=source + 2,
                            crossesBank=y + length > 0xFFFF))
        transfers.append((f"sample {n}", address, 3, rom[source + 2:source + 2 + length]))
        address += length
    # Audio_SendSampleDir (790-833): start, start + loop for the first slot of
    # each listed sample; past the list the model sends zero.
    directory = bytearray(64)
    for k, n in enumerate(numbers):
        first = next(s for s in samples if s["number"] == n)
        start = first["destination"]
        directory[4 * k:4 * k + 4] = start.to_bytes(2, "little") + ((start + first["loopOffset"]) & 0xFFFF).to_bytes(2, "little")
    transfers.append(("directory", 0x1E80, 2, bytes(directory)))
    # LDA.l Audio_SampleParamA/B,X with X = (sample - 1) * 2 in 16 bits (884-939):
    # an unused entry reads table + $FFFE, which carries into bank $C8.
    for label, table, destination in [("parameters A", 0xC70C20, 0x1F40), ("parameters B", 0xC70C9C, 0x1FC0)]:
        data = b"".join(rom[hirom(table + ((2 * ((numbers[k] if k < len(numbers) else 0) - 1)) & 0xFFFF)):][:2]
                        for k in range(16))
        transfers.append((label, destination, 2, data))
    # Audio_SendSongData (991-1108): X = length, send while X - 3 stays >= 0 (BPL):
    # length / 3 + 1 triples, 1-3 bytes past the song.
    source = hirom(long(0x070D18 + 3 * song))
    length = word(source)
    assert length < 0x8000
    steps = length // 3 + 1
    # The fast (non-crossing) copy wraps Y inside its bank; no US song needs it.
    y = (source + 2) & 0xFFFF
    assert y + length > 0xFFFF or y + 3 * steps <= 0x10000
    song_bytes = rom[source + 2:source + 2 + 3 * steps]
    transfers.append(("song", 0x2000, 3, song_bytes))
    # .extra_loop (1112-1164): 12 triples from AudioRom_SongExtra ($C7:1871) + 36 x song.
    extra = hirom(0xC71871 + 36 * song)
    transfers.append(("song extra", 0xF120, 3, rom[extra:extra + 36]))
    return command, arguments, samples, transfers, song_bytes[:length]


def assert_song_load(report, rom, digest, song, mode):
    command, arguments, samples, transfers, data = expected_song_load(rom, song)
    assert report["format"] == "ct-spc-song-load/1"
    assert report["romSHA256"] == digest and report["song"] == song
    assert report["mode"] == f"{mode}; first song load; register-only DSP; no PCM"
    assert report["passed"] is True
    assert {c["name"] for c in report["checks"]} == SONG_LOAD_CHECKS
    assert len(report["checks"]) == len(SONG_LOAD_CHECKS) and all(c["passed"] for c in report["checks"])
    assert report["samples"] == samples
    load = report["transfer"]
    assert (load["command"], load["arguments"]) == (command, arguments)
    assert load["songReply"] == song and load["endReply"] == 0 and load["payloadVerified"] is True
    # Spc_XferReceive waits for (command + 1) & $7F, later headers are !Audio_SeqHeader $E0.
    sequences = [(command + 1) & 0x7F] + [0xE0] * (len(transfers) - 1)
    for got, (label, destination, mode_, payload), sequence in zip(load["transfers"], transfers, sequences):
        expected = dict(label=label, destination=destination, mode=mode_, headerSequence=sequence,
                        steps=len(payload) // mode_, byteCount=len(payload),
                        sha256=hashlib.sha256(payload).hexdigest())
        assert {k: v for k, v in got.items() if k != "cycles"} == expected, (got, expected)
        assert got["cycles"] > 0
    assert len(load["transfers"]) == len(transfers)
    steps = sum(len(p) // m for _, _, m, p in transfers)
    assert load["stepCount"] == steps and load["bytesTransferred"] == sum(len(p) for *_, p in transfers)
    # Command, one header per transfer, each step and the end step: one echo each.
    assert load["acknowledgementCount"] == 1 + len(transfers) + steps + 1
    # The host waits at least 16 clocks after each echo; all US songs load in < 1M.
    assert 16 * load["acknowledgementCount"] < load["loadCycles"]
    assert sum(t["cycles"] for t in load["transfers"]) < load["loadCycles"]
    assert load["loadCycles"] + load["startCycles"] == load["totalCycles"] < 1_000_000
    # Song header (CTSong): no-track word at +2, set A pointers at +4 (track i = bit i).
    no_track = data[2:4]
    tracks = sum(1 << i for i in range(8) if data[4 + 2 * i:6 + 2 * i] != no_track)
    assert load["voicesReport"] == (tracks | tracks >> 4) & 0x0F
    assert 81_920 <= report["driverBootCycles"] <= report["idleCycles"] < 250_000
    assert len(report["limitations"]) == 3
    return load


def transfer_lane(rom, digest, songs):
    assert 0x18 in songs   # the IPL comparison below
    loads = {}
    for song in songs:
        result = song_load(ROM, song)
        assert result.returncode == 0, result.stdout + result.stderr
        report = json.loads(result.stdout)
        loads[song] = assert_song_load(report, rom, digest, song, "direct-ARAM-load")
        assert "upload" not in report and "iplSHA256" not in report
    biggest = max(loads.values(), key=lambda load: load["totalCycles"])
    with tempfile.TemporaryDirectory(prefix="chronoforge-song-load-") as directory:
        d = Path(directory)
        output = d / "report.json"
        assert song_load(ROM, "$18", "--out", output).returncode == 0
        assert_song_load(json.loads(output.read_text()), rom, digest, 0x18, "direct-ARAM-load")
        damaged = d / "damaged.sfc"
        damaged.write_bytes(rom[:0x070E11] + bytes([rom[0x070E11] ^ 1]) + rom[0x070E12:])
        for args in [(ROM, rom[0x070AE9]), (ROM, "x"), (ROM, -1), (damaged, 4)]:
            output.write_text("preserve me")
            assert song_load(*args, "--out", output).returncode != 0, args
            assert output.read_text() == "preserve me"
        assert song_load(ROM).returncode != 0
        alias = d / "alias.sfc"
        alias.symlink_to(ROM)
        assert song_load(ROM, 4, "--out", alias).returncode != 0
        assert hashlib.sha256(ROM.read_bytes()).hexdigest() == digest
    print(f"S-SMP song transfer: {len(songs)} songs through the driver's command protocol, verified at the end "
          f"acknowledgement; largest {biggest['bytesTransferred']} bytes / {biggest['acknowledgementCount']} "
          f"acknowledgements in {biggest['totalCycles']} cycles; CLI refusals pass")
    path = os.environ.get("CHRONOFORGE_IPL_ROM")
    if not path:
        print("S-SMP song transfer after IPL boot: UNVERIFIED (CHRONOFORGE_IPL_ROM unset)")
        return
    ipl = Path(path)
    assert hashlib.sha256(ipl.read_bytes()).hexdigest() == IPL_SHA256, "unexpected IPL image"
    result = song_load(ROM, 0x18, "--ipl", ipl)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    load = assert_song_load(report, rom, digest, 0x18, "IPL-upload")
    assert report["iplSHA256"] == IPL_SHA256 and report["upload"]["bytesTransferred"] == 13_884
    strip = lambda transfers: [{k: v for k, v in t.items() if k != "cycles"} for t in transfers]
    assert strip(load["transfers"]) == strip(loads[0x18]["transfers"])
    print(f"S-SMP song transfer after IPL boot: song $18 {load['bytesTransferred']} bytes in "
          f"{load['totalCycles']} cycles, same transfers as the direct boot")


def assert_driver_report(report, rom, digest, checks):
    word = lambda pc: int.from_bytes(rom[pc:pc + 2], "little")
    assert report["format"] == "ct-spc-driver-check/1"
    assert report["romSHA256"] == digest
    assert report["passed"] is True
    assert len(report["blocks"]) == 6
    for i, (source, destination, size) in enumerate(EXPECTED_BLOCKS):
        assert 0x70000 + word(0x70010 + 2 * i) == source
        assert word(0x7001C + 2 * i) == destination
        assert word(source) == size
        assert report["blocks"][i] == dict(index=i, sourcePC=source, destination=destination,
                                          length=size, sha256=hashlib.sha256(rom[source + 2:source + 2 + size]).hexdigest())
    assert 81_920 <= report["bootCycles"] < report["totalCycles"] < 250_000
    assert {c["name"] for c in report["checks"]} == checks
    assert len(report["checks"]) == len(checks)
    assert all(c["passed"] for c in report["checks"])
    assert report["dspWrites"] > 16
    assert len(report["limitations"]) == 3


def ipl_lane(rom, digest):
    path = os.environ.get("CHRONOFORGE_IPL_ROM")
    if not path:
        print("S-SMP IPL upload: UNVERIFIED (CHRONOFORGE_IPL_ROM unset)")
        return
    ipl = Path(path)
    assert hashlib.sha256(ipl.read_bytes()).hexdigest() == IPL_SHA256, "unexpected IPL image"
    result = run(ROM, "--ipl", ipl)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert_driver_report(report, rom, digest, IPL_CHECKS)
    assert report["mode"] == "IPL-upload; register-only DSP; no PCM"
    assert report["iplSHA256"] == IPL_SHA256
    upload = report["upload"]
    # CT's sender: first token $CC; after a block, last counter + 4 (0 -> 1);
    # the start header reuses that token with command 0.
    token, tokens = 0xCC, []
    for i, (source, destination, size) in enumerate(EXPECTED_BLOCKS):
        last = (size - 1) & 0xFF
        nxt = (last + 4) & 0xFF or 1
        tokens.append(dict(destination=destination, byteCount=size, startToken=token, lastByteToken=last,
                           nextToken=nxt, sha256=hashlib.sha256(rom[source + 2:source + 2 + size]).hexdigest()))
        token = nxt
    assert upload["blocks"] == tokens
    assert upload["startToken"] == token == 0x17
    total = sum(size for _, _, size in EXPECTED_BLOCKS)
    assert upload["bytesTransferred"] == total == 13_884
    assert upload["acknowledgementCount"] == total + len(EXPECTED_BLOCKS) + 1
    assert upload["entry"] == 0x0200 and upload["payloadVerified"] is True
    # Each byte needs at least one IPL receive-loop iteration (>= 20 clocks).
    assert total * 20 < upload["totalCycles"] < 4_000_000
    with tempfile.TemporaryDirectory(prefix="chronoforge-ipl-") as directory:
        d = Path(directory)
        output = d / "report.json"
        assert run(ROM, "--ipl", ipl, "--out", output).returncode == 0
        assert json.loads(output.read_text()) == report
        bad = d / "bad.rom"
        for data in [None, ipl.read_bytes()[:-1], bytes([0xFF]) * 64]:   # missing, short, STOP image
            if data is None:
                bad.unlink(missing_ok=True)
            else:
                bad.write_bytes(data)
            output.write_text("preserve me")
            assert run(ROM, "--ipl", bad, "--out", output).returncode != 0
            assert output.read_text() == "preserve me"
        copy = d / "ipl.rom"
        copy.write_bytes(ipl.read_bytes())
        assert run(ROM, "--ipl", copy, "--out", copy).returncode != 0
        assert hashlib.sha256(copy.read_bytes()).hexdigest() == IPL_SHA256
    print(f"S-SMP IPL upload: {total} bytes / {upload['acknowledgementCount']} acknowledgements in "
          f"{upload['totalCycles']} cycles, verified before $0200; driver {report['bootCycles']} boot cycles, "
          f"{len(IPL_CHECKS)} checks; CLI refusals pass")


def direct_lane(rom, digest):
    result = run(ROM)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert_driver_report(report, rom, digest, DIRECT_CHECKS)
    assert report["mode"] == "direct-ARAM-load; register-only DSP; no PCM"
    assert "upload" not in report and "iplSHA256" not in report
    # Startup opcode sequence actually writes CONTROL, T0, T1, CONTROL.
    assert rom[0x724C5 + 0x3C:0x724C5 + 0x48] == bytes.fromhex("8f30f1 8f2afa 8f80fb 8f03f1")
    with tempfile.TemporaryDirectory(prefix="chronoforge-ssmp-") as directory:
        d = Path(directory)
        output = d / "report.json"
        assert run(ROM, "--out", output).returncode == 0
        assert json.loads(output.read_text()) == report
        for data in [rom[:-1], rom[:0x724C5] + bytes([rom[0x724C5] ^ 1]) + rom[0x724C6:]]:
            damaged = d / "damaged.sfc"
            damaged.write_bytes(data)
            output.write_text("preserve me")
            assert run(damaged, "--out", output).returncode != 0
            assert output.read_text() == "preserve me"
        alias = d / "alias.sfc"
        alias.symlink_to(ROM)
        assert run(ROM, "--out", alias).returncode != 0
        assert hashlib.sha256(ROM.read_bytes()).hexdigest() == digest
    print(f"S-SMP driver: 6 ROM blocks, 12 runtime checks, bounded boot {report['bootCycles']} cycles; CLI refusals pass")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", choices=["all", "direct", "ipl", "transfer"], default="all")
    parser.add_argument("--all-songs", action="store_true", help="transfer lane: every ROM song")
    options = parser.parse_args()
    lane = options.lane
    rom = ROM.read_bytes()
    digest = hashlib.sha256(rom).hexdigest()
    assert digest == "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9"
    if lane in ("all", "direct"):
        direct_lane(rom, digest)
    if lane in ("all", "ipl"):
        ipl_lane(rom, digest)
    if lane in ("all", "transfer"):
        transfer_lane(rom, digest, range(rom[0x070AE9]) if options.all_songs else TRANSFER_SONGS)


if __name__ == "__main__":
    main()
