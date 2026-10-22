#!/usr/bin/env python3
"""Chrono Trigger techs: single, double and triple techs, tech points, evidence.

Tech ids run from 0 to $74: id 0 is no tech, $01-$38 the 56 single techs (8
per character, character c's first is 1 + 8c), $39-$65 the 45 double techs
and $66-$74 the 15 triple techs. The battle code reads them from bank $CC:

  TechNames   $CC:15C4  11 B per id: an optional icon byte, then glyphs ($EF pads)
  TechInfo    $CC:1ACB   2 B per id: menu target mode (+ field-menu bit 7), area number
  TechRec     $CC:1BEB  11 B per id: user set, flags, element, 3 parts, 3 modifiers
  Effects     $CC:213F  12 B per part number (72): what one part does
  UserSets    $CC:249F   3 B per set (52): the character ids that perform a tech
  MpCost      $CC:253B   1 B per part number
  TechTpCost  $CC:26FA   8 words per character: the tech points for single k
  CharTechs   $CC:276A   2 B per character: first single id, how many
  ComboTechs  $CC:2778   5 B per record, $FF-ended: members' bits, first id, count,
                         address of 3 requirement bytes per tech
  PcTechAct   $CD:45A6   7 B per id: the animation (script number, graphics, frames)

The tech state lives in the eighth record of MenuRom_CharRecordInit ($CC:0230,
copied to $7E:2830 for a new game): each character's count of single techs
learned, its single-tech bits, then one byte per ComboTechs record holding the
double (3 per byte) or triple (bit 7) tech bits. The rule that pays tech points
into it (BattleSys_AwardTechPoints $C1:F205 and its callees) is
`award_tech_points`. Each claim is re-derived three ways by `check`: from the
ROM's code bytes, from ChronoRET's matched source (MIT; refs/ChronoRET), and
from the ROM's data. `check --run` (and tests/test_techs.py) also runs the
ROM's own AwardTechPoints in ChronoRET's 65816 interpreter and compares it
with `award_tech_points`: for the ROM's starting state in several parties, and
for the synthetic vectors with their tables patched into a copy of the ROM.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_techs.py decode [--rom PATH]           every tech, part, combination and table (JSON)
    ct_techs.py check [--rom PATH] [--run]    every evidence claim (exit 1 on a failure);
                                              --run also executes the ROM's routine
    ct_techs.py vectors (--out | --check) P   synthetic tech-point vectors for the Swift tests
"""

import argparse
import copy
import json
import re
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
REF = WS / "refs" / "ChronoRET"
ROM_PATH = WS / "ct_clean.sfc"
ROM_SIZE = 4 * 1024 * 1024


def pc(bank, addr):
    """HiROM file offset of $bank:addr."""
    return (bank & 0x3F) << 16 | addr


def u(data, at, size):
    return int.from_bytes(data[at:at + size], "little")


# --- Tables --------------------------------------------------------------------------

CHARACTERS = 7
NAMES = ("crono", "marle", "lucca", "robo", "frog", "ayla", "magus")
TECHS = 0x75                         # ids 0-$74 (Tech_TripleEnd)
FIRST_DOUBLE, FIRST_TRIPLE = 0x39, 0x66
SINGLES_PER_CHARACTER = 8

TECH_NAMES_PC = pc(0xCC, 0x15C4)     # BattleRom_TechNames
NAME_SIZE = 11
TECH_INFO_PC = pc(0xCC, 0x1ACB)      # BattleRom_TechInfo
TECH_REC_PC = pc(0xCC, 0x1BEB)       # BattleRom_TechRec
TECH_REC_SIZE = 11
EFFECTS_PC = pc(0xCC, 0x213F)        # BattleRom_UnkCC213F
EFFECT_SIZE = 12
PARTS = 72                           # effect records and MP costs, by part number
USER_SETS_PC = pc(0xCC, 0x249F)      # BattleRom_TechUserSets
USER_SETS = 52                       # to MpCost
MP_COST_PC = pc(0xCC, 0x253B)        # BattleRom_TechMpCost
TP_COST_PC = pc(0xCC, 0x26FA)        # BattleRom_TechTpCost
CHAR_TECHS_PC = pc(0xCC, 0x276A)     # BattleRom_CharTechs
COMBOS_PC = pc(0xCC, 0x2778)         # BattleRom_ComboTechs
COMBO_SIZE = 5
MODIFIERS_PC = pc(0xCC, 0x2A05)      # BattleRom_UnkCC2A05: 3 B per record, up to AreaRecPtr
MODIFIERS = (0x2AB0 - 0x2A05) // 3
AREA_PTRS_PC = pc(0xCC, 0x2AB0)      # BattleRom_AreaRecPtr
AREAS = 0x0C                         # area numbers 0 (none) to $0B
CHAR_FIRST_TECH_PC = pc(0xFD, 0xA89D)
TECH_ACT_PC = pc(0xCD, 0x45A6)       # BattleRom_PcTechAct
TECH_ACT_SIZE = 7
SCRIPTS = 128                        # BattleRom_PcTechScripts: 2 B per script number
TECH_STATE_PC = pc(0xCC, 0x0230)     # the eighth MenuRom_CharRecordInit record
COMBO_BYTES = 30                     # Battle_TechBits2 (15) + Battle_TechBits3 (15)
TECH_STATE_SIZE = 2 * CHARACTERS + COMBO_BYTES
RECORDS_PC, RECORD_SIZE = pc(0xCC, 0x0000), 0x50

TARGET_MODES = 0x21                  # BattleTgt_ModeTable: 33 handlers
EFFECT_TYPES = 45                    # BattleSys_EffectTable: 45 handlers
MODIFIER_KINDS = 21                  # BattleSys_HitModTable: 21 handlers
AREA_SHAPES = 7                      # BattleSys_AreaTable
AREA_PARAMS = 7                      # BattleSys_AreaParamTable
ANIM_FRAMES = 80

NEEDS_UNLOCK = 0x80                  # TechRec byte 0 bit 7 (Battle_TechNeedsUnlock)
PART_NONE = 0x80                     # a part byte with bit 7 runs nothing (Battle_TechPartNone)
ALL_TECHS = 0x10                     # record +$02 (BattlerStats.Unk2F) bit 4
TOTAL_CAP_HI, TOTAL_CAP_LO = 0x98, 0x967F
NONE = 0xFF

# Element: TechRec byte 3 bits 7-4, the first set picks the target's
# resistance byte n (BattleSys_HitModUnk6CScale); the names give the element.
ELEMENTS = ("lightning", "shadow", "water", "fire")     # bits 7, 6, 5, 4
EFFECT_FIELDS = ("type", "arg1", "arg2", "caster_stat", "target_stat", "formula", "defence", "flags",
                 "flags2", "power", "immunity", "arg11")
ANIM_FIELDS = ("script", "gfx_a", "gfx_b", "frames", "pal", "obj", "arg")
# The same bytes as tech_system.json (TechSystemDef.Effect) names them.
SWIFT_EFFECT_FIELDS = ("type", "arg1", "arg2", "casterStat", "targetStat", "formula", "defence", "flags", "flags2",
                       "power", "immunity", "arg11")


def kind(tech):
    return "none" if tech == 0 else "single" if tech < FIRST_DOUBLE else "double" if tech < FIRST_TRIPLE else "triple"


# --- Codec ---------------------------------------------------------------------------

def _glyphs(ref=REF):
    if str(ref / "tools") not in sys.path:
        sys.path.insert(0, str(ref / "tools"))
    import text
    return text.GLYPHS


