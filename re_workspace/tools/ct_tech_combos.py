#!/usr/bin/env python3
"""Chrono Trigger dual and triple techs, end to end: what a combination is in
the ROM, how the battle and field menus list it, how it is learnt, and how
many there can be.

A combination is spread over the battle tables (ct_techs.py) and the field
menu's own copies:

  ComboTechs     $CC:2778  5 B per record, $FF-ended: members' bits ($80 >> id), first id,
                           count, the bank-$CC address of 3 requirement bytes per tech
  UserSets       $CC:249F  each combination tech's set holds exactly its record's members,
                           in the order its parts follow (user k runs part k)
  TechMenuRec    $CC:24B3  3 B per pair record 0-14: $FF, then the two members (ids, ascending);
                           BankFF_UnkF813 reads bytes 1 and 2 as columns of the cost grid
  TechMenuTiles  $CC:28DB  6 B per pair record: per double, the two members' MP indexes
  TechLineTiles  $CC:2935  3 B per trio record 0-9: per member (bit order), its MP index
  ComboNeeds     $CC:2953  3 B per rock combination 0-4: 1-based Menu_TechBits bit numbers
  ByteMembers    $CC:2963  1 B per Menu_TechBits byte (37 read): the characters it needs.
                           Bytes 22-36 (the triples) are read past the 22 B table, so they are
                           TechLineBits ($CC:2979, the trio records' members) and, for
                           $70-$74, ComboMembers ($CC:2983, the rock combinations' members)

The state and the code fix every id to a record (the capacity proof):
  - BattleSys_UnkCA1A lists the doubles $39-$65 from Battle_TechBits2, 3 per byte from bit 7;
    BattleSys_UnkCCCB the triples $66-$74 from Battle_TechBits3, 1 per byte in bit 7;
    Menu_TechFirstIds does the same for the field menu. So pair record i is byte i and ids
    $39 + 3i..$3B + 3i; trio record j is byte 15 + j and id $66 + j.
  - BattleSys_AwardTechPoints sets the found record's bits at $2830 + 14 + its index.
  - Triple bytes 10-14 ($70-$74) belong to the rock combinations: Menu_Unk834D (each menu
    exit) runs BankFF_UnkF958, then Menu_Unk82E1 zeroes the 5 bytes and sets $80 for each
    character wearing rock $AE + r when combination r is available.
  So the 30 state bytes hold 15 pair records (45 doubles, all used), 10 trio records and
  5 rock triples: there is no room for a new combination. A record can be repurposed
  (other members, user sets, requirements, parts) within its ids.

`check` re-derives the claims from the ROM's code and data, and from ChronoRET's
source; `check --run` also runs the routines in ChronoRET's 65816 interpreter
over every ROM combination and compares them with the model:
  - BattleSys_UnkCA1A / UnkCCCB, the battle menu's list (entries 10-15 and 18:
    ids, MP per member, accessory cuts, partners);
  - BattleSys_AwardTechPoints with BuildComboMasks and LearnComboTechs, each record
    with its members at their requirements and one short;
  - BankFF_UnkF813 (the shown bytes and the field menu's MP index grid) with
    Menu_TechListBytes / Menu_TechListIds (each member's list on pages 1 and 2);
  - BankFF_UnkF958 and Menu_Unk82E1, the rock path.

No ROM bytes are kept here.

    ct_tech_combos.py model [--rom PATH]          the combinations as the model sees them (JSON)
    ct_tech_combos.py check [--rom PATH] [--run]  every claim (exit 1 on a failure)
"""

import argparse
import itertools
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_techs as T  # noqa: E402

pc = T.pc
REF = T.REF

