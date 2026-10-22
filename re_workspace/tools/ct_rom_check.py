#!/usr/bin/env python3
"""Check a ROM written by `chronoforge rom build` against the clean ROM.

Independent of the Swift builder: packs are unpacked with ChronoRET's
transcription of Decomp_ToWram (tools/c3pack.py), decoded with the derived
opcode table, message pointers are resolved by running the ROM's own
TextWin_Init ($C2:57DF) through ChronoRET's abstract interpreter, and the
strings are re-encoded with ChronoRET's text encoder (tools/text.py; MIT).

    ct_rom_check.py <built.sfc> <report.json> [--lowered lowered.json --entry N]

Checks: header checksum and complement; every changed byte is inside a
report write, and every write inside a confirmed free region, the span of a
stream no unchanged entry still uses, a rebuilt entry's pointer, or the
checksum; the new streams and tables lie in such places and do not overlap;
untouched entries unpack exactly as before; each new pack unpacks to the
reported hash within LocLoad_CheckEvtData's limits and decodes; its $B8
operands point at its message table; TextWin_Init finds every message, and
the bytes there are the reported text encoded by the reference encoder.
Songs (tools/ct_spc_seq.py, from the driver's tables): only rebuilt songs'
Audio_SongTable entries change; their old spans are writable when no other
song uses them; each new song is the reported data, walks cleanly and loads
below $4700; untouched songs are as before; the per-song table rows a song
sets (sample list, echo word, drum kit) hold the reported values, which are in
range, and no other row changes. Characters (tools/ct_characters.py): only
the decoded fields of reported records and their growth rows may change; each
record decodes to the reported values, which are in the ranges the game's
code keeps, with equipment of the slot's category that the character can
equip in the clean ROM; the undecoded bytes of every record, the other
characters' records and rows, and ExpToLevel are unchanged.
"""

import argparse
import json
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
sys.path.insert(0, str(WS / "refs" / "ChronoRET" / "tools"))
import c3pack  # noqa: E402
import ct_characters as cc  # noqa: E402
import ct_event_packs as packs  # noqa: E402
import ct_rom_layout as layout  # noqa: E402
import ct_spc_seq as spc  # noqa: E402
import ct_text_profile  # noqa: E402

TEXTWIN_INIT = 0xC257DF
TEXTWIN_DP, STR_INDEX, STR_TABLE, MODE, TEXT_PTR = 0x7E0200, 0x0C, 0x0D, 0x14, 0x31
checks = 0


def check(condition, message):
    global checks
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    checks += 1


def stream(rom, pc):
    data, end, mode = c3pack.unpack(rom, pc)
    return data, range(pc, end), mode


def textwin_pointer(interp, absint, table, index):
    """TextWin_Init run on the built ROM with the field's inputs: the 24-bit
    TextWin_TextPtr it leaves for string `index` of the table at `table`."""
    s = absint.State()
    s.pc, s.a, s.b, s.x, s.y = TEXTWIN_INIT, 0, 0, 0, 0
    s.d, s.db, s.m, s.xf, s.c = 0x0100, 0x00, True, False, False
    s.z = s.n = s.v = None
    s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
    s.at = s.xt = s.yt = s.ft = absint.E
    s.depth = 0
    known = {TEXTWIN_DP + STR_INDEX: index, TEXTWIN_DP + MODE: 0,
             TEXTWIN_DP + STR_TABLE: table & 0xFF, TEXTWIN_DP + STR_TABLE + 1: table >> 8 & 0xFF,
             TEXTWIN_DP + STR_TABLE + 2: table >> 16}
    ends = [st for st, how in interp.machine.run(s, known) if how == "rtl"]
    check(len(ends) == 1, f"TextWin_Init did not return once for string {index}")
    pointer = [ends[0].mem.get(TEXTWIN_DP + TEXT_PTR + k) for k in range(3)]
    check(None not in pointer, f"TextWin_Init left TextWin_TextPtr unknown for string {index}")
    return pointer[0] | pointer[1] << 8 | pointer[2] << 16


def song_tables_of(report_song):
    """The table rows a report song sets, in ct_spc_seq's form."""
    tables = {}
    if report_song.get("samples") is not None:
        tables["samples"] = report_song["samples"]
    for key in ("echo", "drums"):
        if report_song.get(key) is not None:
            tables[key] = bytes(report_song[key])
    return tables