def tech_name(rom, tech, glyphs=None):
    """(icon byte or None, the name): $FF is a space, $EF pads."""
    raw = rom[TECH_NAMES_PC + NAME_SIZE * tech:TECH_NAMES_PC + NAME_SIZE * (tech + 1)]
    icon = raw[0] if raw[0] < 0xA0 and raw[0] not in (0xEF, 0xFF) else None
    glyphs = glyphs if glyphs is not None else _glyphs()
    body = raw[1:] if icon is not None else raw
    name = "".join(" " if b == 0xFF else glyphs.get(b, "?") for b in body if b != 0xEF)
    return icon, name.rstrip()


def element_of(byte3):
    for n, name in enumerate(ELEMENTS):
        if byte3 & (0x80 >> n):
            return name
    return None


def decode_tech(rom, tech):
    rec = rom[TECH_REC_PC + TECH_REC_SIZE * tech:TECH_REC_PC + TECH_REC_SIZE * (tech + 1)]
    info = rom[TECH_INFO_PC + 2 * tech:TECH_INFO_PC + 2 * tech + 2]
    act = rom[TECH_ACT_PC + TECH_ACT_SIZE * tech:TECH_ACT_PC + TECH_ACT_SIZE * (tech + 1)]
    return {"id": tech, "kind": kind(tech),
            "target_mode": info[0] & 0x7F, "field_menu": bool(info[0] & 0x80), "area": info[1],
            "user_set": rec[0] & 0x7F, "needs_unlock": bool(rec[0] & NEEDS_UNLOCK),
            "flags": rec[1], "unk2": rec[2], "element_bits": rec[3] >> 4, "attr": rec[3] & 0x0F, "unk4": rec[4],
            "parts": list(rec[5:8]), "modifiers": list(rec[8:11]),
            "anim": dict(zip(ANIM_FIELDS, act))}


def encode_tech(rom, tech, value):
    """{file offset: byte} of the tech's writable bytes."""
    out = {TECH_INFO_PC + 2 * tech: value["target_mode"] | (0x80 if value["field_menu"] else 0),
           TECH_INFO_PC + 2 * tech + 1: value["area"]}
    at = TECH_REC_PC + TECH_REC_SIZE * tech
    out[at] = value["user_set"] | (NEEDS_UNLOCK if value["needs_unlock"] else 0)
    out[at + 3] = value["element_bits"] << 4 | value["attr"]
    for k in range(3):
        out[at + 5 + k] = value["parts"][k]
        out[at + 8 + k] = value["modifiers"][k]
    act = TECH_ACT_PC + TECH_ACT_SIZE * tech
    for k, name in enumerate(ANIM_FIELDS):
        out[act + k] = value["anim"][name]
    return out


def decode_part(rom, part):
    eff = rom[EFFECTS_PC + EFFECT_SIZE * part:EFFECTS_PC + EFFECT_SIZE * (part + 1)]
    return {"id": part, "mp": rom[MP_COST_PC + part], "effect": dict(zip(EFFECT_FIELDS, eff))}


def tp_words(rom):
    """The words BattleSys_SpendTechPoints can read: the 7 rows of 8, then the
    word after the last row (read for character 6's ninth single)."""
    return [u(rom, TP_COST_PC + 2 * i, 2) for i in range(CHARACTERS * SINGLES_PER_CHARACTER + 1)]


def char_techs(rom):
    return [tuple(rom[CHAR_TECHS_PC + 2 * c:CHAR_TECHS_PC + 2 * c + 2]) for c in range(CHARACTERS)]


def decode_combos(rom):
    """The ComboTechs records up to the $FF mask: mask, first id, count, the
    requirement address (bank $CC) and its 3 bytes per tech."""
    out = []
    at = COMBOS_PC
    while rom[at] != NONE:
        mask, first, count, req = rom[at], rom[at + 1], rom[at + 2], u(rom, at + 3, 2)
        reqs = [list(rom[pc(0xCC, req) + 3 * k:pc(0xCC, req) + 3 * k + 3]) for k in range(count)]
        out.append({"mask": mask, "first": first, "count": count, "req_addr": req, "requirements": reqs})
        at += COMBO_SIZE
    return out


def members(mask):
    """The character ids of a mask's bits, from bit 7 (BattleSys_LearnComboTechs)."""
    return [c for c in range(CHARACTERS) if mask & (0x80 >> c)]


def user_sets(rom):
    return [list(rom[USER_SETS_PC + 3 * s:USER_SETS_PC + 3 * s + 3]) for s in range(USER_SETS)]


def decode_areas(rom):
    """Area number -> its entries (shape, param byte, size byte); area 0 is none."""
    out = [[]]
    for n in range(1, AREAS):
        at = pc(0xCC, u(rom, AREA_PTRS_PC + 2 * n, 2))
        out.append([list(rom[at + 1 + 3 * k:at + 4 + 3 * k]) for k in range(rom[at])])
    return out


def decode_state(rom):
    raw = rom[TECH_STATE_PC:TECH_STATE_PC + TECH_STATE_SIZE]
    return {"counts": list(raw[0:7]), "bits1": list(raw[7:14]), "combo_bits": list(raw[14:44])}


def record_tech_fields(rom, cid):
    rec = rom[RECORDS_PC + RECORD_SIZE * cid:RECORDS_PC + RECORD_SIZE * (cid + 1)]
    return {"flags": rec[2], "tp": u(rec, 0x16, 3), "to_next": u(rec, 0x2D, 2)}


def decode_all(rom):
    glyphs = _glyphs() if REF.exists() else {}
    techs = []
    for t in range(TECHS):
        value = decode_tech(rom, t)
        value["icon"], value["name"] = tech_name(rom, t, glyphs)
        techs.append(value)
    return {"techs": techs, "parts": [decode_part(rom, p) for p in range(PARTS)],
            "user_sets": user_sets(rom), "char_techs": char_techs(rom),
            "tp_cost": [tp_words(rom)[8 * c:8 * c + 8] for c in range(CHARACTERS)],
            "combos": decode_combos(rom), "learned": decode_state(rom), "areas": decode_areas(rom),
            "modifiers": [list(rom[MODIFIERS_PC + 3 * i:MODIFIERS_PC + 3 * i + 3]) for i in range(MODIFIERS)]}


def write_zones(rom):
    """The spans a tech build may write (CTTechROM.writes): TechInfo, TechRec
    bytes 0, 3 and 5-10, PcTechAct's script and frames, MpCost, the effect
    records, TechTpCost, the combination requirements, the new-game state and
    each record's +$02."""
    spans = []
    for t in range(TECHS):
        rec, act = TECH_REC_PC + TECH_REC_SIZE * t, TECH_ACT_PC + TECH_ACT_SIZE * t
        spans += [range(TECH_INFO_PC + 2 * t, TECH_INFO_PC + 2 * t + 2), range(rec, rec + 1), range(rec + 3, rec + 4),
                  range(rec + 5, rec + 11), range(act, act + 1), range(act + 3, act + 4)]
    for p in range(PARTS):
        spans += [range(MP_COST_PC + p, MP_COST_PC + p + 1), range(EFFECTS_PC + EFFECT_SIZE * p, EFFECTS_PC + EFFECT_SIZE * (p + 1))]
    spans.append(range(TP_COST_PC, TP_COST_PC + 16 * CHARACTERS))
    for c in decode_combos(rom):
        at = pc(0xCC, c["req_addr"])
        spans.append(range(at, at + 3 * c["count"]))
    spans.append(range(TECH_STATE_PC, TECH_STATE_PC + TECH_STATE_SIZE))
    spans += [range(RECORDS_PC + RECORD_SIZE * c + 2, RECORDS_PC + RECORD_SIZE * c + 3) for c in range(CHARACTERS)]
    return spans


