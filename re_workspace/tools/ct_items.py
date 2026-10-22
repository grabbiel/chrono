#!/usr/bin/env python3
"""Chrono Trigger items: weapons, armour, helmets, accessories, consumables, evidence.

Item ids run from 0 to $F1 in five categories (Menu_ItemCategoryBounds
$C2:88A7: $00, $5A, $7B, $94, $BC, $F2); the first id of each is "no item".
Every item has a record in two per-category tables of bank $CC, whose
addresses and record sizes are in bank $FF:

  ItemTablesA $FF:CF0E / sizes $FF:CF18   record A: 6, 6, 6, 4, 3 B (Menu_ItemDataPtrA)
  ItemTablesB $FF:CF1D / sizes $FF:CF27   record B: 5, 3, 3, 4, 4 B (Menu_ItemDataPtrB,
                                          BattleFD_ItemRecOffset)
  ItemNames   $CC:0B5E  11 B per id: an icon byte, 10 glyphs ($FF blank, $EF pads)
  TargetMode  $CC:1BB5   1 B per consumable
  ItemBoosts  $CC:29D7  23 words: stat bits (bit 7 down = MenuRom_StatOrder), amount
  DescTable   $CC:2EB1  242 pointers (one per id) to the item descriptions

Record A: byte 0 the item's flags, word 1 its price, byte 3 the characters
that can equip it (bit 7 = character 0), byte 4 a boost number (ItemBoosts)
and byte 5 an elemental bonus (bits 7-4 lightning, shadow, water, fire; low
nibble the amount). Record B: a weapon's attack, critical chance and hit
modifier; armour's defence and modifier; an accessory's battle bytes; a
consumable's use kind and amount. docs/items.md has every field's evidence.

`check` re-derives each claim from the ROM's code bytes, from ChronoRET's
matched source (MIT; refs/ChronoRET) and from the ROM's data. `check --run`
(and tests/test_items.py) also runs the ROM's own Menu_BuildItemTables and
Menu_RefreshAllChars in ChronoRET's 65816 interpreter, with the SNES
multiply and divide registers emulated, and compares the item tables and
every character's equipment stat totals with `item_tables` / `calc_stats`;
then the same with other equipment, with synthetic tables patched into a
copy of the ROM, BattleFD_ItemRecOffset for every id and BattleSys_UnkCF69
(the elemental bonus) for every piece of equipment.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_items.py decode [--rom PATH]           every item and table (JSON)
    ct_items.py check [--rom PATH] [--run]    every evidence claim (exit 1 on a failure)
    ct_items.py vectors (--out | --check) P   synthetic stat vectors for the Swift tests
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


def u(data, at, size):
    return int.from_bytes(data[at:at + size], "little")


# --- Tables --------------------------------------------------------------------------

CATEGORIES = ("weapon", "armor", "helmet", "accessory", "consumable")
FIRST = (0x00, 0x5A, 0x7B, 0x94, 0xBC, 0xF2)        # Menu_ItemCategoryBounds
ITEMS = 0xF2
SIZES_A, SIZES_B = (6, 6, 6, 4, 3), (5, 3, 3, 4, 4)
BOUNDS_PC = pc(0xC2, 0x88A7)
TABLES_A_PC, SIZES_A_PC = pc(0xFF, 0xCF0E), pc(0xFF, 0xCF18)
TABLES_B_PC, SIZES_B_PC = pc(0xFF, 0xCF1D), pc(0xFF, 0xCF27)
STAT_ORDER_PC, STAT_CAPS_PC = pc(0xFF, 0xCF2C), pc(0xFF, 0xCF33)
NAMES_PC, NAME_SIZE, NAME_GLYPHS = pc(0xCC, 0x0B5E), 11, 10
TARGET_MODE_PC = pc(0xCC, 0x1BB5)
BOOSTS_PC, BOOSTS = pc(0xCC, 0x29D7), 23
MODIFIERS = 57                                      # BattleRom_UnkCC2A05 records (ct_techs.MODIFIERS)
CHAR5_ATTACK_PC, CHAR5_ATTACK = pc(0xCC, 0x2D69), 100
DESC_PC, DESC_END = pc(0xCC, 0x2EB1), pc(0xCC, 0x36F4)
RECORDS_PC, RECORD_SIZE, CHARACTERS = pc(0xCC, 0x0000), 0x50, 7
STATS = ("power", "stamina", "speed", "magic", "hit", "evade", "magic_defense")   # record +$0B-$11
ELEMENTS = ("lightning", "shadow", "water", "fire")  # bits 7, 6, 5, 4 (ct_techs.ELEMENTS)

BOOST_HALF, BOOST_QUARTER = 0xA1, 0xA0               # Menu_EquipStatCat3: max HP + 1/2, + 1/4
DOUBLE_STAT5 = 0xA8                                  # Menu_CharRecalc doubles stat 5 with it
HP_CAP = 999
EQUIP_SLOT = {"helmet": 0x27, "armor": 0x28, "weapon": 0x29, "accessory": 0x2A}   # Menu_CharRec
INFO0_MASK = 0x1E                                    # Menu_ItemInfo0Mask
ACCESSORY_BOOST = 0x40                               # record B byte 1 bit 6 (Menu_ItemRecB1Bit6)
BATTLE_LIST = 0x80                                   # consumable record A byte 0 (Battle_ItemListBit)

# Record B fields by category: (name, byte).
FIELDS_B = {
    "weapon": (("attack", 0), ("byte1", 1), ("critical", 2), ("modifier", 3), ("modifier_arg", 4)),
    "armor": (("defence", 0), ("modifier", 1), ("modifier_on", 2)),
    "helmet": (("defence", 0), ("modifier", 1), ("modifier_on", 2)),
    "accessory": (("battle_flags", 0), ("special", 1), ("special_arg", 2), ("special_bits", 3)),
    "consumable": (("use_kind", 0), ("restores", 1), ("amount", 2), ("byte3", 3)),
}


def category(item):
    return next(c for c in range(5) if item < FIRST[c + 1])


def table_a(rom, cat):
    return pc(0xCC, u(rom, TABLES_A_PC + 2 * cat, 2))


def table_b(rom, cat):
    return pc(0xCC, u(rom, TABLES_B_PC + 2 * cat, 2))


def size_b(rom, cat):
    return rom[SIZES_B_PC + cat] if cat < 4 else rom[SIZES_B_PC + 4]


def record_a_pc(rom, item):
    cat = category(item)
    return table_a(rom, cat) + (item - FIRST[cat]) * rom[SIZES_A_PC + cat]


def record_b_pc(rom, item):
    cat = category(item)
    return table_b(rom, cat) + (item - FIRST[cat]) * size_b(rom, cat)


def boosts(rom):
    return [u(rom, BOOSTS_PC + 2 * i, 2) for i in range(BOOSTS)]


def stat_order(rom):
    return list(rom[STAT_ORDER_PC:STAT_ORDER_PC + 7])


def stat_caps(rom):
    return list(rom[STAT_CAPS_PC:STAT_CAPS_PC + 7])


def char5_attack(rom):
    return [u(rom, CHAR5_ATTACK_PC + 2 * i, 2) for i in range(CHAR5_ATTACK)]


def boost_stats(word, order):
    """The stat names an ItemBoosts word raises (bit 7 down = order[0..6])."""
    return [STATS[order[i]] for i in range(7) if word & (0x80 >> i)]


# --- Codec ---------------------------------------------------------------------------

def _text(ref=REF):
    if str(ref / "tools") not in sys.path:
        sys.path.insert(0, str(ref / "tools"))
    import text
    return text


def item_name(rom, item, glyphs=None):
    """(icon byte, name): bytes 1-10 with $FF a blank and $EF padding."""
    raw = rom[NAMES_PC + NAME_SIZE * item:NAMES_PC + NAME_SIZE * (item + 1)]
    glyphs = glyphs if glyphs is not None else _text().GLYPHS
    name = "".join(" " if b == 0xFF else glyphs.get(b, f"{{g{b:02X}}}") for b in raw[1:] if b != 0xEF)
    return raw[0], name


def descriptions(rom):
    """Per id, the description's bank-$CC address and its bytes up to (not with) its $00."""
    out = []
    for item in range(ITEMS):
        addr = u(rom, DESC_PC + 2 * item, 2)
        at = pc(0xCC, addr)
        end = rom.index(0, at, DESC_END)
        out.append((addr, bytes(rom[at:end])))
    return out


