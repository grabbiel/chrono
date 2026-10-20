#!/usr/bin/env python3
"""ct_audio.py — Chrono Trigger audio asset extractor (Phase 2.3).

Blob layout (verified against ROM): [u16 LE payload_len][BRR blocks...]
BRR block: [hdr: shift<<4 | filter<<2 | loop<<1 | end] + 8 bytes of 4-bit ADPCM.
Filters (hardware integer recursions):
  0: y = x
  1: y = x + y1 + (-y1 >> 4)
  2: y = x + (61*y1 >> 5) + (-15*y2 >> 4)
  3: y = x + (115*y1 >> 6) + (-13*y2 >> 4)
"""
from __future__ import annotations
import csv, json, os, re, struct, sys, wave
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WS = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(WS))
ROM = os.path.join(WS, "ct_clean.sfc")
DATA_CSV = os.path.join(WS, "refs", "ChronoRET", "symbols", "data_assets.csv")
SAMPLES_DIR = os.path.join(WS, "assets", "audio", "samples")
TRACKS_DIR = os.path.join(WS, "assets", "audio", "tracks")
SPC_DIR = os.path.join(WS, "assets", "audio", "spc")
MANIFEST = os.path.join(WS, "manifests", "audio_manifest.json")

SNES_RATE = 32000  # SPC700 timer base ~32 kHz output

FILTERS = {
    0: lambda x, y1, y2: x,
    1: lambda x, y1, y2: x + y1 + ((-y1) >> 4),
    2: lambda x, y1, y2: x + ((61 * y1) >> 5) + ((-15 * y2) >> 4),
    3: lambda x, y1, y2: x + ((115 * y1) >> 6) + ((-13 * y2) >> 4),
}


def pc(addr: str) -> int:
    m = re.match(r"\$([0-9A-F]{2}):([0-9A-F]{4})", addr)
    return ((int(m.group(1), 16) & 0x3F) << 16) | int(m.group(2), 16)


def load_rows():
    lines = [l for l in open(DATA_CSV) if not l.startswith("#")]
    return list(csv.DictReader(lines))


def brr_decode(blob: bytes, off: int, n_blocks: int):
    out = np.empty(n_blocks * 16, dtype=np.int16)
    y1 = y2 = 0
    loops = []
    for b in range(n_blocks):
        hdr = blob[off + 9 * b]
        shift, fltr = (hdr >> 4) & 0xF, (hdr >> 2) & 3
        if hdr & 2:
            loops.append(b)
        nibs = blob[off + 9 * b + 1: off + 9 * b + 9]
        for i in range(16):
            raw = (nibs[i >> 1] >> (4 if i % 2 == 0 else 0)) & 0xF
            n = raw - 16 if raw >= 8 else raw
            x = (n << shift) >> 1 if shift == 13 else (0 if shift == 14 else n << shift)
            y = max(-32768, min(32767, FILTERS[fltr](x, y1, y2)))
            out[b * 16 + i] = y
            y2, y1 = y1, y
    return out, loops


def validate_brr(blob: bytes, off: int, n_blocks: int) -> dict:
    bad = 0
    fltrs, shifts = {}, {}
    for b in range(n_blocks):
        h = blob[off + 9 * b]
        if (h >> 4) > 14 or ((h >> 2) & 3) > 3:
            bad += 1
        fltrs[(h >> 2) & 3] = fltrs.get((h >> 2) & 3, 0) + 1
        shifts[(h >> 4) & 0xF] = shifts.get((h >> 4) & 0xF, 0) + 1
    end_ok = bool(blob[off + 9 * (n_blocks - 1)] & 1) if n_blocks else False
    return {"blocks": n_blocks, "invalid_headers": bad, "end_bit_set": end_ok,
            "filters": fltrs, "shifts": shifts}