# --- The tech-point rule ----------------------------------------------------------------

def tables(rom):
    """What the rule reads: CharTechs, the TP words, which ids need the unlock, ComboTechs."""
    return {"char_techs": char_techs(rom), "tp": tp_words(rom),
            "needs_unlock": [bool(rom[TECH_REC_PC + TECH_REC_SIZE * t] & NEEDS_UNLOCK) for t in range(TECHS)],
            "combos": [{"mask": c["mask"], "first": c["first"], "requirements": c["requirements"]}
                       for c in decode_combos(rom)]}


def _unlock_needed(t, tech):
    if tech >= len(t["needs_unlock"]):
        raise ValueError(f"tech ${tech:02X} is past the tech table")
    return t["needs_unlock"][tech]


def try_next_tech(t, s, slot, b2db):
    """BattleSys_TryNextTech: True when the PC's need was paid."""
    cid = slot["char"]
    tech = (t["char_techs"][cid][0] + s["counts"][cid]) & 0xFF
    if _unlock_needed(t, tech) and not s["unlock"] & (1 << cid):
        return False
    need = slot["to_next"]
    if need <= b2db:
        slot["to_next"] = b2db - need
        return True
    slot["to_next"] = need - b2db
    return False


def learn_single_tech(t, s, slot):
    cid = slot["char"]
    count = s["counts"][cid]
    s["bits1"][cid] |= 0x80 >> count if count < 8 else 0
    s["counts"][cid] = (count + 1) & 0xFF
    if s["counts"][cid] >= t["char_techs"][cid][1]:
        slot["flags"] |= ALL_TECHS


def spend_tech_points(t, s, slot, award):
    """BattleSys_SpendTechPoints, quirks included: after T >= L the loop pays
    the award (or a stored leftover) again."""
    b2db = award
    while try_next_tech(t, s, slot, b2db) and not slot["flags"] & ALL_TECHS:
        learn_single_tech(t, s, slot)
        index = slot["char"] * 8 + ((s["counts"][slot["char"]] * 2) & 0xFF) // 2
        if index >= len(t["tp"]):
            raise ValueError("the next cost is past the TP table")
        cost, left = t["tp"][index], slot["to_next"]
        if cost >= left:
            slot["to_next"] = cost - left
        else:
            b2db, slot["to_next"] = left, cost
    low = (slot["tp"] & 0xFFFF) + award
    high = slot["tp"] >> 16
    if low > 0xFFFF:
        low, high = low & 0xFFFF, (high + 1) & 0xFF
    if low >= TOTAL_CAP_LO and high >= TOTAL_CAP_HI:
        high, low = TOTAL_CAP_HI, TOTAL_CAP_LO
    slot["tp"] = high << 16 | low


def combo_masks(chars):
    """BattleSys_BuildComboMasks: the slots' bits sorted up; the pairs, then all three."""
    p = [0 if c is None else (0x80 >> c if c < 8 else 0) for c in chars]
    for i, j in ((0, 1), (0, 2), (1, 2)):
        if not p[i] < p[j]:
            p[i], p[j] = p[j], p[i]
    return [p[0] | p[1], p[0] | p[2], p[1] | p[2], p[0] | p[1] | p[2]]


def learn_combo_techs(t, s, index, rec, mask):
    counts = [s["counts"][c] for c in members(mask)]
    reqs = [b for row in rec["requirements"] for b in row]
    tech = rec["first"]
    for k in range(len(rec["requirements"])):
        bit = 0x80 >> k if k < 8 else 0
        if not s["combo_bits"][index] & bit:
            if all(n >= reqs[3 * k + m] for m, n in enumerate(counts)) and not _unlock_needed(t, tech):
                s["combo_bits"][index] |= bit
        tech = (tech + 1) & 0xFF


def award_tech_points(t, state, award):
    """BattleSys_AwardTechPoints: the state after a battle's `award` (0-65535).
    state: counts, bits1, combo_bits (Battle_TechCount/Bits1/Bits2+3), unlock
    ($7F:01E0) and slots: per PC slot None or {char, flags (+$02), tp (+$16),
    to_next (+$2D)}."""
    s = copy.deepcopy(state)
    for slot in s["slots"]:
        if slot is not None and not slot["flags"] & ALL_TECHS:
            spend_tech_points(t, s, slot, award)
    for mask in combo_masks([None if p is None else p["char"] for p in s["slots"]]):
        index = next((i for i, rec in enumerate(t["combos"]) if rec["mask"] == mask), None)
        if index is None or t["combos"][index]["first"] == NONE:
            continue
        if not t["combos"][index]["requirements"]:
            raise ValueError("a combination record with no techs")
        learn_combo_techs(t, s, index, t["combos"][index], mask)
    return s


def starting_state(rom, party, unlock=0):
    """The ROM's new-game tech state with `party` (char ids or None) in slots 0-2."""
    s = decode_state(rom)
    s["unlock"] = unlock
    s["slots"] = [None if c is None else dict(char=c, **record_tech_fields(rom, c)) for c in party]
    return s


# --- Evidence ---------------------------------------------------------------------------

def _body(rom, bank, start, end):
    return bytes(rom[pc(bank, start):pc(bank, end) + 1])


def _has(body, *patterns):
    return all(p in body for p in patterns)