def decode_item(rom, item, glyphs=None):
    cat = category(item)
    kind = CATEGORIES[cat]
    a, b = record_a_pc(rom, item), record_b_pc(rom, item)
    icon, name = item_name(rom, item, glyphs)
    v = {"id": item, "category": kind, "icon": icon, "name": name, "flags": rom[a], "price": u(rom, a + 1, 2)}
    if cat < 4:
        v["equip"] = rom[a + 3]
    if cat < 3:
        v["boost"], v["element_bonus"] = rom[a + 4], rom[a + 5]
    v.update({name: rom[b + k] for name, k in FIELDS_B[kind]})
    if cat == 4:
        v["target_mode"] = rom[TARGET_MODE_PC + item - FIRST[4]]
    return v


def encode_item(rom, value):
    """{file offset: byte} of an item's writable bytes (names aside)."""
    item, cat = value["id"], category(value["id"])
    a, b = record_a_pc(rom, item), record_b_pc(rom, item)
    out = {a: value["flags"], a + 1: value["price"] & 0xFF, a + 2: value["price"] >> 8}
    if cat < 4:
        out[a + 3] = value["equip"]
    if cat < 3:
        out[a + 4], out[a + 5] = value["boost"], value["element_bonus"]
    for name, k in FIELDS_B[CATEGORIES[cat]]:
        out[b + k] = value[name]
    if cat == 4:
        out[TARGET_MODE_PC + item - FIRST[4]] = value["target_mode"]
    return out


def decode_all(rom):
    glyphs = _text().GLYPHS if REF.exists() else {}
    items = [decode_item(rom, i, glyphs) for i in range(ITEMS)]
    if REF.exists():
        text = _text()
        dic = text.rom_dictionary(rom)
        for v, (addr, raw) in zip(items, descriptions(rom)):
            v["description"] = text.decode_msg(raw, dic)
    order = stat_order(rom)
    return {"items": items, "boosts": [{"stats": boost_stats(w, order), "amount": w >> 8} for w in boosts(rom)],
            "stat_order": [STATS[s] for s in order], "stat_caps": stat_caps(rom)}


def write_zones(rom):
    """The spans an item build may write (CTItemROM.writes): record A bytes
    0-5 (0-3 for accessories, 0-2 for consumables), record B, name bytes
    1-10, the target modes, ItemBoosts and the description table."""
    spans = []
    for item in range(ITEMS):
        cat = category(item)
        a, b = record_a_pc(rom, item), record_b_pc(rom, item)
        spans += [range(a, a + SIZES_A[cat]), range(b, b + SIZES_B[cat]),
                  range(NAMES_PC + NAME_SIZE * item + 1, NAMES_PC + NAME_SIZE * (item + 1))]
    spans.append(range(TARGET_MODE_PC, TARGET_MODE_PC + FIRST[5] - FIRST[4]))
    spans.append(range(BOOSTS_PC, BOOSTS_PC + 2 * BOOSTS))
    spans.append(range(DESC_PC, DESC_END))
    return spans


# --- The menu's item tables and equipment stats ---------------------------------------

def item_tables(rom):
    """Menu_BuildItemTables' item loops: per id, Menu_ItemInfo0 (record A
    byte 0 AND $1E), Info1 (word 1, the price), Menu_ItemEquipChars (byte 3,
    0 from category 4), Info4 (byte 4 below category 3; an accessory's
    record B byte 2 when its byte 1 has bit 6; else 0) and Menu_ItemSortKeys
    (record B byte 0 for ids 0-$93)."""
    t = {"info0": [], "info1": [], "equip": [], "info4": [], "sort": [0] * 0x100}
    for item in range(ITEMS):
        cat, a = category(item), record_a_pc(rom, item)
        t["info0"].append(rom[a] & INFO0_MASK)
        t["info1"].append(u(rom, a + 1, 2))
        t["equip"].append(rom[a + 3] if cat < 4 else 0)
        b = record_b_pc(rom, item)
        if cat < 3:
            t["info4"].append(rom[a + 4])
            t["sort"][item] = rom[b]
        elif cat == 3:
            t["info4"].append(rom[b + 2] if rom[b + 1] & ACCESSORY_BOOST else 0)
        else:
            t["info4"].append(0)
    return t


