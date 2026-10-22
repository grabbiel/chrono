#!/usr/bin/env python3
"""Chrono Trigger playable characters: record layout, the level-up rule, evidence.

The seven playable characters start from the records at $CC:0000 (8 x $50 B
copied to WRAM $7E:2600 for a new game; ids 0-6 are characters, the eighth
record is not). Levels grow them through three per-character tables and one
shared table:

  HpGrowth   $CC:258A  8 B per id: 4 (top level, HP gain) pairs
  MpGrowth   $CC:25C2  8 B per id: the same for MP
  StatGrowth $CC:25FA  7 B per id: growth per level of 7 stats (growth order)
  ExpToLevel $CC:2632  100 words: experience from level L to L + 1

The rule (BattleSys_LevelUpStep $C1:F623, BattleSys_ApplyExpStep $C1:F7B9,
BattleSys_GrowHpMp $C1:F871, BattleSys_AddExp $C1:F908) is in `level_up`;
`level_curve` applies it from a record's level to 99. Each claim is
re-derived three ways by `check`: from the ROM's own code bytes (operands
and constants of the routines), from ChronoRET's matched source (MIT;
refs/ChronoRET), and from the ROM's data (the records are consistent with
the tables). `check --run` (and tests/test_characters.py) also runs the
ROM's own level-up routine in ChronoRET's 65816 interpreter and compares it
with `level_up`: the 7 records to level 99, and the synthetic vectors with
their growth rows patched into a copy of the ROM.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_characters.py decode [--rom PATH]           the 7 records and growth rows (JSON)
    ct_characters.py curve <id> [--rom PATH]       the level curve of character id 0-6 (JSON)
    ct_characters.py check [--rom PATH] [--run]    every evidence claim (exit 1 on a failure);
                                                   --run also executes the ROM's routine
    ct_characters.py vectors (--out | --check) P   synthetic curve vectors for the Swift tests
"""

import argparse
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


def snes(offset):
    return f"${0xC0 | offset >> 16:02X}:{offset & 0xFFFF:04X}"


# --- Tables --------------------------------------------------------------------------

RECORDS_PC = pc(0xCC, 0x0000)        # MenuRom_CharRecordInit
RECORD_SIZE = 0x50
CHARACTERS = 7                       # ids 0-6 (!Pc_NumChars)
# CT's standard id order (ChronoRET constants_battle.inc names 3-6, "inferred");
# the code agrees: ids 1 and 2 attack with hit (AttackFormulaB: bow, gun), id 5
# with power alone and keeps no weapon (fists), id 6 starts at level 37.
NAMES = ("crono", "marle", "lucca", "robo", "frog", "ayla", "magus")
INIT_RECORDS = 8                     # Menu_InitNewGameData copies $280 B
OFFSET_TABLE_PC = pc(0xCC, 0xFC1E)   # BattleRom_CharRecOffset: id * $50
HP_GROWTH_PC = pc(0xCC, 0x258A)
MP_GROWTH_PC = pc(0xCC, 0x25C2)
STAT_GROWTH_PC = pc(0xCC, 0x25FA)
EXP_TO_LEVEL_PC = pc(0xCC, 0x2632)
GROWTH_ROW = 8                       # bytes per HP or MP row
STAT_GROWTH_ROW = 7
LEVEL_MAX = 99
GROWTH_DIVISOR = 100
STAT_CAP, SPEED_CAP_AT_LEVEL_UP = 99, 50
MAX_HP_CAP, MAX_MP_CAP = 999, 99
EXP_CAP_HI, EXP_CAP_LO_OVER, EXP_CAP_LO = 0x98, 0x9680, 0x967F

ITEM_TABLES_A_PC = pc(0xFF, 0xCF0E)  # MenuRom_ItemTablesA: 5 bank-$CC addresses
ITEM_SIZES_A_PC = pc(0xFF, 0xCF18)   # MenuRom_ItemRecSizesA
ITEM_BOUNDS_PC = pc(0xC2, 0x88A7)    # Menu_ItemCategoryBounds
ITEM_NAMES_PC = pc(0xCC, 0x0B5E)     # 11 B per id: icon byte, 10 glyphs
ITEM_NAME_SIZE = 11
EQUIP_MASK_BYTE = 3                  # record A byte 3 (Menu_BuildItemTables)
CHAR_BITS_PC = pc(0xFF, 0xF9BB)      # BankFF_CharBits: $80 >> id

# Record order of the seven stats (+$0B-$11, Menu_CharRec.Stats index 0-6).
STATS = ("power", "stamina", "speed", "magic", "hit", "evade", "magic_defense")
# The growth order: byte k of a StatGrowth row and of .GrowBase (+$2F + k)
# belongs to stat GROWTH_ORDER[k] (BattleSys_LevelUpStep; Menu_ApplyStatItem).
GROWTH_ORDER = (0, 1, 2, 4, 5, 3, 6)
SPEED = 2                            # not recomputed by the level-up rule

SLOTS = ("weapon", "armor", "helmet", "accessory")      # item categories 0-3
SLOT_OFFSET = {"helmet": 0x27, "armor": 0x28, "weapon": 0x29, "accessory": 0x2A}