PAIR_RECORDS, TRIO_RECORDS, ROCKS = 15, 10, 5
COMBO_STATE_BYTES = T.COMBO_BYTES                    # 30: 15 pair bytes, 15 triple bytes
DOUBLES_PER_BYTE = 3
FIRST_ROCK = T.FIRST_TRIPLE + TRIO_RECORDS           # $70
MENU_REC_PC = pc(0xCC, 0x24B3)                       # MenuRom_TechMenuRec
MENU_TILES_PC = pc(0xCC, 0x28DB)                     # MenuRom_TechMenuTiles
LINE_TILES_PC = pc(0xCC, 0x2935)                     # MenuRom_TechLineTiles
COMBO_NEEDS_PC = pc(0xCC, 0x2953)                    # MenuRom_ComboNeeds
BYTE_MEMBERS_PC = pc(0xCC, 0x2963)                   # MenuRom_TechByteMembers (37 read)
LINE_BITS_PC = pc(0xCC, 0x2979)                      # MenuRom_TechLineBits
COMBO_MEMBERS_PC = pc(0xCC, 0x2983)                  # MenuRom_ComboMembers
MENU_BYTES = 37
ROCK_FIRST_ACCESSORY = 0xAE
FIRST_IDS = [1 + 8 * c for c in range(7)] + [T.FIRST_DOUBLE + 3 * i for i in range(PAIR_RECORDS)] + \
    [T.FIRST_TRIPLE + j for j in range(15)]          # Menu_TechFirstIds


def bit(c):
    return 0x80 >> c


def mask_of(chars):
    m = 0
    for c in chars:
        m |= bit(c)
    return m


# --- Decode -----------------------------------------------------------------------------

def decode_menu(rom):
    """The field menu's combination tables."""
    return {
        "byte_members": list(rom[BYTE_MEMBERS_PC:BYTE_MEMBERS_PC + MENU_BYTES]),
        "menu_rec": [list(rom[MENU_REC_PC + 3 * i:MENU_REC_PC + 3 * i + 3]) for i in range(PAIR_RECORDS)],
        "menu_tiles": [[list(rom[MENU_TILES_PC + 6 * i + 2 * k:MENU_TILES_PC + 6 * i + 2 * k + 2]) for k in range(3)]
                       for i in range(PAIR_RECORDS)],
        "line_bits": list(rom[LINE_BITS_PC:LINE_BITS_PC + 15]),
        "line_tiles": [list(rom[LINE_TILES_PC + 3 * j:LINE_TILES_PC + 3 * j + 3]) for j in range(TRIO_RECORDS)],
        "combo_needs": [list(rom[COMBO_NEEDS_PC + 3 * r:COMBO_NEEDS_PC + 3 * r + 3]) for r in range(ROCKS)],
        "combo_members": list(rom[COMBO_MEMBERS_PC:COMBO_MEMBERS_PC + ROCKS]),
    }


def model(rom):
    """Every combination slot of the 30 state bytes: its ids, members, record,
    requirements, each tech's user set and each member's battle part and MP and
    field-menu MP index."""
    d = T.decode_all(rom) if REF.exists() else None
    techs = [T.decode_tech(rom, t) for t in range(T.TECHS)]
    sets = T.user_sets(rom)
    menu = decode_menu(rom)
    mp = [rom[T.MP_COST_PC + p] for p in range(T.PARTS)]
    records = T.decode_combos(rom)
    out = []
    for i in range(COMBO_STATE_BYTES):
        if i < len(records):
            r = records[i]
            who, ids, reqs = T.members(r["mask"]), [r["first"] + k for k in range(r["count"])], r["requirements"]
            kind = "pair" if i < PAIR_RECORDS else "trio"
        else:
            rock = i - PAIR_RECORDS - TRIO_RECORDS
            m = menu["combo_members"][rock]
            who, ids, reqs, kind = T.members(m), [FIRST_ROCK + rock], None, "rock"
        slot = {"index": i, "kind": kind, "members": who, "mask": mask_of(who), "ids": ids, "requirements": reqs,
                "state_byte": i, "techs": []}
        for k, t in enumerate(ids):
            v = techs[t]
            users = sets[v["user_set"]]
            per = []
            for c in who:
                u = users.index(c) if c in users else None
                part = None if u is None else v["parts"][u]
                if kind == "pair":
                    cols = menu["menu_rec"][i][1:]
                    menu_index = menu["menu_tiles"][i][k][cols.index(c)] if c in cols else None
                elif kind == "trio":
                    menu_index = menu["line_tiles"][i - PAIR_RECORDS][who.index(c)]
                else:
                    menu_index = None
                per.append({"char": c, "user": u, "part": part,
                            "mp": None if part is None else mp[part & 0x7F],
                            "menu_index": menu_index, "menu_mp": None if menu_index is None else mp[menu_index]})
            slot["techs"].append({"id": t, "bit": bit(k), "user_set": v["user_set"], "users": users,
                                  "needs_unlock": v["needs_unlock"], "target_mode": v["target_mode"],
                                  "area": v["area"], "members": per,
                                  "name": d["techs"][t]["name"] if d else None})
        if kind == "rock":
            slot["needs"] = menu["combo_needs"][i - PAIR_RECORDS - TRIO_RECORDS]
            slot["accessory"] = ROCK_FIRST_ACCESSORY + i - PAIR_RECORDS - TRIO_RECORDS
        out.append(slot)
    return out