def stat_tables(rom):
    """What Menu_CharRecalc reads besides the item tables."""
    return {"boosts": boosts(rom), "order": stat_order(rom), "caps": stat_caps(rom), "char5": char5_attack(rom)}


def calc_stats(record, items, st):
    """Menu_CharRecalc on a $50-byte character record: (derived, word3) with
    derived the 11 bytes it writes at +$36 (7 stats with boosts, capped, the
    attack, the defence, max HP with the accessory's bonus) and word3 the
    record's +$03 (lowered to that max HP). `items`: sort (256), info4
    (by id); `st`: stat_tables."""
    rec = bytes(record)
    boost, power, armour = [0] * 7, 0, 0

    def add_boosts(item):
        v = items["info4"][item] if item < len(items["info4"]) else 0
        if not v:
            return
        word = st["boosts"][v] if v < len(st["boosts"]) else None
        if word is None:
            raise ValueError(f"boost {v} is past ItemBoosts")
        bits, amount = word & 0xFE, word >> 8
        for i in range(7):
            if bits & (0x80 >> i):
                s = st["order"][i]
                boost[s] = (boost[s] + amount) & 0xFF

    # slot 3: the accessory (max HP bonus), then 2 helmet, 1 armour, 0 weapon
    acc, w5, w3 = rec[EQUIP_SLOT["accessory"]], u(rec, 5, 2), u(rec, 3, 2)
    bonus = w5 >> 1 if acc == BOOST_HALF else w5 >> 2 if acc == BOOST_QUARTER else 0
    max_hp = min((w5 + bonus) & 0xFFFF, HP_CAP)
    if max_hp < w3:
        w3 = max_hp
    add_boosts(acc)
    for slot in ("helmet", "armor"):
        item = rec[EQUIP_SLOT[slot]]
        armour = (armour + items["sort"][item]) & 0xFF
        add_boosts(item)
    weapon = rec[EQUIP_SLOT["weapon"]]
    power = items["sort"][weapon]
    add_boosts(weapon)
    cur = [0] * 7
    for i in range(6, -1, -1):
        s = st["order"][i]
        v = (rec[0x0B + s] + boost[s]) & 0xFF
        cur[s] = v if v < st["caps"][i] else st["caps"][i]
    formula = rec[0] & 7
    if formula in (1, 2):
        dividend, divisor = (2 * (cur[4] + power)) & 0xFFFF, 3
    elif formula == 5:
        dividend, divisor = (16 * cur[0] + st["char5"][rec[0x12] & 0x7F]) & 0xFFFF, 9
    else:
        dividend, divisor = (5 * power + 12 * cur[0]) & 0xFFFF, 9
    quotient = dividend // divisor
    attack = 0xFF if quotient > 0xFF else quotient
    defence = cur[1] + armour
    defence = 0xFF if defence > 0xFF else defence
    if acc == DOUBLE_STAT5:
        cur[5] = cur[5] << 1 & 0xFF
    return cur + [attack, defence, max_hp & 0xFF, max_hp >> 8], w3


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

    claim("Menu_ItemDataPtrA: record A = ItemTablesA[cat] ($FF:CF0E) + index x ItemRecSizesA[cat] ($FF:CF18)",
          _has(_body(rom, 0xC2, 0x88AD, 0x88D7), b"\xbf\x18\xcf\xff", b"\xbf\x0e\xcf\xff", b"\x6f\x16\x42\x00"))
    claim("Menu_ItemDataPtrB: record B = ItemTablesB[cat] ($FF:CF1D) + index x ItemRecSizesB[cat] ($FF:CF27)",
          _has(_body(rom, 0xC2, 0x88D8, 0x88FF), b"\xbf\x27\xcf\xff", b"\xbf\x1d\xcf\xff"))
    build = _body(rom, 0xC2, 0x9875, 0x9987)
    claim("Menu_BuildItemTables: Info0 = A byte 0 AND $1E, EquipChars ($7A00) = byte 3, Info4 ($7B00) = byte 4, "
          "Info1 ($7800) = word 1; names $0B5E + 11 x id; accessory B byte 1 bit 6 -> Info4 = B byte 2; "
          "SortKeys ($7C00) = B byte 0 below $94",
          _has(build, b"\xbf\x00\x00\xcc\x29\x1e\x99\x00\x77", b"\xbf\x03\x00\xcc\x99\x00\x7a",
               b"\xbf\x04\x00\xcc\x99\x00\x7b", b"\xbf\x01\x00\xcc\x99\x00\x78", b"\xa9\x5e\x0b", b"\x69\x0b\x00",
               b"\x89\x40", b"\xbf\x02\x00\xcc\x99\x00\x7b", b"\xbf\x00\x00\xcc\x99\x00\x7c", b"\xc9\x94"))
    claim("Menu_CharCalcStats: stat = .Stats + boost capped by $FF:CF33 in $FF:CF2C order; defence = stat 1 + "
          "Menu_ArmorSum ($0DB6)",
          _has(_body(rom, 0xC2, 0x916E, 0x91DA), b"\xbf\x2c\xcf\xff", b"\xbf\x33\xcf\xff", b"\x6d\xb6\x0d"))
    claim("Menu_EquipStatWeapon: Menu_WeaponPower ($0DB5) = SortKeys[the weapon at record +$29]",
          _has(_body(rom, 0xC2, 0x9276, 0x9280), b"\xae\xb9\x9a", b"\xbd\x00\x7c", b"\x8d\xb5\x0d"))
    claim("Menu_EquipStatCat2: Menu_ArmorSum += SortKeys[+$27 helmet / +$28 armour]",
          _has(_body(rom, 0xC2, 0x9281, 0x9294), b"\xae\xb8\x9a", b"\xae\xb7\x9a", b"\xbd\x00\x7c\x18\x6d\xb6\x0d"))
    claim("Menu_EquipStatCat3: max HP + 1/2 for $A1, + 1/4 for $A0, at most 999",
          _has(_body(rom, 0xC2, 0x9295, 0x92C0), b"\xe0\xa1", b"\xe0\xa0", b"\xc9\xe7\x03"))
    claim("Menu_AddItemBoosts: ItemBoosts $CC:29D7 [Info4 x 2] AND $FFFE, a bit per MenuRom_StatOrder entry",
          _has(_body(rom, 0xC2, 0x92C1, 0x92F3), b"\xbd\x00\x7b", b"\xbf\xd7\x29\xcc", b"\x29\xfe\xff",
               b"\xbf\x2c\xcf\xff"))
    claim("Menu_CharRecalc doubles stat 5 with accessory $A8",
          _has(_body(rom, 0xC2, 0x9137, 0x916D), b"\xc9\xa8", b"\x0e\x21\x9b"))
    claim("Menu_ShopCalcPrices: the buy price is Info1 ($7800) x the shop's factor",
          b"\xb9\x00\x78" in _body(rom, 0xC2, 0xDB9F, 0xDBE7))
    claim("Menu_ShopSellDrawRow: the sell price is Info1 / 2, rounded up",
          b"\xbd\x00\x78\x4a" in _body(rom, 0xC2, 0xDF51, 0xDF75))
    claim("Menu_UseItem: ItemTargetMode $CC:1BB5, B byte 1 (HP / MP bits), B byte 2 AND $0F (amount), B byte 0 kind",
          _has(_body(rom, 0xC2, 0xB0AB, 0xB0ED), b"\xbf\xb5\x1b\xcc", b"\xbf\x01\x00\xcc", b"\xbf\x02\x00\xcc\x29\x0f",
               b"\xbf\x00\x00\xcc"))
    claim("Menu_DrawDescText: string A (an item id) of the table at $CC:2EB1",
          _has(_body(rom, 0xC2, 0xF2F3, 0xF331), b"\xa2\xb1\x2e", b"\xa9\xcc"))
    rec = _body(rom, 0xFD, 0xB033, 0xB0D4)
    claim("BattleFD_ItemRecOffset: id x 5 + $0262, (id - $5A) x 3 + $047E, (id - $7B) x 3 + $04E1, "
          "(id - $94) x 4 + $052C, (id - $BC) x 4 + $05CC",
          _has(rec, b"\xc9\x5a", b"\xa9\x05", b"\x69\x62\x02", b"\x69\x7e\x04", b"\x69\xe1\x04", b"\x69\x2c\x05",
               b"\x69\xcc\x05", b"\xc9\x7b", b"\xc9\x94", b"\xc9\xbc", b"\xc9\xf2"))
    claim("BattleSys_UnkCF69: A byte 5's low nibble added to stat block +$3F-$42 for bits 7-4",
          _has(_body(rom, 0xC1, 0xCF69, 0xCFBD), b"\xbf\x05\x00\xcc", b"\x29\x0f", b"\xbd\x3f\x00\x18\x65\x0a\x9d\x3f\x00",
               b"\xbd\x42\x00\x18\x65\x0a\x9d\x42\x00"))
    claim("BattleSys_HitModChanceMul: the caster's +$72 (weapon B byte 2) is the chance of a 0-99 roll",
          _has(_body(rom, 0xC1, 0xED89, 0xEDB8), b"\xbd\x72\x5e", b"\xa9\x64"))
    claim("BattleSys_CasterUnk73: modifier number = +$73 (weapon B byte 3), its argument +$74 (byte 4)",
          _has(_body(rom, 0xC1, 0xD1BB, 0xD1CE), b"\xbd\x73\x5e", b"\xbd\x74\x5e"))
    return out