# The decoded fields: (offset, size, name, status, evidence). Every byte of a
# record is in exactly one entry; `undecoded` spans are never written.
FIELDS = (
    (0x00, 1, "char_id", "verified",
     "PcStatBlk.CharId: BattleSys_GrowHpMp ($C1:F871) indexes HpGrowth/MpGrowth by it x 8, "
     "BattleSys_LevelUpStep ($C1:F623) StatGrowth by it x 7, Menu_CanEquip ($C2:93A8) BankFF_CharBits, "
     "Menu_CharCalcStats ($C2:916E) the attack formula (AND 7); ROM: record n holds n (n = 0-6)"),
    (0x01, 2, "unk01", "undecoded",
     "PcStatBlk.Unk01 bit 3 picks a PC for target handler $14 (ram_battle.inc); +$02 not traced"),
    (0x03, 2, "hp", "verified",
     "BattlerStats.CurHp ($5E30 = block + $03); Menu_EquipStatCat3 ($C2:9295) lowers it to the max; "
     "ROM: equals max_hp in all 7 records"),
    (0x05, 2, "max_hp", "verified",
     "BattleSys_GrowHpMp adds the HP gain (ADC $0005,X) and caps it at 999 (CMP #$03E7)"),
    (0x07, 2, "mp", "verified",
     "BattlerStats.CurMp ($5E34 = block + $07); Menu_CmdRefillByte7 copies the max's low byte; "
     "ROM: equals max_mp in all 7 records"),
    (0x09, 2, "max_mp", "verified",
     "BattleSys_GrowHpMp adds the MP gain (ADC $0009,X) and caps it at 99 (CMP #$0063)"),
    (0x0B, 1, "power", "verified",
     "stat 0: Menu_AttackFormulaA ($C2:91EB) 12 x stat 0 + 5 x weapon / 9 (ids 0, 3, 4, 6), "
     "Menu_AttackFormulaC ($C2:923C) 16 x stat 0 (id 5); BattleSys_CalcDamage kind 1 c.Unk63 (= +$36) x 12"),
    (0x0C, 1, "stamina", "verified",
     "stat 1: Menu_CharCalcStats defence = stat 1 + Menu_ArmorSum (helmet + armour) (LDA $9B1D; ADC $0DB6)"),
    (0x0D, 1, "speed", "verified",
     "stat 2: MenuRom_StatCaps ($FF:CF33) caps it at 16 (99 for the others); its StatGrowth byte is "
     "never read and BattleSys_LevelUpStep does not recompute it (caps it at 50)"),
    (0x0E, 1, "magic", "verified",
     "stat 3: BattleSys_CalcDamage kind 3 (c.Unk3F level x 12 + c.Unk66 (= +$39) x 12) x b9 / 15; "
     "BattleSys_UpdateKo revive HP = c.Unk66 x 5"),
    (0x0F, 1, "hit", "verified",
     "stat 4: Menu_AttackFormulaB ($C2:9223) 2 x (stat 4 + weapon) / 3 for ids 1 and 2; the hit roll "
     "(BattleSys_EffRecStatPair, BattleSys_RollHit) compares caster byte $3A (= derived stat 4) in 19 effect records"),
    (0x10, 1, "evade", "verified",
     "stat 5: the target byte $3B (= derived stat 5) of the same hit rolls; Menu_CharRecalc ($C2:9137) "
     "doubles derived stat 5 for accessory $A8"),
    (0x11, 1, "magic_defense", "verified",
     "stat 6: BattleSys_AdjustDefence ($C1:E65F) effect byte 6 = $3C takes the target's byte $3C "
     "(= derived stat 6) x 5 / 2, = $3E its byte $3E (derived defence = stamina + armour)"),
    (0x12, 1, "level", "verified",
     "BattleSys_ApplyExpStep ($C1:F7B9) INC, capped at 99; BattleSys_LevelUpStep multiplies by level - 1; "
     "ROM: exp and exp_to_next agree with ExpToLevel for all 7 records"),
    (0x13, 3, "exp", "verified",
     "BattleSys_AddExp ($C1:F908) 24-bit add with carry, capped at $98967F (9,999,999); "
     "ROM: equals the sum of ExpToLevel[1..level-1] in all 7 records"),
    (0x16, 3, "tech_points", "partial",
     "BattlerStats.TechPtTotal ($5E43 = block + $16), 24-bit; BattleSys_SpendTechPoints ($C1:F39A) "
     "adds a battle's tech points (ChronoRET: 'probably')"),
    (0x19, 14, "unk19", "undecoded",
     "+$19 target bit, +$1D/+$1E status bytes (BattlerStats.Status/Status2), +$1F-$21 target bytes; "
     "zero in the ROM records; not edited"),
    (0x27, 1, "helmet", "verified",
     "item category 2 ($7B-$93): Menu_EquipStatTable slot 2 (Menu_EquipStatCat2 adds it to "
     "Menu_ArmorSum); BankFF_EquipOffsets; ROM: each starting id is in category 2 and equippable by its owner"),
    (0x28, 1, "armor", "verified",
     "item category 1 ($5A-$7A): Menu_EquipStatTable slot 1 (Menu_EquipStatCat1); ROM as for helmet"),
    (0x29, 1, "weapon", "verified",
     "item category 0 ($00-$59): Menu_EquipStatWeapon (Menu_WeaponPower, the attack formulas' input); "
     "BankFF_LoadSlotPart re-equips +$27/+$28/+$2A/+$29 but skips +$29 for id 5; ROM as for helmet"),
    (0x2A, 1, "accessory", "verified",
     "item category 3 ($94-$BB): Menu_EquipStatCat3 (max HP bonus); Menu_CharRecalc tests it for $A8; "
     "ROM as for helmet"),
    (0x2B, 2, "exp_to_next", "verified",
     "PcStatBlk.ExpNeed: BattleSys_ApplyExpStep counts it down and reloads ExpToLevel[level] "
     "(LDA.l $CC2632,X), 0 at level 99; ROM: = ExpToLevel[level] in all 7 records"),
    (0x2D, 2, "tech_points_to_next", "partial",
     "BattlerStats.TechPtNeed ($5E5A = block + $2D): tech points still needed for the next single tech "
     "(BattleSys_TryNextTech; ChronoRET: 'probably')"),
    (0x2F, 7, "growth_base", "verified",
     "BattleSys_LevelUpStep: stat = growth_base[k] + growth[k] x (level - 1) / 100 for k = 0, 1, 3, 4, 5, 6 "
     "into stats 0, 1, 4, 5, 3, 6; Menu_ApplyStatItem ($C2:B2A7) raises the same pairs (MenuRom_StatItemStat, "
     "Menu_StatCountOfs), k = 2 with speed; ChronoRET's menu name .StatCounts is this block"),
    (0x36, 26, "derived", "partial",
     "Menu_CharRecalc's copy of the stats with equipment, attack, defence, max HP (+$36-$40); $FF in the "
     "ROM records (recomputed by the menu); +$41-$4F not traced; not edited"),
)

# Spans the builder may write (char_id is fixed by the record's slot).
WRITABLE = ("hp", "max_hp", "mp", "max_mp", "power", "stamina", "speed", "magic", "hit", "evade",
            "magic_defense", "level", "exp", "tech_points", "helmet", "armor", "weapon", "accessory",
            "exp_to_next", "tech_points_to_next", "growth_base")


def field(name):
    for offset, size, n, _, _ in FIELDS:
        if n == name:
            return offset, size
    raise KeyError(name)


def u(data, at, size):
    return int.from_bytes(data[at:at + size], "little")


# --- Codec ---------------------------------------------------------------------------