def code_claims(rom):
    """Claims read from the ROM's code bytes: [(name, ok, detail)]."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    award = _body(rom, 0xC1, 0xF205, 0xF2DA)
    claim("AwardTechPoints: skips a PC with +$02 bit 4, takes the char id from +$00, scans ComboTechs from "
          "$CC:2778 in 5-byte records, a found record's bits at $2830 + 14 + its index",
          _has(award, b"\xbd\x2f\x5e\x29\x10\xd0", b"\xbd\x2d\x5e\x8d\xd1\xb2", b"\xa2\x78\x27",
               b"\xe8\xe8\xe8\xe8\xe8", b"\x69\x3e\x28", b"\xc9\x04"))
    spend = _body(rom, 0xC1, 0xF39A, 0xF45E)
    claim("SpendTechPoints: cost word = TechTpCost[id x 16 + count x 2]; T >= need -> need = T - need, "
          "else B2DB = need and need = T; 24-bit total capped at $98:967F",
          _has(spend, b"\x69\x30\x28", b"\x69\x6a\x27", b"\x0a\x0a\x0a\x0a", b"\xbf\xfa\x26\xcc",
               b"\xdd\x5a\x5e\xb0", b"\x8d\xdb\xb2", b"\x38\xfd\x5a\x5e\x9d\x5a\x5e",
               b"\x7d\x43\x5e\x9d\x43\x5e", b"\xfe\x45\x5e", b"\xc9\x7f\x96", b"\xc9\x98"))
    nxt = _body(rom, 0xC1, 0xF45F, 0xF4DE)
    claim("TryNextTech: tech = CharTechs[id].first + count; TechRec x 11 byte 0 bit 7 needs bit (1 << id) "
          "of $7F:01E0; need <= B2DB pays",
          _has(nxt, b"\xbf\x6a\x27\xcc", b"\xbd\x30\x28", b"\xa2\x0b\x00", b"\xbf\xeb\x1b\xcc\x29\x80",
               b"\x2f\xe0\x01\x7f", b"\xbd\x5a\x5e\xcd\xdb\xb2"))
    learn = _body(rom, 0xC1, 0xF4DF, 0xF532)
    claim("LearnSingleTech: bits1 |= $80 >> count, count + 1, at CharTechs[id].count sets +$02 bit 4",
          _has(learn, b"\xa9\x80", b"\x46\x0a", b"\xbd\x07\x00\x05\x0a\x9d\x07\x00", b"\x1a",
               b"\xdf\x01\x00\xcc", b"\xbd\x2f\x5e\x09\x10\x9d\x2f\x5e"))
    combo = _body(rom, 0xC1, 0xF533, 0xF622)
    claim("LearnComboTechs: members' counts >= the requirement bytes, TechRec byte 0 bit 7 clear, bit from $80 down",
          _has(combo, b"\xbd\x30\x28", b"\xdf\x00\x00\xcc", b"\xbf\xeb\x1b\xcc\x29\x80", b"\x4a\x8d\xdf\xb2"))
    mp = _body(rom, 0xC1, 0xCB48, 0xCB92)
    claim("TechMpCost1-3: TechRec bytes 5-7 (parts) index MpCost $CC:253B",
          _has(mp, b"\xbf\xf0\x1b\xcc", b"\xbf\xf1\x1b\xcc", b"\xbf\xf2\x1b\xcc", b"\xbf\x3b\x25\xcc"))
    users = _body(rom, 0xC1, 0xCB93, 0xCBF5)
    claim("LoadTechUsers: TechRec byte 0 AND $7F x 3 indexes UserSets $CC:249F",
          _has(users, b"\xbf\xeb\x1b\xcc\x29\x7f", b"\xbf\x9f\x24\xcc", b"\xbf\xa0\x24\xcc", b"\xbf\xa1\x24\xcc"))
    run = _body(rom, 0xC1, 0xD523, 0xD7C3)
    claim("RunTechParts: part bit 7 skips; part x 12 copies an effect record from $CC:213F; byte 3 -> B190; "
          "bytes 8-10 -> B2CC; effect byte 0 indexes the effect table ($C1:D9D7)",
          _has(run, b"\xbf\xf0\x1b\xcc\x8d\xc8\xb2\x89\x80", b"\xa9\x0c", b"\xbf\x3f\x21\xcc",
               b"\xbf\xee\x1b\xcc\x8d\x90\xb1", b"\xbf\xf3\x1b\xcc\x8d\xcc\xb2", b"\xfc\xd7\xd9"))
    load = _body(rom, 0xC1, 0x45A0, 0x4620)
    claim("BattleAct_LoadTech: PcTechAct $CD:45A6 x 7, script number indexes PcTechScripts $CD:5EF0",
          _has(load, b"\xbf\xa6\x45\xcd", b"\xbf\xf0\x5e\xcd"))
    info = _body(rom, 0xC1, 0xC1DD, 0xC3FF)
    claim("UnkC1DD: TechInfo byte 1 = area number, byte 0 AND $7F = target mode; AreaRecPtr $CC:2AB0",
          _has(info, b"\xbf\xcc\x1a\xcc", b"\xbf\xcb\x1a\xcc\x29\x7f") and b"\xbf\xb0\x2a\xcc" in _body(rom, 0xC1, 0xC1DD, 0xC96A))
    claim("Menu_InitNewGameData copies $280 B from $CC:0000 (8 x $50: the tech state is the eighth record)",
          b"\xa2\x00\x00\xa0\x00\x26\xa9\x7f\x02\x54\x7e\xcc" in _body(rom, 0xC2, 0x956E, 0x95BA))
    return out


def data_claims(rom):
    """Claims about the ROM's data, given the decoded layout: [(name, ok, detail)]."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    ct = char_techs(rom)
    claim("CharTechs: character c has 8 singles from 1 + 8c", ct == [(1 + 8 * c, 8) for c in range(CHARACTERS)], repr(ct))
    first = list(rom[CHAR_FIRST_TECH_PC:CHAR_FIRST_TECH_PC + 8])
    claim("$FD:A89D agrees with CharTechs (and gives $39 after the last)", first == [f for f, _ in ct] + [FIRST_DOUBLE])
    techs = [decode_tech(rom, t) for t in range(TECHS)]
    claim("tech 0 is empty", techs[0]["parts"] == [0, 0, 0] and techs[0]["user_set"] == 0)
    sets = user_sets(rom)
    for c in range(CHARACTERS):
        singles = techs[1 + 8 * c:9 + 8 * c]
        claim(f"{NAMES[c]}: its 8 singles have user set {c}, part 1 = the tech id, parts 2-3 none",
              all(v["user_set"] == c and v["parts"] == [v["id"], PART_NONE, PART_NONE] for v in singles))
        claim(f"{NAMES[c]}: user set {c} is ({c}, none, none)", sets[c] == [c, NONE, NONE])
    combos = decode_combos(rom)
    claim("ComboTechs: 15 pair records of 3 doubles from $39, then 10 trio records of 1 triple from $66",
          len(combos) == 25
          and all(r["count"] == 3 and r["first"] == FIRST_DOUBLE + 3 * i and len(members(r["mask"])) == 2
                  for i, r in enumerate(combos[:15]))
          and all(r["count"] == 1 and r["first"] == FIRST_TRIPLE + j and len(members(r["mask"])) == 3
                  for j, r in enumerate(combos[15:])),
          f"{len(combos)} records")
    claim("ComboTechs: every mask is distinct and only names characters 0-6",
          len({r["mask"] for r in combos}) == len(combos) and all(r["mask"] & 1 == 0 for r in combos))
    bad_users, bad_parts, bad_reqs = [], [], []
    for i, r in enumerate(combos):
        who = members(r["mask"])
        for k in range(r["count"]):
            v = techs[r["first"] + k]
            users = [c for c in sets[v["user_set"]] if c != NONE]
            if sorted(users) != who:
                bad_users.append(v["id"])
            req = r["requirements"][k]
            if any(not 1 <= req[m] <= 8 for m in range(len(who))) or (len(who) == 2 and req[2] != NONE):
                bad_reqs.append(v["id"])
            for p, user in zip(v["parts"], sets[v["user_set"]]):
                if p & PART_NONE or p >= FIRST_DOUBLE:
                    continue
                # a part that is one of its performer's singles needs that single
                if (p - 1) // 8 == user and req[who.index(user)] < (p - 1) % 8 + 1:
                    bad_parts.append(v["id"])
    claim("each combination tech's user set holds exactly its record's members", not bad_users, repr(bad_users))
    claim("requirements: 1-8 per member, $FF for a pair's third byte", not bad_reqs, repr(bad_reqs))
    claim("a combination part that is a member's own single needs at least that single", not bad_parts, repr(bad_parts))
    reqs = sorted(r["req_addr"] for r in combos)
    claim("requirement bytes follow the table, one record after another",
          reqs[0] == 0x27FA and all(b - a == 3 * combos[i]["count"] for i, (a, b) in
                                    enumerate(zip([r["req_addr"] for r in combos], [r["req_addr"] for r in combos][1:]))))
    in_combo = {r["first"] + k for r in combos for k in range(r["count"])}
    claim("techs $39-$6F are the records' techs; $70-$74 are in no record",
          in_combo == set(range(FIRST_DOUBLE, 0x70)))
    used = {p & 0x7F for v in techs[1:] for p in v["parts"] if not p & PART_NONE}
    mp = [rom[MP_COST_PC + p] for p in range(PARTS)]
    claim("every part a tech runs has an MP cost of at most 99", all(mp[p] <= 99 for p in used))
    parts = [decode_part(rom, p) for p in range(PARTS)]
    claim("every part a tech runs has an effect type of 0-8",
          all(parts[p]["effect"]["type"] <= 8 for p in used))
    claim("every effect type is below 45", all(p["effect"]["type"] < EFFECT_TYPES for p in parts))
    mods = [list(rom[MODIFIERS_PC + 3 * i:MODIFIERS_PC + 3 * i + 3]) for i in range(MODIFIERS)]
    used_mods = {m for v in techs for m in v["modifiers"]}
    claim(f"modifier indexes are below {MODIFIERS} and their records' kinds below 21",
          all(m < MODIFIERS and mods[m][0] < MODIFIER_KINDS for m in used_mods), repr(sorted(used_mods)))
    claim("target modes are at most $20; areas at most $0B",
          all(v["target_mode"] < TARGET_MODES and v["area"] < AREAS for v in techs))
    claim("the element bits (TechRec byte 3 bits 7-4) hold at most one element",
          all(v["element_bits"] & (v["element_bits"] - 1) == 0 for v in techs))
    claim("byte 2 is $40 and byte 4 0 for every tech with parts",
          all(v["unk2"] == 0x40 and v["unk4"] == 0 for v in techs[1:]))
    areas = decode_areas(rom)
    claim("areas 1-$0B: one entry each, shapes below 7, parameters below 7",
          all(len(a) == 1 and a[0][0] < AREA_SHAPES and a[0][1] & 0x7F < AREA_PARAMS for a in areas[1:]))
    claim("animation: script numbers below 128, frames below 80",
          all(v["anim"]["script"] < SCRIPTS and v["anim"]["frames"] < ANIM_FRAMES for v in techs))
    state = decode_state(rom)
    tp = tp_words(rom)
    claim("starting state: each character's bits1 are its count's top bits; no combination learned",
          all(b == (0xFF00 >> n) & 0xFF for b, n in zip(state["bits1"], state["counts"]))
          and not any(state["combo_bits"]))
    for c in range(CHARACTERS):
        r = record_tech_fields(rom, c)
        n = state["counts"][c]
        claim(f"{NAMES[c]}: +$2D = TechTpCost[{c}][{n}] (the next single's cost), +$02 bit 4 clear",
              r["to_next"] == tp[8 * c + n] and not r["flags"] & ALL_TECHS and n < 8)
        locked = [techs[1 + 8 * c + k]["needs_unlock"] for k in range(8)]
        claim(f"{NAMES[c]}: its first single that needs the unlock (if any) costs 0 TP",
              True not in locked or tp[8 * c + locked.index(True)] == 0)
    if REF.exists():
        glyphs = _glyphs()
        names = [tech_name(rom, t, glyphs)[1] for t in range(TECHS)]
        # Plain element words, not names: a single whose name starts with one has that element.
        groups = {"lightning": ("Lightning",), "shadow": ("Dark",), "water": ("Ice", "Water"), "fire": ("Fire", "Flare")}
        bad, seen = [], 0
        for element, words in groups.items():
            for t in range(1, FIRST_DOUBLE):
                if names[t].startswith(words):
                    seen += 1
                    if element_of(techs[t]["element_bits"] << 4) != element:
                        bad.append(names[t])
        claim("the elemental singles' names agree with their element bit", not bad and seen >= 8,
              f"{seen} named singles; disagreeing: {bad!r}")
    return out