def data_claims(rom):
    """Claims about the ROM's data, given the decoded layout: [(name, ok, detail)]."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    claim("Menu_ItemCategoryBounds = $00, $5A, $7B, $94, $BC, $F2", list(rom[BOUNDS_PC:BOUNDS_PC + 6]) == list(FIRST))
    claim("ItemRecSizesA = 6, 6, 6, 4, 3", list(rom[SIZES_A_PC:SIZES_A_PC + 5]) == list(SIZES_A))
    claim("ItemRecSizesB = 5, 3, 3, 4 (+ 4 at $FF:CF2B)",
          [size_b(rom, c) for c in range(5)] == list(SIZES_B) and rom[SIZES_B_PC + 4] == 4)
    a = [table_a(rom, c) for c in range(5)] + [NAMES_PC]
    claim("table A: each category's records end where the next table begins (the last at ItemNames)",
          all(a[c] + SIZES_A[c] * (FIRST[c + 1] - FIRST[c]) == a[c + 1] for c in range(5)), [hex(x) for x in a])
    b = [table_b(rom, c) for c in range(5)] + [table_a(rom, 0)]
    claim("table B: the armour, helmet, accessory and consumable records tile up to table A",
          all(b[c] + SIZES_B[c] * (FIRST[c + 1] - FIRST[c]) == b[c + 1] for c in range(1, 5)), [hex(x) for x in b])
    spare = (b[1] - b[0]) // SIZES_B[0] - FIRST[1]
    claim("table B: the weapon span holds 90 records and 18 more no id reaches",
          (b[1] - b[0]) % SIZES_B[0] == 0 and spare == 18, f"{spare} more")
    claim("BattleFD_ItemRecOffset's offsets are ItemTablesB",
          [x & 0xFFFF for x in b[:5]] == [0x0262, 0x047E, 0x04E1, 0x052C, 0x05CC])
    items = [decode_item(rom, i, {}) for i in range(ITEMS)]
    blank = [items[f] for f in FIRST[:5]]
    claim("each category's first id is empty (zero records, no name)",
          all(v["price"] == 0 and v["flags"] == 0 and all(rom[record_b_pc(rom, v["id"]) + k] == 0
              for k in range(SIZES_B[category(v["id"])])) for v in blank)
          and all(set(rom[NAMES_PC + NAME_SIZE * f:NAMES_PC + NAME_SIZE * (f + 1)]) == {0xEF} for f in FIRST[:5]))
    equip = [v for v in items if v["category"] != "consumable"]
    claim("equip masks name characters 0-6 only (bit 0 clear)", all(not v["equip"] & 1 for v in equip))
    claim("boost numbers are below 23 (ItemBoosts)",
          all(v["boost"] < BOOSTS for v in items if "boost" in v)
          and all(v["special_arg"] < BOOSTS for v in items if v["category"] == "accessory" and v["special"] & ACCESSORY_BOOST))
    claim("ItemBoosts: bit 0 clear in every word; word 0 is no boost",
          all(not w & 1 for w in boosts(rom)) and boosts(rom)[0] == 0)
    claim("weapon modifiers and armour modifiers are BattleRom_UnkCC2A05 records (below 57)",
          all(v["modifier"] < MODIFIERS for v in items if "modifier" in v))
    claim("armour modifier_on is 0 or 1", all(v["modifier_on"] in (0, 1) for v in items if "modifier_on" in v))
    claim("weapon critical chances are 0-100", all(v["critical"] <= 100 for v in items if v["category"] == "weapon"))
    claim("record A byte 0: bits 7 and 4-1 only; bit 7 (the battle list) and bits 1, 3 (menu use, sort first) "
          "on consumables only",
          all(not v["flags"] & 0x61 for v in items) and all(not v["flags"] & 0x8A for v in equip))
    order = stat_order(rom)
    claim("MenuRom_StatOrder is a permutation of the 7 stats", sorted(order) == list(range(7)), repr(order))
    claim("MenuRom_StatCaps are at most 99", all(c <= 99 for c in stat_caps(rom)), repr(stat_caps(rom)))
    claim("ItemTargetMode: every consumable's mode is a byte the menu reduces with (+1) AND 3",
          len(rom[TARGET_MODE_PC:TARGET_MODE_PC + 54]) == 54)
    for c in range(CHARACTERS):
        rec = rom[RECORDS_PC + RECORD_SIZE * c:RECORDS_PC + RECORD_SIZE * (c + 1)]
        ok = all(FIRST[k] <= rec[EQUIP_SLOT[s]] < FIRST[k + 1] and items[rec[EQUIP_SLOT[s]]]["equip"] & (0x80 >> c)
                 for k, s in enumerate(("weapon", "armor", "helmet", "accessory")) if rec[EQUIP_SLOT[s]] != FIRST[k])
        claim(f"character {c}: its starting equipment is of the slot's category and lists it in the equip mask", ok)
    if REF.exists():
        text = _text()
        glyphs = text.GLYPHS
        names = [item_name(rom, i, glyphs)[1] for i in range(ITEMS)]
        claim("names: 10 glyphs after an icon byte, no $EF before the padding",
              all(0xEF not in bytes(rom[NAMES_PC + NAME_SIZE * i + 1:NAMES_PC + NAME_SIZE * (i + 1)]).rstrip(b"\xef")
                  for i in range(ITEMS)))
        claim("names decode (ChronoRET's glyphs); samples Wood Sword, Hide Tunic, Tonic",
              names[1] == "Wood Sword" and names[0x5B] == "Hide Tunic" and names[0xBD] == "Tonic"
              and not any("{g" in n for n in names))
        desc = descriptions(rom)
        dic = text.rom_dictionary(rom)
        claim("DescTable: 242 pointers, each to a $00-ended string between the table and $CC:36F3",
              all(pc(0xCC, a) >= DESC_PC + 2 * ITEMS and pc(0xCC, a) + len(r) < DESC_END for a, r in desc))
        covered = set()
        for a, r in desc:
            covered.update(range(pc(0xCC, a), pc(0xCC, a) + len(r) + 1))
        unused = sorted(set(range(DESC_PC + 2 * ITEMS, DESC_END)) - covered)
        claim("DescTable: the strings tile the region up to $CC:36F3 but for one byte no pointer reaches",
              len(unused) == 1 and rom[unused[0]] == 0xEF, [hex(x) for x in unused])
        claim("descriptions decode and re-encode byte-exact (ChronoRET's codec)",
              all(text.encode_msg(text.decode_msg(r, dic), dic, f"item {i}") == r for i, (_, r) in enumerate(desc)))
    return out


# ChronoRET source claims: (file under asm/, routine label, lines that must
# appear in its body, in order).
ASM_CLAIMS = (
    ("bankC2/bankC2.asm", "Menu_ItemDataPtrA",
     ("JSR Menu_ItemCategory", "LDA.l !MenuRom_ItemRecSizesA,X", "LDA.l !MenuRom_ItemTablesA,X", "ADC.l RDMPYL")),
    ("bankC2/bankC2.asm", "Menu_ItemDataPtrB",
     ("LDA.l !MenuRom_ItemRecSizesB,X", "LDA.l !MenuRom_ItemTablesB,X", "ADC.l RDMPYL")),
    ("bankC2/bankC2.asm", "Menu_BuildItemTables",
     ("JSR Menu_ItemDataPtrA", "LDA.l !MenuRom_ItemRec0,X", "AND.b #!Menu_ItemInfo0Mask", "STA.w !Menu_ItemInfo0,Y",
      "LDA.l !MenuRom_ItemRec3,X", "STA.w !Menu_ItemEquipChars,Y", "LDA.l !MenuRom_ItemRec4,X",
      "STA.w !Menu_ItemInfo4,Y", "LDA.l !MenuRom_ItemRec1,X", "STA.w !Menu_ItemInfo1,Y",
      "JSR Menu_ItemDataPtrB", "BIT.b #!Menu_ItemRecB1Bit6", "LDA.l !MenuRom_ItemRec2,X",
      "STA.w !Menu_ItemSortKeys,Y", "JSR Menu_RefreshAllChars")),
    ("bankC2/bankC2.asm", "Menu_CharCalcStats",
     ("JSR Menu_EquipSlotStats", "LDA.l !MenuRom_StatOrder,X", "ADC.w !Menu_StatBoosts,Y", "CMP.l !MenuRom_StatCaps,X",
      "JSR (Menu_AttackFormulas,X)", "ADC.w !Menu_ArmorSum", "STX.w !Menu_CurAttack")),
    ("bankC2/bankC2.asm", "Menu_EquipStatWeapon",
     ("LDX.w !Menu_CurCharRec+Menu_CharRec.Unk29", "LDA.w !Menu_ItemSortKeys,X", "STA.w !Menu_WeaponPower")),
    ("bankC2/bankC2.asm", "Menu_EquipStatCat2",
     ("LDX.w !Menu_CurCharRec+Menu_CharRec.Unk27", "LDA.w !Menu_ItemSortKeys,X", "ADC.w !Menu_ArmorSum")),
    ("bankC2/bankC2.asm", "Menu_AddItemBoosts",
     ("LDA.w !Menu_ItemInfo4,X", "LDA.l !MenuRom_ItemBoosts,X", "AND.w #!Menu_BoostFlagsMask",
      "LDA.l !MenuRom_StatOrder,X", "ADC.w !Menu_StatBoosts,Y")),
    ("bankC2/bankC2.asm", "Menu_ShopCalcPrices", ("LDA.w !Menu_ItemInfo1,Y",)),
    ("bankC2/bankC2.asm", "Menu_UseItem",
     ("LDA.l !BattleRom_ItemTargetMode,X", "JSR Menu_ItemDataPtrB", "LDA.l !MenuRom_ItemRec0+1,X",
      "LDA.l !MenuRom_ItemRec0+2,X", "AND.b #!Menu_UseAmountMask", "JSR Menu_FirstSetBit")),
    ("bankC2/bankC2.asm", "Menu_DrawDescText", ("LDX.w #!MenuRom_DescStrTable&$FFFF", "JSR Menu_StartDescText")),
    ("bankC1/bankC1.asm", "BattleSys_UnkCE3A",
     ("LDA.w PcStatBlk.Unk29,X", "ADC.w #!BattleRom_EquipRec1&$FFFF", "JSR BattleSys_UnkCF69",
      "SBC.b #!Battle_EquipBase2", "SBC.b #!Battle_EquipBase3")),
    ("bankC1/bankC1.asm", "BattleSys_UnkCF15", ("JSL BattleFD_ItemRecOffset", "LDA.l !BattleRom_UnkCC0000,X")),
    ("bankC1/bankC1.asm", "BattleSys_UnkCF69",
     ("LDA.l !BattleRom_EquipBonus,X", "AND.b #!Battle_EquipBonusMask", "ADC.b !Bonus_Amount",
      "STA.w PcStatBlk.Unk3F,X", "STA.w PcStatBlk.Unk42,X")),
    ("bankC1/bankC1.asm", "BattleSys_HitModChanceMul", ("LDA.w BattlerStats.Unk72,X", "JSR Battle_RandRangeAlt")),
    ("bankC1/bankC1.asm", "BattleSys_CasterUnk73", ("LDA.w BattlerStats.Unk73,X", "LDA.w BattlerStats.Unk74,X")),
    ("bankFD/bankFD.asm", "BattleFD_ItemRecOffset",
     ("CMP.b #!Battle_ItemClass1First", "LDA.b #!Battle_ItemRec0Size", "ADC.w #!Battle_ItemRec0Ofs",
      "ADC.w #!Battle_ItemRec1Ofs", "ADC.w #!Battle_ItemRec2Ofs")),
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


# --- The ROM's routines, run ------------------------------------------------------------

def _hw(addr):
    bank, low = addr >> 16 & 0xFF, addr & 0xFFFF
    return (bank & 0x7F) < 0x40 and 0x4200 <= low < 0x4220


class RomItems:
    """The game's own item routines executed by ChronoRET's 65816
    interpreter (refs/ChronoRET/tools/absint.py) over `image` (the ROM, or a
    copy with other tables patched in), with the multiply ($4202/$4203 ->
    $4216) and divide ($4204-$4206 -> $4214, $4216) registers emulated. Every
    value is known, so each run has one end; a callee it could not follow is
    an error."""

    RECORDS = 0x7E2600                  # Menu_CharRecords
    INFO0, INFO1, EQUIP, INFO4, SORT = 0x7E7700, 0x7E7800, 0x7E7A00, 0x7E7B00, 0x7E7C00
    LOC_ID = 0x7E0100                   # DP_Field + Loc_Id: a location in bank $C2's range
    BLOCK = 0x7E5E2D                    # PcStatBlk of slot 0

    def __init__(self, image, ref=REF):
        if str(ref / "tools") not in sys.path:
            sys.path.insert(0, str(ref / "tools"))
        import absint

        class Machine(absint.Machine):
            def write8(self, s, addr, v):
                if addr is None or not _hw(addr):
                    return super().write8(s, addr, v)
                low = addr & 0xFFFF
                s.mem[low] = v
                if low == 0x4203:
                    a = s.mem.get(0x4202)
                    p = None if a is None or v is None else a * v
                    s.mem[0x4216], s.mem[0x4217] = (None, None) if p is None else (p & 0xFF, p >> 8)
                elif low == 0x4206:
                    lo, hi = s.mem.get(0x4204), s.mem.get(0x4205)
                    q = r = None
                    if None not in (lo, hi, v):
                        d = lo | hi << 8
                        q, r = (d // v, d % v) if v else (0xFFFF, d)
                    for at, val in ((0x4214, q), (0x4216, r)):
                        s.mem[at], s.mem[at + 1] = (None, None) if val is None else (val & 0xFF, val >> 8)

            def read8(self, s, addr):
                if addr is not None and _hw(addr):
                    return s.mem.get(addr & 0xFFFF)
                return super().read8(s, addr)

        self.absint = absint
        self.machine = Machine(bytes(image), bytearray(b"\x01") * len(image), max_steps=10 ** 8,
                               callee_steps=10 ** 7)
        self.machine.widen_after = 10 ** 9

    def _run(self, entry, known, how="rts", a=0, x=0, xf=True):
        s = self.absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, a, 0, x, 0
        s.d, s.db, s.m, s.xf, s.c = 0, 0x7E, True, xf, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = self.absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != how or self.machine.opaque:
            raise RuntimeError(f"${entry:06X}: {[h for _, h in ends]} opaque {self.machine.opaque}")
        return ends[0][0], {**known, **ends[0][0].mem}

    @staticmethod
    def _memory(records):
        known = {a: 0 for a in range(0x7E0000, 0x7F0000)}
        known.update({a: 0 for a in range(0x7F0000, 0x7F0400)})
        known[RomItems.LOC_ID + 1] = 0x01
        known[RomItems.LOC_ID] = 0xF0
        for c, rec in enumerate(records):
            known.update({RomItems.RECORDS + RECORD_SIZE * c + i: b for i, b in enumerate(rec)})
        return known

    def build(self, records):
        """Menu_BuildItemTables ($C2:9875) with `records` (7 x $50 B) in
        Menu_CharRecords: (the item tables, the records after it, memory)."""
        _, mem = self._run(0xC29875, self._memory(records))
        return self._read(mem), self._records(mem), mem

    def refresh(self, mem, records):
        """Menu_RefreshAllChars ($C2:99B2) with other records, over the item
        tables of an earlier build: the records after it."""
        known = dict(mem)
        for c, rec in enumerate(records):
            known.update({self.RECORDS + RECORD_SIZE * c + i: b for i, b in enumerate(rec)})
        _, after = self._run(0xC299B2, known)
        return self._records(after)

    def _read(self, mem):
        t = {"info0": [mem[self.INFO0 + i] & INFO0_MASK for i in range(ITEMS)],
             "info1": [mem[self.INFO1 + 2 * i] | mem[self.INFO1 + 2 * i + 1] << 8 for i in range(ITEMS)],
             "equip": [mem[self.EQUIP + i] for i in range(ITEMS)],
             "info4": [mem[self.INFO4 + i] for i in range(ITEMS)],
             "sort": [mem[self.SORT + i] for i in range(0x100)]}
        if any(v is None for k in t for v in t[k]):
            raise RuntimeError("an unknown byte in the item tables")
        return t

    def _records(self, mem):
        out = [bytes(mem[self.RECORDS + RECORD_SIZE * c + i] for i in range(RECORD_SIZE)) for c in range(CHARACTERS)]
        return out

    def rec_offset(self, item):
        """BattleFD_ItemRecOffset ($FD:B033) for item `item`: X."""
        known = {a: 0 for a in range(0x7E0000, 0x7E0040)}
        s, _ = self._run(0xFDB033, known, how="rtl", a=item, x=0, xf=False)
        return s.x

    def element_bonus(self, record_offset):
        """BattleSys_UnkCF69 ($C1:CF69) over a zeroed slot-0 stat block with
        DP $08 = a record A offset: what it adds to the block's +$3F-$42."""
        known = {a: 0 for a in range(0x7E0000, 0x7E0040)}
        known.update({self.BLOCK + i: 0 for i in range(0x80)})
        known[0x7E0000], known[0x7E0001] = self.BLOCK & 0xFF, self.BLOCK >> 8 & 0xFF
        known[0x7E0008], known[0x7E0009] = record_offset & 0xFF, record_offset >> 8
        _, mem = self._run(0xC1CF69, known, xf=False)
        return [mem[self.BLOCK + 0x3F + k] for k in range(4)]