def single_of_bit(n):
    """A 1-based Menu_TechBits bit number of a single: (character, single index)."""
    return (n - 1) // 8, (n - 1) % 8


# --- Claims -----------------------------------------------------------------------------

def code_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    def body(bank, start, end):
        return T._body(rom, bank, start, end)

    ca1a = body(0xC1, 0xCA1A, 0xCB47)
    claim("BattleSys_UnkCA1A: ids $39-$65 from Battle_TechBits2 ($283E), 3 per byte, at most 6 entries",
          T._has(ca1a, b"\xa9\x39", b"\xa9\x66", b"\xbd\x3e\x28", b"\xc9\x03", b"\xc9\x06"))
    cccb = body(0xC1, 0xCCCB, 0xCDFE)
    claim("BattleSys_UnkCCCB: ids $66-$74 from Battle_TechBits3 ($284D), one per byte",
          T._has(cccb, b"\xa9\x66", b"\xa9\x75", b"\xbd\x4d\x28"))
    first = list(rom[pc(0xC2, 0xBD40):pc(0xC2, 0xBD40) + MENU_BYTES])
    claim("Menu_TechFirstIds: 7 bytes of 8 singles, 15 of 3 doubles from $39, 15 of 1 triple from $66",
          first == FIRST_IDS)
    claim("Menu_TechPages: pages at bytes 0 (7), 7 (15) and 22 (15)",
          list(rom[pc(0xC2, 0xBD65):pc(0xC2, 0xBD65) + 6]) == [0, 7, 7, 15, 22, 15])
    award = body(0xC1, 0xF205, 0xF2DA)
    claim("AwardTechPoints: a found record's bits at $2830 + 14 + its index (record = state byte)",
          T._has(award, b"\x69\x3e\x28"))
    f813 = body(0xFF, 0xF813, 0xF950)
    claim("BankFF_UnkF813: 37 Menu_TechBits bytes against MenuRom_TechByteMembers $CC:2963; 15 menu records "
          "($CC:24B3, $CC:28DB) and line bits/tiles ($CC:2979, $CC:2935)",
          T._has(f813, b"\xa2\x24", b"\xbf\x63\x29\xcc", b"\xbf\xb3\x24\xcc", b"\xbf\xdb\x28\xcc",
                 b"\xbf\x79\x29\xcc", b"\xbf\x35\x29\xcc", b"\xc9\x0f"))
    f958 = body(0xFF, 0xF958, 0xF9BA)
    claim("BankFF_UnkF958: 5 rock combinations, members $CC:2983, 3 needed bit numbers each $CC:2953",
          T._has(f958, b"\xbf\x83\x29\xcc", b"\xbf\x53\x29\xcc", b"\xc9\x05"))
    e1 = body(0xC2, 0x82E1, 0x831F)
    claim("Menu_Unk82E1: zeroes $2857 (triple bytes 10-14) and sets $80 for a record wearing $AE-$B2",
          T._has(e1, b"\x9c\x57\x28", b"\xc9\xae", b"\xc9\xb3", b"\xa9\x80"))
    lb = body(0xC2, 0xBCCD, 0xBCFF)
    claim("Menu_TechListBytes: a page's bytes whose MenuRom_TechByteMembers has the character's bit",
          T._has(lb, b"\xbf\x63\x29\xcc", b"\xbf\x65\xbd\xc2"))
    learn = body(0xC1, 0xF533, 0xF622)
    claim("LearnComboTechs: TechRec byte 0 bit 7 skips the tech, with no $7F:01E0 test (a combination that "
          "needs the unlock is never learnt by tech points)",
          T._has(learn, b"\xbf\xeb\x1b\xcc\x29\x80\xd0") and b"\xe0\x01\x7f" not in learn)
    return out