def brr_encode(samples: np.ndarray, loop_start: int | None = None, loop_end: int | None = None) -> bytes:
    """Encode int16 samples to BRR blocks with optimal per-block (shift, filter)
    selection: simulate the decoder for all 14x4 combos, keep min SSE.
    Loop/end flags set on the blocks containing loop_start / the last block."""
    n_blocks = (len(samples) + 15) // 16
    out = bytearray()
    y1 = y2 = 0
    for b in range(n_blocks):
        seg = samples[b * 16:(b + 1) * 16].astype(np.int32)
        if len(seg) < 16:
            seg = np.pad(seg, (0, 16 - len(seg)))
        best = None
        for shift in range(14):
            for fltr in range(4):
                # simulate decode of this block with candidate params
                sy1, sy2, sse = y1, y2, 0
                for i in range(16):
                    target = seg[i]
                    # quantize: invert filter prediction, round to 4-bit
                    pred = {0: 0,
                            1: sy1 + ((-sy1) >> 4),
                            2: ((61 * sy1) >> 5) + ((-15 * sy2) >> 4),
                            3: ((115 * sy1) >> 6) + ((-13 * sy2) >> 4)}[fltr]
                    div = 1 << shift if shift < 13 else (1 << 13) >> 1
                    q = int(round((target - pred) / div)) if div else 0
                    q = max(-8, min(7, q))
                    x = (q << shift) >> 1 if shift == 13 else (0 if shift == 14 else q << shift)
                    y = max(-32768, min(32767, FILTERS[fltr](x, sy1, sy2)))
                    sse += (int(y) - int(target)) ** 2
                    sy2, sy1 = sy1, y
                if best is None or sse < best[0]:
                    best = (sse, shift, fltr)
        _, shift, fltr = best
        # emit with the chosen params, advancing the real decoder state
        sy1, sy2 = y1, y2
        nib = bytearray(8)
        for i in range(16):
            target = int(seg[i])
            pred = {0: 0,
                    1: sy1 + ((-sy1) >> 4),
                    2: ((61 * sy1) >> 5) + ((-15 * sy2) >> 4),
                    3: ((115 * sy1) >> 6) + ((-13 * sy2) >> 4)}[fltr]
            div = 1 << shift if shift < 13 else (1 << 13) >> 1
            q = int(round((target - pred) / div)) if div else 0
            q = max(-8, min(7, q))
            nib[i >> 1] |= (q & 0xF) << (4 if i % 2 == 0 else 0)
            x = (q << shift) >> 1 if shift == 13 else (0 if shift == 14 else q << shift)
            y = max(-32768, min(32767, FILTERS[fltr](x, sy1, sy2)))
            sy2, sy1 = sy1, y
        y1, y2 = sy1, sy2
        hdr = (shift << 4) | (fltr << 2)
        if loop_start is not None and loop_start // 16 == b:
            hdr |= 2
        if b == n_blocks - 1:
            hdr |= 1
        out.append(hdr)
        out.extend(nib)
    return bytes(out)


def wav_write(path: str, samples: np.ndarray, rate: int = SNES_RATE):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(samples.tobytes())