class RomTechPoints:
    """The game's own BattleSys_AwardTechPoints ($C1:F205) with its callees,
    executed by ChronoRET's 65816 interpreter (refs/ChronoRET/tools/absint.py)
    over `image` (the ROM, or a copy with other tables patched in). Every value
    is known, so each run has one end; a callee it could not follow is an error."""

    BLOCKS = 0x7E5E2D                # BattlerStats[slot] + $2D = PcStatBlk, $80 per slot
    SLOT_IDS = 0x7EAEFF              # Battler_UnkAEFF: char id or $FF per slot
    AWARD = 0x7EB2DB
    STATE = 0x7E2830                 # Battle_TechCount, Bits1, Bits2, Bits3
    UNLOCK = 0x7F01E0
    SCRATCH = range(0x7EB1F0, 0x7EB400)

    def __init__(self, image, ref=REF):
        if str(ref / "tools") not in sys.path:
            sys.path.insert(0, str(ref / "tools"))
        import absint
        self.absint = absint
        self.machine = absint.Machine(bytes(image), bytearray(b"\x01") * len(image),
                                      max_steps=10 ** 7, callee_steps=10 ** 6)
        self.machine.widen_after = 10 ** 9

    def award(self, state, award):
        known = {a: 0 for a in range(0x7E0000, 0x7E0040)}
        known.update({a: 0 for a in self.SCRATCH})
        raw = state["counts"] + state["bits1"] + state["combo_bits"]
        known.update({self.STATE + i: b for i, b in enumerate(raw)})
        known[self.UNLOCK] = state["unlock"]
        known[self.AWARD], known[self.AWARD + 1] = award & 0xFF, award >> 8
        for n, slot in enumerate(state["slots"]):
            block = self.BLOCKS + 0x80 * n
            known.update({block + i: 0 for i in range(RECORD_SIZE)})
            known[self.SLOT_IDS + n] = NONE if slot is None else slot["char"]
            if slot is not None:
                known[block] = slot["char"]
                known[block + 2] = slot["flags"]
                for i in range(3):
                    known[block + 0x16 + i] = slot["tp"] >> 8 * i & 0xFF
                known[block + 0x2D], known[block + 0x2E] = slot["to_next"] & 0xFF, slot["to_next"] >> 8
        s = self.absint.State()
        s.pc, s.a, s.b, s.x, s.y = 0xC1F205, 0, 0, 0, 0
        s.d, s.db, s.m, s.xf, s.c = 0, 0x7E, True, False, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = self.absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != "rts" or self.machine.opaque:
            raise RuntimeError(f"AwardTechPoints: {[how for _, how in ends]} opaque {self.machine.opaque}")
        mem = {**known, **ends[0][0].mem}
        raw = [mem[self.STATE + i] for i in range(TECH_STATE_SIZE)]
        out = {"counts": raw[0:7], "bits1": raw[7:14], "combo_bits": raw[14:44], "unlock": mem[self.UNLOCK], "slots": []}
        for n, slot in enumerate(state["slots"]):
            block = self.BLOCKS + 0x80 * n
            out["slots"].append(None if slot is None else {
                "char": mem[block], "flags": mem[block + 2],
                "tp": mem[block + 0x16] | mem[block + 0x17] << 8 | mem[block + 0x18] << 16,
                "to_next": mem[block + 0x2D] | mem[block + 0x2E] << 8})
        if any(b is None for b in raw) or any(v is None for p in out["slots"] if p for v in p.values()):
            raise RuntimeError("an unknown byte in the tech state")
        return out


# Parties and awards for the run claims: every character in a pair and a trio.
RUN_PARTIES = ((0, 1, 2), (3, 4, 5), (6, 0, 4), (1, 5, 3), (2, 6, None), (None, 4, 1), (5, None, 2))
RUN_AWARDS = (0, 7, 30, 99, 150, 400, 1000, 65535)