def data_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    m = model(rom)
    menu = decode_menu(rom)
    records = T.decode_combos(rom)
    claim("records 0-14 are pairs at state bytes 0-14 with ids $39 + 3i, 3 each; 15-24 trios at bytes 15-24 "
          "with id $66 + j", all(s["ids"] == [T.FIRST_DOUBLE + 3 * s["index"] + k for k in range(3)] for s in m[:15])
          and all(s["ids"] == [T.FIRST_TRIPLE + s["index"] - 15] for s in m[15:25]) and len(records) == 25)
    claim("the 5 triple bytes past the records ($70-$74) are the rock combinations",
          [s["ids"][0] for s in m[25:]] == list(range(FIRST_ROCK, T.TECHS)) and all(s["kind"] == "rock" for s in m[25:]))
    claim("every state byte is used: 45 doubles, 10 trio triples, 5 rock triples (no free combination)",
          sum(len(s["ids"]) for s in m) == T.TECHS - T.FIRST_DOUBLE)
    claim("ByteMembers bytes 7-21 are the pair records' masks",
          menu["byte_members"][7:22] == [s["mask"] for s in m[:15]])
    claim("ByteMembers bytes 22-36, read past its 22 B, are TechLineBits then ComboMembers",
          menu["byte_members"][22:] == menu["line_bits"][:10] + menu["combo_members"])
    claim("TechLineBits 0-9 are the trio records' masks", menu["line_bits"][:10] == [s["mask"] for s in m[15:25]])
    sets = T.user_sets(rom)
    claim("TechMenuRec record i is the bytes of user sets 6-7 + i: bytes 1-2 are set 7 + i's first two ids",
          MENU_REC_PC + 1 == T.USER_SETS_PC + 3 * 7
          and all(menu["menu_rec"][i][1:] == sets[7 + i][:2] for i in range(15)))
    claim("user set 7 + i holds pair record i's members (the field menu's two cost columns)",
          all(sorted(sets[7 + i][:2]) == m[i]["members"] and sets[7 + i][2] == T.NONE for i in range(15)))
    claim("each rock triple's user set holds its ComboMembers",
          all(sorted(c for c in sets[T.decode_tech(rom, s["ids"][0])["user_set"]] if c != T.NONE) == s["members"]
              for s in m[25:]))
    bad = []
    for s in m[25:]:
        for n in s["needs"]:
            c, _ = single_of_bit(n)
            if c not in s["members"]:
                bad.append(s["ids"][0])
    claim("each rock combination needs one single of each member (ComboNeeds)", not bad, repr(bad))
    differ = sorted({t["id"] for s in m[:25] for t in s["techs"] for p in t["members"] if p["mp"] != p["menu_mp"]})
    total = sum(len(t["members"]) for s in m[:25] for t in s["techs"])
    count = sum(1 for s in m[:25] for t in s["techs"] for p in t["members"] if p["mp"] != p["menu_mp"])
    claim("the field menu's MP index gives the battle part's MP to every member but three, in $5E, $67 and $6A "
          "(the menu shows another cost there)", differ == [0x5E, 0x67, 0x6A] and count == 3,
          f"{total - count} of {total} agree; differing {[f'${t:02X}' for t in differ]}")
    claim("no combination tech needs the unlock (LearnComboTechs would never learn it)",
          not any(t["needs_unlock"] for s in m for t in s["techs"]))
    used = {t["user_set"] for s in m for t in s["techs"]}
    shared = [n for n in used if len({s["index"] for s in m for t in s["techs"] if t["user_set"] == n}) > 1]
    claim("no user set is shared by two combinations", not shared, repr(shared))
    return out


# --- The interpreter ---------------------------------------------------------------------