def main() -> int:
    rom = open(ROM, "rb").read()
    rows = load_rows()
    os.makedirs(SAMPLES_DIR, exist_ok=True)
    os.makedirs(TRACKS_DIR, exist_ok=True)
    os.makedirs(SPC_DIR, exist_ok=True)
    report = {"samples": [], "sequences": [], "spc_program": [], "tables": [], "errors": []}

    # --- BRR sample blobs ---
    for r in rows:
        if not r["asset"].startswith("brr_sample/"):
            continue
        s, e = pc(r["start"]), pc(r["end"]) + 1
        blob = rom[s:e]
        payload_len = struct.unpack_from("<H", blob, 0)[0]
        ok_len = payload_len == len(blob) - 2 and payload_len % 9 == 0
        n = payload_len // 9 if ok_len else (len(blob) - 2) // 9
        info = validate_brr(blob, 2, n)
        samples, loops = brr_decode(blob, 2, n)
        label = r["label"]
        wav_path = os.path.join(SAMPLES_DIR, label + ".wav")
        wav_write(wav_path, samples)
        meta = {
            "label": label, "snes": f"{r['start']}-{r['end']}", "pc": hex(s),
            "payload_len_field": payload_len, "layout_ok": bool(ok_len),
            "decoded_blocks": n,
            "wav": os.path.relpath(wav_path, WS), "rate": SNES_RATE,
            "loop_blocks": loops, "peak": int(np.max(np.abs(samples))),
            "rms": round(float(np.sqrt(np.mean(samples.astype(np.float64) ** 2))), 1),
            **info,
        }
        report["samples"].append(meta)
        with open(os.path.join(SAMPLES_DIR, label + ".json"), "w") as f:
            json.dump(meta, f, indent=1)

    # --- music sequences ---
    for r in rows:
        if not r["asset"].startswith("music_sequence/"):
            continue
        s, e = pc(r["start"]), pc(r["end"]) + 1
        blob = rom[s:e]
        label = r["label"]
        out = os.path.join(TRACKS_DIR, label + ".bin")
        open(out, "wb").write(blob)
        report["sequences"].append({"label": label, "snes": f"{r['start']}-{r['end']}",
                                    "pc": hex(s), "size": len(blob),
                                    "file": os.path.relpath(out, WS)})

    # --- everything else audio (spc_data, tables, spc program region) ---
    for r in rows:
        a = r["asset"]
        if a.startswith(("spc_data/", "table/Audio", "unknown/")) and "Audio" in r["label"]:
            s, e = pc(r["start"]), pc(r["end"]) + 1
            blob = rom[s:e]
            out = os.path.join(SPC_DIR, r["label"] + ".bin")
            open(out, "wb").write(blob)
            report["tables"].append({"label": r["label"], "asset": a,
                                     "snes": f"{r['start']}-{r['end']}", "pc": hex(s),
                                     "size": len(blob), "file": os.path.relpath(out, WS)})

    # --- SPC700 program image + embedded strings ---
    # Driver program starts at $C7:24C3 per ChronoRET; find its declared extent
    # via the CSV rows that cover the $C7:24C3..$C7:40B3 range.
    prog_rows = [r for r in rows if pc(r["start"]) >= 0x724C3 and pc(r["end"]) < 0x740B4]
    for r in prog_rows:
        s, e = pc(r["start"]), pc(r["end"]) + 1
        blob = rom[s:e]
        out = os.path.join(SPC_DIR, r["label"] + ".bin")
        open(out, "wb").write(blob)
        report["spc_program"].append({"label": r["label"], "snes": f"{r['start']}-{r['end']}",
                                      "size": len(blob), "file": os.path.relpath(out, WS)})
    # If the program region isn't itemized in the CSV, dump it as one blob.
    if not prog_rows:
        blob = rom[0x724C3:0x740B4]
        out = os.path.join(SPC_DIR, "SpcProgram_C7_24C3.bin")
        open(out, "wb").write(blob)
        report["spc_program"].append({"label": "SpcProgram_C7_24C3",
                                      "snes": "$C7:24C3-$C7:40B3", "size": len(blob),
                                      "file": os.path.relpath(out, WS)})
    # embedded ASCII strings in the driver (identity evidence)
    strings = re.findall(rb"[ -~]{6,}", rom[0x724C3:0x740B4])
    report["driver_strings"] = [x.decode() for x in strings][:40]

    # --- song tables ---
    for lbl in ("AudioRom_SongSamples", "AudioRom_SongExtra", "AudioRom_SongEcho"):
        row = next((r for r in rows if r["label"] == lbl), None)
        if row:
            s, e = pc(row["start"]), pc(row["end"]) + 1
            report["tables"].append({"label": lbl, "snes": f"{row['start']}-{row['end']}",
                                     "pc": hex(s), "size": e - s})

    n_ok = sum(1 for m in report["samples"] if m["layout_ok"] and m["invalid_headers"] == 0 and m["end_bit_set"])
    n_layout = sum(1 for m in report["samples"] if m["layout_ok"])
    report["summary"] = {
        "brr_samples_decoded": len(report["samples"]),
        "brr_layout_ok": n_layout,
        "brr_fully_valid": n_ok,
        "music_sequences_dumped": len(report["sequences"]),
        "spc_program_blobs": len(report["spc_program"]),
        "tables": len(report["tables"]),
    }
    with open(MANIFEST, "w") as f:
        json.dump(report, f, indent=1)
    print(json.dumps(report["summary"], indent=1))
    print("driver strings:", report["driver_strings"][:6])
    # gate: every blob decoded to WAV, and every layout-ok blob fully valid BRR
    all_decoded = len(report["samples"]) > 0 and all("wav" in m for m in report["samples"])
    return 0 if all_decoded and n_ok == n_layout else 1


if __name__ == "__main__":
    sys.exit(main())