def run_claims(rom, ref=REF):
    """The ROM's AwardTechPoints against `award_tech_points`, from the ROM's
    starting state, in RUN_PARTIES, with and without the unlock: each party
    gets a series of awards: [(name, ok, detail)]."""
    runner = RomTechPoints(rom, ref)
    t = tables(rom)
    out = []
    for party in RUN_PARTIES:
        for unlock in (0, 0x7F):
            s = starting_state(rom, party, unlock)
            bad, steps = None, 0
            for award in RUN_AWARDS + (250,) * 12 + (5,) * 4:
                want, got = award_tech_points(t, s, award), runner.award(s, award)
                steps += 1
                if got != want:
                    bad = award
                    break
                s = want
            learned = sum(s["counts"])
            out.append((f"party {party} unlock ${unlock:02X}: the ROM's AwardTechPoints = award_tech_points "
                        f"({steps} awards, {learned} singles learned)", bad is None, f"differs at award {bad}"))
    return out


def patched_image(rom, case):
    """A copy of `rom` with a synthetic case's tables: the TP rows, each id's
    unlock bit and the combination records with their requirements."""
    image = bytearray(rom)
    words = [w for row in case["tp_cost"] for w in row]
    image[TP_COST_PC:TP_COST_PC + 2 * len(words)] = b"".join(w.to_bytes(2, "little") for w in words)
    for tech, locked in enumerate(case["needs_unlock"]):
        at = TECH_REC_PC + TECH_REC_SIZE * tech
        image[at] = image[at] & 0x7F | (NEEDS_UNLOCK if locked else 0)
    req = 0x27FA
    for i, rec in enumerate(case["combos"]):
        at = COMBOS_PC + COMBO_SIZE * i
        image[at:at + 5] = bytes([rec["mask"], rec["first"], len(rec["requirements"]), req & 0xFF, req >> 8])
        for row in rec["requirements"]:
            image[pc(0xCC, req):pc(0xCC, req) + 3] = bytes(row)
            req += 3
    image[COMBOS_PC + COMBO_SIZE * len(case["combos"])] = NONE
    return bytes(image)


def case_tables(case):
    tp = [w for row in case["tp_cost"] for w in row] + [case["tp_after"]]
    return {"char_techs": [tuple(x) for x in case["char_techs"]], "tp": tp, "needs_unlock": case["needs_unlock"],
            "combos": case["combos"]}


def synthetic_run_claims(rom, ref=REF):
    """The ROM's routine with each synthetic case's tables patched in, against the vectors."""
    out = []
    for n, case in enumerate(synthetic_cases()["cases"]):
        runner = RomTechPoints(patched_image(rom, case), ref)
        s, bad = case["state"], None
        for step in case["steps"]:
            got = runner.award(s, step["award"])
            if got != step["state"]:
                bad = step["award"]
                break
            s = got
        out.append((f"synthetic case {n}: the ROM's routine with its tables patched in = the vectors "
                    f"({len(case['steps'])} awards)", bad is None, f"differs at award {bad}"))
    return out


# ChronoRET source claims: (file under asm/, routine label, lines that must
# appear in its body, in order).
ASM_CLAIMS = (
    ("bankC1/bankC1.asm", "BattleSys_AwardTechPoints",
     ("LDA.w !Battler_UnkAEFF,X", "LDA.w BattlerStats.Unk2F,X", "AND.b #!Battle_Unk2FAllTechs",
      "LDA.w BattlerStats.Unk2D,X", "STA.w !Battle_TpCharId", "JSR BattleSys_SpendTechPoints",
      "JSR BattleSys_BuildComboMasks", "LDX.w #!BattleRom_ComboTechs&$FFFF", "CMP.w !Battle_ComboMasks,Y",
      "ADC.w #!Battle_TechBits2", "JSR BattleSys_LearnComboTechs")),
    ("bankC1/bankC1.asm", "BattleSys_SpendTechPoints",
     ("JSR BattleSys_TryNextTech", "ADC.w #!Battle_TechCount", "AND.b #!Battle_Unk2FAllTechs",
      "JSR BattleSys_LearnSingleTech", "LDA.l !BattleRom_TechTpCost,X", "CMP.w BattlerStats.TechPtNeed,X",
      "STA.w !Battle_UnkB2DB", "SBC.w BattlerStats.TechPtNeed,X", "ADC.w BattlerStats.TechPtTotal,X",
      "INC.w BattlerStats.TechPtTotal+2,X", "CMP.w #!Battle_TotalCapLo", "CMP.b #!Battle_TotalCapHi")),
    ("bankC1/bankC1.asm", "BattleSys_TryNextTech",
     ("LDA.l !BattleRom_CharTechs,X", "LDA.w !Battle_TechCount,X", "LDA.l BattleRom_TechRec.UserSet,X",
      "AND.b #!Battle_TechNeedsUnlock", "AND.l !Battle_Unk7F01E0", "LDA.w BattlerStats.TechPtNeed,X",
      "CMP.w !Battle_UnkB2DB", "STA.w !Battle_TpLearned")),
    ("bankC1/bankC1.asm", "BattleSys_LearnSingleTech",
     ("LDA.b #!Battle_TechBit0", "LSR.b !LearnTech_Bit", "STA.w !Battle_TechBits1-!Battle_TechCount,X",
      "INC A", "CMP.l !BattleRom_BankCC+1,X", "ORA.b #!Battle_Unk2FAllTechs")),
    ("bankC1/bankC1.asm", "BattleSys_BuildComboMasks",
     ("LDA.w !Battler_UnkAEFF", "LSR.b !ComboBits_Bit", "CMP.w !Battle_ComboPcBit+1",
      "ORA.w !Battle_ComboPcBit+1", "STA.w !Battle_ComboMasks+3")),
    ("bankC1/bankC1.asm", "BattleSys_LearnComboTechs",
     ("LDA.w !Battle_TechCount,X", "LDA.b #!Battle_TechBit0", "CMP.l !BattleRom_BankCC,X",
      "LDA.l BattleRom_TechRec.UserSet,X", "AND.b #!Battle_TechNeedsUnlock", "ORA.w !Battle_ComboTechBit")),
    ("bankC1/bankC1.asm", "BattleSys_RunTechParts",
     ("LDA.l BattleRom_TechRec.UserSet,X", "LDA.l !BattleRom_TechUserSets,X", "JSR BattleSys_CheckTechMp",
      "LDA.l BattleRom_TechRec.Part1,X", "BIT.b #!Battle_TechPartNone", "LDA.l !BattleRom_UnkCC213F,X",
      "LDA.l BattleRom_TechRec.PartUnk,X", "LDA.l BattleRom_TechRec.Unk3,X", "JSR (BattleSys_EffectTable,X)",
      "CMP.b #!Battle_TechParts")),
    ("bankC1/bankC1.asm", "BattleSys_HitModUnk6CScale",
     ("LDA.w !Battle_UnkB190", "BIT.b #!Battle_B190Bit7", "BIT.b #!Battle_B190Bit6", "BIT.b #!Battle_B190Bit5",
      "BIT.b #!Battle_B190Bit4", "LDA.w BattlerStats.Unk6C,X")),
    ("bankC1/bankC1.asm", "BattleAct_LoadTech",
     ("LDA.l BattleRom_PcTechAct.Script,X", "LDA.l BattleRom_PcTechAct.Frames,X", "LDA.l !BattleRom_PcTechScripts,X")),
)


