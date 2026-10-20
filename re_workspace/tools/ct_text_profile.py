#!/usr/bin/env python3
"""Generate local TextWin assets and a reproducible ROM-bound evidence manifest.

Reads the user's clean ROM and the matched ChronoRET text implementation. The
generated profile/corpus contain game data and are ignored local assets; only
the generator, tests and metadata-only verification manifest should be shared.
No malformed message, truncated operand or failed round trip is silently skipped.
"""

import argparse
import csv
import hashlib
import importlib.util
import itertools
import json
import re
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parents[1]
REFERENCE = WORKSPACE / "refs" / "ChronoRET"
ROM_SHA256 = "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9"
ASSETS = WORKSPACE / "assets" / "text"
MANIFEST = WORKSPACE / "manifests" / "text_codec_verification.json"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def reference_codec():
    path = REFERENCE / "tools" / "text.py"
    spec = importlib.util.spec_from_file_location("chronoret_text_reference", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pc(address):
    return int(address.replace("$", "").replace(":", ""), 16) - 0xC00000


def read_rom(path=WORKSPACE / "ct_clean.sfc"):
    data = Path(path).read_bytes()
    if len(data) != 0x400000 or digest(data) != ROM_SHA256:
        raise ValueError("Expected the pinned 4 MiB unheadered Chrono Trigger US ROM")
    return data


def control_evidence(rom, codec):
    """Compare every ROM dispatch pointer against the matched assembly header."""
    source = codec.BANK_C2.read_text()
    headers = dict((name, int(address, 16)) for address, name in re.findall(
        r"^; \$C2:([0-9A-F]{4}) — (TextWin_\w+)", source, re.M))
    for name, address in re.findall(
        r"sub-entry (TextWin_\w+) at \$C2:([0-9A-F]{4})", source):
        headers[name] = int(address, 16)
    base = 0x20000 + headers["TextWin_CodeTable"]
    records = []
    for code, handler in enumerate(codec.code_table()):
        offset = base + code * 2
        actual = int.from_bytes(rom[offset:offset + 2], "little")
        expected = headers[handler]
        if actual != expected:
            raise ValueError(f"Control {code:02X}: ROM pointer disagrees with {handler}")
        records.append({"code": code, "handler": handler, "operandBytes": codec.OPERANDS[code],
                        "pointerPC": offset, "targetSNES": 0xC20000 + actual})
    return {"pc": base, "byteCount": 66, "sha256": digest(rom[base:base + 66]),
            "matchedPointers": len(records), "entries": records}


def build(rom):
    if len(rom) != 0x400000 or digest(rom) != ROM_SHA256:
        raise ValueError("ROM identity mismatch")
    codec = reference_codec()
    dictionary = codec.rom_dictionary(rom)
    if len(dictionary.entries) != 128:
        raise ValueError("Expected 128 dictionary entries")
    dictionary_evidence = []
    for index, entry in enumerate(dictionary.entries):
        offset = 0x1EFA00 + index * 2
        target = 0x1E0000 | int.from_bytes(rom[offset:offset + 2], "little")
        if not 0x1EFB00 <= target < 0x1EFD01 or target + 1 + len(entry) > 0x1EFD01:
            raise ValueError(f"Dictionary {index}: outside surveyed dictionary extent")
        if rom[target] != len(entry) or not entry or min(entry) < codec.FIRST_GLYPH:
            raise ValueError(f"Dictionary {index}: invalid length-prefixed glyph entry")
        dictionary_evidence.append({"index": index, "pointerPC": offset, "entryPC": target,
                                    "glyphCount": len(entry), "sha256": digest(entry)})

    survey_path = REFERENCE / "symbols" / "data_survey.csv"
    with survey_path.open() as file:
        rows = {row["start"]: row for row in csv.DictReader(
            line for line in file if not line.startswith("#"))}
    cases, tables = [], []
    pointer_cases = 0
    stats = {}
    for address in codec.MESSAGE_TABLES:
        row = rows[address]
        start, stop = pc(row["start"]), pc(row["end"]) + 1
        count = codec._table_count(rom, start, stop)
        if count * 2 != codec._word(rom, start) - (start & 0xFFFF):
            raise ValueError(f"{address}: incomplete pointer table")
        local_stats = {}
        targets = []
        covered = set()
        for index in range(count):
            target = (start & 0xFF0000) | codec._word(rom, start + index * 2)
            if not start + count * 2 <= target < stop:
                raise ValueError(f"{address}:{index}: pointer outside text region")
            end = codec._string_end(rom, target, stop)
            data = rom[target:end]
            tokens = codec._tokens(data)
            if not tokens or tokens[-1] != ("c", 0, None) or any(t[0] == "raw" for t in tokens):
                raise ValueError(f"{address}:{index}: missing terminator or truncated control")
            text = codec.decode_msg(data, dictionary, local_stats).replace("\n", "")
            label = f"Messages_{address[1:3]}{address[4:]}:{index}"
            if codec.encode_msg(text, dictionary, label) != data:
                raise ValueError(f"{label}: reference round trip is not byte exact")
            cases.append({"label": label, "bytes": list(data), "text": text})
            pointer_cases += 1
            targets.append(target)
            covered.update(range(target, end))
        unreferenced = []
        missing = sorted(set(range(start + count * 2, stop)) - covered)
        for _, group in itertools.groupby(enumerate(missing), lambda item: item[1] - item[0]):
            offsets = [value for _, value in group]
            first, last = offsets[0], offsets[-1] + 1
            data = rom[first:last]
            label = f"Messages_{address[1:3]}{address[4:]}:unreferenced:{first:06X}"
            text = codec.decode_msg(data, dictionary, local_stats).replace("\n", "")
            if codec.encode_msg(text, dictionary, label) != data:
                raise ValueError(f"{label}: reference round trip is not byte exact")
            cases.append({"label": label, "bytes": list(data), "text": text})
            unreferenced.append({"pc": first, "byteCount": len(data), "sha256": digest(data)})
        tables.append({"address": address, "pc": start, "stopPC": stop,
                       "pointerCount": count, "uniqueTargets": len(set(targets)),
                       "sha256": digest(rom[start:stop]), "stats": local_stats,
                       "unreferencedSpans": unreferenced})
        for key, value in local_stats.items():
            stats[key] = stats.get(key, 0) + value
    if len(tables) != 15 or pointer_cases != 4579:
        raise ValueError("Pinned ROM corpus must contain all 15 tables / 4,579 pointers")
    profile = {"schema": "ct-text-us/1", "romSHA256": ROM_SHA256,
               "dictionary": [list(entry) for entry in dictionary.entries]}
    corpus = {"cases": cases}
    paths = [REFERENCE / "tools" / "text.py", codec.BANK_C2,
             codec.CONSTANTS, survey_path]
    evidence = {
        "schema": "ct-text-verification/1", "romSHA256": ROM_SHA256,
        "sources": [{"path": str(p.relative_to(WORKSPACE)), "sha256": digest(p.read_bytes())}
                    for p in paths],
        "controlTable": control_evidence(rom, codec),
        "dictionary": {"pointerPC": 0x1EFA00, "entryCount": 128,
                       "directEntries": 127, "extendedEntry127Bytes": [18, 104],
                       "greedySkippedIndices": sorted(codec.GREEDY_SKIP),
                       "entries": dictionary_evidence},
        "messageTables": tables, "corpusCases": len(cases), "pointerCases": pointer_cases, "stats": stats,
        "normalization": "Reference decode formatting newlines removed; explicit control tags preserved.",
        "coverage": "All 4,579 pointer entries in the 15 event-message tables, plus unreferenced table-body spans; duplicates retained.",
        "malformedOrOmittedCases": 0,
        "limitations": ["Static ROM and matched-source evidence, not runtime rendering verification.",
                        "Message corpus excludes stale text, menus, names, credits and battle-only tables.",
                        "Glyph readable spelling follows the matched reference font interpretation."],
    }
    return profile, corpus, evidence


def serialize(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", type=Path, default=WORKSPACE / "ct_clean.sfc")
    parser.add_argument("--check", action="store_true", help="Compare existing assets without writing")
    args = parser.parse_args()
    profile, corpus, evidence = build(read_rom(args.rom))
    outputs = [(ASSETS / "text_profile.json", profile), (ASSETS / "message_corpus.json", corpus),
               (MANIFEST, evidence)]
    for path, value in outputs:
        encoded = serialize(value)
        if args.check:
            if not path.is_file() or path.read_text() != encoded:
                raise ValueError(f"Missing or stale generated output: {path}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(encoded)
    print(f"Verified {len(corpus['cases']):,} corpus cases (4,579 message pointers), 15 tables, 128 dictionary entries, 33 control pointers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
