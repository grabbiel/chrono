#!/usr/bin/env python3
"""Independent ROM/CLI acceptance checks for the native S-SMP milestone.

Lanes: `direct` (boot blocks copied to ARAM) and `ipl` (blocks uploaded through
the local S-SMP IPL image named by CHRONOFORGE_IPL_ROM). With the variable
unset the IPL lane prints UNVERIFIED and is not run; a set but bad path fails.
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


def run(*args):
    return subprocess.run([str(CLI), "music", "driver-check", *map(str, args)],
                          capture_output=True, text=True, timeout=60)


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
    parser.add_argument("--lane", choices=["all", "direct", "ipl"], default="all")
    lane = parser.parse_args().lane
    rom = ROM.read_bytes()
    digest = hashlib.sha256(rom).hexdigest()
    assert digest == "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9"
    if lane in ("all", "direct"):
        direct_lane(rom, digest)
    if lane in ("all", "ipl"):
        ipl_lane(rom, digest)


if __name__ == "__main__":
    main()