def decode_record(raw):
    """The decoded fields of one $50-byte record."""
    assert len(raw) == RECORD_SIZE
    value = {name: u(raw, *field(name)) for name in ("char_id", "hp", "max_hp", "mp", "max_mp", "level", "exp",
                                                      "exp_to_next", "tech_points", "tech_points_to_next")}
    value["stats"] = {s: raw[0x0B + i] for i, s in enumerate(STATS)}
    value["growth_base"] = {STATS[GROWTH_ORDER[k]]: raw[0x2F + k] for k in range(7)}
    value["equipment"] = {slot: raw[SLOT_OFFSET[slot]] for slot in ("helmet", "armor", "weapon", "accessory")}
    return value


def encode_record(base, value):
    """`base` with the writable fields of `value` (as decode_record gives) put in."""
    raw = bytearray(base)
    for name in ("hp", "max_hp", "mp", "max_mp", "level", "exp", "exp_to_next", "tech_points",
                 "tech_points_to_next"):
        offset, size = field(name)
        raw[offset:offset + size] = value[name].to_bytes(size, "little")
    for slot, item in value["equipment"].items():
        raw[SLOT_OFFSET[slot]] = item
    for i, s in enumerate(STATS):
        raw[0x0B + i] = value["stats"][s]
    for k in range(7):
        raw[0x2F + k] = value["growth_base"][STATS[GROWTH_ORDER[k]]]
    return bytes(raw)


def decode_growth(rom, cid):
    hp = rom[HP_GROWTH_PC + GROWTH_ROW * cid:HP_GROWTH_PC + GROWTH_ROW * (cid + 1)]
    mp = rom[MP_GROWTH_PC + GROWTH_ROW * cid:MP_GROWTH_PC + GROWTH_ROW * (cid + 1)]
    st = rom[STAT_GROWTH_PC + STAT_GROWTH_ROW * cid:STAT_GROWTH_PC + STAT_GROWTH_ROW * (cid + 1)]
    return {"hp": [[hp[2 * i], hp[2 * i + 1]] for i in range(4)],
            "mp": [[mp[2 * i], mp[2 * i + 1]] for i in range(4)],
            "stats": {STATS[GROWTH_ORDER[k]]: st[k] for k in range(7)}}


def encode_growth(growth):
    """(HP row, MP row, StatGrowth row) bytes."""
    hp = bytes(b for pair in growth["hp"] for b in pair)
    mp = bytes(b for pair in growth["mp"] for b in pair)
    st = bytes(growth["stats"][STATS[GROWTH_ORDER[k]]] for k in range(7))
    return hp, mp, st


def exp_to_level(rom):
    return [u(rom, EXP_TO_LEVEL_PC + 2 * i, 2) for i in range(LEVEL_MAX + 1)]


def record(rom, cid):
    return rom[RECORDS_PC + RECORD_SIZE * cid:RECORDS_PC + RECORD_SIZE * (cid + 1)]


def item_category(item, bounds):
    category = 0
    while category < 4 and item >= bounds[category + 1]:
        category += 1
    return category


def equip_mask(rom, item):
    """Menu_ItemEquipChars[item]: record A byte 3 below category 4, else 0."""
    bounds = rom[ITEM_BOUNDS_PC:ITEM_BOUNDS_PC + 6]
    category = item_category(item, bounds)
    if category >= 4:
        return 0
    table = u(rom, ITEM_TABLES_A_PC + 2 * category, 2)
    size = rom[ITEM_SIZES_A_PC + category]
    return rom[pc(0xCC, table + (item - bounds[category]) * size) + EQUIP_MASK_BYTE]


def decode_all(rom):
    return {"characters": [dict(decode_record(record(rom, c)), growth=decode_growth(rom, c))
                           for c in range(CHARACTERS)],
            "exp_to_level": exp_to_level(rom)}


# --- The level-up rule ----------------------------------------------------------------

def row_gain(row, level):
    """The gain of the first (top level, gain) pair whose top level is at least
    `level` (BattleSys_GrowHpMp). The game would scan on past the row's 8 bytes
    when none is; such a row is refused here."""
    for top, gain in row:
        if top >= level:
            return gain
    raise ValueError(f"no pair of the row reaches level {level}")


def add_exp(total, amount):
    """BattleSys_AddExp: 24-bit add with carry, then the cap as coded."""
    low = (total & 0xFFFF) + amount
    high = total >> 16
    if low > 0xFFFF:
        low &= 0xFFFF
        high = (high + 1) & 0xFF
    if high >= EXP_CAP_HI:
        high = EXP_CAP_HI
        if low >= EXP_CAP_LO_OVER:
            low = EXP_CAP_LO
    return high << 16 | low


def level_up(value, growth, table):
    """One level the game grants when the battle's experience covers
    exp_to_next: the record (decode_record form) after BattleSys_AddExp of
    exp_to_next and one BattleSys_LevelUpStep. Below level 99 only."""
    v = json.loads(json.dumps(value))
    assert 1 <= v["level"] < LEVEL_MAX
    v["exp"] = add_exp(v["exp"], v["exp_to_next"])
    # BattleSys_ApplyExpStep
    v["level"] = min(v["level"] + 1, LEVEL_MAX)
    v["exp_to_next"] = 0 if v["level"] >= LEVEL_MAX else table[v["level"]]
    # BattleSys_GrowHpMp (16-bit adds)
    v["max_hp"] = min((v["max_hp"] + row_gain(growth["hp"], v["level"])) & 0xFFFF, MAX_HP_CAP)
    v["max_mp"] = min((v["max_mp"] + row_gain(growth["mp"], v["level"])) & 0xFFFF, MAX_MP_CAP)
    # stats: base + growth x (level - 1) / 100 as an 8-bit sum, speed skipped
    stats = [v["stats"][s] for s in STATS]
    for k in range(7):
        if GROWTH_ORDER[k] == SPEED:
            continue
        name = STATS[GROWTH_ORDER[k]]
        quotient = growth["stats"][name] * ((v["level"] - 1) & 0xFF) // GROWTH_DIVISOR
        stats[GROWTH_ORDER[k]] = (v["growth_base"][name] + (quotient & 0xFF)) & 0xFF
    stats = [min(s, STAT_CAP) for s in stats]
    stats[SPEED] = min(stats[SPEED], SPEED_CAP_AT_LEVEL_UP)
    v["stats"] = dict(zip(STATS, stats))
    return v


def level_curve(value, growth, table):
    """The record at its own level and after each level-up to 99."""
    out = [value]
    while out[-1]["level"] < LEVEL_MAX:
        out.append(level_up(out[-1], growth, table))
    return out