class Rom65816:
    """ChronoRET's interpreter over `image` with a zeroed WRAM: `call`
    returns the memory after the routine at `entry` ends once."""

    def __init__(self, image, ref=REF):
        if str(ref / "tools") not in sys.path:
            sys.path.insert(0, str(ref / "tools"))
        import absint
        self.absint = absint
        self.machine = absint.Machine(bytes(image), bytearray(b"\x01") * len(image),
                                      max_steps=10 ** 7, callee_steps=10 ** 6)
        self.machine.widen_after = 10 ** 9
        self.zero = {a: 0 for a in range(0x7E0000, 0x7EC000)}
        self.zero.update({a: 0 for a in range(0x7F0000, 0x7F0300)})

    def call(self, entry, memory, m=True, x16=True, db=0x7E, how="rts"):
        known = dict(self.zero)
        known.update(memory)
        s = self.absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, 0, 0, 0, 0
        s.d, s.db, s.m, s.xf, s.c = 0, db, m, not x16, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = self.absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != how or self.machine.opaque:
            raise RuntimeError(f"${entry:06X}: {[e for _, e in ends]} opaque {self.machine.opaque}")
        mem = {**known, **ends[0][0].mem}
        return mem


TECH_BITS = 0x7E2830 + 7                             # Menu_TechBits / Battle_TechBits1 ($2837)
BITS2, BITS3 = 0x7E283E, 0x7E284D
SLOT_IDS, CHAR_SLOT, CUTS = 0x7EAEFF, 0x7EB1BE, 0x7EB3BA
ENTRY_PTR_PC, ENTRY_SIZE = pc(0xFD, 0xA84F), 7


def battle_menu_memory(party, bits2, bits3, cuts):
    mem = {}
    for c in range(7):
        mem[CHAR_SLOT + c] = 0xFF
    for n, c in enumerate(party):
        mem[SLOT_IDS + n] = 0xFF if c is None else c
        if c is not None:
            mem[CHAR_SLOT + c] = n
        mem[CUTS + n] = cuts[n]
    for i, b in enumerate(bits2):
        mem[BITS2 + i] = b
    for i, b in enumerate(bits3):
        mem[BITS3 + i] = b
    return mem


def cut(cost, acc):
    if acc == 0xA2:
        return (cost >> 1) + (cost & 1)
    if acc == 0xA3:
        half = (cost >> 1) + (cost & 1)
        return (half >> 1) + (half & 1)
    return cost


def model_battle_entries(rom, party, slot, bits2, bits3, cuts):
    """What BattleSys_UnkCA1A and UnkCCCB put in slot `slot`'s entries 10-15 and 18."""
    sets = T.user_sets(rom)
    techs = [T.decode_tech(rom, t) for t in range(T.TECHS)]
    info = [list(rom[T.TECH_INFO_PC + 2 * t:T.TECH_INFO_PC + 2 * t + 2]) for t in range(T.TECHS)]
    mp = [rom[T.MP_COST_PC + p] for p in range(T.PARTS)]
    where = {c: n for n, c in enumerate(party) if c is not None}

    def entry(t, users):
        e = [t, info[t][0], info[t][1] & 0x3F, 0xFF, 0, 0xFF, 0xFF]
        for k, c in enumerate(users):
            cost = cut(mp[techs[t]["parts"][k] & 0x7F], cuts[where[c]])
            e[(3, 5, 6)[min(where[c], 2)]] = cost
        return e

    doubles = []
    if party[slot] is not None:
        for t in range(T.FIRST_DOUBLE, T.FIRST_TRIPLE):
            i, k = divmod(t - T.FIRST_DOUBLE, 3)
            users = sets[techs[t]["user_set"]][:2]
            if not bits2[i] & bit(k) or any(c == T.NONE or c not in where for c in users):
                continue
            if slot not in (where[users[0]], where[users[1]]):
                continue
            e = entry(t, users)
            other = where[users[1]] if where[users[1]] != slot else where[users[0]]
            e[4] = 0xF0 | other
            doubles.append(e)
            if len(doubles) == 6:
                break
    triple = None
    if party[slot] is not None:
        for t in range(T.FIRST_TRIPLE, T.TECHS):
            users = sets[techs[t]["user_set"]]
            if not bits3[t - T.FIRST_TRIPLE] & 0x80 or any(c == T.NONE or c not in where for c in users):
                continue
            e = entry(t, users)
            slots = [where[c] for c in users]
            lo, hi = slots[1], slots[2]
            if lo == slot:
                lo = slots[0]
            if hi == slot:
                hi = slots[0]
            e[4] = hi << 4 | lo
            triple = e
            break
    return doubles, triple


