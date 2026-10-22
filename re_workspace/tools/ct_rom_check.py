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
characters' records and rows, and ExpToLevel are unchanged. Techs
(tools/ct_techs.py), when reported: only the writable fields of the tech
tables, the combination requirements, the new-game tech state and bit 4 of
each record's +$02 may change; each decodes to the reported values, in the
ranges the game's jump tables and tables allow; the read-only bits (user
sets, flags, attributes, the animation's graphics), the combination records
and every other table are unchanged; bit 4 of +$02 is set exactly for the
characters with all 8 singles. Without techs, none of those bytes change.
Items (tools/ct_items.py), when reported: only record A and B, name bytes
1-10, the target modes, ItemBoosts and the description table may change;
each reported item decodes to the reported values, in the ranges the game's
code keeps, with its icon byte unchanged; unreported items are unchanged;
ItemBoosts is the reported table (or unchanged); every description pointer
lands in the table's span on a $00-terminated string, which is the clean
ROM's bytes for an unchanged text and the reference encoder's bytes for a
new one. Without items, none of those bytes change.
Maps (tools/ct_maps.py), when reported: the pointer tables the relocations
use point at no free region, and ExitRom ends where its padding begins; only
the reported locations' LocRom records, their Map_PropsPtrs entries (a new
entry only in a slot no record names whose pointer was 0), the spans of the
MapProps packs no unreported location still uses, ExitRom and the reported
treasure lists may change; each reported location decodes to the report's
record, MapProps hash and size (one bank, inside a write zone), exits and
treasure; every other location decodes as in the clean ROM. Tilesets
(tools/ct_tilesets.py), when reported: only the reported palette sets, cycle
lists and frames, metatile and pack pointers, LocGfx_Lists rows, the packs'
and tables' old spans and the tile-animation lists may change; each reported
block unpacks (ChronoRET's Decomp_ToWram transcription) to its reported
hash and is what its pointer names; forks take only numbers no loader names;
every unreported Tileset12, Tileset3 and palette set, and the battle
backgrounds' packs, decode as in the clean ROM. Enemies
(tools/ct_enemies.py), when reported: only the reported enemies' stat
records, reward records and names may change; each decodes to the reported
values, in the ranges the battle code keeps (HP below $8000, level 0-99, an
attack record that exists, item ids below $F2), and its name is the reported
one (or unchanged); every other enemy, the attack and tech records, the
effect records, the AI pointers and every AI script are as in the clean ROM,
but for the reported AI scripts. Enemy AI scripts, when reported: only their
pointers (when relocated) and spans are written; each re-decodes (the
parser's twin in tools/ct_enemies.py) to the reported text, bytes and hash,
has no test byte $FF or target code past the table, and its reaction part is
where BattleAi_FindReactPart's scan finds it; a script in place lies in its
own unshared span, a relocated one in bank $CC's padding; scripts never
overlap; every unreported enemy's pointer and script are unchanged.
Sprites (tools/ct_sprites.py), when reported: only the reported playable
characters' tile blocks, frame records, frame-id and duration rows and
colours 1-12 may change; the bank-$E4 pointer tables and sprite records are
unchanged; each reported set decodes to the reported frames, animations and
colours with the clean ROM's addresses, counts and block ends, its tile block
hashes as reported, exactly the reported tiles differ and tile 0 stays blank;
every unreported set is as in the clean ROM.
Samples (tools/ct_samples.py), when reported: the sample tables are where the
code's twelve long operands say (moved, with one entry per appended sample,
only into a confirmed free region when the report says so; else in place);
each reported sample's pointer, length, BRR bytes (hash), loop, tuning and
ADSR words are the reported ones, its BRR is whole blocks the S-DSP plays as
one sample (end flag on the last block only and a loop offset on a block,
unless kept as it is) and decodes, it lies in free space or a replaced
sample's old span no other entry uses, and appended samples are numbered from
63; every other entry is the clean ROM's; only reported songs' sample lists
change, each to the reported list of numbers the tables hold; every song a
sample names loads it; and every written song's samples end below its echo
buffer ($F100 - EDL x $800), as the report's budgets say.
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
import ct_enemies as ce  # noqa: E402
import ct_event_packs as packs  # noqa: E402
import ct_items as ci  # noqa: E402
import ct_maps as cm  # noqa: E402
import ct_rom_layout as layout  # noqa: E402
import ct_samples as csm  # noqa: E402
import ct_spc_seq as spc  # noqa: E402
import ct_sprites as csp  # noqa: E402
import ct_techs as ct  # noqa: E402
import ct_text_profile  # noqa: E402
import ct_tilesets as cts  # noqa: E402

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


def tech_bytes(record, report):
    """The record bytes a tech build may change: +$02 (bit 4) of records
    0-6 and the tech state that begins the eighth."""
    if not report.get("techs"):
        return set()
    return {2} if record < cc.CHARACTERS else set(range(ct.TECH_STATE_SIZE))


def item_record_bytes(clean, record, report):
    """The record bytes an item build may change: the eighth record's block
    ends inside the weapons' record B table (ids $00-$05), checked by check_items."""
    if report.get("items") is None and report.get("itemTables") is None:
        return set()
    start = cc.RECORDS_PC + cc.RECORD_SIZE * record
    return {at - start for z in ci.write_zones(clean) for at in z if start <= at < start + cc.RECORD_SIZE}


def check_characters(clean, built, report):
    reported = report.get("characters") or []
    ids = [c["charId"] for c in reported]
    check(all(0 <= i < cc.CHARACTERS for i in ids) and len(set(ids)) == len(ids), f"character records {ids}")
    writable = {b for name in cc.WRITABLE for o, n in [cc.field(name)] for b in range(o, o + n)}
    bounds = clean[cc.ITEM_BOUNDS_PC:cc.ITEM_BOUNDS_PC + 6]
    by_id = {c["charId"]: c for c in reported}
    for i in range(cc.INIT_RECORDS):
        before, after = cc.record(clean, i), cc.record(built, i)
        techs = tech_bytes(i, report) | item_record_bytes(clean, i, report)
        if i not in by_id:
            check(all(before[b] == after[b] for b in range(cc.RECORD_SIZE) if b not in techs),
                  f"record {i} changed but is not reported")
            continue
        c = by_id[i]
        check(all(before[b] == after[b] for b in range(cc.RECORD_SIZE) if b not in writable | techs),
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


def enemy_spans(e, named):
    """The stat record, reward record and (when written) name of enemy number e."""
    spans = [range(ce.STATS_PC + ce.STATS_SIZE * e, ce.STATS_PC + ce.STATS_SIZE * (e + 1)),
             range(ce.REWARDS_PC + ce.REWARDS_SIZE * e, ce.REWARDS_PC + ce.REWARDS_SIZE * (e + 1))]
    if named:
        spans.append(range(ce.NAMES_PC + ce.NAME_SIZE * e, ce.NAMES_PC + ce.NAME_SIZE * (e + 1)))
    return spans


def enemy_zones(report):
    """The spans the builder may write for each reported enemy."""
    return [r for e in report.get("enemies") or [] for r in enemy_spans(e["enemyId"], e.get("name") is not None)]


ENEMY_STAT_KEYS = ("stamina", "speed", "magic", "hit", "evade", "magicDefense", "attack", "defense")


def report_enemy(e):
    """A report enemy in ct_enemies.decode_stats / decode_reward form."""
    r = e["enemy"]
    stats = {"hp": r["hp"], "level": r["level"], "status": r["status"],
             "stats": {s: r["stats"][k] for s, k in zip(ce.STAT_NAMES, ENEMY_STAT_KEYS)},
             "affinity": {x: r["affinity"][x] for x in ce.ELEMENTS},
             "immunity": r["immunity"], "flags15": r["flags15"], "attack_id": r["attackId"]}
    w = r["reward"]
    reward = {"exp": w["exp"], "gold": w["gold"], "drop": w["drop"], "charm": w["charm"], "tech_points": w["techPoints"]}
    return stats, reward


def check_enemies(clean, built, report):
    reported = report.get("enemies") or []
    by_id = {e["enemyId"]: e for e in reported}
    check(len(by_id) == len(reported) and all(0 <= i < ce.EMPTY_ID for i in by_id), f"enemy ids {sorted(by_id)}")
    glyphs = ce._glyphs()
    for i in range(ce.ENEMIES):
        e = by_id.get(i)
        if e is None:
            check(all(clean[r.start:r.stop] == built[r.start:r.stop] for r in enemy_spans(i, i < ce.NAMED)),
                  f"enemy {i} changed but is not reported")
            continue
        stats, reward = report_enemy(e)
        got = ce.decode_stats(ce.stats_record(built, i))
        check(got == stats, f"enemy {e['id']}: the stat record is not the reported values")
        check(ce.decode_reward(ce.reward_record(built, i)) == reward, f"enemy {e['id']}: the reward record is not the reported values")
        check(got["hp"] < 0x8000 and got["level"] <= 99 and got["attack_id"] < ce.ATTACKS,
              f"enemy {e['id']}: HP, level or attack id")
        check(reward["drop"] < ce.ITEM_COUNT and reward["charm"] < ce.ITEM_COUNT, f"enemy {e['id']}: drop or charm")
        name = e.get("name")
        if name is None:
            check(i >= ce.NAMED or ce.name_record(built, i) == ce.name_record(clean, i), f"enemy {e['id']}: the name changed")
        else:
            check(i < ce.NAMED and ce.decode_name(ce.name_record(built, i), glyphs) == name,
                  f"enemy {e['id']}: the name is not {name!r}")
    # Every other enemy table, from the names' end to the AI pointers, and every AI script but
    # those the report writes (check_enemy_scripts).
    start = ce.NAMES_PC + ce.NAME_SIZE * ce.NAMED
    check(clean[start:ce.AI_PTRS_PC] == built[start:ce.AI_PTRS_PC], "an enemy attack, tech or effect table changed")
    written = {s["enemyId"] for s in report.get("enemyScripts") or []}
    lengths = ce.act_lengths(clean)
    bank = ce.AI_BANK & 0x3F
    for i in range(ce.ENEMIES):
        if i in written:
            continue
        check(clean[ce.AI_PTRS_PC + 2 * i:ce.AI_PTRS_PC + 2 * i + 2] == built[ce.AI_PTRS_PC + 2 * i:ce.AI_PTRS_PC + 2 * i + 2],
              f"enemy {i}'s AI pointer changed but its script is not reported")
        at = clean[ce.AI_PTRS_PC + 2 * i] | clean[ce.AI_PTRS_PC + 2 * i + 1] << 8
        try:
            _, end = ce.parse_script(clean[bank << 16:(bank + 1) << 16], at, lengths)
        except ce.ScriptError:
            continue
        check(clean[(bank << 16) + at:(bank << 16) + end] == built[(bank << 16) + at:(bank << 16) + end],
              f"enemy {i}'s AI script changed")


def script_zones(clean, report):
    """The spans the builder may write for each reported AI script: the
    script's own span (in place) or its new span and its pointer (relocated)."""
    out = []
    for s in report.get("enemyScripts") or []:
        out.append(range(s["pc"], s["pc"] + s["bytes"]))
        if s.get("placement") == "free":
            out.append(range(ce.AI_PTRS_PC + 2 * s["enemyId"], ce.AI_PTRS_PC + 2 * s["enemyId"] + 2))
    return out


def check_enemy_scripts(clean, built, report, inside):
    """Each reported script: its pointer, its bytes re-decoded to the report's
    text, in place only inside its own unshared span, else inside bank $CC's
    padding; the game's ends ($FF of each part) where the parser finds them."""
    scripts = report.get("enemyScripts") or []
    ids = [s["enemyId"] for s in scripts]
    check(len(set(ids)) == len(ids) and all(0 <= i < ce.EMPTY_ID for i in ids), f"enemy script ids {ids}")
    listed = {e["enemyId"] for e in report.get("enemies") or []}
    check(set(ids) <= listed, f"scripts written for enemies the report does not list: {sorted(set(ids) - listed)}")
    lengths = ce.act_lengths(clean)
    spans = ce.script_spans(clean, lengths)
    shared = ce.sharers(spans)
    data = ce.bank(built)
    free = range(ce.AI_FREE_PC, ce.AI_FREE_PC + ce.AI_FREE_SIZE)
    placed = []
    for s in scripts:
        i = s["enemyId"]
        check(i in spans, f"enemy {i}: a script written over a pointer that is not a script in the clean ROM")
        at = ce.script_pointer(built, i)
        check(ce.pc(ce.AI_BANK, at) == s["pc"], f"enemy {i}'s AI pointer is ${at:04X}, the report says {s['address']}")
        try:
            parts, end = ce.parse_script(data, at, lengths)
        except ce.ScriptError as e:
            check(False, f"enemy {i}'s written AI script does not parse: {e}")
            continue
        span = range(s["pc"], ce.pc(ce.AI_BANK, end))
        check(len(span) == s["bytes"] and packs.sha(data[at:end]) == s["sha256"], f"enemy {i}: script bytes")
        check(ce.format_parts(parts) == s["text"], f"enemy {i}: the script does not re-decode to the reported text")
        check(ce.ai_assemble(s["text"], lengths) == data[at:end], f"enemy {i}: the reported text does not assemble to it")
        check(not ce.write_problems(parts), f"enemy {i}: {ce.write_problems(parts)}")
        check(data.index(ce.PART_END, at) == at + len(ce.assemble_parts(parts[:1])) - 1,
              f"enemy {i}: BattleAi_FindReactPart would not find the reaction part")
        check(i not in spans or clean[spans[i].start:spans[i].stop] != data[at:end], f"enemy {i}: reported but unchanged")
        if s["placement"] == "original":
            check(i in spans and i not in shared and span.start == spans[i].start and span.stop <= spans[i].stop
                  and ce.script_pointer(clean, i) == at, f"enemy {i}: in place outside its own unshared span")
        else:
            check(s["placement"] == "free" and span.start >= free.start and span.stop <= free.stop,
                  f"enemy {i}: relocated outside bank $CC's padding")
        check(inside(span), f"enemy {i}: script outside the write zones")
        placed.append(span)
    ordered = sorted(placed, key=lambda r: r.start)
    for a, b in zip(ordered, ordered[1:]):
        check(a.stop <= b.start, f"scripts at ${a.start:06X} and ${b.start:06X} overlap")
    return placed


def sprite_zones(clean, report):
    """The spans the builder may write for each reported sprite set."""
    return [r for s in report.get("sprites") or [] if s.get("family") == "ct-pc" and 0 <= s.get("set", -1) < csp.SETS
            for r in csp.set_spans(clean, s["set"]).values()]


def check_sprites(clean, built, report):
    reported = report.get("sprites") or []
    by_set = {s["set"]: s for s in reported}
    check(len(by_set) == len(reported) and all(s["family"] == "ct-pc" and 0 <= s["set"] < csp.SETS for s in reported),
          f"sprite sets {sorted(by_set)}")
    tables = range(csp.pc(csp.TILES_PTR), csp.pc(csp.ANIM_DURS) + 2 * csp.POINTERS)
    check(clean[tables.start:tables.stop] == built[tables.start:tables.stop], "a bank-$E4 sprite pointer table changed")
    recs = range(csp.pc(csp.SPR_REC), csp.pc(csp.SPR_REC) + csp.SPR_REC_BYTES * csp.POINTERS)
    check(clean[recs.start:recs.stop] == built[recs.start:recs.stop], "a sprite record changed")
    for c in range(csp.SETS):
        spans = csp.set_spans(clean, c)
        s = by_set.get(c)
        if s is None:
            check(all(clean[r.start:r.stop] == built[r.start:r.stop] for r in spans.values()),
                  f"sprite set {c} changed but is not reported")
            continue
        name = f"sprite {s['id']}"
        before, d = csp.decode_set(clean, c), csp.decode_set(built, c)
        for key in ("tiles", "frames"):
            check(d[key] == before[key] and (d[key]["address"], d[key]["count"]) == (s[key], s[key[:-1] + "Count"]),
                  f"{name}: its {key} block moved, grew or shrank")
        check(d["animations"] == before["animations"] and d["animations"]["rows"] == s["rows"]
              and (d["animations"]["frameIds"], d["animations"]["durations"]) == (s["frameIds"], s["durations"]),
              f"{name}: its animation rows moved")
        check(d["palette"]["address"] == s["palette"], f"{name}: its palette moved")
        check(d["frameList"] == [{"cells": f["cells"], "pieces": f["pieces"]} for f in s["frameList"]],
              f"{name}: the frame records are not the reported frames")
        want = [{k: a[k] for k in ("row", "facing", "frames", "durations")} for a in s["animations"]]
        check([{k: a[k] for k in ("row", "facing", "frames", "durations")} for a in d["animationList"]] == want,
              f"{name}: the animation rows are not the reported animations")
        check(csp.palette(built, c) == s["colours"] and all(w < 0x8000 for w in s["colours"]),
              f"{name}: colours 1-12 are not the reported colours")
        tb, tb0 = csp.tiles(built, c), csp.tiles(clean, c)
        check(packs.sha(b"".join(tb)) == s["tilesSHA256"], f"{name}: the tile block is not the reported one")
        check([t for t in range(len(tb)) if tb[t] != tb0[t]] == s["changedTiles"], f"{name}: other tiles changed than reported")
        check(not any(tb[0]), f"{name}: tile 0 is not blank")
        words = [w for f in d["frameList"] for w in f["cells"]]
        check(all(w & 0x3800 == 0 and w & csp.TILE_MASK < len(tb) for w in words), f"{name}: a cell's tile or bits 11-13")
        check(all(0 < x <= 0xFF and i < len(d["frameList"]) for a in d["animationList"]
                  for x, i in zip(a["durations"], a["frames"])), f"{name}: a duration or frame id")


def check_techs(clean, built, report):
    # Every byte inside ct.write_zones is compared below; main()'s span check
    # rejects changed bytes outside them (CharTechs, the TP word after the rows).
    system = report.get("techs")
    if not system:
        for z in ct.write_zones(clean):
            check(built[z.start:z.stop] == clean[z.start:z.stop], f"tech byte ${z.start:06X} changed but techs are not reported")
        return
    areas = ct.decode_areas(clean)
    check(len(system["techs"]) == ct.TECHS and len(system["parts"]) == ct.PARTS, "the reported tables' sizes")
    for t, want in enumerate(system["techs"]):
        before, v = ct.decode_tech(clean, t), ct.decode_tech(built, t)
        name = f"tech ${t:02X}"
        for key in ("user_set", "flags", "unk2", "attr", "unk4"):
            check(v[key] == before[key], f"{name}: {key} is read-only")
        check(all(v["anim"][k] == before["anim"][k] for k in ct.ANIM_FIELDS if k not in ("script", "frames")),
              f"{name}: only the animation's script and frames are writable")
        check(want["id"] == t and v["target_mode"] == want["targetMode"] and v["field_menu"] == want["fieldMenu"]
              and v["area"] == want["area"] and v["needs_unlock"] == want["needsUnlock"]
              and ct.element_of(v["element_bits"] << 4) == want.get("element") and v["parts"] == want["parts"]
              and v["modifiers"] == want["modifiers"] and v["anim"]["script"] == want["anim"]["script"]
              and v["anim"]["frames"] == want["anim"]["frames"], f"{name}: not the reported values")
        check(v["target_mode"] < ct.TARGET_MODES and v["area"] < ct.AREAS and (v["area"] == 0 or areas[v["area"]]),
              f"{name}: target mode or area out of range")
        check(v["element_bits"] & (v["element_bits"] - 1) == 0, f"{name}: more than one element bit")
        check(all(p & 0x7F < ct.PARTS for p in v["parts"]) and all(m < ct.MODIFIERS for m in v["modifiers"]),
              f"{name}: a part or modifier past its table")
        check(v["anim"]["script"] < ct.SCRIPTS and v["anim"]["frames"] < ct.ANIM_FRAMES, f"{name}: animation out of range")
    for p, want in enumerate(system["parts"]):
        v = ct.decode_part(built, p)
        check(want["id"] == p and v["mp"] == want["mp"]
              and [v["effect"][k] for k in ct.EFFECT_FIELDS] == [want["effect"][k] for k in ct.SWIFT_EFFECT_FIELDS],
              f"part {p}: not the reported values")
        check((v["mp"] <= 99 or v["mp"] == 0xFF) and v["effect"]["type"] < ct.EFFECT_TYPES, f"part {p}: MP or type out of range")
    check(ct.tp_words(built)[:-1] == [w for row in system["tpCost"] for w in row], "TechTpCost is not the reported table")
    before, after = ct.decode_combos(clean), ct.decode_combos(built)
    check(len(after) == len(before) == len(system["combos"]), "the combination records' count")
    for b, a, want in zip(before, after, system["combos"]):
        check((a["mask"], a["first"], a["count"], a["req_addr"]) == (b["mask"], b["first"], b["count"], b["req_addr"]),
              f"combination ${b['first']:02X}: its record changed")
        check(a["requirements"] == want["requirements"], f"combination ${b['first']:02X}: not the reported requirements")
        n = len(ct.members(a["mask"]))
        check(all(all(1 <= r <= 8 for r in row[:n]) and all(r == ct.NONE for r in row[n:]) for row in a["requirements"]),
              f"combination ${b['first']:02X}: requirements out of range")
    state = ct.decode_state(built)
    learned = system["learned"]
    check(state == {"counts": learned["counts"], "bits1": learned["bits1"], "combo_bits": learned["comboBits"]},
          "the new-game tech state is not the reported one")
    check(all(n <= 8 for n in state["counts"]) and all(b == (0xFF00 >> n) & 0xFF for b, n in zip(state["bits1"], state["counts"])),
          "the new-game counts and single bits disagree")
    for i, b in enumerate(state["combo_bits"]):
        allowed = (0xFF00 >> after[i]["count"]) & 0xFF if i < len(after) else 0x80 if i >= 15 else 0
        check(not b & ~allowed, f"combination byte {i}: a bit past its techs")
    for c in range(ct.CHARACTERS):
        at = ct.RECORDS_PC + ct.RECORD_SIZE * c + 2
        check(built[at] & ~ct.ALL_TECHS == clean[at] & ~ct.ALL_TECHS
              and bool(built[at] & ct.ALL_TECHS) == (state["counts"][c] >= 8), f"record {c} +$02")


ITEM_FIELDS = {"weapon": ("attack", "byte1", "critical", "modifier", "modifierArg"),
               "armor": ("defence", "modifier", "modifierOn"), "helmet": ("defence", "modifier", "modifierOn"),
               "accessory": ("battleFlags", "special", "specialArg", "specialBits"),
               "consumable": ("useKind", "restores", "amount", "byte3")}
STAT_NAMES = {"magic_defense": "magicDefense"}


def item_bytes(rom, item):
    """Every byte of `item` an item build may write, by offset."""
    cat = ci.category(item)
    a, b = ci.record_a_pc(rom, item), ci.record_b_pc(rom, item)
    at = list(range(a, a + ci.SIZES_A[cat])) + list(range(b, b + ci.SIZES_B[cat]))
    at += range(ci.NAMES_PC + ci.NAME_SIZE * item + 1, ci.NAMES_PC + ci.NAME_SIZE * (item + 1))
    if cat == 4:
        at.append(ci.TARGET_MODE_PC + item - ci.FIRST[4])
    return {i: rom[i] for i in at}


def check_items(clean, built, report):
    # Every byte inside ci.write_zones is compared below; main()'s span check
    # rejects changed bytes outside them (the icons, the tables they point at).
    items, tables = report.get("items"), report.get("itemTables")
    if items is None and tables is None:
        for z in ci.write_zones(clean):
            check(built[z.start:z.stop] == clean[z.start:z.stop], f"item byte ${z.start:06X} changed but items are not reported")
        return
    check(all(built[ci.NAMES_PC + ci.NAME_SIZE * i] == clean[ci.NAMES_PC + ci.NAME_SIZE * i] for i in range(ci.ITEMS)),
          "an icon byte changed (read-only)")
    reported = {}
    for want in items or []:
        r = want["rom"]
        n = r["itemId"]
        name = f"item ${n:02X}"
        check(0 <= n < ci.ITEMS and n not in reported, f"{name}: id out of range or reported twice")
        reported[n] = want
        kind = ci.CATEGORIES[ci.category(n)]
        v = ci.decode_item(built, n)
        check(want["kind"] == kind and v["icon"] == r["icon"], f"{name}: kind or icon is not the item's")
        check(v["flags"] == r["flags"] and v["price"] == want["price"] and v.get("equip") == r.get("equip")
              and v.get("boost") == r.get("boost") and v.get("element_bonus") == r.get("elementBonus")
              and v.get("target_mode") == r.get("targetMode")
              and [v[f] for f, _ in ci.FIELDS_B[kind]] == [want["stats"][f] for f in ITEM_FIELDS[kind]]
              and v["name"] == want["name"], f"{name}: not the reported values")
        check(not v["flags"] & 0x61 and (v.get("equip", 0) & 1) == 0 and v.get("boost", 0) < ci.BOOSTS,
              f"{name}: flags, equip mask or boost out of range")
        if kind in ("weapon", "armor", "helmet"):
            check(v["modifier"] < ci.MODIFIERS, f"{name}: modifier past BattleRom_UnkCC2A05")
        if kind in ("armor", "helmet"):
            check(v["modifier_on"] in (0, 1), f"{name}: modifier_on is 0 or 1")
        if kind == "accessory" and v["special"] & ci.ACCESSORY_BOOST:
            check(v["special_arg"] < ci.BOOSTS, f"{name}: the boost in special_arg is past ItemBoosts")
        raw = built[ci.NAMES_PC + ci.NAME_SIZE * n + 1:ci.NAMES_PC + ci.NAME_SIZE * (n + 1)]
        glyphs = bytes(raw).rstrip(b"\xef")
        check(all(g >= 0xA0 and g != 0xEF for g in glyphs), f"{name}: the name has a non-glyph or inner $EF byte")
    for n in range(ci.ITEMS):
        if n not in reported:
            check(item_bytes(built, n) == item_bytes(clean, n), f"item ${n:02X} changed but is not reported")
    if tables is None:
        check(ci.boosts(built) == ci.boosts(clean), "ItemBoosts changed but item_tables.json is not reported")
    else:
        order = ci.stat_order(built)
        got = [{"stats": [STAT_NAMES.get(x, x) for x in ci.boost_stats(w, order)], "amount": w >> 8} for w in ci.boosts(built)]
        check(got == tables["boosts"] and all(w & 1 == 0 for w in ci.boosts(built)), "ItemBoosts is not the reported table")
        check(tables["statCaps"] == ci.stat_caps(built) and tables["char5Attack"] == ci.char5_attack(built)
              and [STAT_NAMES.get(ci.STATS[i], ci.STATS[i]) for i in order] == tables["statOrder"],
              "the read-only stat tables are not the ROM's")
    # Descriptions: each pointer on a $00-terminated string inside the table's span.
    codec = ct_text_profile.reference_codec()
    dictionary = codec.rom_dictionary(clean)
    before = ci.descriptions(clean)
    start = ci.DESC_PC + 2 * ci.ITEMS
    for n in range(ci.ITEMS):
        at = ci.pc(0xCC, int.from_bytes(built[ci.DESC_PC + 2 * n:ci.DESC_PC + 2 * n + 2], "little"))
        check(start <= at < ci.DESC_END and 0 in built[at:ci.DESC_END], f"item ${n:02X}: description pointer")
        string = bytes(built[at:built.index(0, at, ci.DESC_END)])
        text = reported.get(n, {}).get("description")
        if string != before[n][1]:
            check(text is not None, f"item ${n:02X}: description changed but is not reported")
            expect = codec.encode_msg(text.replace("\n", "{line}"), dictionary, f"item {n}")
            check(string + b"\x00" == expect or string == expect, f"item ${n:02X}: description bytes are not the encoded text")


# --- Maps and tilesets ------------------------------------------------------------------------

BATTLE_SETS, BATTLE_SET_BYTES = 0xD1ECDB, 24                         # BattleFx_BgSetPacks
FIELD_ANIM_B_END = 0xFDFF29                                          # the data after FieldAnimListB


def lpc(long):
    return cts.pc(long)


def packed_span(rom, long, what=None):
    """(unpacked bytes, PC range of the packed stream) by ChronoRET's transcription."""
    try:
        data, end, _ = c3pack.unpack(rom, lpc(long))
    except Exception as e:  # noqa: BLE001  (a damaged stream raises from inside the transcription)
        check(False, f"{what or f'${long:06X}'} does not unpack ({e})")
    return data, range(lpc(long), end)


def exit_block_end(rom):
    return cm.EXIT_OFS + cts.u16(rom, cm.EXIT_OFS + 2 * cm.LOC_COUNT)


def location_users(rom):
    users = {}
    for i in range(cm.LOC_COUNT):
        users.setdefault(cm.header(rom, i)["mapProps"], []).append(i)
    return users


def check_layout_tables(clean, regions):
    """The relocations' free space: no pointer of the tables they repoint, and
    no map, exit or treasure block, lies in a confirmed free region."""
    targets = [cm.props_pointer(clean, e) for e in set(cm.header(clean, i)["mapProps"] for i in range(cm.LOC_COUNT))]
    targets += [cts.u24(clean, cts.META12_PTRS + 3 * t) for t in cts.used_t12(clean)]
    targets += [cts.u24(clean, cts.META3_PTRS + 3 * n) for n in cts.used_t3(clean)]
    targets += [cts.u24(clean, cts.PACK_PTRS + 3 * n) for n in pack_users(clean)]
    for long in targets:
        at = lpc(long)
        check(not any(at in r for r in regions), f"a table pointer ${long:06X} points into a free region")
    end = lpc(exit_block_end(clean))
    check(any(r.start == end for r in regions), "ExitRom does not end where a free region begins")
    t_end = lpc(cm.TREASURE_BANK + cts.u16(clean, cm.TREASURE_OFS + 2 * cm.LOC_COUNT))
    check(not any(r.start < t_end and lpc(cm.TREASURE_OFS) < r.stop for r in regions), "TreasureRom overlaps a free region")


def map_content(rom, i):
    """ct_maps.decode without the addresses a rewritten ExitRom moves."""
    d = cm.decode(rom, i)
    d["exits"] = [{k: v for k, v in e.items() if k != "at"} for e in d["exits"]]
    return d


def map_zones(clean, report, regions):
    maps = report.get("maps")
    if maps is None:
        return []
    zones, reported = [], {m["location"] for m in maps}
    users = location_users(clean)
    for m in maps:
        loc = m["location"]
        zones.append(range(lpc(cm.LOC_ROM) + cm.LOC_BYTES * loc, lpc(cm.LOC_ROM) + cm.LOC_BYTES * (loc + 1)))
        zones.append(range(lpc(cm.MAP_PROPS_PTRS) + 3 * m["entry"], lpc(cm.MAP_PROPS_PTRS) + 3 * m["entry"] + 3))
        old = cm.header(clean, loc)["mapProps"]
        if set(users[old]) <= reported:                     # no unreported location still reads it
            zones.append(packed_span(clean, cm.props_pointer(clean, old))[1])
            zones.append(range(lpc(cm.MAP_PROPS_PTRS) + 3 * old, lpc(cm.MAP_PROPS_PTRS) + 3 * old + 3))
        list_loc = m["treasureList"]
        first = cts.u16(clean, cm.TREASURE_OFS + 2 * list_loc)
        end = cts.u16(clean, cm.TREASURE_OFS + 2 * list_loc + 2)
        zones.append(range(lpc(cm.TREASURE_BANK + first), lpc(cm.TREASURE_BANK + end)))
    # ExitRom may grow into the padding that begins where it ends.
    end = lpc(exit_block_end(clean))
    zones.append(range(lpc(cm.EXIT_OFS), max([r.stop for r in regions if r.start == end] + [end])))
    return zones


def check_maps(clean, built, report, inside):
    maps = report.get("maps")
    if maps is None:
        for i in range(cm.LOC_COUNT):
            check(bytes(built[lpc(cm.LOC_ROM) + cm.LOC_BYTES * i:lpc(cm.LOC_ROM) + cm.LOC_BYTES * (i + 1)])
                  == bytes(clean[lpc(cm.LOC_ROM) + cm.LOC_BYTES * i:lpc(cm.LOC_ROM) + cm.LOC_BYTES * (i + 1)]),
                  f"LocRom[{i}] changed but no maps are reported")
        return
    used = location_users(clean)
    reported = {}
    spans = {}
    for m in maps:
        loc = m["location"]
        name = f"map {m['id']}"
        check(0 <= loc < cm.LOC_COUNT and loc not in reported, f"{name}: location out of range or reported twice")
        reported[loc] = m
        record = list(built[lpc(cm.LOC_ROM) + cm.LOC_BYTES * loc:lpc(cm.LOC_ROM) + cm.LOC_BYTES * (loc + 1)])
        check(record == m["record"], f"{name}: LocRom record is not the reported one")
        h = cm.header(built, loc)
        check(h["mapProps"] == m["entry"], f"{name}: the record names entry {h['mapProps']}, the report {m['entry']}")
        if m["newEntry"]:
            check(m["entry"] not in used and cm.props_pointer(clean, m["entry"]) == 0,
                  f"{name}: new entry {m['entry']} was not a free Map_PropsPtrs slot")
        at = cm.props_pointer(built, m["entry"])
        data, span = packed_span(built, at, f"{name}: MapProps")
        check(lpc(at) == m["pc"] and len(span) == m["packedBytes"] and packs.sha(data) == m["unpackedSHA256"]
              and len(data) == m["unpackedBytes"], f"{name}: MapProps is not the reported pack")
        check(span.start >> 16 == (span.stop - 1) >> 16, f"{name}: MapProps crosses a bank")
        if m["placement"] != "unchanged":
            check(inside(span), f"{name}: MapProps outside free space")
            if spans.get(span.start, span) != span:
                check(False, f"{name}: MapProps overlaps another")
            spans[span.start] = span
        else:
            check(at == cm.props_pointer(clean, cm.header(clean, loc)["mapProps"]), f"{name}: unchanged MapProps moved")
        try:
            cm.parse_props(data)
        except Exception as e:  # noqa: BLE001
            check(False, f"{name}: MapProps does not parse ({e})")
        exits = [list(raw) for _, raw in cm.exit_records(built, loc)]
        check(exits == m["exits"], f"{name}: exits are not the reported ones")
        check(all(cm.decode_exit(raw)["dest"] < cm.LOC_COUNT for raw in exits), f"{name}: an exit leaves the locations")
        tloc, tlist = cm.treasure_list(built, loc)
        check(tloc == m["treasureList"] and [[t & 0xFF, t >> 8, c] for _, t, c in tlist] == m["treasure"],
              f"{name}: treasure is not the reported list")
        check(len(tlist) == len(cm.treasure_list(clean, loc)[1]), f"{name}: the treasure count changed (flag numbers)")
    ordered = sorted(spans.values(), key=lambda r: r.start)
    for a, b in zip(ordered, ordered[1:]):
        check(a.stop <= b.start, f"MapProps at ${a.start:06X} and ${b.start:06X} overlap")
    check(cts.u16(built, cm.TREASURE_OFS) == cts.u16(clean, cm.TREASURE_OFS)
          and all(cts.u16(built, cm.TREASURE_OFS + 2 * i) == cts.u16(clean, cm.TREASURE_OFS + 2 * i)
                  for i in range(cm.LOC_COUNT + 1)), "TreasureRom's offset words changed")
    check(cm.treasure_list(built, 0) == cm.treasure_list(clean, 0), "location 0's dummy treasure changed")
    for i in range(cm.LOC_COUNT):
        if i not in reported:
            check(map_content(built, i) == map_content(clean, i), f"location {i} changed but is not reported")


def pack_users(rom):
    """{pack number: [users]} of the location lists in use, the Tileset3 packs
    and the battle backgrounds (the only readers of LocGfx_PackPtrs)."""
    out = {}
    for t in cts.used_t12(rom):
        for k, n in enumerate(cts.pack_list(rom, t)):
            if n is not None:
                out.setdefault(n, []).append(("t12", t, k))
    for n in cts.used_t3(rom):
        out.setdefault(n, []).append(("t3", n, 0))
    for k, n in enumerate(rom[lpc(BATTLE_SETS):lpc(BATTLE_SETS) + BATTLE_SET_BYTES]):
        if n != cts.NONE:
            out.setdefault(n, []).append(("battle", k // 4, k % 4))
    return out


def tileset_zones(clean, report):
    tilesets = report.get("tilesets")
    if tilesets is None:
        return []
    zones = []
    users = pack_users(clean)
    reported = {(t["kind"], t["index"]) for t in tilesets}
    for t in tilesets:
        i = t["index"]
        if t["kind"] == "palette":
            at = lpc(cts.LOC_PAL + cts.PAL_SET_BYTES * i)
            zones.append(range(at, at + cts.PAL_SET_BYTES))
            records, start, end = cts.anim_list_b(clean, i)
            zones.append(range(lpc(start), lpc(end)))
            for r in records:
                if r and "offset" in r:
                    f = lpc(cts.PAL_ANIM_ROM + r["offset"])
                    zones.append(range(f, f + 2 * r["count"] * len(r["colours"])))
            continue
        ptrs = cts.META12_PTRS if t["kind"] == "bg12" else cts.META3_PTRS
        zones.append(range(lpc(ptrs) + 3 * i, lpc(ptrs) + 3 * i + 3))
        zones.append(packed_span(clean, cts.u24(clean, ptrs + 3 * i))[1])
        if t["kind"] == "bg12":
            zones.append(range(lpc(cts.LISTS) + cts.LIST_BYTES * i, lpc(cts.LISTS) + cts.LIST_BYTES * (i + 1)))
            _, start, end = cts.anim_list_a(clean, i)
            zones.append(range(lpc(start), lpc(end)))
        numbers = [n for n in cts.pack_list(clean, i) if n is not None] if t["kind"] == "bg12" else [i]
        for n in numbers:
            # A pack's old span is writable when every user of it is reported.
            if all((("bg12" if k == "t12" else "bg3"), j) in reported for k, j, _ in users[n] if k != "battle") \
                    and not any(k == "battle" for k, _, _ in users[n]):
                zones.append(packed_span(clean, cts.u24(clean, cts.PACK_PTRS + 3 * n))[1])
            zones.append(range(lpc(cts.PACK_PTRS) + 3 * n, lpc(cts.PACK_PTRS) + 3 * n + 3))
        for b in t["blocks"]:
            if "fork of" in b["what"]:
                f = int(b["what"].split()[1])
                zones.append(range(lpc(cts.PACK_PTRS) + 3 * f, lpc(cts.PACK_PTRS) + 3 * f + 3))
    return zones


def tileset_content(rom, kind, i):
    """A tileset's decode without the fields other tilesets' builds may move
    (the locations using it, the preview, pack addresses)."""
    if kind == "bg12":
        d = cts.decode_t12(rom, i)
        window, _ = cts.bg12_vram(rom, i)
        wram, _ = cts.anim_wram(rom, i)
        return (d["metatiles"], d["knownTiles"], d["animKnown"], d["tileAnims"]["records"], window, wram)
    if kind == "bg3":
        d = cts.decode_t3(rom, i)
        return (d["metatiles"], d["knownTiles"], cts.bg3_vram(rom, i)[0])
    d = cts.decode_pal(rom, i)
    return (d["rows"], d["cycles"]["records"])


def check_tilesets(clean, built, report, inside):
    tilesets = report.get("tilesets")
    reported = {(t["kind"], t["index"]): t for t in tilesets or []}
    free_numbers = {n for n in range(cts.PACK_COUNT) if n not in pack_users(clean)}
    spans = {}
    for t in tilesets or []:
        name = t["id"]
        i = t["index"]
        check(t["kind"] in ("bg12", "bg3", "palette") and list(reported).count((t["kind"], i)) == 1,
              f"{name}: kind or index reported twice")
        # What the report says it left alone decodes as in the clean ROM.
        unchanged = {"palette": lambda r: cts.palette_set(r, i),
                     "cycles": lambda r: [x and {k: v for k, v in x.items() if k not in ("offset", "colours")}
                                          for x in cts.anim_list_b(r, i)[0]],
                     "frames": lambda r: [x and x.get("colours") for x in cts.anim_list_b(r, i)[0]],
                     "metatiles": lambda r: cts.meta_table(r, cts.META12_PTRS if t["kind"] == "bg12" else cts.META3_PTRS, i)["metatiles"],
                     "characters": lambda r: (cts.bg12_vram(r, i)[0], cts.anim_wram(r, i)[0]) if t["kind"] == "bg12"
                     else cts.bg3_vram(r, i)[0],
                     "animations": lambda r: cts.anim_list_a(r, i)[0]}
        parts = {"palette": ("palette", "cycles", "frames"), "bg12": ("metatiles", "characters", "animations"),
                 "bg3": ("metatiles", "characters")}[t["kind"]]
        for part in parts:
            if part not in t["changed"] and not (part == "cycles" and "frames" in t["changed"]):
                check(unchanged[part](built) == unchanged[part](clean), f"{name}: {part} changed but is not reported")
        if t["kind"] == "palette":
            records, start, end = cts.anim_list_b(built, i)
            check(lpc(cts.ANIM_B) <= lpc(start) and lpc(end) <= lpc(FIELD_ANIM_B_END), f"{name}: cycle list outside FieldAnimListB")
            for r in records:
                if r:
                    last = r["first"] + r["count"] - (0 if r["kind"] in (2, 3) else 1)
                    check(r["kind"] in (1, 2, 3, 8) and r["first"] >= 16 and last < 128, f"{name}: a cycle leaves rows 1-7")
                    if "offset" in r:
                        f = lpc(cts.PAL_ANIM_ROM + r["offset"])
                        check(inside(range(f, f + 2 * r["count"] * len(r["colours"]))) or
                              bytes(built[f:f + 2 * r["count"] * len(r["colours"])])
                              == bytes(clean[f:f + 2 * r["count"] * len(r["colours"])]), f"{name}: frames outside free space")
            continue
        ptrs = cts.META12_PTRS if t["kind"] == "bg12" else cts.META3_PTRS
        meta_at = cts.u24(built, ptrs + 3 * i)
        names = {}
        for b in t["blocks"]:
            data, span = packed_span(built, 0xC00000 | b["pc"], f"{name}: {b['what']} at {b['address']} does not unpack to the reported bytes;")
            check(len(span) == b["packedBytes"] and len(data) == b["unpackedBytes"] and packs.sha(data) == b["unpackedSHA256"],
                  f"{name}: {b['what']} at {b['address']} does not unpack to the reported bytes")
            check(span.start >> 16 == (span.stop - 1) >> 16 and inside(span), f"{name}: {b['what']} outside free space")
            check(spans.get(span.start, (span, b["unpackedSHA256"])) == (span, b["unpackedSHA256"]),
                  f"{name}: {b['what']} overlaps another block")
            spans[span.start] = (span, b["unpackedSHA256"])
            names[b["what"]] = b["pc"]
        if "metatiles" in names:
            check(lpc(meta_at) == names["metatiles"], f"{name}: the metatile pointer does not name the new table")
        else:
            check(meta_at == cts.u24(clean, ptrs + 3 * i), f"{name}: the metatile pointer moved")
        for what, at in names.items():
            if what.startswith("pack "):
                n = int(what.split()[1])
                check(lpc(cts.u24(built, cts.PACK_PTRS + 3 * n)) == at, f"{name}: {what} is not what its pointer names")
                if "fork of" in what:
                    check(n in free_numbers, f"{name}: fork {n} took a number a loader names")
        if t["kind"] == "bg12":
            check([cts.NONE if n is None else n for n in cts.pack_list(built, i)] == t["packs"], f"{name}: pack list is not the reported one")
            for n in cts.pack_list(built, i):
                if n is not None and n not in cts.pack_list(clean, i):
                    check(n in free_numbers and any(f"pack {n} (fork" in w for w in names), f"{name}: list names pack {n}, not a reported fork")
    for kind, values in (("bg12", cts.used_t12(clean)), ("bg3", cts.used_t3(clean)), ("palette", cts.used_pal(clean))):
        for i in values:
            if (kind, i) not in reported:
                check(tileset_content(built, kind, i) == tileset_content(clean, kind, i),
                      f"{kind} {i} changed but is not reported")
    for k, n in enumerate(clean[lpc(BATTLE_SETS):lpc(BATTLE_SETS) + BATTLE_SET_BYTES]):
        if n != cts.NONE:
            check(cts.pack(built, n)["data"] == cts.pack(clean, n)["data"], f"battle background pack {n} changed")
    check(built[lpc(BATTLE_SETS):lpc(BATTLE_SETS) + BATTLE_SET_BYTES] == clean[lpc(BATTLE_SETS):lpc(BATTLE_SETS) + BATTLE_SET_BYTES],
          "BattleFx_BgSetPacks changed")


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
    if report.get("techs"):
        zones += ct.write_zones(clean)
    if report.get("items") is not None or report.get("itemTables") is not None:
        zones += ci.write_zones(clean)
    if report.get("maps") is not None or report.get("tilesets") is not None:
        check_layout_tables(clean, zones[:len(rom_layout["freeRegions"])])
    zones += map_zones(clean, report, zones[:len(rom_layout["freeRegions"])])
    zones += tileset_zones(clean, report)
    zones += enemy_zones(report)
    zones += script_zones(clean, report)
    zones += sprite_zones(clean, report)
    zones += csm.zones(clean, report)

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

    # Samples: tables, entries, sample lists and budgets (tools/ct_samples.py).
    free = zones[:len(rom_layout["freeRegions"])]
    sample_spans, sample_count = csm.check_samples(clean, built, report, check, inside, free)

    # Songs: untouched ones as before, new ones as reported.
    counts, _ = spc.driver_tables(built)
    new_spans = dict(sample_spans)
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
        check(len(samples) <= 16 and all(1 <= x <= sample_count for x in samples), f"song {s['song']}: sample list")
        check(len(tables.get("echo", b"..")) == 2 and len(tables.get("drums", bytes(36))) == 36, f"song {s['song']}: table sizes")
        for at, row, want in spc.table_rows(tables):
            got = built[at + row * s["song"]:at + row * (s["song"] + 1)]
            check(got == want, f"song {s['song']}: table row at ${at + row * s['song']:06X}")
        new_spans[pc] = range(pc, pc + 2 + len(data))

    check_characters(clean, built, report)
    check_techs(clean, built, report)
    check_items(clean, built, report)
    check_maps(clean, built, report, inside)
    check_tilesets(clean, built, report, inside)
    check_enemies(clean, built, report)
    for span in check_enemy_scripts(clean, built, report, inside):
        if span.start >= ce.AI_FREE_PC:
            new_spans[span.start] = span
    check_sprites(clean, built, report)

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
          f"{len(report.get('songs', []))} songs, {len(report.get('characters') or [])} characters"
          + (", techs" if report.get("techs") else "")
          + (f", {len(report['items'])} items" if report.get("items") is not None else "")
          + (f", {len(report['maps'])} maps" if report.get("maps") is not None else "")
          + (f", {len(report['tilesets'])} tilesets" if report.get("tilesets") is not None else "")
          + (f", {len(report['enemies'])} enemies" if report.get("enemies") is not None else "")
          + (f", {len(report['enemyScripts'])} AI scripts" if report.get("enemyScripts") is not None else "")
          + (f", {len(report['sprites'])} sprites" if report.get("sprites") is not None else "")
          + (f", {len(report['samples'])} samples" if report.get("samples") is not None else "") + ")")


if __name__ == "__main__":
    main()