# A curve row, as the Swift twin (CTLevelCurve) and `chronoforge characters
# curve --json` give it: these columns, the stats in record order.
CURVE_COLUMNS = ("level", "exp", "expToNext", "maxHp", "maxMp") + STATS


def curve_rows(curve):
    return [[v["level"], v["exp"], v["exp_to_next"], v["max_hp"], v["max_mp"]] + [v["stats"][s] for s in STATS]
            for v in curve]


# --- Evidence ---------------------------------------------------------------------------

def _body(rom, bank, start, end):
    return bytes(rom[pc(bank, start):pc(bank, end) + 1])


def _has(body, *patterns):
    return all(p in body for p in patterns)


def levelup_triplets(rom):
    """(growth byte k, growth-base offset, stat offset) of each step of
    BattleSys_LevelUpStep, from its code bytes: LDA.l $CC000k,X (BF 0k 00 CC)
    of the growth row, then LDA.w $00gg,X / TAX / STX $28 / CLC / ADC $2C /
    LDX $B285 / STA.w $00ss,X."""
    body = _body(rom, 0xC1, 0xF623, 0xF7B8)
    ks = [m[0] for m in re.findall(rb"\xbf([\x00-\x07])\x00\xcc", body)]
    pairs = re.findall(rb"\xbd(.)\x00\xaa\x86\x28\x18\x65\x2c\xae\x85\xb2\x9d(.)\x00", body, re.S)
    return [(k, gb[0], st[0]) for k, (gb, st) in zip(ks, pairs)]