def battle_menu_runs(rom, runner=None):
    """BattleSys_UnkCA1A and UnkCCCB for every record's members with a third
    member or none, each slot, all bits and a sparse pattern, with and without
    MP cuts: [(name, ok, detail)]."""
    runner = runner or Rom65816(rom)
    out, runs, bad = [], 0, []
    m = model(rom)
    for s in m:
        who = s["members"]
        others = [c for c in range(7) if c not in who]
        parties = []
        if len(who) == 2:
            parties += [(who[0], who[1], None), (others[0], who[1], who[0]), (who[1], others[-1], who[0])]
        else:
            parties += [tuple(who), (who[2], who[0], who[1])]
        for party, (bits2, bits3, cuts) in itertools.product(parties, (
                ([0xE0] * 15, [0x80] * 15, [0, 0, 0]),
                ([0x40 if i % 2 else 0xA0 for i in range(15)], [0x80 * (j % 2) for j in range(15)], [0xA2, 0, 0xA3]))):
            for slot in range(3):
                known = battle_menu_memory(party, bits2, bits3, cuts)
                known[0x7E0006] = slot
                base = T.u(rom, ENTRY_PTR_PC + 2 * slot, 2)
                got = runner.call(0xC1CA1A, known)
                got = runner.call(0xC1CCCB, {**known, **{a: got[a] for a in range(0x7E1A80, 0x7E1C30)}})
                runs += 2
                doubles, triple = model_battle_entries(rom, party, slot, bits2, bits3, cuts)
                rows = [[got[0x7E0000 + base + ENTRY_SIZE * (10 + n) + b] for b in range(ENTRY_SIZE)] for n in range(6)]
                want = doubles + [[0] * ENTRY_SIZE] * (6 - len(doubles))
                row18 = [got[0x7E0000 + base + ENTRY_SIZE * 18 + b] for b in range(ENTRY_SIZE)]
                if rows != want or row18 != (triple or [0] * ENTRY_SIZE):
                    bad.append((s["index"], party, slot))
    listed = sum(1 for s in m for _ in s["ids"])
    out.append((f"BattleSys_UnkCA1A + UnkCCCB = the model's battle menu ({runs} runs over the "
                f"{len(m)} combinations, {listed} techs)", not bad, repr(bad[:4])))
    return out


def learn_runs(rom, image=None):
    """AwardTechPoints (BuildComboMasks, LearnComboTechs) for each record: its
    members at the requirements learn the tech; one member short does not."""
    image = image or rom
    runner = T.RomTechPoints(image)
    t = T.tables(image)
    out, bad, runs = [], [], 0
    for i, rec in enumerate(T.decode_combos(image)):
        who = T.members(rec["mask"])
        party = who + [None] * (3 - len(who))
        for k in range(rec["count"]):
            req = rec["requirements"][k]
            for short in [None] + list(range(len(who))):
                s = T.starting_state(image, party, 0)
                s["counts"] = [8 if c not in who else req[who.index(c)] for c in range(7)]
                if short is not None:
                    s["counts"][who[short]] -= 1
                s["bits1"] = [(0xFF00 >> n) & 0xFF for n in s["counts"]]
                s["combo_bits"] = [0] * T.COMBO_BYTES
                for slot in s["slots"]:
                    if slot is not None:
                        slot["flags"] = T.ALL_TECHS
                got, want = runner.award(s, 0), T.award_tech_points(t, s, 0)
                runs += 1
                learnt = bool(got["combo_bits"][i] & bit(k))
                expect = short is None and not t["needs_unlock"][rec["first"] + k]
                if got != want or learnt != expect:
                    bad.append((i, k, short))
    out.append((f"AwardTechPoints learns each combination tech at its requirements and not one short "
                f"({runs} runs)", not bad, repr(bad[:4])))
    return out


PARTY_ORDER, CUR_CHAR, TECH_PAGE = 0x7E2980, 0x7E9A90, 0x7E0418
TECH_SHOWN, TECH_LIST, TECH_BYTE_OF, TECH_COUNT = 0x7E7F00, 0x7E0F00, 0x7E0F30, 0x7E0F49
COST_GRID = 0x7E1640


