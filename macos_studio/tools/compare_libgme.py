#!/usr/bin/env python3
"""S-DSP PCM against libgme, an external reference used only by this harness.

libgme (game-music-emu, LGPL) is loaded through ctypes from CHRONOFORGE_LIBGME
or /opt/homebrew/lib/libgme.dylib; none of its code is part of ChronoForge.
What libgme 0.6.5 (Spc_Emu, its default fast Spc_Dsp, SPC_LESS_ACCURATE) does
differently, and how the comparison accounts for it:

- Output stage: no low-pass filter (accuracy off) and gain 1.4 as
  clamp16((s * 358) >> 8). Our PCM goes through the same transform.
- Surround removal negates MVOLL when MVOLL * MVOLR < -$4000. Probes stay
  above that; a song that crosses it fails the song lane.
- Load: echo RAM (ESA, EDL * 2 KiB) is filled with $FF when FLG allows echo
  writes. The harness applies the same fill to every snapshot before both
  renders.
- State an SPC file does not carry: libgme's DSP loads with a rate counter
  phase our model reaches with counter $7F0 (LIBGME_COUNTER), and its CPU sees
  a timer tick in the same clock as the access that reads T0OUT-T2OUT or
  enables a timer. Our defaults are counter 0 (reset) and access before the
  timers; the comparisons pass `--counter` and `--timers-first` instead.
- Rounding shortcuts: voices that are neither noise nor a PMON source take a
  Gaussian sum without per-tap rounding or the 15-bit mask, and the mixer,
  FIR and feedback skip the per-voice and per-tap SAR 6 and the echo &~1;
  the voice sum saturates only after MVOL. Exact probes keep to paths where
  both sides do the same integer arithmetic (PMON-source or noise voices,
  voice volumes 64/-64/-128, FIR taps 0/64/-128, EFB 0, whole output terms);
  measured probes leave them and report the error.

Lanes: the fullsnes Gaussian table must appear interleaved in the libgme
binary; exact probes must match bit for bit at a fixed lag of -3 frames (ours
earlier), except samples where our voice sum saturated; measured probes, a
key-on sweep, a timer-poll sweep and the CT songs ($00, $04, $18, $3F) must
meet thresholds calibrated from the measurements in docs/spc700.md. Songs
are also rendered with our default conventions and reported, not gated;
--all-songs reports every song. Without libgme, or without the clean ROM for
the song lane, the script prints UNVERIFIED and exits 3 after running what it
can.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import wave

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
ROM = ROOT / "re_workspace/ct_clean.sfc"
ROM_SHA256 = "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9"
CLI = Path(os.environ.get("CHRONOFORGE_CLI", ROOT / "macos_studio/.build/debug/chronoforge"))
LIBGME = Path(os.environ.get("CHRONOFORGE_LIBGME", "/opt/homebrew/lib/libgme.dylib"))
SDSP_SOURCE = ROOT / "macos_studio/Sources/ChronoForgeCore/SDSP.swift"
SONGS = [0x00, 0x04, 0x18, 0x3F]
UNVERIFIED = 3
# Our S-DSP rate counter start equivalent to libgme's loader: its DSP keeps
# three synchronised sub-counters, and this start reproduced their firing
# pattern for all 31 rates over 12000 samples.
LIBGME_COUNTER = 0x7F0

# Thresholds, calibrated from the measurements recorded in docs/spc700.md.
PROBE_LAG = -3                                      # our frame n - 3 is libgme's frame n
FAST_PATH_MIN_SNR, FAST_PATH_MAX_DIFF = 65.0, 12    # measured 72.6 dB, max 6
FEEDBACK_MIN_SNR, FEEDBACK_MAX_DIFF = 55.0, 20      # measured 60.8 dB, max 10
SONG_MIN_SNR, SONG_MAX_DIFF = 45.0, 32              # measured 50.5-52.5 dB, max 14


# ---------------------------------------------------------------- libgme

def load_libgme():
    if not LIBGME.exists():
        return None
    lib = ctypes.CDLL(str(LIBGME))
    lib.gme_open_data.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.POINTER(ctypes.c_void_p), ctypes.c_int]
    lib.gme_open_data.restype = ctypes.c_char_p
    lib.gme_start_track.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.gme_start_track.restype = ctypes.c_char_p
    lib.gme_play.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_short)]
    lib.gme_play.restype = ctypes.c_char_p
    lib.gme_ignore_silence.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.gme_set_autoload_playback_limit.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.gme_mute_voices.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.gme_delete.argtypes = [ctypes.c_void_p]
    return lib


def gme_render(lib, spc, frames, voices=0xFF):
    """libgme's stereo PCM for an SPC image, at its native 32 kHz."""
    emu = ctypes.c_void_p()
    error = lib.gme_open_data(spc, len(spc), ctypes.byref(emu), 32000)
    assert not error, error
    try:
        lib.gme_ignore_silence(emu, 1)
        lib.gme_set_autoload_playback_limit(emu, 0)
        lib.gme_mute_voices(emu, 0xFF ^ voices)
        assert not lib.gme_start_track(emu, 0)
        buffer = (ctypes.c_short * (2 * frames))()
        assert not lib.gme_play(emu, 2 * frames, buffer)
        return np.frombuffer(bytes(buffer), dtype="<i2").astype(np.int64)
    finally:
        lib.gme_delete(emu)