def record(rom, c):
    return bytes(rom[RECORDS_PC + RECORD_SIZE * c:RECORDS_PC + RECORD_SIZE * (c + 1)])


def derived_of(rec):
    return list(rec[0x36:0x41]), u(rec, 3, 2)


def equipped(rom, rec, weapon, armor, helmet, accessory):
    r = bytearray(rec)
    for slot, item in (("weapon", weapon), ("armor", armor), ("helmet", helmet), ("accessory", accessory)):
        r[EQUIP_SLOT[slot]] = item
    return bytes(r)


class Lcg:
    """Deterministic numbers (no ROM data)."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self, n):
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.state >> 8) % n


def run_claims(rom, ref=REF):
    """The ROM's routines against the model: [(name, ok, detail)]."""
    out = []
    runner = RomItems(rom, ref)
    records = [record(rom, c) for c in range(CHARACTERS)]
    tables, after, mem = runner.build(records)
    want = item_tables(rom)
    for k in ("info0", "info1", "equip", "info4"):
        out.append((f"Menu_BuildItemTables: Menu_Item{dict(info0='Info0', info1='Info1 (prices)', equip='EquipChars', info4='Info4 (boosts)')[k]} "
                    f"= item_tables for all 242 ids", tables[k] == want[k], ""))
    out.append(("Menu_BuildItemTables: Menu_ItemSortKeys = record B byte 0 for ids 0-$93",
                tables["sort"][:FIRST[3]] == want["sort"][:FIRST[3]], ""))
    st = stat_tables(rom)
    bad = [c for c in range(CHARACTERS) if derived_of(after[c]) != calc_stats(records[c], tables, st)]
    out.append(("Menu_RefreshAllChars: every starting record's derived stats, attack, defence and max HP = calc_stats",
                not bad, f"differs for {bad}"))
    # Other equipment on each character: every weapon, armour, helmet and accessory id.
    rng, checked, bad = Lcg(0x17E5), 0, None
    for n in range(24):
        recs = []
        for c in range(CHARACTERS):
            pick = [FIRST[k] + (rng.next(FIRST[k + 1] - FIRST[k]) if n else (c * 13 + k) % (FIRST[k + 1] - FIRST[k]))
                    for k in range(4)]
            if n % 6 == 1:
                pick[3] = (BOOST_HALF, BOOST_QUARTER, DOUBLE_STAT5)[c % 3]
            recs.append(equipped(rom, records[c], *pick))
        got = runner.refresh(mem, recs)
        for c in range(CHARACTERS):
            checked += 1
            if derived_of(got[c]) != calc_stats(recs[c], tables, st):
                bad = (n, c)
        if bad:
            break
    out.append((f"Menu_RefreshAllChars with other equipment ({checked} records) = calc_stats", bad is None,
                f"differs at {bad}"))
    offsets = [runner.rec_offset(i) for i in range(0x100)]
    out.append(("BattleFD_ItemRecOffset: every id's record B offset (ids $F2 and up: X unchanged)",
                offsets[:ITEMS] == [record_b_pc(rom, i) & 0xFFFF for i in range(ITEMS)]
                and all(x == 0 for x in offsets[ITEMS:]), ""))
    bad = []
    for item in range(FIRST[3]):
        got = runner.element_bonus(record_a_pc(rom, item) & 0xFFFF)
        bonus = decode_item(rom, item, {})["element_bonus"]
        if got != [bonus & 0x0F if bonus & (0x80 >> k) else 0 for k in range(4)]:
            bad.append(item)
    out.append(("BattleSys_UnkCF69: every weapon, armour and helmet's A byte 5 adds its low nibble to the "
                "resistance bytes of its bits 7-4", not bad, repr(bad)))
    return out