def character_zones(report):
    """The spans the builder may write for each reported character."""
    spans = []
    for c in report.get("characters") or []:
        base = cc.RECORDS_PC + cc.RECORD_SIZE * c["charId"]
        for name in cc.WRITABLE:
            offset, size = cc.field(name)
            spans.append(range(base + offset, base + offset + size))
        if c.get("growth") is not None:
            for at, row in ((cc.HP_GROWTH_PC, cc.GROWTH_ROW), (cc.MP_GROWTH_PC, cc.GROWTH_ROW),
                            (cc.STAT_GROWTH_PC, cc.STAT_GROWTH_ROW)):
                spans.append(range(at + row * c["charId"], at + row * (c["charId"] + 1)))
    return spans


STAT_KEYS = ("power", "stamina", "speed", "magic", "hit", "evade", "magicDefense")   # the report's names


def report_value(c):
    """A report character's record in ct_characters.decode_record form."""
    r = c["record"]
    return {"char_id": r["charId"], "hp": r["hp"], "max_hp": r["maxHp"], "mp": r["mp"], "max_mp": r["maxMp"],
            "level": r["level"], "exp": r["exp"], "exp_to_next": r["expToNext"], "tech_points": r["techPoints"],
            "tech_points_to_next": r["techPointsToNext"],
            "stats": {s: r["stats"][k] for s, k in zip(cc.STATS, STAT_KEYS)},
            "growth_base": {s: r["growthBase"][k] for s, k in zip(cc.STATS, STAT_KEYS)},
            "equipment": {slot: r["equipment"][slot] for slot in ("helmet", "armor", "weapon", "accessory")}}


def report_growth(g):
    return {"hp": [[s["toLevel"], s["gain"]] for s in g["hp"]], "mp": [[s["toLevel"], s["gain"]] for s in g["mp"]],
            "stats": {s: g["stats"][k] for s, k in zip(cc.STATS, STAT_KEYS)}}