def asm_claims(ref=REF):
    """Each ASM_CLAIMS routine holds its lines in order: [(name, ok, detail)]."""
    out = []
    sources = {}
    for path, label, lines in ASM_CLAIMS:
        text = sources.setdefault(path, (ref / "asm" / path).read_text().splitlines())
        try:
            start = next(i for i, line in enumerate(text) if line.strip() == f"{label}:")
        except StopIteration:
            out.append((f"{path} {label}", False, "label not found"))
            continue
        end = next((i for i in range(start + 1, len(text))
                    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", text[i])), len(text))
        body = [line.split(";")[0].strip() for line in text[start + 1:end]]
        at, missing = 0, None
        for want in lines:
            found = next((i for i in range(at, len(body)) if body[i] == want), None)
            if found is None:
                missing = want
                break
            at = found + 1
        out.append((f"{path} {label}", missing is None, f"missing {missing!r}" if missing else f"line {start + 1}"))
    return out


# --- Synthetic vectors for the Swift twin ------------------------------------------------

class Lcg:
    """Deterministic numbers (no ROM data)."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self, n):
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.state >> 8) % n


# CharTechs as the code needs it (8 singles from 1 + 8c), and the word after
# the TP rows that it makes (first 1, count 8).
SYNTHETIC_CHAR_TECHS = [[1 + 8 * c, 8] for c in range(CHARACTERS)]
SYNTHETIC_TP_AFTER = 1 | 8 << 8


def _synthetic_combos(rng):
    pairs = [(a, b) for a in range(CHARACTERS) for b in range(a + 1, CHARACTERS)]
    trios = [(a, b, c) for a in range(CHARACTERS) for b in range(a + 1, CHARACTERS) for c in range(b + 1, CHARACTERS)]
    picks = [pairs[i] for i in sorted({rng.next(len(pairs)) for _ in range(20)})][:15]
    picks += [trios[i] for i in sorted({rng.next(len(trios)) for _ in range(14)})][:10]
    out, tech = [], FIRST_DOUBLE
    for who in picks:
        count = 1 + rng.next(3) if len(who) == 2 else 1
        count = min(count, 0x75 - tech)
        if count <= 0:
            break
        reqs = [[1 + rng.next(8) if m < len(who) else NONE for m in range(3)] for _ in range(count)]
        mask = 0
        for c in who:
            mask |= 0x80 >> c
        out.append({"mask": mask, "first": tech, "requirements": reqs})
        tech += count
    return out


def synthetic_cases():
    rng = Lcg(0x7EC4)
    cases = []
    for n in range(12):
        tp_cost = [[(0 if rng.next(5) == 0 else rng.next(1200)) if n != 1 else rng.next(30) for _ in range(8)]
                   for _ in range(CHARACTERS)]
        locked = [False] * TECHS
        for c in range(CHARACTERS):
            if rng.next(3):
                k = rng.next(8)
                for j in range(k, min(8, k + 1 + rng.next(4))):
                    locked[1 + 8 * c + j] = True
        for t in range(FIRST_DOUBLE, TECHS):
            locked[t] = rng.next(9) == 0
        combos = _synthetic_combos(rng)
        counts = [rng.next(9) for _ in range(CHARACTERS)]
        if n == 0:
            counts = [0] * CHARACTERS
        state = {"counts": counts, "bits1": [(0xFF00 >> k) & 0xFF for k in counts],
                 "combo_bits": [rng.next(256) if rng.next(4) == 0 else 0 for _ in range(COMBO_BYTES)],
                 "unlock": rng.next(128) if n % 3 else (0 if n % 2 else 0x7F), "slots": []}
        chars = list(range(CHARACTERS))
        for slot in range(3):
            if rng.next(7) == 0 and n:
                state["slots"].append(None)
                continue
            cid = chars.pop(rng.next(len(chars)))
            count = state["counts"][cid]
            flags = (rng.next(256) & ~ALL_TECHS) | (ALL_TECHS if count >= 8 else 0)
            tp = rng.next(1 << 24) if n == 2 else rng.next(20000)
            if n == 3:
                tp = 0x98967F - rng.next(300)
            state["slots"].append({"char": cid, "flags": flags, "tp": tp,
                                   "to_next": tp_cost[cid][min(count, 7)] if rng.next(3) else rng.next(2000)})
        case = {"char_techs": SYNTHETIC_CHAR_TECHS, "tp_cost": tp_cost, "tp_after": SYNTHETIC_TP_AFTER,
                "needs_unlock": locked, "combos": combos, "state": state, "steps": []}
        t = case_tables(case)
        s = state
        for k in range(10):
            award = (0, 1, 65535)[k] if n == 4 and k < 3 else rng.next(1600) if k % 4 else rng.next(65536)
            if n == 1:
                award = rng.next(40)
            s = award_tech_points(t, s, award)
            case["steps"].append({"award": award, "state": s})
        cases.append(case)
    return {"schema": "ct-tech-point-vectors/1",
            "note": "synthetic tables and states (no ROM data); steps by re_workspace/tools/ct_techs.py",
            "cases": cases}


def _state_json(s):
    return json.dumps(s, sort_keys=True, separators=(",", ":"))


def vectors_text():
    """The vectors as JSON, one state per line; the Swift field names."""
    v = synthetic_cases()
    cases = []
    for case in v["cases"]:
        steps = ",\n".join(f'    {{"award":{st["award"]},"state":{_state_json(swift_state(st["state"]))}}}'
                           for st in case["steps"])
        locked = [t for t, x in enumerate(case["needs_unlock"]) if x]
        cases.append("  {" + f'"charTechs": {json.dumps(case["char_techs"], separators=(",", ":"))},\n'
                     f'   "tpCost": {json.dumps(case["tp_cost"], separators=(",", ":"))},\n'
                     f'   "tpAfter": {case["tp_after"]},\n'
                     f'   "needsUnlock": {json.dumps(locked, separators=(",", ":"))},\n'
                     f'   "combos": {json.dumps(case["combos"], sort_keys=True, separators=(",", ":"))},\n'
                     f'   "state": {_state_json(swift_state(case["state"]))},\n'
                     f'   "steps": [\n{steps}]}}')
    head = ",\n".join(f' "{k}": {json.dumps(v[k])}' for k in ("schema", "note"))
    return "{\n" + head + ',\n "cases": [\n' + ",\n".join(cases) + "]}\n"


def swift_state(s):
    """A rule state with the Swift twin's names."""
    return {"counts": s["counts"], "bits1": s["bits1"], "comboBits": s["combo_bits"], "unlock": s["unlock"],
            "slots": [None if p is None else {"char": p["char"], "flags": p["flags"], "tp": p["tp"],
                                              "toNext": p["to_next"]} for p in s["slots"]]}


# --- The manifest proposal ----------------------------------------------------------------

def _f(offset, size, name, status, evidence):
    return {"offset": f"+${offset:02X}", "size": size, "name": name, "status": status, "evidence": evidence}


RUN = "executed: ct_techs.py check --run runs BattleSys_AwardTechPoints against award_tech_points"

# Record types of items_and_techs_schema.json as this tool decodes and checks
# them: (name, addr, stride, count, role, fields). ct_schemas.techs_manifest_update
# puts them in.
MANIFEST_TYPES = (
    ("TechInfo", "$CC:1ACB", 2, TECHS, "per tech id: menu target mode and area (BattleSys_UnkC1DD)", [
        _f(0, 1, "target_mode", "decoded",
           "bits 6-0: BattleTgt_ModeTable handler (33 words; UnkC1DD AND $7F); bit 7: usable from the field menu "
           "(set on the healing techs only)"),
        _f(1, 1, "area", "decoded",
           "area number: BattleRom_AreaRecPtr index (UnkC1DD), 0 = none; AND $3F -> TechMenuRec.Flags"),
    ]),
    ("TechRec", "$CC:1BEB", TECH_REC_SIZE, TECHS, "per tech id: who performs it and its three parts", [
        _f(0, 1, "user_set", "verified",
           "bits 6-0: TechUserSets index (LoadTechUsers AND $7F x 3); singles: the owner, combinations: their "
           "record's members (data); bit 7: needs the character's $7F:01E0 bit (TryNextTech, LearnComboTechs; "
           + RUN + " with the bits patched)"),
        _f(1, 1, "flags", "partial",
           "bits 6, 5 -> Battle_UnkB2CA (RunTechParts); bits 2-0: Battle_SumHitSets merge count; bits 7, 4 not traced"),
        _f(2, 1, "unk02", "partial", "ORed with the user slot into Battle_UnkB18E; $40 in every tech"),
        _f(3, 1, "element", "decoded",
           "bits 7-4 -> Battle_UnkB190: the first set picks the target's resistance byte n (HitModUnk6CScale); "
           "the elemental singles' names agree (lightning, shadow, water, fire); bits 3-0 not traced"),
        _f(4, 1, "unk04", "undecoded", "0 in every tech; not read"),
        _f(5, 3, "parts", "decoded",
           "user k's part: MpCost index (TechMpCost1-3) and effect record number (RunTechParts); bit 7 = none"),
        _f(8, 3, "modifiers", "partial", "user k's BattleRom_UnkCC2A05 record (-> Battle_UnkB2CC; 21 handlers)"),
    ]),
    ("TechEffects", "$CC:213F", EFFECT_SIZE, PARTS, "per part number: what one part does (RunTechParts copies it)", [
        _f(0, 1, "type", "decoded", "BattleSys_EffectTable handler (45 words; types 9-$28 do nothing)"),
        _f(1, 2, "args", "partial", "per type: heal factor, status byte and bits, hit count"),
        _f(3, 2, "stat_pair", "decoded", "caster / target stat block offsets of the hit roll (BattleSys_EffRecStatPair)"),
        _f(5, 2, "formula_defence", "partial", "BattleSys_CalcDamage kind; the defence byte (BattleSys_AdjustDefence)"),
        _f(7, 2, "flags", "partial", "-> Battle_UnkAE4D / AE4E (hit roll, immunity, barrier, defence scale)"),
        _f(9, 1, "power", "decoded", "BattleSys_CalcDamage's power byte"),
        _f(10, 1, "immunity", "partial", "tested against the target's .Unk46"),
        _f(11, 1, "unk11", "undecoded", "not traced"),
    ]),
    ("TechUserSets", "$CC:249F", 3, USER_SETS, "per set: the character ids that perform a tech, $FF = none", [
        _f(0, 3, "char_ids", "verified", "LoadTechUsers; 52 sets up to TechMpCost; the menu reads sets 7-$15"),
    ]),
    ("TechMpCost", "$CC:253B", 1, PARTS, "per part number: its MP cost", [
        _f(0, 1, "mp_cost", "decoded", "TechMpCost1-3 index it by the part (bit 7 masked); BattleSys_PayTechMp"),
    ]),
    ("TechTpCost", "$CC:26FA", 16, CHARACTERS, "per character id: the tech points for each of its 8 singles", [
        _f(0, 16, "tp_cost", "verified",
           "word k = the need for single k + 1 once k are learned (SpendTechPoints reads id x 16 + count x 2); "
           + RUN),
    ]),
    ("CharTechs", "$CC:276A", 2, CHARACTERS, "per character id: first single id, how many", [
        _f(0, 1, "first", "verified", "TryNextTech: the next single = first + count; = $FD:A89D; " + RUN),
        _f(1, 1, "count", "verified", "LearnSingleTech sets +$02 bit 4 at this count; " + RUN),
    ]),
    ("ComboTechs", "$CC:2778", COMBO_SIZE, 25, "the double and triple tech records, $FF-ended", [
        _f(0, 1, "member_bits", "verified", "$80 >> id per member; matched against BuildComboMasks; " + RUN),
        _f(1, 1, "first_tech_id", "verified", "LearnComboTechs counts the id up; " + RUN),
        _f(2, 1, "tech_count", "verified", "3 for the 15 pair records, 1 for the 10 trio records; " + RUN),
        _f(3, 2, "req_addr_cc", "verified",
           "3 requirement bytes per tech: each member's minimum count of singles (member order), $FF third for a "
           "pair; " + RUN),
    ]),
    ("TechState", "$CC:0230", TECH_STATE_SIZE, 1, "the eighth MenuRom_CharRecordInit record: the new-game tech state", [
        _f(0, 7, "tech_count", "verified", "Battle_TechCount $7E:2830: singles learned per character; " + RUN),
        _f(7, 7, "tech_bits1", "verified", "Battle_TechBits1: bit 7 down = the singles in order; " + RUN),
        _f(14, 15, "tech_bits2", "verified", "Battle_TechBits2: one byte per pair record, 3 doubles from bit 7; " + RUN),
        _f(29, 15, "tech_bits3", "verified", "Battle_TechBits3: one byte per triple, bit 7 ($70-$74: no record); " + RUN),
    ]),
    ("PcTechAct", "$CD:45A6", TECH_ACT_SIZE, TECHS, "per tech id: its animation (BattleAct_LoadTech)", [
        _f(0, 1, "script", "decoded", "PcTechScripts index ($CD:5EF0, 128 words of bank-$CE offsets)"),
        _f(1, 2, "gfx", "partial", "BattleRom_PcTechAct.GfxA/GfxB"),
        _f(3, 1, "frames", "decoded", "BattleRom_PcTechAct.Frames (below 80 in every tech)"),
        _f(4, 3, "pal_obj_arg", "partial", "BattleRom_PcTechAct.Pal/Obj/Arg"),
    ]),
)


VECTORS = WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "techs" / "tp_vectors.json"


def read_rom(path):
    data = Path(path).read_bytes()
    if len(data) == ROM_SIZE + 512:
        data = data[512:]
    if len(data) != ROM_SIZE:
        raise SystemExit("expected a 4 MiB Chrono Trigger ROM")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("decode").add_argument("--rom", default=str(ROM_PATH))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(ROM_PATH))
    k.add_argument("--run", action="store_true", help="also run the ROM's tech-point routine")
    v = sub.add_parser("vectors")
    group = v.add_mutually_exclusive_group(required=True)
    group.add_argument("--out")
    group.add_argument("--check")
    args = parser.parse_args()

    if args.command == "vectors":
        text = vectors_text()
        if args.out:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(text)
        elif Path(args.check).read_text() != text:
            raise SystemExit("vectors differ from ct_techs.py; regenerate with --out")
        print(f"{len(synthetic_cases()['cases'])} synthetic tech-point cases")
        return
    rom = read_rom(args.rom)
    if args.command == "decode":
        print(json.dumps(decode_all(rom), indent=1))
    else:
        results = code_claims(rom) + data_claims(rom) + (asm_claims() if REF.exists() else [])
        if args.run:
            results += run_claims(rom) + synthetic_run_claims(rom)
        for name, ok, detail in results:
            print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f"  [{detail}]" if detail and not ok else ""))
        failed = [r for r in results if not r[1]]
        print(f"{len(results) - len(failed)} of {len(results)} tech claims hold")
        if failed:
            sys.exit(1)


if __name__ == "__main__":
    main()