def patched_image(rom, case):
    """A copy of `rom` with a synthetic case's ItemBoosts, MenuRom_StatOrder
    and StatCaps."""
    image = bytearray(rom)
    image[BOOSTS_PC:BOOSTS_PC + 2 * BOOSTS] = b"".join(w.to_bytes(2, "little") for w in case["boosts"])
    image[STAT_ORDER_PC:STAT_ORDER_PC + 7] = bytes(case["order"])
    image[STAT_CAPS_PC:STAT_CAPS_PC + 7] = bytes(case["caps"])
    image[CHAR5_ATTACK_PC:CHAR5_ATTACK_PC + 2 * CHAR5_ATTACK] = b"".join(w.to_bytes(2, "little") for w in case["char5"])
    return bytes(image)


def synthetic_run_claims(rom, ref=REF):
    """The ROM's Menu_RefreshAllChars with each synthetic case's tables (the
    ROM tables patched in, the menu's item tables given) against the vectors."""
    out = []
    for n, case in enumerate(synthetic_cases()["cases"]):
        runner = RomItems(patched_image(rom, case), ref)
        mem = RomItems._memory([bytes(RECORD_SIZE)] * CHARACTERS)
        mem.update({RomItems.SORT + i: v for i, v in enumerate(case["sort"])})
        mem.update({RomItems.INFO4 + i: v for i, v in enumerate(case["info4"])})
        bad = None
        for k in range(0, len(case["records"]), CHARACTERS):
            recs = [bytes(r) for r in case["records"][k:k + CHARACTERS]]
            got = runner.refresh(mem, recs)
            for c, rec in enumerate(got):
                exp = case["expected"][k + c]
                if derived_of(rec) != (exp["derived"], exp["word3"]):
                    bad = k + c
                    break
            if bad is not None:
                break
        out.append((f"synthetic case {n}: the ROM's routine with its tables patched in = the vectors "
                    f"({len(case['records'])} records)", bad is None, f"differs at record {bad}"))
    return out