def model_field(rom, party, bits):
    """BankFF_UnkF813's shown bytes (combination bytes only), the MP index grid,
    and each member's list on pages 1 and 2."""
    menu = decode_menu(rom)
    present = mask_of(c for c in party if c is not None)
    shown = [bits[b] if not menu["byte_members"][b] & ~present & 0xFE else 0 for b in range(MENU_BYTES)]
    grid = {}
    for i in range(PAIR_RECORDS):
        a, b = menu["menu_rec"][i][1:]
        for k in range(3):
            grid[(a, 3 * i + k)] = menu["menu_tiles"][i][k][0]
            grid[(b, 3 * i + k)] = menu["menu_tiles"][i][k][1]
    flat = [x for row in menu["line_tiles"] for x in row]
    n = 0
    for r in range(15):
        for c in T.members(menu["line_bits"][r]) if menu["line_bits"][r] & 0xFE == menu["line_bits"][r] else []:
            if n < len(flat):
                grid[(c, 45 + r)] = flat[n]
            n += 1
    lists = {}
    for c in party:
        if c is None:
            continue
        for page, (start, count) in ((1, (7, 15)), (2, (22, 15))):
            ids = []
            for b in range(start, start + count):
                if not menu["byte_members"][b] & bit(c):
                    continue
                end = FIRST_IDS[b + 1] if b + 1 < MENU_BYTES else FIRST_IDS[b] + 1
                for k, t in enumerate(range(FIRST_IDS[b], end)):
                    if shown[b] & bit(k):
                        ids.append(t)
            lists[(c, page)] = ids
    return shown, grid, lists


def field_menu_runs(rom, runner=None):
    """BankFF_UnkF813, then Menu_TechListBytes + ListIds for each member and
    page, for each combination's members with all bits and a sparse pattern."""
    runner = runner or Rom65816(rom)
    bad, runs = [], 0
    for s in model(rom):
        who = s["members"]
        party = who + [c for c in range(7) if c not in who][:3 - len(who)]
        for bits in ([0xFF] * 7 + [0xE0] * 15 + [0x80] * 15,
                     [0xFF] * 7 + [0xA0 if i % 2 else 0x40 for i in range(15)] + [0x80 * (j % 2) for j in range(15)]):
            known = {PARTY_ORDER + n: party[n] if n < 3 else 0x80 for n in range(9)}
            known.update({TECH_BITS + b: v for b, v in enumerate(bits)})
            got = runner.call(0xFFF813, known, m=False, how="rtl")
            runs += 1
            shown, grid, lists = model_field(rom, party, bits)
            if [got[TECH_SHOWN + b] for b in range(7, MENU_BYTES)] != shown[7:]:
                bad.append((s["index"], "shown"))
            if any(got[COST_GRID + 64 * c + col] != v for (c, col), v in grid.items()):
                bad.append((s["index"], "grid"))
            for (c, page), ids in lists.items():
                listing = {a: got[a] for a in range(TECH_SHOWN, TECH_SHOWN + MENU_BYTES)}
                listing.update({CUR_CHAR: c, TECH_PAGE: page})
                mem = runner.call(0xC2BCCD, listing, x16=False)
                mem = runner.call(0xC2BD00, {**listing, **{a: mem[a] for a in range(0x7E9890, 0x7E98B0)}}, x16=False)
                runs += 2
                n = mem[TECH_COUNT]
                if [mem[TECH_LIST + q] for q in range(n)] != ids:
                    bad.append((s["index"], c, page))
    return [(f"BankFF_UnkF813 + Menu_TechListBytes/ListIds = the model's field menu ({runs} runs)",
             not bad, repr(bad[:4]))]


ROCK_FLAGS, CHAR_RECORDS = 0x7E04A4, 0x7E2600


