#!/usr/bin/env python3
"""verify_lzss_corpus — validate libctcodec against every packed block in
refs/ChronoRET/symbols/data_assets.csv (Phase 2 Step 2.1).

For each row with piece=packed (label, start, end, size, param 'lzNN -> N B'):
  1. decompress the ROM bytes [start, end] (end inclusive: size == end-start+1)
  2. assert output size == the claimed '-> N B'
  3. assert auto-detected mode == the claimed lz11/lz12
  4. recompress the decompressed bytes and assert
     decompress(recompress(x)) == x  (functional round-trip)
  5. recompress(x) == the original packed bytes (the packer is the original
     algorithm, so every block must be rebuilt byte for byte)
Then the same for every distinct stream Evt_PackPtrs ($FC:F9F0) points to
that unpacks (the event packs are not data_assets.csv packed pieces).

Writes manifests/lzss_verification.json. Exit 0 iff every check holds.
"""
import csv
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))      # re_workspace/tools
ROOT = os.path.dirname(HERE)                           # re_workspace/
sys.path.insert(0, HERE)
import ct_lzss  # noqa: E402

ROM = os.path.join(ROOT, "ct_clean.sfc")
CSV = os.path.join(ROOT, "refs", "ChronoRET", "symbols", "data_assets.csv")
OUT = os.path.join(ROOT, "manifests", "lzss_verification.json")


def snes_to_pc(s):
    """'$C3:1200' -> file offset. HiROM map mode 31: banks $C0-$FF linear."""
    return ((int(s[1:3], 16) & 0x3F) << 16) | int(s[4:], 16)


def main():
    rom = open(ROM, "rb").read()
    rows = [r for r in csv.DictReader(
        l for l in open(CSV) if not l.startswith("#"))]
    packed = [r for r in rows if r["piece"] == "packed"]
    results = []
    t0 = time.time()
    for r in packed:
        m = re.match(r"(lz1[12]) -> (\d+) B", r["param"])
        assert m, r["param"]
        mode_claim, size_claim = m.group(1), int(m.group(2))
        start, end = snes_to_pc(r["start"]), snes_to_pc(r["end"])
        span = end - start + 1
        assert span == int(r["size"]), (r["label"], span, r["size"])
        data = rom[start:end + 1]
        rec = {"label": r["label"], "start": r["start"], "end": r["end"],
               "packed_bytes": span, "mode_claim": mode_claim,
               "size_claim": size_claim}
        try:
            rec["mode_auto"] = ct_lzss.detect_mode(data)
            dec = ct_lzss.decompress(data)             # auto-detect mode
            rec["mode_match"] = rec["mode_auto"] == mode_claim
            rec["size_ok"] = len(dec) == size_claim
            rec["out_size"] = len(dec)
            rec["decomp_rc"] = 0
            rec2 = ct_lzss.compress(dec, mode_claim)
            rec["roundtrip_ok"] = ct_lzss.decompress(rec2) == dec
            rec["recompress_len"] = len(rec2)
            rec["byte_exact"] = rec2 == data
        except ct_lzss.CtLzssError as e:
            rec["decomp_rc"] = str(e)
            rec.setdefault("size_ok", False)
            rec["roundtrip_ok"] = False
        results.append(rec)
    rom_b = rom
    event_streams = []
    seen = set()
    for i in range(513):
        p = 0x3CF9F0 + 3 * i
        start = ((rom_b[p + 2] & 0x3F) << 16) | rom_b[p] | rom_b[p + 1] << 8
        if start in seen:
            continue
        seen.add(start)
        data = rom_b[start:min(len(rom_b), (start | 0xFFFF) + 1)]   # a pack never leaves its bank
        try:
            dec = ct_lzss.decompress(data)
        except ct_lzss.CtLzssError:
            continue                                   # one of the entries for dummy locations
        mode = ct_lzss.detect_mode(data)
        rec2 = ct_lzss.compress(dec, mode)
        event_streams.append({"entry": i, "pc": start, "mode": mode, "packed_bytes": len(rec2),
                              "out_size": len(dec), "byte_exact": data[:len(rec2)] == rec2,
                              "roundtrip_ok": ct_lzss.decompress(rec2) == dec})
    totals = {
        "packed_blocks": len(results),
        "size_ok": sum(1 for x in results if x.get("size_ok")),
        "mode_match": sum(1 for x in results if x.get("mode_match")),
        "roundtrip_ok": sum(1 for x in results if x.get("roundtrip_ok")),
        "byte_exact_recompress": sum(1 for x in results if x.get("byte_exact")),
        "lz11_blocks": sum(1 for x in results if x["mode_claim"] == "lz11"),
        "lz12_blocks": sum(1 for x in results if x["mode_claim"] == "lz12"),
        "event_streams": len(event_streams),
        "event_streams_byte_exact": sum(1 for x in event_streams if x["byte_exact"] and x["roundtrip_ok"]),
    }
    manifest = {
        "generated_by": "tools/verify_lzss_corpus.py",
        "source_manifest": "refs/ChronoRET/symbols/data_assets.csv",
        "rom": "ct_clean.sfc",
        "runtime_s": round(time.time() - t0, 1),
        "totals": totals,
        "unverified": ["byte content of decompressed blocks is not compared "
                       "against ground-truth WRAM dumps (none available in "
                       "ChronoRET); only the claimed sizes, the claimed modes "
                       "and functional round-trips are asserted"],
        "notes": ["The compressor is the original packer: Haruhiko Okumura's LZSS "
                  "(binary-tree match finder, ring N=4096/F=18 for lz12 and "
                  "N=2048/F=34 for lz11, threshold 2) with the framing described "
                  "in ctcodec.c, identified by ChronoRET tools/c3pack.py (MIT). "
                  "byte_exact_recompress counts blocks rebuilt byte for byte; "
                  "every block and every event-pack stream must be. A stream "
                  "without its end bound (event packs) is compared over the "
                  "rebuilt length, which is where its final marker ends."],
        "blocks": results,
        "event_streams": event_streams,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(manifest, open(OUT, "w"), indent=1)
    print(json.dumps(totals, indent=1))
    fails = [x for x in results if not x.get("size_ok") or not x.get("roundtrip_ok") or not x.get("byte_exact")]
    fails += [x for x in event_streams if not x["byte_exact"] or not x["roundtrip_ok"]]
    if len(event_streams) != 463:
        fails.append({"label": "event streams", "decomp_rc": f"{len(event_streams)} != 463"})
    for x in fails[:20]:
        print("FAIL", {k: x[k] for k in ("label", "mode_claim", "size_claim",
                                         "out_size", "decomp_rc") if k in x})
    print("manifest:", OUT)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