# --- Synthetic vectors for the Swift twin ------------------------------------------------

def synthetic_cases():
    rng = Lcg(0x1735)
    cases = []
    for n in range(6):
        order = list(range(7))
        for i in range(6, 0, -1):
            j = rng.next(i + 1)
            order[i], order[j] = order[j], order[i]
        caps = [99 if n % 2 == 0 else 30 + rng.next(70) for _ in range(7)]
        boost_words = [0] + [rng.next(128) << 1 | (rng.next(256) if n == 3 else rng.next(6)) << 8
                             for _ in range(BOOSTS - 1)]
        if n == 4:
            boost_words = [0] + [0xFE | 0xF0 << 8] * (BOOSTS - 1)       # every stat, a large amount: wraps
        char5 = [rng.next(1 << (16 if n == 5 else 10)) for _ in range(CHAR5_ATTACK)]
        sort = [rng.next(256) if i < FIRST[3] else 0 for i in range(0x100)]
        info4 = [rng.next(BOOSTS) if rng.next(3) == 0 else 0 for _ in range(ITEMS)]
        case = {"order": order, "caps": caps, "boosts": boost_words, "char5": char5, "sort": sort, "info4": info4,
                "records": [], "expected": []}
        for k in range(2 * CHARACTERS):
            rec = bytearray(RECORD_SIZE)
            rec[0] = (k % CHARACTERS) | rng.next(32) << 3
            w5 = rng.next(1000) if n != 5 else rng.next(1 << 16)
            w3 = rng.next(w5 + 200)
            rec[3:5], rec[5:7] = (w3 & 0xFFFF).to_bytes(2, "little"), w5.to_bytes(2, "little")
            for s in range(7):
                rec[0x0B + s] = rng.next(256) if n == 4 else rng.next(100)
            # the doubled index is taken 8-bit: 128 and up read entry v - 128
            rec[0x12] = rng.next(CHAR5_ATTACK) | (0x80 if rng.next(4) == 0 else 0)
            for kk in range(4):
                rec[0x27 + kk] = FIRST[(2, 1, 0, 3)[kk]] + rng.next(FIRST[(2, 1, 0, 3)[kk] + 1] - FIRST[(2, 1, 0, 3)[kk]])
            if k % 5 == 0:
                rec[0x2A] = (BOOST_HALF, BOOST_QUARTER, DOUBLE_STAT5)[rng.next(3)]
            derived, word3 = calc_stats(rec, {"sort": sort, "info4": info4},
                                        {"boosts": boost_words, "order": order, "caps": caps, "char5": char5})
            case["records"].append(list(rec))
            case["expected"].append({"derived": derived, "word3": word3})
        cases.append(case)
    return {"schema": "ct-item-stat-vectors/1",
            "note": "synthetic tables and records (no ROM data); expected by re_workspace/tools/ct_items.py",
            "cases": cases}