def gme_gain(pcm):
    """libgme's output stage with its filter off: gain 1.4 in 8-bit fixed point."""
    return np.clip((pcm * 358) >> 8, -32768, 32767)


# ---------------------------------------------------------------- ours

def read_wav(path):
    with wave.open(str(path)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (2, 2, 32000)
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int64)


def spc_render(spc, seconds, directory, voices=0xFF, libgme_conventions=True):
    source, out = Path(directory) / "in.spc", Path(directory) / "out.wav"
    source.write_bytes(spc)
    options = ["--counter", str(LIBGME_COUNTER), "--timers-first"] if libgme_conventions else []
    result = subprocess.run([str(CLI), "music", "spc-render", str(source), "--seconds", str(seconds),
                             "--voices", str(voices), *options, "--out", str(out)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return read_wav(out)


def song_snapshot(song, directory):
    """The state `music render` starts recording from, as an SPC image."""
    d = Path(directory)
    result = subprocess.run([str(CLI), "music", "render", str(ROM), str(song), "--seconds", "0.01",
                             "--out", str(d / "live.wav"), "--spc", str(d / "start.spc")],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["song"] == song and all(check["passed"] for check in report["loadChecks"]), report
    return (d / "start.spc").read_bytes()


# ---------------------------------------------------------------- comparison

def compare(ours, reference, lag, skip=0):
    """Our frame n + lag, through libgme's gain, against libgme's frame n, from frame `skip`."""
    ours = gme_gain(ours)
    frames = min(len(ours), len(reference)) // 2
    start, end = max(skip, -lag), min(frames, frames - lag)
    a = ours[2 * (start + lag):2 * (end + lag)]
    b = reference[2 * start:2 * end]
    diff = a - b
    signal, noise = float(np.sum(b * b)), float(np.sum(diff * diff))
    first = np.flatnonzero(diff)
    norm = np.sqrt(float(np.sum(a * a)) * signal)
    return {
        "lag": lag, "frames": end - start,
        "snr_db": round(10 * float(np.log10(signal / noise)), 2) if noise and signal else (float("inf") if signal else None),
        "max_abs_diff": int(np.max(np.abs(diff))) if len(diff) else 0,
        "equal_fraction": round(float(np.mean(diff == 0)), 6) if len(diff) else 1.0,
        "first_diff_frame": int(start + first[0] // 2) if len(first) else None,
        "correlation": round(float(np.sum(a * b)) / norm, 5) if norm else None,
    }


def best_lag(ours, reference, lags=range(-12, 13), window=32000):
    """Lag with the least squared error over the first `window` frames."""
    def error(lag):
        n = min(len(ours), len(reference)) // 2
        start, end = max(0, -lag), min(n, window, n - lag)
        d = gme_gain(ours[2 * (start + lag):2 * (end + lag)]) - reference[2 * start:2 * end]
        return float(np.sum(d * d))
    return min(lags, key=error)


def onset(pcm):
    nonzero = np.flatnonzero(pcm)
    return int(nonzero[0] // 2) if len(nonzero) else None


# ---------------------------------------------------------------- SPC images

def lcg(seed):
    state = seed & 0xFFFFFFFF
    while True:
        state = (state * 1103515245 + 12345) & 0xFFFFFFFF
        yield state >> 16


def brr(seed, blocks, modes, loop_block=0):
    """Looping BRR sample with (shift, filter) cycling through `modes` and random nibbles."""
    numbers, data = lcg(seed), bytearray()
    for block in range(blocks):
        shift, filter = modes[block % len(modes)]
        data.append(shift << 4 | filter << 2 | (3 if block == blocks - 1 else 0))
        data += bytes(next(numbers) & 0xFF for _ in range(8))
    return bytes(data), loop_block * 9


SAMPLES = [
    # Moderate amplitudes through every filter, looping from block 4.
    brr(1, 12, [(8, 0), (8, 1), (7, 2), (7, 3), (9, 1), (6, 2)], loop_block=4),
    # Shifts 13-15 (nibble SAR 3) mixed with filtered blocks.
    brr(2, 9, [(7, 1), (13, 0), (6, 3), (14, 2), (7, 2), (15, 1)]),
    # Shift 12 through filters 2/3: 16-bit clamps and 15-bit wraps.
    brr(3, 10, [(12, 2), (12, 3), (11, 2), (12, 0), (12, 1)], loop_block=2),
    # Small amplitudes for the echo probes.
    brr(4, 8, [(6, 0), (6, 2), (5, 1), (6, 3)], loop_block=1),
]


def sample_ram():
    """Directory at $0300, samples from $0400."""
    directory, writes, address = bytearray(), [], 0x0400
    for blocks, loop in SAMPLES:
        directory += address.to_bytes(2, "little") + (address + loop).to_bytes(2, "little")
        writes.append((address, blocks))
        address += len(blocks)
    return [(0x0300, bytes(directory))] + writes


def spc_image(dsp, program=b"\x2F\xFE"):
    """SPC v0.30 image: samples, CPU at $0200 running `program`, timers and IPL off."""
    ram = bytearray(0x10000)
    ram[0x0200:0x0200 + len(program)] = program
    for address, data in sample_ram():
        ram[address:address + len(data)] = data
    header = bytearray(0x100)
    header[0:33] = b"SNES-SPC700 Sound File Data v0.30"
    header[0x21:0x25] = bytes([0x1A, 0x1A, 0x1B, 30])
    header[0x25:0x27] = (0x0200).to_bytes(2, "little")
    header[0x2B] = 0xEF                                            # SP
    regs = bytearray(128)
    for register, value in dsp.items():
        regs[register] = value & 0xFF
    return bytes(header + ram + regs + bytes(64) + ram[0xFFC0:])


def with_libgme_echo_fill(spc):
    """The echo region filled with $FF, as libgme's start_track does when FLG
    allows echo writes."""
    image = bytearray(spc)
    dsp = 0x10100
    if not image[dsp + 0x6C] & 0x20:
        start = image[dsp + 0x6D] * 0x100
        end = min(start + 0x800 * (image[dsp + 0x7D] & 0x0F), 0x10000)
        image[0x100 + start:0x100 + end] = b"\xFF" * (end - start)
    return bytes(image)


def voice(v, srcn, pitch, volume, adsr1=0, adsr2=0, gain=0):
    b = v << 4
    return {b + 0: volume[0], b + 1: volume[1], b + 2: pitch & 0xFF, b + 3: pitch >> 8,
            b + 4: srcn, b + 5: adsr1, b + 6: adsr2, b + 7: gain}


GLOBALS = {"kon": 0x4C, "pmon": 0x2D, "non": 0x3D, "eon": 0x4D, "efb": 0x0D, "flg": 0x6C, "edl": 0x7D}


def dsp_image(voices, mvol, evol=(0, 0), fir=(), **registers):
    """Directory $03, echo buffer at $8000, FLG $20 (echo writes off) unless given."""
    dsp = {0x5D: 0x03, 0x6D: 0x80, 0x6C: 0x20}
    for v in voices:
        dsp.update(v)
    dsp[0x0C], dsp[0x1C] = mvol
    dsp[0x2C], dsp[0x3C] = evol
    for tap, c in enumerate(fir):
        dsp[tap << 4 | 0x0F] = c
    for name, value in registers.items():
        dsp[GLOBALS[name]] = value
    return dsp


def probes():
    """(name, exact, DSP registers, frames skipped before comparing)."""
    exact_voices = [
        voice(0, 0, 0x1000, (64, -64), adsr1=0xD9, adsr2=0x6E),        # ADSR attack/decay/sustain
        voice(2, 1, 0x0B37, (-128, 64), gain=0xF3),                    # GAIN bent line, rate 19
        voice(4, 2, 0x1F12, (64, 64), adsr1=0x8F, adsr2=0x35),         # attack rate 31, sustain level 1
        voice(6, 0, 0x0800, (-64, -128), gain=0x30),                   # noise, GAIN direct
    ]
    fast_voices = [
        voice(0, 0, 0x1000, (100, -77), adsr1=0xD9, adsr2=0x6E),
        voice(2, 1, 0x0B37, (-90, 45), gain=0xF3),
        voice(4, 2, 0x1F12, (23, 51), adsr1=0x8F, adsr2=0x35),
        voice(6, 0, 0x0800, (-64, -128), gain=0x30),
    ]
    echo_voices = [
        voice(0, 3, 0x1000, (-128, -128), adsr1=0xDB, adsr2=0x4F),
        voice(2, 3, 0x0C00, (-128, -128), gain=0xD4),                  # GAIN linear increase
    ]
    return [
        ("voices exact (PMON sources, noise, BRR filters/clamps, ADSR, GAIN)", True,
         dsp_image(exact_voices, (80, -60), kon=0x55, pmon=0x2A, non=0x40, flg=0x3A), 0),
        # The first EDL pass reads libgme's $FF fill, which only libgme keeps odd.
        ("echo exact (EON, FIR taps 0/7, EVOL, EFB 0)", True,
         dsp_image(echo_voices, (64, -64), (48, -40), [64, 0, 0, 0, 0, 0, 0, 0x80],
                   kon=0x05, pmon=0x0A, eon=0x05, efb=0, flg=0x00, edl=1), 512 + 16),
        ("fast path (no PMON, other volumes)", False,
         dsp_image(fast_voices, (90, 70), kon=0x55, non=0x40, flg=0x3A), 0),
        ("echo feedback (EFB, low-pass FIR)", False,
         dsp_image(fast_voices[:2], (70, 70), (40, 35), [0x0C, 0x21, 0x2B, 0x2B, 0x13, 0xFE, 0xF3, 0xF9],
                   kon=0x05, eon=0x05, efb=0x40, flg=0x00, edl=2), 0),
    ]


KEY_ON_VOICE = dsp_image([voice(0, 0, 0x1000, (64, 64), gain=0x7F)], (127, 127))


def key_on_sweep_image(nops):
    """MOV $F2,#$4C; NOP x nops; MOV $F3,#$01 (KON voice 0); BRA $."""
    program = bytes([0x8F, 0x4C, 0xF2]) + b"\x00" * nops + bytes([0x8F, 0x01, 0xF3, 0x2F, 0xFE])
    return spc_image(KEY_ON_VOICE, program)


def timer_sweep_image(nops):
    """NOP x nops; T0 target 1; enable T0; poll T0OUT until it ticks; KON voice 0; BRA $."""
    program = (bytes([0x8F, 0x4C, 0xF2]) + b"\x00" * nops + bytes([0x8F, 0x01, 0xFA, 0x8F, 0x01, 0xF1])
               + bytes([0xE4, 0xFD, 0xF0, 0xFC, 0x8F, 0x01, 0xF3, 0x2F, 0xFE]))
    return spc_image(KEY_ON_VOICE, program)


# ---------------------------------------------------------------- lanes

def gauss_lane():
    """fullsnes table from SDSP.swift: properties, then the interleaved form
    libgme stores (pairs gauss[255-j], gauss[511-j]) found in its binary."""
    body = re.search(r"gaussTable: \[Int16\] = \[(.*?)\]", SDSP_SOURCE.read_text(), re.S).group(1)
    g = [int(x, 16) for x in re.findall(r"0x([0-9A-F]+)", body)]
    assert len(g) == 512 and g == sorted(g), "table: 512 non-decreasing entries"
    sums = [g[255 - i] + g[511 - i] + g[256 + i] + g[i] for i in range(256)]
    assert min(sums) == 0x7FF and max(sums) == 0x801, (min(sums), max(sums))
    interleaved = b"".join(g[255 - j].to_bytes(2, "little") + g[511 - j].to_bytes(2, "little") for j in range(256))
    offset = LIBGME.read_bytes().find(interleaved)
    assert offset >= 0, "fullsnes Gaussian table not found in libgme"
    print(f"Gaussian table: 512 entries non-decreasing, tap sums $7FF-$801 "
          f"({sums.count(0x801)} x $801, {sums.count(0x7FF)} x $7FF); "
          f"present interleaved in libgme at byte {offset}")
    return {"offset": offset}


def probe_lane(lib, directory, seconds=3.0):
    frames = int(seconds * 32000)
    results = []
    for name, exact, dsp, skip in probes():
        spc = with_libgme_echo_fill(spc_image(dsp))
        ours, reference = spc_render(spc, seconds, directory), gme_render(lib, spc, frames)
        assert np.any(reference), f"{name}: libgme rendered silence"
        lag = best_lag(ours, reference)
        result = compare(ours, reference, lag, skip)
        result["name"] = name
        results.append(result)
        print(f"probe {name}: lag {lag}, {result['frames']} frames, equal {result['equal_fraction']}, "
              f"max diff {result['max_abs_diff']}, SNR {result['snr_db']} dB")
        if exact:
            # Our mixer saturates after each voice (fullsnes); libgme only
            # after MVOL. Any other difference fails.
            saturated = [{(0x7FFF * m) >> 7, (-0x8000 * m) >> 7} for m in ((dsp[r] ^ 0x80) - 0x80 for r in (0x0C, 0x1C))]
            start = max(skip, -lag)
            a = ours[2 * (start + lag):2 * (len(reference) // 2 + lag)]
            diff = np.flatnonzero(gme_gain(a) - reference[2 * start:2 * start + len(a)])
            result["saturated_differences"] = len(diff)
            assert lag == PROBE_LAG, result
            assert all(int(a[i]) in saturated[i % 2] for i in diff), result
            print(f"  bit-exact from frame {start}" + (f" except {len(diff)} samples, each where our voice sum "
                                                       f"saturated before MVOL" if len(diff) else ""))
        else:
            minimum, largest = (FEEDBACK_MIN_SNR, FEEDBACK_MAX_DIFF) if "feedback" in name \
                else (FAST_PATH_MIN_SNR, FAST_PATH_MAX_DIFF)
            assert lag == PROBE_LAG and result["snr_db"] >= minimum and result["max_abs_diff"] <= largest, result
    return results


def sweep_lane(lib, directory, name, image, nops):
    """Onset of a CPU-timed key-on, ours (lag-corrected) minus libgme's, with
    libgme's conventions (gated: all equal) and with our defaults (reported)."""
    shifts = {"libgme conventions": {}, "defaults": {}}
    for n in nops:
        spc = image(n)
        reference = onset(gme_render(lib, spc, 2048))
        for key, conventions in (("libgme conventions", True), ("defaults", False)):
            ours = onset(spc_render(spc, 0.064, directory, libgme_conventions=conventions))
            assert ours is not None and reference is not None, (name, n, ours, reference)
            shifts[key][n] = ours - PROBE_LAG - reference
    differing = {n: s for n, s in shifts["defaults"].items() if s}
    print(f"{name}: {len(nops)} delays, onsets equal with libgme conventions; with our defaults "
          + (f"{len(differing)} differ (delay: frames {differing})" if differing else "all equal"))
    assert not any(shifts["libgme conventions"].values()), shifts
    return shifts


def song_lane(lib, directory, songs, seconds, gated):
    frames = int(seconds * 32000)
    results = []
    for song in songs:
        spc = with_libgme_echo_fill(song_snapshot(song, directory))
        reference = gme_render(lib, spc, frames)
        mvol = [(spc[0x10100 + r] ^ 0x80) - 0x80 for r in (0x0C, 0x1C)]
        result = {"song": song, "surround_flip": mvol[0] * mvol[1] < -0x4000}
        for key, conventions in (("libgme conventions", True), ("defaults", False)):
            ours = spc_render(spc, seconds, directory, libgme_conventions=conventions)
            if not np.any(reference) and not np.any(ours):
                result[key] = "silent in both"
                continue
            result[key] = compare(ours, reference, best_lag(ours, reference))
        matched, default = result["libgme conventions"], result["defaults"]
        if isinstance(matched, str):
            print(f"song ${song:02X}: silent in both renders")
        else:
            print(f"song ${song:02X}: libgme conventions lag {matched['lag']}, SNR {matched['snr_db']} dB, "
                  f"max diff {matched['max_abs_diff']}, correlation {matched['correlation']}; "
                  f"our defaults SNR {default['snr_db']} dB, max diff {default['max_abs_diff']}")
            if gated:
                assert matched["lag"] == PROBE_LAG and matched["snr_db"] >= SONG_MIN_SNR \
                    and matched["max_abs_diff"] <= SONG_MAX_DIFF, result
        if gated:
            assert not result["surround_flip"], result
        results.append(result)
    return results


def solo_lane(lib, directory, song, seconds):
    """Per-voice comparison of one song's snapshot (evidence, not gated)."""
    spc = with_libgme_echo_fill(song_snapshot(song, directory))
    frames = int(seconds * 32000)
    for conventions in (True, False):
        for v in range(8):
            ours = spc_render(spc, seconds, directory, 1 << v, libgme_conventions=conventions)
            reference = gme_render(lib, spc, frames, 1 << v)
            if not np.any(reference) and not np.any(ours):
                continue
            r = compare(ours, reference, PROBE_LAG)
            print(f"song ${song:02X} voice {v} ({'libgme conventions' if conventions else 'defaults'}): "
                  f"SNR {r['snr_db']} dB, max diff {r['max_abs_diff']}, first diff frame {r['first_diff_frame']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--all-songs", action="store_true", help="report every ROM song (not gated)")
    parser.add_argument("--seconds", type=float, default=6.0, help="song render length")
    parser.add_argument("--solo", type=lambda s: int(s.lstrip("$"), 16), help="per-voice report for one song ($hex)")
    parser.add_argument("--json", type=Path, help="write all measurements here")
    options = parser.parse_args()
    lib = load_libgme()
    if lib is None:
        print(f"S-DSP vs libgme: UNVERIFIED (libgme not found at {LIBGME})")
        return UNVERIFIED
    print(f"libgme: {LIBGME} sha256 {hashlib.sha256(LIBGME.read_bytes()).hexdigest()}")
    status, measurements = 0, {}
    with tempfile.TemporaryDirectory(prefix="chronoforge-libgme-") as directory:
        measurements["gauss"] = gauss_lane()
        measurements["probes"] = probe_lane(lib, directory)
        measurements["key_on_sweep"] = sweep_lane(lib, directory, "key-on sweep", key_on_sweep_image, range(48))
        measurements["timer_sweep"] = sweep_lane(lib, directory, "timer-poll sweep", timer_sweep_image, range(72))
        if not ROM.exists() or hashlib.sha256(ROM.read_bytes()).hexdigest() != ROM_SHA256:
            print("CT songs vs libgme: UNVERIFIED (clean ROM missing)")
            status = UNVERIFIED
        else:
            measurements["songs"] = song_lane(lib, directory, SONGS, options.seconds, gated=True)
            if options.all_songs:
                count = ROM.read_bytes()[0x070AE9]
                measurements["all_songs"] = song_lane(lib, directory, range(count), options.seconds, gated=False)
            if options.solo is not None:
                solo_lane(lib, directory, options.solo, options.seconds)
    if options.json:
        options.json.write_text(json.dumps(measurements, indent=1, default=str))
    print("S-DSP vs libgme: " + ("PASS" if status == 0 else "UNVERIFIED"))
    return status


if __name__ == "__main__":
    sys.exit(main())