def rock_runs(rom, runner=None):
    """BankFF_UnkF958 for each rock combination: its members present and its
    three singles learnt make it available; one single or one member missing
    does not. Menu_Unk82E1 then marks a wearer's triple byte."""
    runner = runner or Rom65816(rom)
    menu = decode_menu(rom)
    bad, runs = [], 0
    for r in range(ROCKS):
        who = T.members(menu["combo_members"][r])
        needs = menu["combo_needs"][r]
        for missing in [None, "member"] + list(range(3)):
            party = list(who) if missing != "member" else [c for c in range(7) if c not in who][:1] + who[1:]
            bits = [0] * MENU_BYTES
            for q, n in enumerate(needs):
                if missing != q:
                    bits[(n - 1) >> 3] |= bit((n - 1) & 7)
            known = {PARTY_ORDER + n: party[n] if n < len(party) else 0x80 for n in range(9)}
            known.update({TECH_BITS + b: v for b, v in enumerate(bits)})
            got = runner.call(0xFFF958, known, how="rtl")
            runs += 1
            want = [1 if q == r and missing is None else got[ROCK_FLAGS + q] for q in range(ROCKS)]
            if got[ROCK_FLAGS + r] != (1 if missing is None else 0):
                bad.append((r, missing))
            wear = dict(known)
            wear.update({ROCK_FLAGS + q: want[q] for q in range(ROCKS)})
            wear[CHAR_RECORDS + 0x50 * who[0] + 0x2A] = ROCK_FIRST_ACCESSORY + r
            mem = runner.call(0xC282E1, wear)
            runs += 1
            if mem[0x7E2857 + r] != (0x80 if missing is None else 0):
                bad.append((r, missing, "82E1"))
    return [(f"BankFF_UnkF958 + Menu_Unk82E1 = the rock path ({runs} runs)", not bad, repr(bad[:4]))]


def run_claims(rom):
    runner = Rom65816(rom)
    return battle_menu_runs(rom, runner) + learn_runs(rom) + field_menu_runs(rom, runner) + rock_runs(rom, runner)


ASM_CLAIMS = (
    ("bankC1/bankC1.asm", "BattleSys_UnkCA1A",
     ("LDA.b #!Tech_FirstComboId", "LDA.b #!Tech_FirstTripleId", "LDA.w !Battle_TechBits2,X",
      "JSR BattleSys_LoadTechUsers", "LDA.w !Battle_UnkB1BE,X", "JSR BattleSys_StoreMpCost10",
      "ORA.b #!Tech_PartnerHiMask", "CMP.b #!Battle_MaxDoubleEntries", "CMP.b #!Battle_DoubleBitsPerByte")),
    ("bankC1/bankC1.asm", "BattleSys_UnkCCCB",
     ("LDA.b #!Tech_FirstTripleId", "LDA.b #!Tech_TripleEnd", "LDA.w !Battle_TechBits3,X",
      "JSR BattleSys_LoadTechUsers")),
    ("bankFF/bankFF.asm", "BankFF_UnkF813",
     ("JSL BankFF_UnkF958", "LDA.l !MenuRom_TechByteMembers,X", "LDA.l !MenuRom_TechMenuRec,X",
      "LDA.l !MenuRom_TechMenuTiles,X", "LDA.l !MenuRom_TechLineBits,X", "LDA.l !MenuRom_TechLineTiles,X")),
    ("bankFF/bankFF.asm", "BankFF_UnkF958",
     ("LDA.l !MenuRom_ComboMembers,X", "LDA.l !MenuRom_ComboNeeds,X", "AND.w !Menu_TechBits,Y",
      "CMP.b #!BankFF_ComboCount")),
    ("bankC2/bankC2.asm", "Menu_Unk82E1",
     ("STZ.w !Menu_Unk2857", "CMP.b #!Menu_Unk82E1First", "CMP.b #!Menu_Unk82E1End", "LDA.b #!Menu_Unk2857Mark")),
    ("bankC2/bankC2.asm", "Menu_TechListIds",
     ("LDA.w !Menu_TechShown,X", "LDA.l Menu_TechFirstIds+1,X", "LDA.l Menu_TechFirstIds,X")),
)


def asm_claims(ref=REF):
    saved = T.ASM_CLAIMS
    try:
        T.ASM_CLAIMS = ASM_CLAIMS
        return T.asm_claims(ref)
    finally:
        T.ASM_CLAIMS = saved


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("model").add_argument("--rom", default=str(T.ROM_PATH))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(T.ROM_PATH))
    k.add_argument("--run", action="store_true", help="also run the routines in the interpreter")
    args = parser.parse_args()
    rom = T.read_rom(args.rom)
    if args.command == "model":
        print(json.dumps(model(rom), indent=1))
        return
    results = code_claims(rom) + data_claims(rom) + (asm_claims() if REF.exists() else [])
    if args.run:
        results += run_claims(rom)
    for name, ok, detail in results:
        print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f"  [{detail}]" if detail else ""))
    failed = [r for r in results if not r[1]]
    print(f"{len(results) - len(failed)} of {len(results)} combination claims hold")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