def vectors_text():
    v = synthetic_cases()
    cases = []
    for case in v["cases"]:
        rows = ",\n".join(f'    {{"record":{json.dumps(r, separators=(",", ":"))},'
                          f'"derived":{json.dumps(e["derived"], separators=(",", ":"))},"word3":{e["word3"]}}}'
                          for r, e in zip(case["records"], case["expected"]))
        tables = {"statOrder": case["order"], "statCaps": case["caps"], "boosts": case["boosts"], "char5Attack": case["char5"],
                  "sortKeys": case["sort"], "info4": case["info4"]}
        head = ",\n".join(f'   "{k}": {json.dumps(val, separators=(",", ":"))}' for k, val in tables.items())
        cases.append("  {\n" + head + ',\n   "rows": [\n' + rows + "]}")
    head = ",\n".join(f' "{k}": {json.dumps(v[k])}' for k in ("schema", "note"))
    return "{\n" + head + ',\n "cases": [\n' + ",\n".join(cases) + "]}\n"


VECTORS = WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "items" / "stat_vectors.json"


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
    k.add_argument("--run", action="store_true", help="also run the ROM's item routines")
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
            raise SystemExit("vectors differ from ct_items.py; regenerate with --out")
        print(f"{len(synthetic_cases()['cases'])} synthetic item-stat cases")
        return
    rom = read_rom(args.rom)
    if args.command == "decode":
        print(json.dumps(decode_all(rom), indent=1, ensure_ascii=False))
    else:
        results = code_claims(rom) + data_claims(rom) + (asm_claims() if REF.exists() else [])
        if args.run:
            results += run_claims(rom) + synthetic_run_claims(rom)
        for name, ok, detail in results:
            print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f"  [{detail}]" if detail and not ok else ""))
        failed = [r for r in results if not r[1]]
        print(f"{len(results) - len(failed)} of {len(results)} item claims hold")
        if failed:
            sys.exit(1)


if __name__ == "__main__":
    main()