def code_claims(rom):
    """Claims read from the ROM's code bytes: [(name, ok, detail)]."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    up = _body(rom, 0xC1, 0xF623, 0xF7B8)
    trip = levelup_triplets(rom)
    want = [(k, 0x2F + k, 0x0B + GROWTH_ORDER[k]) for k in range(7) if GROWTH_ORDER[k] != SPEED]
    claim("LevelUpStep stat steps (growth byte, base offset, stat offset)", trip == want, repr(trip))
    claim("LevelUpStep row = id x 7 + $25FA; level - 1; divisor 100",
          _has(up, b"\xa2\x07\x00\x86\x2a", b"\x69\xfa\x25", b"\xbd\x12\x00\x3a", b"\xa2\x64\x00\x86\x2a"))
    claim("LevelUpStep caps 7 stats from +$0B at 99, then +$0D at 50",
          _has(up, b"\xbd\x0b\x00\xc9\x63\x90\x05\xa9\x63\x9d\x0b\x00\xe8\xc8\xc0\x07\x00",
               b"\xa9\x32\xae\x85\xb2\xdd\x0d\x00\xb0\x05\xa9\x32\x9d\x0d\x00"))
    grow = _body(rom, 0xC1, 0xF871, 0xF907)
    claim("GrowHpMp rows id x 8; first pair with top >= level; +$05 capped 999; +$09 capped 99",
          _has(grow, b"\xbd\x00\x00\x0a\x0a\x0a", b"\xbf\x8a\x25\xcc\xae\x85\xb2\xdd\x12\x00\x90",
               b"\xbf\x8b\x25\xcc", b"\x7d\x05\x00\x9d\x05\x00\xc9\xe7\x03",
               b"\xbf\xc2\x25\xcc\xae\x85\xb2\xdd\x12\x00\x90", b"\xbf\xc3\x25\xcc",
               b"\x7d\x09\x00\x9d\x09\x00\xc9\x63\x00"))
    apply_ = _body(rom, 0xC1, 0xF7B9, 0xF870)
    claim("ApplyExpStep: +$2B counted down, +$12 + 1 capped 99, +$2B = ExpToLevel[level], 0 at 99",
          _has(apply_, b"\xdd\x2b\x00\x90", b"\xbd\x12\x00\x1a\x9d\x12\x00", b"\xa9\x63\xdd\x12\x00",
               b"\xbd\x12\x00\x0a\xaa\xc2\x20\xbf\x32\x26\xcc\xae\x85\xb2\x9d\x2b\x00",
               b"\x9d\x2b\x00\x9d\x2c\x00"))
    add = _body(rom, 0xC1, 0xF908, 0xF93D)
    claim("AddExp: 24-bit +$13 with carry into +$15, capped $98:967F",
          _has(add, b"\xbd\x13\x00\x18\x6d\x8c\xb2\x9d\x13\x00", b"\xfe\x15\x00", b"\xc9\x98",
               b"\xc9\x80\x96", b"\xa9\x7f\x96"))
    init = _body(rom, 0xC2, 0x956E, 0x95BA)
    claim("Menu_InitNewGameData copies $280 B from $CC:0000 to $7E:2600",
          b"\xa2\x00\x00\xa0\x00\x26\xa9\x7f\x02\x54\x7e\xcc" in init)
    offsets = [u(rom, OFFSET_TABLE_PC + 2 * i, 2) for i in range(CHARACTERS)]
    claim("BattleRom_CharRecOffset = id x $50", offsets == [RECORD_SIZE * i for i in range(CHARACTERS)])

    # Stat identities.
    calc = _body(rom, 0xC2, 0x916E, 0x91DA)
    claim("CharCalcStats: stat s = .Stats[s] + boost, capped by MenuRom_StatCaps; defence = stat 1 + armour",
          _has(calc, b"\xbf\x2c\xcf\xff\xa8\xb9\x9b\x9a\x18\x79\xae\x0d\xdf\x33\xcf\xff",
               b"\xad\x1d\x9b\x18\x6d\xb6\x0d"))
    order = list(rom[pc(0xFF, 0xCF2C):pc(0xFF, 0xCF2C) + 7])
    caps = list(rom[pc(0xFF, 0xCF33):pc(0xFF, 0xCF33) + 7])
    claim("MenuRom_StatCaps: speed (stat 2) 16, the others 99",
          sorted(order) == list(range(7)) and all(c == (16 if s == SPEED else 99) for s, c in zip(order, caps)),
          f"order {order} caps {caps}")
    forms = [u(rom, pc(0xC2, 0x91DB) + 2 * i, 2) for i in range(8)]
    claim("Menu_AttackFormulas: B ($9223) for ids 1, 2; C ($923C) for id 5; A ($91EB) otherwise",
          forms == [0x91EB, 0x9223, 0x9223, 0x91EB, 0x91EB, 0x923C, 0x91EB, 0x91EB], repr(forms))
    claim("AttackFormulaA 12 x stat 0, B stat 4 + weapon, C 16 x stat 0 + table[level]",
          b"\xa9\x0c\x8f\x02\x42\x00\xad\x1c\x9b" in _body(rom, 0xC2, 0x91EB, 0x9222)
          and b"\xad\x20\x9b\xc2\x21\x65\x00\x0a" in _body(rom, 0xC2, 0x9223, 0x923B)
          and _has(_body(rom, 0xC2, 0x923C, 0x9260), b"\xa9\x10\x8f\x02\x42\x00\xad\x1c\x9b", b"\xad\xa2\x9a"))
    recalc = _body(rom, 0xC2, 0x9137, 0x916D)
    claim("CharRecalc: accessory $A8 doubles stat 5; 11 derived bytes copied to record + $36",
          _has(recalc, b"\xc9\xa8\xd0\x03\x0e\x21\x9b", b"\xa2\x1c\x9b\x98\x18\x69\x36\x00\xa8\xa9\x0a\x00"))
    pair = _body(rom, 0xC1, 0xD174, 0xD19F)
    claim("EffRecStatPair: caster byte at block + effect byte 3, target byte at block + effect byte 4",
          _has(pair, b"\xad\xe9\xae", b"\xbd\x2d\x5e\x85\x16", b"\xad\xea\xae", b"\xbd\x2d\x5e\x85\x18"))
    pairs = [tuple(rom[pc(0xCC, 0x213F) + 12 * i + 3:pc(0xCC, 0x213F) + 12 * i + 5]) for i in range(72)]
    hits = pairs.count((0x3A, 0x3B))
    others = {p for p in pairs if p != (0, 0) and p != (0x3A, 0x3B)}
    claim("effect records: (byte 3, byte 4) = ($3A, $3B) = derived stats 4 / 5 is the hit-roll pair",
          hits >= 10 and all(pairs.count(p) <= 2 for p in others), f"{hits} records")
    defence = _body(rom, 0xC1, 0xE65F, 0xE76D)
    claim("AdjustDefence: effect byte 6 $3E / $3C pick the target's block + $3E / + $3C",
          _has(defence, b"\xa5\x18\xc9\x3e\xd0", b"\xbd\x2d\x5e\x85\x18", b"\xc9\x3c\xd0"))
    damage = _body(rom, 0xC1, 0xE0F5, 0xE63A)
    claim("CalcDamage reads the caster's level (+$12 = $5E3F) and derived stat 3 (+$39 = $5E66)",
          _has(damage, b"\xbd\x3f\x5e", b"\xbd\x66\x5e"))
    item = _body(rom, 0xC2, 0xB2A7, 0xB315)
    claim("ApplyStatItem raises .Stats[MenuRom_StatItemStat[kind]] and +$2F + Menu_StatCountOfs[kind]",
          _has(item, b"\xbf\x15\xb3\xc2", b"\xbf\x2b\xcf\xff", b"\xfe\x0b\x00", b"\xbd\x2f\x00\xc9\x63",
               b"\x9d\x2f\x00"))
    count_ofs = list(rom[pc(0xC2, 0xB316):pc(0xC2, 0xB316) + 6])
    item_stat = order[:6]                       # MenuRom_StatItemStat = $FF:CF2B, kinds 1-6
    menu_pairs = sorted(zip(count_ofs, item_stat))
    level_pairs = sorted((k, GROWTH_ORDER[k]) for k in range(7) if k != 6)
    claim("the stat items pair growth-base bytes and stats as the level-up does",
          menu_pairs == level_pairs, f"menu {menu_pairs}")

    # Equipment.
    slots = [u(rom, pc(0xC2, 0x926E) + 2 * i, 2) for i in range(4)]
    claim("Menu_EquipStatTable: weapon, cat 1, cat 2, accessory routines",
          slots == [0x9276, 0x9281, 0x9286, 0x9295]
          and b"\xae\xb9\x9a" in _body(rom, 0xC2, 0x9276, 0x9280)
          and b"\xae\xb8\x9a" in _body(rom, 0xC2, 0x9281, 0x9285)
          and b"\xae\xb7\x9a" in _body(rom, 0xC2, 0x9286, 0x9294)
          and b"\xae\xba\x9a" in _body(rom, 0xC2, 0x9295, 0x92C0), repr(slots))
    claim("BankFF_EquipOffsets = +$27, +$28, +$2A, +$29; id 5 ($190 = 5 x $50) skips the last",
          list(rom[pc(0xFF, 0xFBCF):pc(0xFF, 0xFBCF) + 4]) == [0x27, 0x28, 0x2A, 0x29]
          and b"\xc9\x90\x01\xd0\x02\xc6\x04" in _body(rom, 0xFF, 0xFAED, 0xFBC0))
    claim("Menu_CanEquip: Menu_ItemEquipChars[id] AND BankFF_CharBits[record byte 0]",
          _has(_body(rom, 0xC2, 0x93A8, 0x93BE), b"\xbd\x00\x7a", b"\xae\x90\x9a\x3f\xbb\xf9\xff"))
    claim("BankFF_CharBits = $80 >> id", list(rom[CHAR_BITS_PC:CHAR_BITS_PC + 9]) == [0x80 >> i for i in range(8)] + [0])
    claim("Menu_BuildItemTables: Menu_ItemEquipChars = record A byte 3",
          b"\xbf\x03\x00\xcc\x99\x00\x7a" in _body(rom, 0xC2, 0x9875, 0x9987))
    claim("Menu_ItemCategoryBounds $00 $5A $7B $94 $BC $F2",
          list(rom[ITEM_BOUNDS_PC:ITEM_BOUNDS_PC + 6]) == [0x00, 0x5A, 0x7B, 0x94, 0xBC, 0xF2])
    return out


# Records whose exp_to_next is another level's ExpToLevel entry: id 6 starts
# at level 37 with the level-40 entry, so it needs more for its first level.
EXP_QUIRKS = {6: 40}


def data_claims(rom):
    """Claims about the ROM's data, given the decoded layout: [(name, ok, detail)]."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    table = exp_to_level(rom)
    claim("ExpToLevel: 0, then strictly increasing to level 98, 0 at 99",
          table[0] == 0 and all(a < b for a, b in zip(table[1:99], table[2:99])) and table[99] == 0)
    bounds = rom[ITEM_BOUNDS_PC:ITEM_BOUNDS_PC + 6]
    for c in range(CHARACTERS):
        v = decode_record(record(rom, c))
        g = decode_growth(rom, c)
        lv = v["level"]
        claim(f"id {c}: record byte 0", v["char_id"] == c)
        claim(f"id {c}: hp = max_hp <= 999, mp = max_mp <= 99",
              v["hp"] == v["max_hp"] <= MAX_HP_CAP and v["mp"] == v["max_mp"] <= MAX_MP_CAP)
        need_at = EXP_QUIRKS.get(c, lv)
        claim(f"id {c}: exp = sum ExpToLevel[1..{lv - 1}], exp_to_next = ExpToLevel[{need_at}]",
              v["exp"] == sum(table[1:lv]) and v["exp_to_next"] == table[need_at], f"{v['exp']} {v['exp_to_next']}")
        claim(f"id {c}: stats and growth base within 0-99, speed <= 16",
              all(x <= STAT_CAP for x in v["stats"].values()) and all(x <= STAT_CAP for x in v["growth_base"].values())
              and v["stats"]["speed"] <= 16)
        for slot, item in v["equipment"].items():
            category = SLOTS.index(slot)
            claim(f"id {c}: {slot} ${item:02X} is in category {category} and equippable",
                  item_category(item, bounds) == category and equip_mask(rom, item) & (0x80 >> c))
        claim(f"id {c}: HP and MP rows reach level 99",
              any(t >= LEVEL_MAX for t, _ in g["hp"]) and any(t >= LEVEL_MAX for t, _ in g["mp"]))
        claim(f"id {c}: speed's growth byte and growth base are 0 (unused)",
              g["stats"]["speed"] == 0 and v["growth_base"]["speed"] == 0)
        # The two stats every record agrees on; the others may sit off the curve
        # until the first level-up (see off_curve).
        claim(f"id {c}: power and stamina are on the level-{lv} curve",
              all(v["stats"][s] == v["growth_base"][s] + g["stats"][s] * (lv - 1) // 100 for s in ("power", "stamina")))
    weapons = [equip_mask(rom, i) for i in range(1, bounds[1])]
    claim("every weapon with a non-zero mask names one character",
          all(m & (m - 1) == 0 for m in weapons), "")
    return out


class RomLevelUp:
    """The game's own level-up, run: BattleSys_AddExp ($C1:F908) of the
    record's exp_to_next, then one BattleSys_LevelUpStep ($C1:F623), on PC
    slot 0's block ($7E:5E2D), executed by ChronoRET's 65816 interpreter
    (refs/ChronoRET/tools/absint.py) over `image` (the ROM, or a copy with
    other growth rows or ExpToLevel put in). Every value is known, so each
    run has one end; a callee it could not follow is an error."""

    BLOCK = 0x7E5E2D                 # BattlerStats[0] + $2D = PcStatBlk of slot 0
    EXP_REC, EXP_AMOUNT, SLOT = 0x7EB285, 0x7EB28C, 0x7EB1F4
    REWARD_BYTES = (0x7EB2AF, 0x7EB2B0, 0x7EB311)
    STATUS, KO = 0x1D, 0x80          # PcStatBlk.Status: ApplyExpStep skips a KO'd PC

    def __init__(self, image, ref=REF):
        if str(ref / "tools") not in sys.path:
            sys.path.insert(0, str(ref / "tools"))
        import absint
        self.absint = absint
        self.machine = absint.Machine(bytes(image), bytearray(b"\x01") * len(image),
                                      max_steps=10 ** 7, callee_steps=10 ** 6)
        self.machine.widen_after = 10 ** 9   # loops run exactly: nothing is unknown

    def _run(self, entry, x, known):
        s = self.absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, 0, 0, x, 0
        s.d, s.db, s.m, s.xf, s.c = 0, 0x7E, True, False, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = self.absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != "rts" or self.machine.opaque:
            raise RuntimeError(f"${entry:06X}: {[how for _, how in ends]} opaque {self.machine.opaque}")
        return {**known, **ends[0][0].mem}

    def step(self, raw):
        """The record (bytes) after one level-up; +$1D bit 7 is cleared first."""
        rec = bytearray(raw)
        rec[self.STATUS] &= ~self.KO & 0xFF
        known = {a: 0 for a in range(0x7E0000, 0x7E0040)}        # direct page
        known.update({self.BLOCK + i: b for i, b in enumerate(rec)})
        for addr, value in ((self.EXP_REC, self.BLOCK & 0xFFFF), (self.EXP_AMOUNT, u(rec, *field("exp_to_next"))),
                            (self.SLOT, 0)):
            known[addr], known[addr + 1] = value & 0xFF, value >> 8
        known.update({a: 0 for a in self.REWARD_BYTES})
        mem = self._run(0xC1F908, self.BLOCK & 0xFFFF, known)
        mem = self._run(0xC1F623, 0, mem)
        if mem[self.EXP_AMOUNT] or mem[self.EXP_AMOUNT + 1]:
            raise RuntimeError("the experience was not used up by one level")
        out = bytes(mem[self.BLOCK + i] for i in range(RECORD_SIZE))
        if any(b is None for b in out):
            raise RuntimeError("an unknown byte in the record")
        return out


def patched_image(rom, cid, growth=None, table=None):
    """A copy of `rom` with character `cid`'s growth rows and the ExpToLevel table replaced."""
    image = bytearray(rom)
    if growth is not None:
        hp, mp, st = encode_growth(growth)
        image[HP_GROWTH_PC + GROWTH_ROW * cid:HP_GROWTH_PC + GROWTH_ROW * (cid + 1)] = hp
        image[MP_GROWTH_PC + GROWTH_ROW * cid:MP_GROWTH_PC + GROWTH_ROW * (cid + 1)] = mp
        image[STAT_GROWTH_PC + STAT_GROWTH_ROW * cid:STAT_GROWTH_PC + STAT_GROWTH_ROW * (cid + 1)] = st
    if table is not None:
        image[EXP_TO_LEVEL_PC:EXP_TO_LEVEL_PC + 2 * (LEVEL_MAX + 1)] = b"".join(w.to_bytes(2, "little") for w in table)
    return bytes(image)


def run_claims(rom, levels=None, ref=REF):
    """The ROM's routine against `level_up` for the 7 records, each from its
    level to 99 (or `levels` level-ups): [(name, ok, detail)]."""
    runner = RomLevelUp(rom, ref)
    table = exp_to_level(rom)
    out = []
    for c in range(CHARACTERS):
        raw = record(rom, c)
        value, growth = decode_record(raw), decode_growth(rom, c)
        lv, bad = value["level"], None
        for _ in range(levels or LEVEL_MAX):
            if value["level"] >= LEVEL_MAX:
                break
            raw, value = runner.step(raw), level_up(value, growth, table)
            if decode_record(raw) != value:
                bad = value["level"]
                break
        out.append((f"id {c}: the ROM's AddExp + LevelUpStep = level_up, level {lv} to {value['level']}",
                    bad is None, f"differs at level {bad}"))
    return out


def with_row(value, row):
    """`value` (decode_record form) at a curve_rows row."""
    v = json.loads(json.dumps(value))
    v.update(level=row[0], exp=row[1], exp_to_next=row[2], max_hp=row[3], max_mp=row[4], stats=dict(zip(STATS, row[5:])))
    return v


def synthetic_run_claims(rom, points=6, ref=REF):
    """The ROM's routine, with each synthetic case's growth rows and ExpToLevel
    patched into a copy of the ROM, against the vectors: one level-up from
    the first two levels, the last and `points` levels between."""
    vectors = synthetic_cases()
    out = []
    for n, case in enumerate(vectors["cases"]):
        cid = n % CHARACTERS
        raw = bytearray.fromhex(case["record"])
        raw[0] = cid                                     # the rows are indexed by it
        runner = RomLevelUp(patched_image(rom, cid, case["growth"], vectors["expToLevel"]), ref)
        rows = case["curve"]
        last = len(rows) - 1
        picks = sorted({0, 1, last - 1, *(i * last // points for i in range(points))} & set(range(last)))
        bad = None
        for i in picks:
            stepped = runner.step(encode_record(raw, with_row(decode_record(bytes(raw)), rows[i])))
            if curve_rows([decode_record(stepped)])[0] != rows[i + 1]:
                bad = rows[i]["level"]
                break
        out.append((f"synthetic case {n}: the ROM's routine with its rows patched in = the vectors "
                    f"({len(picks)} level-ups)", bad is None, f"differs after level {bad}"))
    return out


def off_curve(value, growth):
    """Stats whose starting value differs from growth_base + growth x (level-1)/100:
    the first level-up recomputes them."""
    lv = value["level"]
    out = {}
    for k in range(7):
        s = STATS[GROWTH_ORDER[k]]
        if GROWTH_ORDER[k] == SPEED:
            continue
        expect = min((value["growth_base"][s] + growth["stats"][s] * (lv - 1) // GROWTH_DIVISOR) & 0xFF, STAT_CAP)
        if expect != value["stats"][s]:
            out[s] = (value["stats"][s], expect)
    return out


# ChronoRET source claims: (file under asm/, routine label, lines that must
# appear in its body, in order).
ASM_CLAIMS = (
    ("bankC1/bankC1.asm", "BattleSys_LevelUpStep",
     ("JSR BattleSys_ApplyExpStep", "JSR BattleSys_GrowHpMp", "ADC.w #!BattleRom_StatGrowth&$FFFF",
      "LDA.w PcStatBlk.GrowBase,X", "STA.w PcStatBlk.Unk0B,X", "LDA.w PcStatBlk.GrowBase+1,X",
      "STA.w PcStatBlk.Unk0C,X", "LDA.w PcStatBlk.GrowBase+3,X", "STA.w PcStatBlk.Unk0F,X",
      "LDA.w PcStatBlk.GrowBase+4,X", "STA.w PcStatBlk.Unk10,X", "LDA.w PcStatBlk.GrowBase+5,X",
      "STA.w PcStatBlk.Unk0E,X", "LDA.w PcStatBlk.GrowBase+6,X", "STA.w PcStatBlk.Unk11,X",
      "CMP.b #!Battle_GrowStatMax", "LDA.b #!Battle_GrowStat0DMax")),
    ("bankC1/bankC1.asm", "BattleSys_ApplyExpStep",
     ("CMP.w PcStatBlk.ExpNeed,X", "INC A", "STA.w PcStatBlk.Level,X", "LDA.l !BattleRom_ExpToLevel,X",
      "STA.w PcStatBlk.ExpNeed,X")),
    ("bankC1/bankC1.asm", "BattleSys_GrowHpMp",
     ("LDA.l !BattleRom_HpGrowth,X", "CMP.w PcStatBlk.Level,X", "ADC.w PcStatBlk.MaxHp,X",
      "CMP.w #!Battle_MaxHpCap", "LDA.l !BattleRom_MpGrowth,X", "ADC.w PcStatBlk.MaxMp,X",
      "CMP.w #!Battle_MaxMpCap")),
    ("bankC1/bankC1.asm", "BattleSys_AddExp",
     ("ADC.w !Battle_UnkB28C", "STA.w PcStatBlk.Exp,X", "INC.w PcStatBlk.Exp+2,X", "CMP.b #!Battle_TotalCapHi")),
    ("bankC2/bankC2.asm", "Menu_InitNewGameData",
     ("LDX.w #!MenuRom_CharRecordInit", "LDY.w #!Menu_CharRecords", "LDA.w #!Menu_CharRecordInitSize-1")),
    ("bankC2/bankC2.asm", "Menu_CharCalcStats",
     ("LDA.l !MenuRom_StatOrder,X", "LDA.w !Menu_CurCharRec+Menu_CharRec.Stats,Y", "CMP.l !MenuRom_StatCaps,X",
      "JSR (Menu_AttackFormulas,X)", "LDA.w !Menu_CurStats+1", "ADC.w !Menu_ArmorSum", "STA.w !Menu_CurDefense")),
    ("bankC2/bankC2.asm", "Menu_AttackFormulaA", ("LDA.b #!Menu_AtkStatMulA", "LDA.w !Menu_CurStats")),
    ("bankC2/bankC2.asm", "Menu_AttackFormulaB", ("LDA.w !Menu_CurStats+4", "ADC.b !Menu_Tmp00")),
    ("bankC2/bankC2.asm", "Menu_AttackFormulaC",
     ("LDA.w !Menu_CurStats", "LDA.w !Menu_CurCharRec+Menu_CharRec.Unk12", "LDA.l !MenuRom_Char5Attack,X")),
    ("bankC2/bankC2.asm", "Menu_CharRecalc",
     ("CMP.b #!Menu_DoubleStat5Item", "ASL.w !Menu_CurStats+5", "ADC.w #Menu_CharRec.Derived")),
    ("bankC2/bankC2.asm", "Menu_ApplyStatItem",
     ("LDA.l Menu_StatCountOfs-1,X", "LDA.l !MenuRom_StatItemStat,X", "INC.w Menu_CharRec.Stats,X",
      "LDA.w Menu_CharRec.StatCounts,X", "STA.w Menu_CharRec.StatCounts,X")),
    ("bankC2/bankC2.asm", "Menu_EquipStatWeapon", ("LDX.w !Menu_CurCharRec+Menu_CharRec.Unk29",)),
    ("bankC2/bankC2.asm", "Menu_EquipStatCat1", ("LDX.w !Menu_CurCharRec+Menu_CharRec.Unk28",)),
    ("bankC2/bankC2.asm", "Menu_EquipStatCat2", ("LDX.w !Menu_CurCharRec+Menu_CharRec.Unk27", "ADC.w !Menu_ArmorSum")),
    ("bankC2/bankC2.asm", "Menu_EquipStatCat3", ("LDX.w !Menu_CurCharRec+Menu_CharRec.Unk2A",)),
    ("bankC2/bankC2.asm", "Menu_CanEquip", ("LDA.w !Menu_ItemEquipChars,X", "AND.l BankFF_CharBits,X")),
    ("bankC2/bankC2.asm", "Menu_BuildItemTables", ("LDA.l !MenuRom_ItemRec3,X", "STA.w !Menu_ItemEquipChars,Y")),
    ("bankC1/bankC1.asm", "BattleSys_EffRecStatPair",
     ("LDA.w !Battle_UnkAEE6+3", "LDA.w BattlerStats.Unk2D,X", "LDA.w !Battle_UnkAEE6+4")),
    ("bankC1/bankC1.asm", "BattleSys_AdjustDefence", ("CMP.b #!Battle_DefUnk6B", "LDA.w BattlerStats.Unk2D,X")),
    ("bankFF/bankFF.asm", "BankFF_LoadSlotPart",
     ("LDA.b #!MenuRom_CharRecordInit>>16", "CMP.w #!Pc_CharAyla*!Menu_CharRecBytes", "DEC.b !Menu_Tmp04",
      "LDA.l BankFF_EquipOffsets,X")),
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


def synthetic_cases():
    rng = Lcg(0xC7)
    table = [0]
    for level in range(1, LEVEL_MAX):
        table.append(table[-1] + 5 + rng.next(900))
    table.append(0)
    cases = []
    for n in range(24):
        level = (1, 1, 2, 37, 98, 99, 50)[n] if n < 7 else 1 + rng.next(98)
        tops = sorted(rng.next(99) + 1 for _ in range(3))
        hp_row = [[tops[0], rng.next(256)], [tops[1], rng.next(256)], [tops[2], rng.next(256)], [99 + rng.next(157), rng.next(256)]]
        mp_row = [[tops[1], rng.next(8)], [99, rng.next(4)], [0, 0], [0, 0]]
        growth = {"hp": hp_row, "mp": mp_row,
                  "stats": {s: (255 if n == 1 else rng.next(256)) for s in STATS}}
        base = {s: (99 if n == 1 else rng.next(100)) for s in STATS}
        stats = {s: rng.next(100) for s in STATS}
        if n == 2:
            stats["speed"] = 77           # above 50: capped at the first level-up
        exp = sum(table[1:level]) if n % 3 else rng.next(1 << 20)
        value = {"char_id": n % 7, "hp": rng.next(1000), "max_hp": 1 + rng.next(999), "mp": rng.next(100),
                 "max_mp": rng.next(100), "level": level, "exp": exp,
                 "exp_to_next": 0 if level >= 99 else table[level], "tech_points": rng.next(1000),
                 "tech_points_to_next": rng.next(1000), "stats": stats, "growth_base": base,
                 "equipment": {"helmet": 0x7B + rng.next(25), "armor": 0x5A + rng.next(33),
                               "weapon": rng.next(0x5A), "accessory": 0x94 + rng.next(40)}}
        if n == 3:
            value["exp"] = 0x989600 - 10   # AddExp's cap
        raw = encode_record(bytes(rng.next(256) for _ in range(RECORD_SIZE)), value)
        value["char_id"] = raw[0]
        cases.append({"record": raw.hex(), "growth": growth, "curve": curve_rows(level_curve(value, growth, table))})
    return {"schema": "ct-character-curve-vectors/1",
            "note": "synthetic records (no ROM data); curves by re_workspace/tools/ct_characters.py",
            "columns": list(CURVE_COLUMNS), "expToLevel": table, "cases": cases}


def vectors_text():
    """The vectors as JSON, one curve row per line."""
    v = synthetic_cases()
    cases = []
    for case in v["cases"]:
        rows = ",\n".join("    " + json.dumps(r, separators=(",", ":")) for r in case["curve"])
        cases.append(f'  {{"record": "{case["record"]}",\n   "growth": '
                     f'{json.dumps(case["growth"], sort_keys=True, separators=(",", ":"))},\n   "curve": [\n{rows}]}}')
    head = ",\n".join(f' "{k}": {json.dumps(v[k], separators=(",", ":"))}' for k in ("schema", "note", "columns", "expToLevel"))
    return "{\n" + head + ',\n "cases": [\n' + ",\n".join(cases) + "]}\n"


VECTORS = WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "characters" / "curve_vectors.json"


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
    k.add_argument("--run", action="store_true", help="also run the ROM's level-up routine (about 35 s)")
    c = sub.add_parser("curve")
    c.add_argument("id", type=int, choices=range(CHARACTERS))
    c.add_argument("--rom", default=str(ROM_PATH))
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
            raise SystemExit("vectors differ from ct_characters.py; regenerate with --out")
        print(f"{len(synthetic_cases()['cases'])} synthetic curve cases")
        return
    rom = read_rom(args.rom)
    if args.command == "decode":
        print(json.dumps(decode_all(rom), indent=1))
    elif args.command == "curve":
        value = decode_record(record(rom, args.id))
        rows = curve_rows(level_curve(value, decode_growth(rom, args.id), exp_to_level(rom)))
        print(json.dumps({"columns": list(CURVE_COLUMNS), "rows": rows}))
    else:
        results = code_claims(rom) + data_claims(rom) + (asm_claims() if REF.exists() else [])
        if args.run:
            results += run_claims(rom) + synthetic_run_claims(rom)
        for name, ok, detail in results:
            print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f"  [{detail}]" if detail and not ok else ""))
        failed = [r for r in results if not r[1]]
        print(f"{len(results) - len(failed)} of {len(results)} character claims hold")
        if failed:
            sys.exit(1)


if __name__ == "__main__":
    main()