def check_characters(clean, built, report):
    reported = report.get("characters") or []
    ids = [c["charId"] for c in reported]
    check(all(0 <= i < cc.CHARACTERS for i in ids) and len(set(ids)) == len(ids), f"character records {ids}")
    writable = {b for name in cc.WRITABLE for o, n in [cc.field(name)] for b in range(o, o + n)}
    bounds = clean[cc.ITEM_BOUNDS_PC:cc.ITEM_BOUNDS_PC + 6]
    by_id = {c["charId"]: c for c in reported}
    for i in range(cc.INIT_RECORDS):
        before, after = cc.record(clean, i), cc.record(built, i)
        if i not in by_id:
            check(before == after, f"record {i} changed but is not reported")
            continue
        c = by_id[i]
        check(all(before[b] == after[b] for b in range(cc.RECORD_SIZE) if b not in writable),
              f"character {c['id']}: an undecoded byte changed")
        v = cc.decode_record(after)
        check(v == report_value(c), f"character {c['id']}: the record is not the reported values")
        check(1 <= v["level"] <= cc.LEVEL_MAX and v["exp"] <= cc.EXP_CAP_HI << 16 | cc.EXP_CAP_LO,
              f"character {c['id']}: level or exp")
        check(v["hp"] <= v["max_hp"] <= cc.MAX_HP_CAP and v["mp"] <= v["max_mp"] <= cc.MAX_MP_CAP,
              f"character {c['id']}: HP or MP")
        check(all(x <= cc.STAT_CAP for x in list(v["stats"].values()) + list(v["growth_base"].values())),
              f"character {c['id']}: a stat or growth base above 99")
        for slot, item in v["equipment"].items():
            check(cc.item_category(item, bounds) == cc.SLOTS.index(slot) and cc.equip_mask(clean, item) & 0x80 >> i,
                  f"character {c['id']}: {slot} ${item:02X}")
    for i in range(cc.CHARACTERS):
        c = by_id.get(i)
        g = cc.decode_growth(built, i)
        if c is None or c.get("growth") is None:
            check(g == cc.decode_growth(clean, i), f"growth rows of record {i} changed but are not reported")
        else:
            check(g == report_growth(c["growth"]), f"character {c['id']}: growth rows are not the reported ones")
            check(all(any(t >= cc.LEVEL_MAX for t, _ in g[k]) for k in ("hp", "mp")),
                  f"character {c['id']}: a growth row does not reach level 99")
    check(cc.exp_to_level(built) == cc.exp_to_level(clean), "ExpToLevel changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("built")
    parser.add_argument("report")
    parser.add_argument("--lowered", help="ct-event-lowered/1 output of `event lower` for --entry")
    parser.add_argument("--entry", type=int)
    args = parser.parse_args()

    clean = packs.read_rom()
    built = Path(args.built).read_bytes()
    report = json.loads(Path(args.report).read_text())
    rom_layout = json.loads(layout.MANIFEST.read_text())
    check(report["schema"] == "ct-rom-build/1" and len(built) == len(clean), "report schema or ROM size")
    check(packs.sha(built) == report["outputSHA256"], "output hash differs from the report")
    check(report["baseSHA256"] == packs.ROM_SHA256, "base is not the clean ROM")

    # Header.
    total = layout.checksum(built)
    stored = built[layout.CHECKSUM_PC] | built[layout.CHECKSUM_PC + 1] << 8
    complement = built[layout.COMPLEMENT_PC] | built[layout.COMPLEMENT_PC + 1] << 8
    check(total == stored == report["checksum"] and stored ^ complement == 0xFFFF, "header checksum")

    # Where the builder may write.
    entries_before, entries_after = packs.pointer_entries(clean), packs.pointer_entries(built)
    rebuilt = {p["entry"] for p in report["packs"]}
    changed_entries = {i for i in range(len(entries_before)) if entries_before[i] != entries_after[i]}
    check(changed_entries <= rebuilt, f"entries changed that the report does not build: {changed_entries - rebuilt}")
    not_packs = {d["entry"] for d in rom_layout["eventPacks"]["notPacks"]}
    check(not rebuilt & not_packs, "a rebuilt entry did not point at an event pack")
    still_used = {packs.to_pc(entries_before[i]) for i in range(len(entries_before)) if i not in rebuilt}
    zones = []
    for region in rom_layout["freeRegions"]:
        check(all(b == region["fill"] for b in clean[region["pc"]:region["pc"] + region["size"]]),
              f"free region {region['start']} is not fill in the clean ROM")
        zones.append(range(region["pc"], region["pc"] + region["size"]))
    for entry in rebuilt:
        old = packs.to_pc(entries_before[entry])
        if old not in still_used:
            zones.append(stream(clean, old)[1])
        zones.append(range(packs.PTRS_PC + 3 * entry, packs.PTRS_PC + 3 * entry + 3))
    zones.append(range(layout.COMPLEMENT_PC, layout.COMPLEMENT_PC + 4))
    songs_before, songs_after = spc.songs(clean), spc.songs(built)
    rebuilt_songs = {s["song"] for s in report.get("songs", [])}
    check(len(songs_before) == len(songs_after), "song count changed")
    changed_songs = {s[0] for s, t in zip(songs_before, songs_after) if s[1] != t[1]}
    check(changed_songs <= rebuilt_songs, f"song pointers changed that the report does not build: {changed_songs - rebuilt_songs}")
    songs_used = {s[2] for s in songs_before if s[0] not in rebuilt_songs}
    for i in rebuilt_songs:
        check(0 <= i < len(songs_before), f"song {i} is not in Audio_SongTable")
        _, _, old, data = songs_before[i]
        if old not in songs_used:
            zones.append(range(old, old + 2 + len(data)))
        zones.append(range(spc.SONG_TABLE_PC + 3 * i, spc.SONG_TABLE_PC + 3 * i + 3))
    for s in report.get("songs", []):
        for pc, row, _ in spc.table_rows(song_tables_of(s)):
            zones.append(range(pc + row * s["song"], pc + row * (s["song"] + 1)))
    zones += character_zones(report)

    def inside(r):
        return any(r.start >= z.start and r.stop <= z.stop for z in zones)

    writes = [range(w["pc"], w["pc"] + w["length"]) for w in report["writes"]]
    for w in writes:
        check(inside(w), f"write at ${w.start:06X} (+{len(w)}) is outside free space")
    written = set().union(*writes) if writes else set()
    differing = {i for i in range(len(clean)) if clean[i] != built[i]}
    check(differing <= written, f"{len(differing - written)} changed bytes are not in a report write")

    # Untouched entries unpack as before.
    for i in range(len(entries_before)):
        if i in rebuilt or i in not_packs:
            continue
        check(stream(built, packs.to_pc(entries_after[i]))[0] == stream(clean, packs.to_pc(entries_before[i]))[0],
              f"entry {i} no longer unpacks as before")

    # Songs: untouched ones as before, new ones as reported.
    counts, _ = spc.driver_tables(built)
    new_spans = {}
    for (i, _, _, before), (_, pointer, pc, after) in zip(songs_before, songs_after):
        if i not in rebuilt_songs:
            check(after == before, f"song {i} changed")
    for s in report.get("songs", []):
        _, pointer, pc, data = songs_after[s["song"]]
        check(pc == s["pc"] and pointer >> 22 == 3, f"song {s['song']} points at ${pc:06X}, the report says ${s['pc']:06X}")
        check(len(data) == s["bytes"] and packs.sha(data) == s["dataSHA256"], f"song {s['song']}: data")
        check(spc.fits(len(data)), f"song {s['song']}: its transfer reaches $4700")
        try:
            spc.Song(data, counts).walk()
        except ValueError as e:
            check(False, f"song {s['song']}: {e}")
        check(inside(range(pc, pc + 2 + len(data))), f"song {s['song']}: outside free space")
        tables = song_tables_of(s)
        samples = tables.get("samples", [])
        check(len(samples) <= 16 and all(1 <= x <= spc.SAMPLE_MAX for x in samples), f"song {s['song']}: sample list")
        check(len(tables.get("echo", b"..")) == 2 and len(tables.get("drums", bytes(36))) == 36, f"song {s['song']}: table sizes")
        for at, row, want in spc.table_rows(tables):
            got = built[at + row * s["song"]:at + row * (s["song"] + 1)]
            check(got == want, f"song {s['song']}: table row at ${at + row * s['song']:06X}")
        new_spans[pc] = range(pc, pc + 2 + len(data))

    check_characters(clean, built, report)

    # New packs and tables.
    table_doc = json.loads(packs.TABLE.read_text())["opcodes"]
    tables = {t["pc"]: t for t in report["messageTables"]}
    for p in report["packs"]:
        pc = packs.to_pc(entries_after[p["entry"]])
        check(pc == p["pc"], f"entry {p['entry']} points at ${pc:06X}, the report says ${p['pc']:06X}")
        data, span, mode = stream(built, pc)
        check(span.start >> 16 == (span.stop - 1) >> 16, f"entry {p['entry']}: pack crosses a bank")
        check(inside(span), f"entry {p['entry']}: pack outside free space")
        check(len(span) == p["packedBytes"] and packs.sha(data) == p["unpackedSHA256"], f"entry {p['entry']}: unpacked bytes")
        check(1 <= len(data) <= layout.EVT_DATA_MAX and data[:2] != b"\x0d\x0a", f"entry {p['entry']}: LocLoad_CheckEvtData")
        ops, _, _ = packs.decode(table_doc, data)
        new_spans[span.start] = span
        b8 = [int.from_bytes(data[1 + y + 1:1 + y + 4], "little") for y, o in ops.items() if o[0] == 0xB8]
        if p.get("messageTable"):
            table = tables[layout.pc(p["messageTable"])]
            check(b8 and all(packs.to_pc(a) == table["pc"] for a in b8), f"entry {p['entry']}: $B8 operands")
            used = [data[1 + y + 1] for y, o in ops.items() if o[0] in (0xBB, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4)]
            check(all(i < len(table["messages"]) for i in used), f"entry {p['entry']}: message index past the table")
        if args.lowered and p["entry"] == args.entry:
            lowered = json.loads(Path(args.lowered).read_text())
            expect = bytearray(lowered["bytes"])
            for r in lowered["relocations"]:
                at = table["pc"]
                expect[r["offset"]:r["offset"] + 3] = bytes([at & 0xFF, at >> 8 & 0xFF, 0xC0 | at >> 16])
            check(bytes(expect) == data, f"entry {p['entry']}: not the CLI's lowered pack with its table relocated")

    interp, _ = packs.interpreter(built)
    import absint  # noqa: E402  (on sys.path once interpreter() has run)
    codec = ct_text_profile.reference_codec()
    dictionary = codec.rom_dictionary(clean)
    for table in report["messageTables"]:
        pc = table["pc"]
        last = pc + 2 * len(table["messages"])
        for index, message in enumerate(table["messages"]):
            pointer = textwin_pointer(interp, absint, 0xC00000 | pc, index)
            string = packs.to_pc(pointer)
            check(string >> 16 == pc >> 16 and string == layout.pc(message["address"]), f"message {message['id']} pointer")
            expect = codec.encode_msg(message["text"].replace("\n", "{line}"), dictionary, message["id"])
            if not expect.endswith(b"\x00"):
                expect += b"\x00"
            check(built[string:string + len(expect)] == expect, f"message {message['id']}: bytes are not the encoded text")
            last = max(last, string + len(expect))
        span = range(pc, last)
        check(inside(span), f"message table at ${pc:06X} outside free space")
        new_spans[pc] = span
    ordered = sorted(new_spans.values(), key=lambda r: r.start)
    for a, b in zip(ordered, ordered[1:]):
        check(a.stop <= b.start, f"${a.start:06X} and ${b.start:06X} overlap")
    print(f"ROM build: {checks} checks passed ({len(report['packs'])} packs, {len(report['messageTables'])} message tables, "
          f"{len(report.get('songs', []))} songs, {len(report.get('characters') or [])} characters)")


if __name__ == "__main__":
    main()
