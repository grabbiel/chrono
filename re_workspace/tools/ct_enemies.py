#!/usr/bin/env python3
"""Chrono Trigger enemies: stat records, rewards, names, attacks, AI scripts, evidence.

Enemy ids run from 0 to 255 (a battle's !Battler_UnkAF0A entry). The battle
code reads them from bank $CC:

  EnemyStats   $CC:4700  23 B per id: the record BattleFD_UnkB438 ($FD:B438)
                         copies into the enemy's BattlerStats block
  EnemyReward  $CC:5E00   7 B per id: exp, gold, drop, charm, tech points
                         (BattleFD_AddEnemyRewards $FD:ABA2; the steal code)
  EnemyNames   $CC:6500  11 B per id, ids 0-250: glyphs, $EF a blank
                         (TextWin_ExtEnemyName $C2:5AD0)
  EnemyTechs   $CC:6FC9  11 B per tech number: TechRec's layout (BattleSys_UnkD7C4)
  EffectsA     $CC:7AC9  12 B per part number: their effect records
  TechTarget   $CC:86C9   2 B per tech number: target mode, area
  EnemyAttacks $CC:88C9  11 B per attack number: TechRec's layout (BattleSys_UnkD8D1)
  EffectsB     $CC:89C6  12 B per part number: their effect records
  AiScriptPtrs $CC:8B08   2 B per id: the bank-$CC address of its AI script

An AI script (BattleAi_RunMainPart $C1:AFD2, BattleAi_FindReactPart
$C1:B488) is a main part and a reaction part, each a list of blocks ended
by $FF. A block is one or two 4-byte test records then $FE, and action
records then $FE; an action record's length is BattleFD_AiActLength
($FD:BA4A) of its code (code 4: the code byte alone, BattleAi_ChooseByChance).
`ai_text` shows a script with the names of the handlers that read each
code and byte (ChronoRET's labels); `ai_assemble` turns the text back
into the same bytes.

Each claim is re-derived three ways by `check`: from the ROM's own code
bytes, from ChronoRET's matched source (MIT; refs/ChronoRET), and from the
ROM's data. `check --run` also runs the ROM's loader BattleFD_UnkB438 and
reward routine BattleFD_AddEnemyRewards in ChronoRET's 65816 interpreter
for every enemy and compares battle RAM with the decode.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_enemies.py decode [--rom PATH]          every enemy, attack, tech and script (JSON)
    ct_enemies.py ai <id> [--rom PATH]          an enemy's AI script as text
    ct_enemies.py check [--rom PATH] [--run]    every evidence claim (exit 1 on a failure);
                                                --run also executes the ROM's routines
    ct_enemies.py vectors (--out | --check) P   synthetic AI-script vectors for the Swift tests
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


def u(data, at, size):
    return int.from_bytes(data[at:at + size], "little")


# --- Tables --------------------------------------------------------------------------

ENEMIES = 256                        # ids 0-255; the pointer, stat and reward tables hold 256
STATS_PC, STATS_SIZE = pc(0xCC, 0x4700), 23        # !BattleRom_EnemyStats
REWARDS_PC, REWARDS_SIZE = pc(0xCC, 0x5E00), 7     # BattleRom_EnemyReward
NAMES_PC, NAME_SIZE = pc(0xCC, 0x6500), 11         # !TextWinRom_EnemyNames
NAMED = 251                          # ids 0-250: the names end where EnemyTechs start
TECHS_PC, TECH_SIZE = pc(0xCC, 0x6FC9), 11         # !BattleRom_UnkCC6FCB - 2
TECHS = 256                          # up to EffectsA
EFFECTS_A_PC, EFFECT_SIZE = pc(0xCC, 0x7AC9), 12   # !BattleRom_EnemyEffectRecA
TECH_TARGET_PC = pc(0xCC, 0x86C9)    # !BattleRom_EnemyTechTarget
ATTACKS_PC = pc(0xCC, 0x88C9)        # !BattleRom_UnkCC88CB - 2
ATTACKS = 23                         # up to EffectsB
EFFECTS_B_PC = pc(0xCC, 0x89C6)      # !BattleRom_EnemyEffectRecB
AI_PTRS_PC = pc(0xCC, 0x8B08)        # !BattleRom_AiScriptPtrs
AI_BANK = 0xCC
FIXED_SCRIPTS = (0x8D08, 0x8D1E)     # BattleAi_PickScript's stand-ins
AI_ACT_LENGTH_PC = pc(0xFD, 0xBA4A)  # BattleFD_AiActLength
BLOCK_END, PART_END = 0xFE, 0xFF
TEST_SIZE = 4
PART_NONE = 0xFF                     # BattleSys_UnkD7C4 / D8D1: part $FF runs no effect record
EFFECT_TYPES = 45                    # BattleSys_EffectTable (ct_techs.py)

ITEM_COUNT = 0xF2                    # item ids 0-$F1 (Menu_ItemCategoryBounds' last bound)
EMPTY_ID = 0xFF                      # !Battle_EntryNone: id $FF is no enemy to the reward code
NAME_BLANK = 0xEF                    # ' ' in the name glyphs; also pads

# Element of resistance byte n (BattleSys_HitModUnk6CScale: the first of
# TechRec byte 3's bits 7, 6, 5, 4); the names are ct_techs.py's.
ELEMENTS = ("lightning", "shadow", "water", "fire")
AFFINITY_NORMAL = 4                  # the divisor 4 a PC gets (BattleFD_UnkB3FE)

# The stat record: (offset, size, name, status, where BattleFD_UnkB438 puts it
# (BattlerStats offset), evidence). Every byte is in exactly one entry.
FIELDS = (
    (0x00, 2, "hp", "verified", 0x30,
     "BattleFD_UnkB438 stores it to BattlerStats.CurHp and .MaxHp (16-bit); BattleFD_RestoreEnemies' "
     "HP modes halve or quarter it; run: the block's +$03 and +$05"),
    (0x02, 1, "level", "verified", 0x3F,
     "-> BattlerStats.Unk3F = PcStatBlk.Level (+$12): BattleSys_CalcDamage reads the caster's $5E3F (the magic "
     "formula's level x ...), as for a PC (ct_characters.py); run: the block's +$12"),
    (0x03, 1, "status03", "partial", 0x4F,
     "-> BattlerStats.Unk4C+3 (PcStatBlk +$22): BattleSys_UnkB3? clears and tests it (ChronoRET $C1:30813); "
     "values 0 or $7F in the ROM; not named"),
    (0x04, 1, "status04", "partial", 0x50,
     "-> BattlerStats.Unk4C+4: BattleAi_PickScript keeps the enemy's own script while Status2 bit 2 is set "
     "when this byte has bit 2 ((Status2 ^ it) & Status2); the other bits not traced"),
    (0x05, 1, "status05", "undecoded", 0x51, "-> BattlerStats.Unk4C+5; 0 in every ROM record"),
    (0x06, 1, "status06", "partial", 0x52,
     "-> BattlerStats.Unk4C+6 and (copied by BattleFD_UnkB438) .Unk4C+1: bit 7 halves turn-list timers "
     "(BattleSys_ListHandler8), bit 6 list 4's amount; 0 in every ROM record"),
    (0x07, 1, "status07", "partial", 0x53,
     "-> BattlerStats.Unk4C+7 and (copied) .Unk4C+2: bit 7 makes BattleAi_PickScript use the fixed script "
     "$CC:8D08 (!BattleAi_Unk4CBit7)"),
    (0x08, 1, "stamina", "partial", 0x64,
     "-> BattlerStats.Unk64 (derived stat +$37, a PC's stamina slot): BattleSys_ListHandler1 adds it to turn "
     "list 1's reload and halves it (+ 8) as its HP amount's divisor; summed into .Unk3E for a PC"),
    (0x09, 1, "speed", "verified", 0x65,
     "-> BattlerStats.Unk65 = PcStatBlk +$38: BattleFD_UnkB7EB picks the first !Battler_UnkAFAB (the turn "
     "gauge) from it, capped at 16 (!Battle_StatCap16); ROM: 0-16 in every record"),
    (0x0A, 1, "magic", "verified", 0x66,
     "-> BattlerStats.Unk66 (+$39): BattleSys_CalcDamage kind 3 (c.Unk66 x 12, ct_characters.py claims), "
     "BattleSys_UpdateKo's revive HP = it x 5"),
    (0x0B, 1, "hit", "verified", 0x67,
     "-> BattlerStats.Unk67 (+$3A): the caster byte $3A of the hit roll (BattleSys_EffRecStatPair, 19 effect "
     "records); BattleSys_CalcDamage kind 2"),
    (0x0C, 1, "evade", "verified", 0x68,
     "-> BattlerStats.Unk68 (+$3B): the target byte $3B of the same hit rolls"),
    (0x0D, 1, "magic_defense", "verified", 0x69,
     "-> BattlerStats.Unk69 (+$3C): BattleSys_AdjustDefence effect byte 6 = $3C takes it x 5 / 2"),
    (0x0E, 1, "attack", "partial", 0x6A,
     "-> BattlerStats.Unk6A (+$3D, a PC's weapon attack, Battle_SetupBattle): BattleSys_CalcDamage kind 4's "
     "caster stat"),
    (0x0F, 1, "defense", "verified", 0x6B,
     "-> BattlerStats.Unk6B (+$3E, a PC's stamina + armour): BattleSys_AdjustDefence effect byte 6 = $3E"),
    (0x10, 4, "affinity", "decoded", 0x6C,
     "-> BattlerStats.Unk6C+0..3: BattleSys_HitModUnk6CScale divides an elemental hit by byte n (element n: "
     "lightning, shadow, water, fire) x 4: bit 7 = absorb (healed), bit 6 = divisor - 2, bits 5-0 the "
     "divisor; 4 = normal (a PC's, BattleFD_UnkB3FE)"),
    (0x14, 1, "immunity", "partial", 0x46,
     "-> BattlerStats.Unk46 (PcStatBlk +$19): BattleSys_EffRecArg10Unk46 sets it against effect byte 10 "
     "(the status-hit immunity test, BattleSys_Effect03); modifiers $0E/$12 skip a target with bit 7; "
     "target handler $25 picks bit 0"),
    (0x15, 1, "flags15", "partial", 0x47,
     "-> BattlerStats.Unk47: bits 0-1 -> !Battle_UnkA020 (BattleFD_UnkB121), bit 1 inverted -> "
     "!Battler_Unk9F29 (BattleFD_UnkB0D5); not named"),
    (0x16, 1, "attack_id", "verified", 0x48,
     "-> BattlerStats.Unk48: BattleAi_RunAttack with id 1 makes it !Battle_UnkB18C, the EnemyAttacks record "
     "(BattleFD_LoadUnkB18E2, BattleSys_UnkD8D1); ROM: 0-22, below the 23 attack records"),
)
STAT_NAMES = ("stamina", "speed", "magic", "hit", "evade", "magic_defense", "attack", "defense")

REWARD_FIELDS = (
    (0, 2, "exp", "verified",
     "BattleRom_EnemyReward.Unk0: BattleFD_AddEnemyRewards adds it to !Battle_UnkB28C, the amount "
     "BattleSys_AddExp ($C1:F908) adds to each PC's exp (ct_characters.py); run"),
    (2, 2, "gold", "verified",
     ".Gold: added to !Battle_RewardGold, which BattleSys_Main's victory path pays (BankC1_AddGold); run"),
    (4, 1, "drop", "verified",
     ".ItemA (0 = none): 90% (!Battle_ItemDrawBelow) into the first reward list when it differs from the "
     "charm, always when equal; the steal's plain item ($C1 steal: !BattleRom_EnemyUnk5E04); "
     "Battle_SetupBattle's !Battle_UnkAE5D bit 6; ROM: an item id 0-$F1; run"),
    (5, 1, "charm", "verified",
     ".ItemB: the steal's better item (!Battle_AE5DBit7 path, !BattleRom_EnemyUnk5E05); equal to the drop = "
     "the drop is certain; ROM: an item id 0-$F1; run"),
    (6, 1, "tech_points", "verified",
     ".Unk6: added to the 24-bit !Battle_UnkB2DB, the award BattleSys_SpendTechPoints pays (ct_techs.py "
     "check --run); run"),
)

# Spans the builder may write (all of the stat and reward records).
WRITABLE = tuple(f[2] for f in FIELDS) + tuple(f[2] for f in REWARD_FIELDS)


def field(name):
    for offset, size, n, *_ in FIELDS:
        if n == name:
            return offset, size
    raise KeyError(name)


# --- Codec ---------------------------------------------------------------------------

def decode_stats(raw):
    """The decoded fields of one 23-byte stat record."""
    assert len(raw) == STATS_SIZE
    v = {"hp": u(raw, 0, 2), "level": raw[2], "status": [raw[3], raw[4], raw[5], raw[6], raw[7]],
         "stats": {s: raw[8 + i] for i, s in enumerate(STAT_NAMES)},
         "affinity": {e: raw[0x10 + i] for i, e in enumerate(ELEMENTS)},
         "immunity": raw[0x14], "flags15": raw[0x15], "attack_id": raw[0x16]}
    return v


def encode_stats(v):
    raw = bytearray(STATS_SIZE)
    raw[0:2] = v["hp"].to_bytes(2, "little")
    raw[2] = v["level"]
    raw[3:8] = bytes(v["status"])
    for i, s in enumerate(STAT_NAMES):
        raw[8 + i] = v["stats"][s]
    for i, e in enumerate(ELEMENTS):
        raw[0x10 + i] = v["affinity"][e]
    raw[0x14], raw[0x15], raw[0x16] = v["immunity"], v["flags15"], v["attack_id"]
    return bytes(raw)


def decode_reward(raw):
    assert len(raw) == REWARDS_SIZE
    return {"exp": u(raw, 0, 2), "gold": u(raw, 2, 2), "drop": raw[4], "charm": raw[5], "tech_points": raw[6]}


def encode_reward(v):
    return v["exp"].to_bytes(2, "little") + v["gold"].to_bytes(2, "little") + bytes(
        [v["drop"], v["charm"], v["tech_points"]])


def affinity_text(byte):
    """BattleSys_HitModUnk6CScale's reading of a resistance byte."""
    divisor = (byte & 0x3F) - (2 if byte & 0x40 else 0)
    head = "absorb " if byte & 0x80 else ""
    if divisor <= 0:
        return head + "none (0 damage)" if not head else head + "x0"
    return f"{head}x{AFFINITY_NORMAL}/{divisor}"


def _glyphs(ref=REF):
    if str(ref / "tools") not in sys.path:
        sys.path.insert(0, str(ref / "tools"))
    import text
    return text.GLYPHS


def decode_name(raw, glyphs):
    """11 glyphs, $EF a blank (and the padding)."""
    return "".join(glyphs.get(b, f"{{g{b:02X}}}") for b in raw).rstrip(" ")


def encode_name(name, glyphs):
    back = {v: k for k, v in glyphs.items() if v and k != 0xFF}
    back[" "] = NAME_BLANK
    out, i = [], 0
    while i < len(name):
        m = re.match(r"\{g([0-9A-F]{2})\}", name[i:])
        if m:
            out.append(int(m.group(1), 16))
            i += m.end()
            continue
        if name[i] not in back:
            raise ValueError(f"no glyph for {name[i]!r}")
        out.append(back[name[i]])
        i += 1
    if len(out) > NAME_SIZE:
        raise ValueError(f"{name!r} is {len(out)} glyphs; the most is {NAME_SIZE}")
    return bytes(out + [NAME_BLANK] * (NAME_SIZE - len(out)))


def stats_record(rom, e):
    return rom[STATS_PC + STATS_SIZE * e:STATS_PC + STATS_SIZE * (e + 1)]


def reward_record(rom, e):
    return rom[REWARDS_PC + REWARDS_SIZE * e:REWARDS_PC + REWARDS_SIZE * (e + 1)]


def name_record(rom, e):
    return rom[NAMES_PC + NAME_SIZE * e:NAMES_PC + NAME_SIZE * (e + 1)]


# Enemy techs and attacks: TechRec's layout (ct_techs.py), one part.
EFFECT_FIELDS = ("type", "arg1", "arg2", "caster_stat", "target_stat", "formula", "defence", "flags",
                 "flags2", "power", "immunity", "arg11")


def decode_action_record(rom, base, n, effects_pc, target_pc=None):
    rec = rom[base + TECH_SIZE * n:base + TECH_SIZE * (n + 1)]
    part = rec[5]
    out = {"id": n, "flags": rec[1], "b18e": rec[2], "element_bits": rec[3] >> 4, "attr": rec[3] & 0x0F,
           "part": part, "modifier": rec[8], "raw_unread": [rec[0], rec[4], rec[6], rec[7], rec[9], rec[10]]}
    if part != PART_NONE:
        eff = rom[effects_pc + EFFECT_SIZE * part:effects_pc + EFFECT_SIZE * (part + 1)]
        out["effect"] = dict(zip(EFFECT_FIELDS, eff))
    if target_pc is not None:
        out["target_mode"], out["area"] = rom[target_pc + 2 * n], rom[target_pc + 2 * n + 1]
    return out


# --- AI scripts --------------------------------------------------------------------------

# Test codes $00-$28: (display name, labels of bytes 1-3), from the
# BattleAi_TestTable handlers' headers in ChronoRET ("Record [...]").
TESTS = {
    0x00: ("Always", ("b1", "b2", "b3")),
    0x01: ("HpHalfOrLess", ("target", "b2", "b3")),
    0x02: ("StatusBits", ("which", "offset", "mask")),
    0x03: ("TargetId", ("target", "id", "b3")),
    0x04: ("EnemyIdPresent", ("b1", "id", "absent")),
    0x05: ("EnemyCountAtMost", ("n", "b2", "b3")),
    0x06: ("TimeAtLeast", ("low", "middle", "high")),
    0x07: ("UnkB320", ("value", "mode", "b3")),
    0x08: ("HpAtMost", ("target", "hpLow", "hpHigh")),
    0x09: ("StatByteAtLeast", ("target", "offset", "value")),
    0x0A: ("StatByteBits", ("target", "offset", "mask")),
    0x0B: ("StatByteAtMost", ("target", "offset", "value")),
    0x0C: ("TargetWithin32", ("target", "invert", "b3")),
    0x0D: ("AnySameRow", ("target", "invert", "b3")),
    0x0E: ("AnyAboveOrLeft", ("target", "invert", "dir")),
    0x0F: ("PathClear", ("target", "invert", "arg")),
    0x10: ("ScreenArea", ("b1", "which", "columns")),
    0x11: ("B19EKind", ("kind", "b2", "invert")),
    0x12: ("B19EKindAndId", ("kind", "id", "invert")),
    0x13: ("B19EBit4", ("value", "b2", "invert")),
    0x14: ("B19ESlot", ("id", "mode", "invert")),
    0x15: ("B19EByte2Bits", ("mask", "b2", "invert")),
    0x16: ("Always16", ("b1", "b2", "b3")),
    0x17: ("Chance", ("percent", "b2", "b3")),
    0x18: ("StatByteEquals", ("value", "target", "offset")),
    0x19: ("Always19", ("b1", "b2", "b3")),
    0x1A: ("OtherEnemy", ("id", "skipSelf", "want")),
    0x1B: ("PcCountAtMost", ("n", "b2", "b3")),
    0x1C: ("UnkAF0AMatch", ("target", "any", "absent")),
    0x1D: ("TargetGone", ("target", "b2", "gone")),
    0x1E: ("ChooseAndGoOn", ("b1", "b2", "b3")),
    0x1F: ("TargetWithin48", ("target", "invert", "b3")),
    0x20: ("UnkAEB3Set", ("b1", "b2", "b3")),
    0x21: ("UnkAF15Set", ("b1", "b2", "b3")),
    0x22: ("UnkB158", ("target", "value", "atLeast")),
}
for _c in range(0x23, 0x29):
    TESTS[_c] = ("StatByteEquals", ("value", "target", "offset"))

# The handler each test code dispatches to (BattleAi_TestTable, $C1:B80D).
TEST_HANDLERS = {c: "BattleAi_Test00" if c == 0 else "BattleAi_Test" + n for c, (n, _) in TESTS.items()}

_PAIRS4 = tuple(f"{k}{i}" for i in range(1, 5) for k in ("offset", "value"))
_DELTAS4 = tuple(f"{k}{i}" for i in range(1, 5) for k in ("offset", "delta"))
_PAIRS5 = tuple(f"{k}{i}" for i in range(1, 6) for k in ("offset", "value"))
_DELTAS5 = tuple(f"{k}{i}" for i in range(1, 6) for k in ("offset", "delta"))
# Action codes $00-$16: (display name, labels of the bytes after the code),
# from the BattleAi_ChooseTable / BattleAi_RunTable headers. None: the
# length table gives no usable length (0 or $FF) and the code is not parsed.
ACTIONS = {
    0x00: ("AnimTarget", ("b1", "target", "anim")),
    0x01: ("Attack", ("id", "target", "arg")),
    0x02: ("Tech", ("tech", "target", "helper1", "helper2", "message")),
    0x03: ("Nop03", None),
    0x04: ("ByChance", ()),
    0x05: ("ChooseRepeat", None),
    0x06: ("Nop06", ("b1", "b2", "b3")),
    0x07: ("SwapInEnemy", ("id", "action", "rebuild")),
    0x08: ("Nop08", ("b1", "b2", "b3")),
    0x09: ("Leave", ("action",)),
    0x0A: ("KoSelf", ("action", "message")),
    0x0B: ("SetStatByte", ("offset", "value", "or", "message")),
    0x0C: ("AddStatByte", ("offset", "delta", "message")),
    0x0D: ("SetFlags", ("flags", "message")),
    0x0E: ("Nop0E", ("b1",)),
    0x0F: ("Message", ("byte",)),
    0x10: ("RestoreEnemies", ("hpMode", "action", "message")),
    0x11: ("SetStatBytes", _PAIRS4 + ("message",)),
    0x12: ("SetStatsTech", ("tech", "b2", "helper1", "helper2") + _PAIRS5 + ("message",)),
    0x13: ("AddUnkB158", ("target", "delta")),
    0x14: ("AddStatBytes", _DELTAS4 + ("message",)),
    0x15: ("AddStatsTech", ("tech", "b2", "helper1", "helper2") + _DELTAS5 + ("message",)),
    0x16: ("RestoreAndSetStats", ("b1", "action") + tuple(f"p{i}" for i in range(1, 9)) + ("message",)),
}
RUN_HANDLERS = ("RunNothing", "RunAttack", "RunTech", "RunNop03", "RunNop04", "RunChooseRepeat", "RunNop06",
                "RunSwapInEnemy", "RunNop08", "RunLeave", "RunKoSelf", "RunSetStatByte", "RunAddStatByte",
                "RunSetFlags", "RunNop0E", "RunMessage", "RunRestoreEnemies", "RunSetStatBytes",
                "RunSetStatsTech", "RunAddUnkB158", "RunAddStatBytes", "RunAddStatsTech",
                "RunRestoreAndSetStats")
CHOOSE_HANDLERS = ("ChooseAnimTarget", "ChooseTarget", "ChooseTarget", "ChooseNop03", "ChooseByChance",
                   "ChooseNop05", "ChooseNop06", "ChooseClear07", "ChooseNop08", "ChooseActId", "ChooseNop0A",
                   "ChooseClear0B", "ChooseNop0C", "ChooseNop0D", "ChooseNop0E", "ChooseNop0F",
                   "ChooseIfGoneEnemy", "ChooseClear11", "ChooseClear11", "ChooseClear11", "ChooseClear11",
                   "ChooseClear11", "ChooseIfGoneEnemy")
# Target codes $00-$38 (BattleAi_TargetTable, $C1:B8BB): the handlers' names.
TARGETS = ("None", "Pcs", "All", "Self", "FromUnkB19E", "RandomPc", "NearestPc", "FarthestPc", "LowestHpPc",
           "PcStatus", "PcStatus2", "PcUnk1F", "PcUnk20", "PcUnk21", "PcStatus2Bit1", "PcStatus2Bit7",
           "PcStatus2Bit2", "PcUnk21Bit2", "PcUnk21Bit6", "PcUnk20Bit4", "PcUnk01Bit3", "OtherEnemies",
           "Enemies", "NearestEnemy", "FarthestEnemy", "LowestHpEnemy", "OtherEnemyStatus", "EnemyStatus",
           "OtherEnemyStatus2", "EnemyStatus2", "OtherEnemyUnk1F", "EnemyUnk1F", "OtherEnemyStatus2Bit1",
           "OtherEnemyStatus2Bit7", "OtherEnemyStatus2Bit2", "OtherEnemyUnk21Bit6", "OtherEnemyStatusBit1",
           "OtherEnemyUnk19Bit0", "LowestHpOtherEnemy", "Enemy0", "Enemy1", "Enemy2", "Enemy3", "Enemy4",
           "Enemy5", "Enemy6", "Enemy7", "RandomUnkAF15", "Slot0", "Slot1", "Slot2", "Slot3", "Slot4",
           "Slot5", "Slot6", "HighestHpPc", "RandomOtherEnemy")


def act_lengths(rom):
    return list(rom[AI_ACT_LENGTH_PC:AI_ACT_LENGTH_PC + len(ACTIONS)])


def action_length(code, lengths):
    """Bytes of an action record; None when the code cannot be stepped over."""
    if code == 0x04:
        return 1                     # BattleAi_ChooseByChance steps one byte past it
    if code >= len(lengths) or ACTIONS[code][1] is None:
        return None
    return lengths[code]


class ScriptError(ValueError):
    pass


def parse_script(data, at, lengths):
    """The two parts of the script at `at` in `data` (the bank's bytes, or a
    whole synthetic script): [[(tests, actions)], ...] with each test 4 bytes
    and each action its length's bytes, and the end offset. The game scans
    bytes for $FE and $FF; a record holding one before its end would be cut
    there, so such a script is refused."""
    parts, x = [], at
    for _ in range(2):
        blocks = []
        while True:
            if x >= len(data):
                raise ScriptError("runs past the data")
            if data[x] == PART_END:
                x += 1
                break
            end = data.index(BLOCK_END, x)
            tests = data[x:end]
            if len(tests) not in (TEST_SIZE, 2 * TEST_SIZE):
                raise ScriptError(f"a test part of {len(tests)} bytes at +{x - at}")
            tests = [bytes(tests[i:i + TEST_SIZE]) for i in range(0, len(tests), TEST_SIZE)]
            for t in tests:
                if t[0] not in TESTS:
                    raise ScriptError(f"test code ${t[0]:02X} past the table")
            x = end + 1
            actions = []
            while data[x] != BLOCK_END:
                n = action_length(data[x], lengths) if data[x] < 0x80 else None
                if n is None:
                    raise ScriptError(f"action code ${data[x]:02X} at +{x - at} has no length")
                rec = bytes(data[x:x + n])
                if BLOCK_END in rec[1:] or PART_END in rec[1:]:
                    raise ScriptError(f"action ${data[x]:02X} at +{x - at} holds $FE or $FF")
                actions.append(rec)
                x += n
            x += 1
            blocks.append((tests, actions))
        parts.append(blocks)
    return parts, x


def assemble_parts(parts):
    out = bytearray()
    for blocks in parts:
        for tests, actions in blocks:
            out += b"".join(tests) + bytes([BLOCK_END]) + b"".join(actions) + bytes([BLOCK_END])
        out.append(PART_END)
    return bytes(out)


def _target_note(labels, rec):
    notes = [f"{TARGETS[rec[1 + i]]}" for i, label in enumerate(labels)
             if label in ("target", "helper1", "helper2") and rec[1 + i] < len(TARGETS)
             and not (label.startswith("helper") and rec[1 + i] == 0)]
    return f"  ; {', '.join(notes)}" if notes else ""


def record_line(kind, rec):
    name, labels = (TESTS if kind == "test" else ACTIONS)[rec[0]]
    args = " ".join(f"{label}=${b:02X}" for label, b in zip(labels, rec[1:]))
    return f"{kind} ${rec[0]:02X} {name}" + (f" {args}" if args else "") + _target_note(labels, rec)


def format_parts(parts):
    lines = []
    for title, blocks in zip(("main", "reaction"), parts):
        lines.append(title)
        for tests, actions in blocks:
            lines.append("  block")
            lines += ["    " + record_line("test", t) for t in tests]
            lines += ["    " + record_line("act", a) for a in actions]
    lines.append("end")
    return "\n".join(lines) + "\n"


def ai_text(data, at, lengths):
    return format_parts(parse_script(data, at, lengths)[0])


def ai_assemble(text, lengths):
    """The bytes of a script in `format_parts`' text (names are checked
    against the codes; labels are only read as `label=$hh` or `$hh`)."""
    parts, blocks = [], None
    for number, line in enumerate(text.splitlines(), 1):
        line = line.split(";")[0].strip()
        if not line:
            continue
        head = line.split()
        if head[0] in ("main", "reaction") and len(head) == 1:
            if (head[0] == "main") != (len(parts) == 0):
                raise ScriptError(f"line {number}: main, then reaction")
            blocks = []
            parts.append(blocks)
        elif head[0] == "end":
            break
        elif head[0] == "block" and blocks is not None:
            blocks.append(([], []))
        elif head[0] in ("test", "act") and blocks:
            m = re.fullmatch(r"\$([0-9A-Fa-f]{2})", head[1]) if len(head) > 1 else None
            if not m:
                raise ScriptError(f"line {number}: expected a $code")
            code = int(m.group(1), 16)
            table = TESTS if head[0] == "test" else ACTIONS
            if code not in table or table[code][1] is None:
                raise ScriptError(f"line {number}: no {head[0]} ${code:02X}")
            name, labels = table[code]
            rest = head[2:]
            if rest and not rest[0].startswith("$") and "=" not in rest[0]:
                if rest[0] != name:
                    raise ScriptError(f"line {number}: ${code:02X} is {name}, not {rest[0]}")
                rest = rest[1:]
            values = []
            for token in rest:
                m = re.fullmatch(r"(?:[A-Za-z0-9]+=)?\$([0-9A-Fa-f]{2})", token)
                if not m:
                    raise ScriptError(f"line {number}: bad byte {token!r}")
                values.append(int(m.group(1), 16))
            if len(values) != len(labels):
                raise ScriptError(f"line {number}: {name} takes {len(labels)} bytes, not {len(values)}")
            if head[0] == "act" and action_length(code, lengths) != 1 + len(labels):
                raise ScriptError(f"line {number}: the length table gives ${code:02X} another length")
            blocks[-1][0 if head[0] == "test" else 1].append(bytes([code] + values))
        else:
            raise ScriptError(f"line {number}: {line!r}")
    if len(parts) != 2:
        raise ScriptError("a script has a main and a reaction part")
    for blocks in parts:
        for tests, actions in blocks:
            if len(tests) not in (1, 2):
                raise ScriptError("a block has one or two tests")
    out = assemble_parts(parts)
    parse_script(out, 0, lengths)          # the game would read it back the same way
    return out


def script_pointer(rom, e):
    return u(rom, AI_PTRS_PC + 2 * e, 2)


def bank(rom):
    return rom[pc(AI_BANK, 0):pc(AI_BANK, 0) + 0x10000]


def decode_script(rom, e, lengths=None):
    lengths = lengths or act_lengths(rom)
    at = script_pointer(rom, e)
    try:
        parts, end = parse_script(bank(rom), at, lengths)
    except ScriptError as err:
        return {"address": f"$CC:{at:04X}", "error": str(err)}
    return {"address": f"$CC:{at:04X}", "bytes": end - at, "text": format_parts(parts)}


def decode_enemy(rom, e, glyphs, lengths=None):
    v = {"id": e, "name": decode_name(name_record(rom, e), glyphs) if e < NAMED else None}
    v.update(decode_stats(stats_record(rom, e)))
    v["reward"] = decode_reward(reward_record(rom, e))
    v["ai"] = decode_script(rom, e, lengths)
    return v


def decode_all(rom, glyphs=None):
    glyphs = glyphs if glyphs is not None else _glyphs()
    lengths = act_lengths(rom)
    return {"enemies": [decode_enemy(rom, e, glyphs, lengths) for e in range(ENEMIES)],
            "attacks": [decode_action_record(rom, ATTACKS_PC, n, EFFECTS_B_PC) for n in range(ATTACKS)],
            "techs": [decode_action_record(rom, TECHS_PC, n, EFFECTS_A_PC, TECH_TARGET_PC) for n in range(TECHS)],
            "actLengths": lengths}


# --- Evidence ---------------------------------------------------------------------------

def _body(rom, bank_, start, end):
    return bytes(rom[pc(bank_, start):pc(bank_, end) + 1])


def _has(body, *patterns):
    return all(p in body for p in patterns)


def _long(addr):
    return bytes([addr & 0xFF, addr >> 8 & 0xFF, addr >> 16])


def code_claims(rom):
    """Claims read from the ROM's code bytes: [(name, ok, detail)]."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    load = _body(rom, 0xFD, 0xB438, 0xB4D5)
    stats = b"\xbf" + _long(0xCC4700)                     # LDA.l $CC4700,X
    claim("UnkB438 reads EnemyStats $CC:4700 (23 reads of LDA.l $CC4700,X in 6 sites)", load.count(stats) == 6,
          f"{load.count(stats)} sites")
    claim("UnkB438: X = id x 8 x 2 + id x 8 - id = id x 23", _has(load, b"\x0a\x0a\x0a\x85\x00\x0a\x18\x65\x00\x38\xe5\x04"))
    claim("UnkB438: HP to CurHp and MaxHp of BattlerStats[3] ($5FB0/$5FB2), level to .Unk3F ($5FBF)",
          _has(load, stats + b"\x99\xb0\x5f\x99\xb2\x5f", stats + b"\x99\xb1\x5f\x99\xb3\x5f", stats + b"\x99\xbf\x5f"))
    claim("UnkB438: copies 5 bytes to .Unk4C+3 ($5FCF), 12 to .Unk64 ($5FE4), 3 to .Unk46 ($5FC6)",
          _has(load, stats + b"\x99\xcf\x5f", b"\xc9\x05", stats + b"\x99\xe4\x5f", b"\xc9\x0c",
               stats + b"\x99\xc6\x5f", b"\xc9\x03"))
    claim("UnkB438: .Unk4C+1/+2 ($5FCD/$5FCE) = .Unk4C+6/+7 ($5FD2/$5FD3)",
          _has(load, b"\xb9\xd2\x5f\x99\xcd\x5f\xb9\xd3\x5f\x99\xce\x5f"))
    reward = _body(rom, 0xFD, 0xABA2, 0xAC6D)
    claim("AddEnemyRewards: record = id x 7 ($FD Mul16 by 7)", b"\xa2\x07\x00\x86\x2a" in reward)
    claim("AddEnemyRewards: +0 -> $B28C, +2 -> $B2A5 (16-bit), +6 -> $B2DB with carry into $B2DD",
          _has(reward, b"\xbf" + _long(0xCC5E00) + b"\x18\x6d\x8c\xb2\x8d\x8c\xb2",
               b"\xbf" + _long(0xCC5E02) + b"\x18\x6d\xa5\xb2\x8d\xa5\xb2",
               b"\xbf" + _long(0xCC5E06), b"\x6d\xdb\xb2", b"\xee\xdd\xb2"))
    claim("AddEnemyRewards: +4 (0 = none) compared with +5; a roll below 90 of 100; lists at $B2A7 / $B2AA",
          _has(reward, b"\xbf" + _long(0xCC5E04), b"\xdf" + _long(0xCC5E05), b"\xa9\x64", b"\xc9\x5a",
               b"\xb9\xa7\xb2", b"\xb9\xaa\xb2"))
    steal = rom[pc(0xC1, 0x0000):pc(0xC1, 0xFFFF)]
    claim("the steal and Battle_SetupBattle read +5 (charm, bit 7) and +4 (drop, bit 6) at id x 7",
          steal.count(b"\xbf" + _long(0xCC5E05)) == 2 and steal.count(b"\xbf" + _long(0xCC5E04)) == 2)
    name = _body(rom, 0xC2, 0x5AD0, 0x5B05)
    claim("TextWin_ExtEnemyName: name n at $CC:6500 + n x 11, 11 bytes",
          _has(name, b"\xa9\x0b\x8f\x03\x42\x00", b"\x69\x00\x65", b"\xa9\xcc"))
    for routine, start, end in (("RunMainPart", 0xAFD2, 0xB092), ("FindReactPart", 0xB488, 0xB4A9)):
        body = _body(rom, 0xC1, start, end)
        claim(f"BattleAi_{routine}: script = LDA.l $CC8B08,X (id x 2); scans for $FF",
              _has(body, b"\x0a\xaa\xbf\x08\x8b\xcc", b"\xc9\xff"))
    main = _body(rom, 0xC1, 0xAFD2, 0xB092)
    claim("RunMainPart: a second test when byte 4 is not $FE; tests at +0 and +4; skips to $FE twice",
          _has(main, b"\xbf\x04\x00\xcc\xc9\xfe", b"\xe8\xe8\xe8\xe8", b"\xbf\x00\x00\xcc\xc9\xfe"))
    turn = _body(rom, 0xC1, 0x8CF9, 0x8EA6)
    claim("EnemyTurn steps an action by BattleFD_AiActLength ($FD:BA4A) of its code",
          b"\xbf\x4a\xba\xfd" in turn)
    chance = _body(rom, 0xC1, 0x98C5, 0x995F)
    claim("ChooseByChance: the code-4 byte alone (INX), then steps by the length table",
          _has(chance, b"\xae\xd2\xb1\xe8\x8e\xd2\xb1", b"\xbf\x4a\xba\xfd"))
    lengths = act_lengths(rom)
    claim("BattleFD_AiActLength: code 3 holds 0 and codes 4, 5 $FF (not steppable); the others 2-16",
          lengths[3] == 0 and lengths[4] == lengths[5] == 0xFF
          and all(2 <= n <= 16 for c, n in enumerate(lengths) if c not in (3, 4, 5)), repr(lengths))
    claim("action records: the length table = 1 + the labelled bytes",
          all(lengths[c] == 1 + len(labels) for c, (_, labels) in ACTIONS.items() if labels is not None and c != 4))
    attack = _body(rom, 0xC1, 0x99BE, 0x9A38)
    claim("RunAttack: id 1 makes $B18C the enemy's BattlerStats.Unk48 ($5E48,X)",
          _has(attack, b"\xc9\x01\xd0", b"\xbd\x48\x5e\x8d\x8c\xb1"))
    return out


def handler_addresses(ref=REF):
    """ChronoRET's '$C1:XXXX — Label (' headers: {label: address}."""
    text = (ref / "asm" / "bankC1" / "bankC1.asm").read_text()
    return {m.group(2): int(m.group(1), 16) for m in re.finditer(r"^; \$C1:([0-9A-F]{4}) — (BattleAi_\w+) \(",
                                                                 text, re.M)}


def table_claims(rom, ref=REF):
    """The ROM's dispatch tables against the handlers ChronoRET names, and its
    headers' record layouts against TESTS / ACTIONS."""
    out = []
    at = handler_addresses(ref)
    words = lambda base, n: [u(rom, pc(0xC1, base) + 2 * i, 2) for i in range(n)]
    tests = words(0xB80D, 0x29)
    out.append(("BattleAi_TestTable ($C1:B80D): 41 words = the named test handlers",
                tests == [at.get(TEST_HANDLERS[c]) for c in range(0x29)], ""))
    choose = words(0xB85F, 23)
    out.append(("BattleAi_ChooseTable ($C1:B85F): 23 words = the choose handlers",
                choose == [at.get("BattleAi_" + n) for n in CHOOSE_HANDLERS], ""))
    run = words(0xB88D, 23)
    out.append(("BattleAi_RunTable ($C1:B88D): 23 words = the run handlers",
                run == [at.get("BattleAi_" + n) for n in RUN_HANDLERS], ""))
    targets = words(0xB8BB, len(TARGETS))
    out.append(("BattleAi_TargetTable ($C1:B8BB): 57 words = the target handlers",
                targets == [at.get("BattleAi_Target" + n) for n in TARGETS], ""))
    src = (ref / "asm" / "bankC1" / "bankC1.asm").read_text()
    flat = re.sub(r"\n; ?", " ", src)
    missing = []
    for c, (name, labels) in TESTS.items():
        if "target" in labels and c not in range(0x23, 0x29):
            m = re.search(rf"BattleAi_TestTable entr(?:y|ies) \${c:02X}\b[^.]*\. Record \[([^\]]*)\]", flat)
            alias = re.search(rf"BattleAi_TestTable entry \${c:02X}\. As BattleAi_Test(\w+)", flat)
            if alias and "target" in next((lb for n, lb in TESTS.values() if n == alias.group(1)), ()):
                continue
            if not m or "target code" not in m.group(1):
                missing.append(f"test ${c:02X}")
    for c in (0x01, 0x02, 0x07, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0F, 0x10, 0x13):
        m = re.search(rf"BattleAi_RunTable entry \${c:02X}\. Record \[([^\]]*)\]", flat)
        if not m:
            missing.append(f"action ${c:02X}")
    out.append(("ChronoRET's headers give the target-code byte of each test that names one, and the records of "
                "11 actions", not missing, f"missing {missing}"))
    return out


def data_claims(rom, glyphs=None):
    """Claims about the ROM's data, given the decoded layout: [(name, ok, detail)]."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    glyphs = glyphs if glyphs is not None else _glyphs()
    recs = [decode_stats(stats_record(rom, e)) for e in range(ENEMIES)]
    rewards = [decode_reward(reward_record(rom, e)) for e in range(ENEMIES)]
    claim("tables meet end to end: stats + 256 x 23 = rewards, + 256 x 7 = names, + 251 x 11 = techs, "
          "+ 256 x 11 = effects A, + 256 x 12 = tech targets, + 512 = attacks, + 23 x 11 = effects B",
          STATS_PC + ENEMIES * STATS_SIZE == REWARDS_PC and REWARDS_PC + ENEMIES * REWARDS_SIZE == NAMES_PC
          and NAMES_PC + NAMED * NAME_SIZE == TECHS_PC and TECHS_PC + TECHS * TECH_SIZE == EFFECTS_A_PC
          and EFFECTS_A_PC + TECHS * EFFECT_SIZE == TECH_TARGET_PC and TECH_TARGET_PC + 2 * TECHS == ATTACKS_PC
          and ATTACKS_PC + ATTACKS * TECH_SIZE == EFFECTS_B_PC)
    claim("every record: stat encode(decode) and reward encode(decode) give the ROM's bytes",
          all(encode_stats(recs[e]) == stats_record(rom, e) and encode_reward(rewards[e]) == reward_record(rom, e)
              for e in range(ENEMIES)))
    placeholders = [e for e, r in enumerate(recs) if r["level"] == 0]
    claim("levels 1-99, but level-0 records of 1 HP (placeholders)", all(
        1 <= r["level"] <= 99 or (r["level"] == 0 and r["hp"] <= 1) for r in recs), f"{len(placeholders)} placeholders")
    claim("speed 0-17 (BattleFD_UnkB7EB caps it at 16)", all(r["stats"]["speed"] <= 17 for r in recs))
    claim("hit, evade and magic defense 0-100", all(r["stats"][s] <= 100 for r in recs
                                                    for s in ("hit", "evade", "magic_defense")))
    claim("attack ids below the 23 attack records", all(r["attack_id"] < ATTACKS for r in recs))
    claim("byte +5 is 0 in every record", all(r["status"][2] == 0 for r in recs))
    claim("drop and charm are item ids (below $F2)", all(r["drop"] < ITEM_COUNT and r["charm"] < ITEM_COUNT
                                                        for r in rewards))
    names = [name_record(rom, e) for e in range(NAMED)]
    claim("251 names: every byte a glyph; encode(decode) gives the ROM's bytes",
          all(all(b in glyphs for b in raw) and encode_name(decode_name(raw, glyphs), glyphs) == raw for raw in names))
    lengths = act_lengths(rom)
    data = bank(rom)
    parsed, ends, failed = {}, {}, []
    for e in range(ENEMIES):
        at = script_pointer(rom, e)
        try:
            parts, end = parse_script(data, at, lengths)
        except ScriptError:
            failed.append(e)
            continue
        parsed[e], ends[e] = parts, end
    claim("every AI script but one parses (tests of 4 bytes, actions of their length, $FE / $FF ends)",
          len(failed) <= 1, f"unparsed: {failed}")
    claim("every parsed script assembles back to its bytes", all(
        assemble_parts(parts) == data[script_pointer(rom, e):ends[e]] for e, parts in parsed.items()))
    claim("every parsed script's text assembles back to its bytes", all(
        ai_assemble(format_parts(parts), lengths) == data[script_pointer(rom, e):ends[e]]
        for e, parts in parsed.items()))
    fixed = []
    for at in FIXED_SCRIPTS:
        try:
            parts, _ = parse_script(data, at, lengths)
            fixed.append(len(parts[0]) == 1 and len(parts[0][0][0]) == 1 and parts[0][0][0][0][0] == 0)
        except ScriptError:
            fixed.append(False)
    claim("the fixed scripts $CC:8D08 / $8D1E are one block of the single test $00", all(fixed))
    codes = {r[0] for parts in parsed.values() for blocks in parts for tests, acts in blocks for r in tests + acts}
    claim("the scripts use only codes the tables reach (tests <= $28, actions <= $16)",
          all(c <= 0x28 for c in codes))
    used_attacks = {r["attack_id"] for r in recs}
    ids = {a[1] for parts in parsed.values() for blocks in parts for _, acts in blocks for a in acts if a[0] == 1}
    claim("attack actions use id 1 (the enemy's own attack record) or other ids", 1 in ids, f"ids {sorted(ids)}")
    techs = {a[1] for parts in parsed.values() for blocks in parts for _, acts in blocks for a in acts
             if a[0] in (0x02, 0x12, 0x15)}
    claim("tech actions name tech records below 256", all(t < TECHS for t in techs), f"{len(techs)} techs used")
    parts_a = {rom[TECHS_PC + TECH_SIZE * t + 5] for t in techs} - {PART_NONE}
    claim("the techs used: each part's EffectsA record has an effect type below 45",
          all(rom[EFFECTS_A_PC + EFFECT_SIZE * p] < EFFECT_TYPES for p in parts_a), f"{len(parts_a)} parts")
    parts_b = {rom[ATTACKS_PC + TECH_SIZE * a + 5] for a in range(ATTACKS)} - {PART_NONE}
    claim("the 23 attacks: each part's EffectsB record has an effect type below 45 and ends before the "
          "script pointers", all(rom[EFFECTS_B_PC + EFFECT_SIZE * p] < EFFECT_TYPES
                                 and EFFECTS_B_PC + EFFECT_SIZE * (p + 1) <= AI_PTRS_PC for p in parts_b),
          f"parts {sorted(parts_b)}")
    return out


# ChronoRET source claims: (file under asm/, routine label, lines that must appear in its body, in order).
ASM_CLAIMS = (
    ("bankFD/bankFD.asm", "BattleFD_UnkB438",
     ("LDA.w !Battler_UnkAF0A+!Battle_FirstEnemySlot,X", "JSR BattleFD_ZeroStatBlock",
      "STA.w BattlerStats[3].Unk2D,Y", "LDA.l !BattleRom_EnemyStats,X", "STA.w BattlerStats[3].CurHp,Y",
      "STA.w BattlerStats[3].MaxHp,Y", "STA.w BattlerStats[3].Unk3F,Y", "STA.w BattlerStats[3].Status,Y",
      "STA.w BattlerStats[3].Status2,Y", "STA.w BattlerStats[3].Unk4C+3,Y", "CMP.b #!Battle_EnemyRec4FBytes",
      "STA.w BattlerStats[3].Unk4C+1,Y", "STA.w BattlerStats[3].Unk4C+2,Y", "STA.w BattlerStats[3].Unk64,Y",
      "CMP.b #!Battle_EnemyRec64Bytes", "STA.w BattlerStats[3].Unk46,Y", "CMP.b #!Battle_EnemyRec46Bytes")),
    ("bankFD/bankFD.asm", "BattleFD_AddEnemyRewards",
     ("LDA.l BattleRom_EnemyReward.Unk0,X", "ADC.w !Battle_UnkB28C", "LDA.l BattleRom_EnemyReward.Gold,X",
      "ADC.w !Battle_RewardGold", "LDA.l BattleRom_EnemyReward.Unk6,X", "ADC.w !Battle_UnkB2DB",
      "INC.w !Battle_UnkB2DD", "LDA.l BattleRom_EnemyReward.ItemA,X", "CMP.l BattleRom_EnemyReward.ItemB,X",
      "CMP.b #!Battle_ItemDrawBelow", "STA.w !Battle_RewardItems,Y")),
    ("bankC1/bankC1.asm", "BattleSys_AddExp", ("ADC.w !Battle_UnkB28C",)),
    ("bankC2/bankC2.asm", "TextWin_ExtEnemyName",
     ("LDA.b #!TextWin_RomNameSize", "ADC.w #!TextWinRom_EnemyNames&$FFFF")),
    ("bankC1/bankC1.asm", "BattleAi_RunMainPart",
     ("LDA.l !BattleRom_AiScriptPtrs,X", "CMP.b #!BattleAi_BlockEnd", "JSR (BattleAi_TestTable,X)",
      "CMP.b #!BattleAi_ScriptEnd")),
    ("bankC1/bankC1.asm", "BattleAi_FindReactPart",
     ("LDA.l !BattleRom_AiScriptPtrs,X", "CMP.b #!BattleAi_ScriptEnd")),
    ("bankC1/bankC1.asm", "BattleAi_EnemyTurn",
     ("JSR (BattleAi_RunTable,X)", "LDA.l !BattleRom_AiActLength,X")),
    ("bankC1/bankC1.asm", "BattleAi_ChooseByChance",
     ("LDA.b #!BattleAi_PercentBound", "LDA.l !BattleRom_AiActLength,X")),
    ("bankC1/bankC1.asm", "BattleAi_RunAttack", ("LDA.w BattlerStats.Unk48,X", "STA.w !Battle_UnkB18C")),
    ("bankC1/bankC1.asm", "BattleAi_PickScript",
     ("LDA.w BattlerStats.Unk4C+2,X", "ORA.w BattlerStats.Unk4C+7,X", "LDA.w BattlerStats.Status2,X",
      "EOR.w BattlerStats.Unk4C+4,X")),
    ("bankC1/bankC1.asm", "BattleSys_HitModUnk6CScale", ("LDA.w BattlerStats.Unk6C,X",)),
    ("bankC1/bankC1.asm", "BattleSys_EffRecArg10Unk46", ("LDA.w !Battle_UnkAEE6+10", "LDA.w BattlerStats.Unk46,X")),
)


def asm_claims(ref=REF):
    """Each ASM_CLAIMS routine holds its lines in order: [(name, ok, detail)]."""
    out, sources = [], {}
    for path, label, lines in ASM_CLAIMS:
        text = sources.setdefault(path, (ref / "asm" / path).read_text().splitlines())
        try:
            start = next(i for i, line in enumerate(text) if line.strip() == f"{label}:")
        except StopIteration:
            out.append((f"{path} {label}", False, "label not found"))
            continue
        end = next((i for i in range(start + 1, len(text)) if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", text[i])),
                   len(text))
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


# --- Running the ROM's routines ------------------------------------------------------------

BLOCKS = 0x7E5E2D                    # BattlerStats[0].Unk2D; slot n at + n x $80
BLOCK_SIZE = 0x80


def expected_block(raw, e):
    """The enemy's $80-byte block as BattleFD_UnkB438 leaves it (from .Unk2D)."""
    out = bytearray(BLOCK_SIZE)
    out[0] = e
    out[0x03:0x05] = out[0x05:0x07] = raw[0:2]
    out[0x12] = raw[2]
    out[0x22:0x27] = raw[3:8]
    out[0x20], out[0x21] = raw[6], raw[7]
    out[0x37:0x43] = raw[8:0x14]
    out[0x19:0x1C] = raw[0x14:0x17]
    return bytes(out)


class RomEnemy:
    """The game's enemy loader BattleFD_UnkB438 ($FD:B438) and reward routine
    BattleFD_AddEnemyRewards ($FD:ABA2), run by ChronoRET's 65816
    interpreter (refs/ChronoRET/tools/absint.py) over `image`."""

    AF0A, AF15, AE5D = 0x7EAF0A, 0x7EAF15, 0x7EAE5D
    EXP, GOLD, ITEMS, B2AF, TP = 0x7EB28C, 0x7EB2A5, 0x7EB2A7, 0x7EB2AF, 0x7EB2DB

    def __init__(self, image, ref=REF):
        if str(ref / "tools") not in sys.path:
            sys.path.insert(0, str(ref / "tools"))
        import absint
        self.absint = absint
        self.machine = absint.Machine(bytes(image), bytearray(b"\x01") * len(image),
                                      max_steps=10 ** 6, callee_steps=10 ** 5)
        self.machine.widen_after = 10 ** 9

    def _run(self, entry, x, known):
        s = self.absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry, 0, 0, x, 0
        s.d, s.db, s.m, s.xf, s.c = 0, 0x7E, True, False, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = self.absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != "rtl" or self.machine.opaque:
            raise RuntimeError(f"${entry:06X}: {[how for _, how in ends]} opaque {self.machine.opaque}")
        return {**known, **ends[0][0].mem}

    def load(self, e, entry):
        """The enemy's block after BattleFD_UnkB438 for id `e` in enemy entry `entry` (0-7)."""
        known = {a: 0 for a in range(0x7E0000, 0x7E0040)}
        known[0x7E0002], known[0x7E0003] = entry, 0
        known.update({self.AF0A + 3 + i: 0xFF for i in range(8)})
        known[self.AF0A + 3 + entry] = e
        start = BLOCKS + (3 + entry) * BLOCK_SIZE
        known.update({start + i: 0xAA for i in range(BLOCK_SIZE)})   # garbage the zeroing must clear
        mem = self._run(0xFDB438, entry, known)
        out = bytes(mem[start + i] for i in range(BLOCK_SIZE))
        if any(b is None for b in out):
            raise RuntimeError("an unknown byte in the block")
        return out

    def reward(self, e, entry, sums, items):
        """(exp, gold, tech points (24-bit), the six item slots) after
        BattleFD_AddEnemyRewards for id `e` in `entry`, from `sums` and
        `items`, with the 90% draw switched off (!Battle_UnkAE5D bit 6 clear)."""
        known = {a: 0 for a in range(0x7E0000, 0x7E0040)}
        slot = 3 + entry
        known[0x7E000E], known[0x7E000F] = slot, 0
        known.update({self.AF0A + i: 0xFF for i in range(11)})
        known[self.AF0A + slot] = e
        known.update({self.AF15 + i: 0 for i in range(8)})
        known.update({self.AE5D + i: 0 for i in range(8)})
        exp, gold, tp = sums
        for addr, value, size in ((self.EXP, exp, 2), (self.GOLD, gold, 2), (self.TP, tp, 3)):
            for i in range(size):
                known[addr + i] = value >> (8 * i) & 0xFF
        known.update({self.ITEMS + i: b for i, b in enumerate(items)})
        known[self.B2AF] = 0
        for a in range(0x7E4200, 0x7E4220):
            known[a] = 0
        mem = self._run(0xFDABA2, 0, known)
        word = lambda a, n: sum(mem[a + i] << (8 * i) for i in range(n))
        return word(self.EXP, 2), word(self.GOLD, 2), word(self.TP, 3), [mem[self.ITEMS + i] for i in range(6)]


def expected_reward(rec, sums, items, e):
    """BattleFD_AddEnemyRewards' sums; id $FF is !Battle_EntryNone (no enemy: nothing added)."""
    exp, gold, tp = sums
    out = list(items)
    if e == EMPTY_ID:
        return exp, gold, tp, out
    if rec["drop"] and rec["drop"] == rec["charm"] and rec["drop"] not in out[3:6] and 0 in out[3:6]:
        out[3 + out[3:6].index(0)] = rec["drop"]
    return (exp + rec["exp"]) & 0xFFFF, (gold + rec["gold"]) & 0xFFFF, (tp + rec["tech_points"]) & 0xFFFFFF, out


def run_claims(rom, ref=REF):
    runner = RomEnemy(rom, ref)
    bad_load, bad_reward = [], []
    for e in range(ENEMIES):
        entry = e % 8
        if runner.load(e, entry) != expected_block(stats_record(rom, e), e):
            bad_load.append(e)
        rec = decode_reward(reward_record(rom, e))
        for sums, items in (((0, 0, 0), [0] * 6), ((0xFFF0, 0x1234, 0xFFFFF0), [0, 0, 0, rec["drop"], 0, 0])):
            got = runner.reward(e, entry, sums, items)
            if got != expected_reward(rec, sums, items, e):
                bad_reward.append(e)
                break
    return [(f"BattleFD_UnkB438 run for all {ENEMIES} ids (entries 0-7) = the decoded fields in battle RAM",
             not bad_load, f"differs for {bad_load[:8]}"),
            (f"BattleFD_AddEnemyRewards run for all {ENEMIES} ids (two starting states) = exp, gold, tech points "
             "and the certain drop (id $FF: nothing, it is !Battle_EntryNone)", not bad_reward, f"differs for {bad_reward[:8]}")]


# --- Writing scripts (the twin of macos_studio's CTEnemyAIPatch) -------------------------

AI_FREE_PC = pc(0xCC, 0xFC4F)        # Padding_CCFC4F: 945 x $FF, confirmed (manifests/rom_layout.json)
AI_FREE_SIZE = 945
SCRIPTS_PC, SCRIPTS_END = pc(0xCC, 0x8D08), pc(0xCC, 0xCBC9)   # the fixed scripts, then the enemies';
                                                               # BattleRom_ScriptMsgStrings follows
SCRIPT_MSG_PC = SCRIPTS_END


def script_spans(rom, lengths=None):
    """{id: range of PC addresses} of every pointer that leads to a script that parses."""
    lengths = lengths or act_lengths(rom)
    data, out = bank(rom), {}
    for e in range(ENEMIES):
        at = script_pointer(rom, e)
        try:
            _, end = parse_script(data, at, lengths)
        except ScriptError:
            continue
        out[e] = range(pc(AI_BANK, at), pc(AI_BANK, end))
    return out


def sharers(spans):
    """{id: [other ids whose script overlaps its span]} (ids with none left out)."""
    out = {}
    for a, ra in spans.items():
        others = [b for b, rb in spans.items() if b != a and ra.start < rb.stop and rb.start < ra.stop]
        if others:
            out[a] = sorted(others)
    return out


def write_problems(parts):
    """What the writer refuses beyond the parser: a test byte $FF (BattleAi_FindReactPart
    takes the first $FF as the main part's end) and a target code past BattleAi_TargetTable."""
    out = []
    for blocks in parts:
        for tests, actions in blocks:
            for t in tests:
                if PART_END in t[1:]:
                    out.append(f"test ${t[0]:02X} holds $FF")
            for kind, recs, table in (("test", tests, TESTS), ("act", actions, ACTIONS)):
                for r in recs:
                    for i, label in enumerate(table[r[0]][1] or ()):
                        if label == "target" and r[1 + i] >= len(TARGETS):
                            out.append(f"{kind} ${r[0]:02X}: target ${r[1 + i]:02X} past the table")
    return out


def region_claims(rom, ref=REF):
    """Where scripts live and what a writer may use: [(name, ok, detail)]."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    c1 = rom[pc(0xC1, 0):pc(0xC1, 0xFFFF) + 1]
    claim("bank $C1 holds the long operand $CC8B08 (AiScriptPtrs) exactly twice: RunMainPart and FindReactPart",
          c1.count(_long(0xCC8B08)) == 2 and _has(_body(rom, 0xC1, 0xAFD2, 0xAFDA), b"\xbf\x08\x8b\xcc")
          and _has(_body(rom, 0xC1, 0xB488, 0xB490), b"\xbf\x08\x8b\xcc"), f"{c1.count(_long(0xCC8B08))} sites")
    if ref.exists():
        lines = [(f.name, line.split(";")[0].strip()) for f in sorted((ref / "asm").glob("bank*/*.asm"))
                 for line in f.read_text().splitlines()]
        ptr = [ln for _, ln in lines if "!BattleRom_AiScriptPtrs" in ln]
        bank_reads = [ln for _, ln in lines if re.search(r"!BattleRom_ScriptBank\b(?!Enemy|Pc)", ln)]
        claim("ChronoRET: the pointer table is read only as LDA.l !BattleRom_AiScriptPtrs,X (u16, X = id x 2)",
              len(ptr) == 2 and all(ln == "LDA.l !BattleRom_AiScriptPtrs,X" for ln in ptr), f"{ptr}")
        claim("ChronoRET: every script byte is read as LDA.l !BattleRom_ScriptBank+k,X (k 0-15, 16-bit X): "
              "a script must lie inside bank $CC", bank_reads and all(
                  re.fullmatch(r"LDA\.l !BattleRom_ScriptBank(\+(\d+|!BattleAi_RecordSize))?,X", ln) for ln in bank_reads),
              f"{len(bank_reads)} reads")
        cc = (ref / "asm" / "data" / "bankCC.asm").read_text()
        claim("ChronoRET: $CC:8B08-$CC:CBC8 is the pointers and scripts; BattleRom_ScriptMsgStrings starts at "
              "$CC:CBC9; Padding_CCFC4F is 945 x $FF, confirmed",
              "$CC:8B08-$CC:CBC8" in cc and "org $CCCBC9\nBattleRom_ScriptMsgStrings:" in cc
              and "$CC:FC4F-$CC:FFFF (945 B), padding, confirmed" in cc)
    lengths = act_lengths(rom)
    spans = script_spans(rom, lengths)
    data = bank(rom)
    fixed = [range(pc(AI_BANK, a), pc(AI_BANK, parse_script(data, a, lengths)[1])) for a in FIXED_SCRIPTS]
    covered = set()
    for r in list(spans.values()) + fixed:
        covered.update(r)
    gap = sorted(set(range(SCRIPTS_PC, SCRIPTS_END)) - covered)
    p127 = pc(AI_BANK, script_pointer(rom, 127))
    claim("the fixed scripts and the 255 parsed scripts fill $CC:8D08-$CC:CBC8 but for the bytes at the unparsed "
          "pointer (enemy 127)", min(r.start for r in spans.values()) >= SCRIPTS_PC and max(
              r.stop for r in spans.values()) == SCRIPTS_END and gap and gap[0] == p127
          and gap == list(range(p127, p127 + len(gap))), f"{len(gap)} bytes from {snes(p127)}")
    starts = [r.start for r in spans.values()]
    shared = sharers(spans)
    claim("no two pointers share a start; scripts overlap only where one's tail is the next one's head",
          len(set(starts)) == len(starts) and all(
              all(spans[a].start < spans[b].start < spans[a].stop <= spans[b].stop
                  or spans[b].start < spans[a].start < spans[b].stop <= spans[a].stop for b in bs)
              for a, bs in shared.items()), f"shared {shared}")
    free = rom[AI_FREE_PC:AI_FREE_PC + AI_FREE_SIZE]
    claim("bank $CC's padding $CC:FC4F-$CC:FFFF is 945 x $FF and a confirmed free region of the layout manifest",
          free == b"\xff" * AI_FREE_SIZE and AI_FREE_PC + AI_FREE_SIZE == pc(0xCD, 0) and _layout_free(AI_FREE_PC, AI_FREE_SIZE))
    parts = [parse_script(data, script_pointer(rom, e), lengths)[0] for e in spans]
    claim("no ROM script has a test byte $FF or a target code past BattleAi_TargetTable (the writer refuses both)",
          not any(write_problems(p) for p in parts))
    claim("BattleFD_AiActLength = the table ChronoRET lists (SYNTHETIC_LENGTHS, CTEnemyAIPatch.listedLengths)",
          lengths == SYNTHETIC_LENGTHS)
    return out


def _layout_free(at, size):
    path = WS / "manifests" / "rom_layout.json"
    if not path.exists():
        return False
    regions = json.loads(path.read_text())["freeRegions"]
    return any(r["pc"] == at and r["size"] == size and r["fill"] == 0xFF for r in regions)


class RomAi:
    """The game's script reader BattleAi_RunMainPart ($C1:AFD2) and
    BattleAi_FindReactPart ($C1:B488), run by ChronoRET's 65816 interpreter
    over `image` with battle RAM zeroed except: PCs 0-2 present, enemy entry
    `entry` holding id `e` (the only enemy) and no block chosen before. The
    pointer table and bank $CC from $CC:8D08 are given as known memory, so
    the run lists every script byte it reads."""

    B252, B242, B24A, AEFF, ENEMY_COUNT = 0x7EB252, 0x7EB242, 0x7EB24A, 0x7EAEFF, 0x7EAEC6
    CHOSEN, ACT_CODE, SCRIPT_POS, B1D2, TARGETS = 0x7EB26B, 0x7EAEE3, 0x7EB1E4, 0x7EB1D2, 0x7EAECC

    def __init__(self, image, ref=REF):
        if str(ref / "tools") not in sys.path:
            sys.path.insert(0, str(ref / "tools"))
        import absint
        self.absint = absint
        self.image = bytes(image)
        self.machine = absint.Machine(self.image, bytearray(b"\x01") * len(image),
                                      max_steps=10 ** 6, callee_steps=10 ** 5)
        self.machine.widen_after = 10 ** 9

    def _known(self, e, entry):
        known = {0x7E0000 + i: 0 for i in range(0x10000)}
        known[self.B252] = entry
        for i in range(11):
            known[self.AEFF + i] = i if i < 3 else 0xFF
        known[self.AEFF + 3 + entry] = e
        known[self.ENEMY_COUNT] = entry + 1
        for i in range(8):
            known[self.CHOSEN + i] = 0xFF
        for a in list(range(AI_PTRS_PC, AI_PTRS_PC + 2 * ENEMIES)) + list(range(SCRIPTS_PC, pc(0xCD, 0))):
            known[0xC00000 | a] = self.image[a]
        return known

    def _run(self, entry_pc, a, known):
        s = self.absint.State()
        s.pc, s.a, s.b, s.x, s.y = entry_pc, a, 0, 0, 0
        s.d, s.db, s.m, s.xf, s.c = 0, 0x7E, True, False, False
        s.z = s.n = s.v = False
        s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
        s.at = s.xt = s.yt = s.ft = self.absint.E
        s.depth = 0
        ends = self.machine.run(s, known)
        if len(ends) != 1 or ends[0][1] != "rts" or self.machine.opaque:
            raise RuntimeError(f"${entry_pc:06X}: {[how for _, how in ends]} opaque {self.machine.opaque}")
        mem = {**known, **ends[0][0].mem}
        reads = sorted(a & 0x3FFFFF for a in self.machine.reads if a >= 0xC00000)
        return mem, reads

    def main(self, e, entry=0):
        """RunMainPart for id `e`: (outcome, script PC addresses read, written battle RAM)."""
        known = self._known(e, entry)
        mem, reads = self._run(0xC1AFD2, e, known)
        word = lambda a: mem[a] | mem[a + 1] << 8
        outcome = {"test": mem[self.B242 + entry], "result": mem[self.B24A + entry],
                   "block": mem[self.CHOSEN + entry], "act": mem[self.ACT_CODE],
                   "action": word(self.SCRIPT_POS + 2 * entry), "target": mem[self.TARGETS]}
        written = {a: v for a, v in mem.items() if known.get(a) != v}
        return outcome, reads, written

    def reaction(self, e, entry=0):
        """FindReactPart for id `e`: the bank-$CC address of the reaction part."""
        mem, reads = self._run(0xC1B488, e, self._known(e, entry))
        return mem[self.B1D2] | mem[self.B1D2 + 1] << 8, reads


def expected_main(parts, start, present, entry=0):
    """What RunMainPart chooses for a script at bank-$CC address `start`
    made only of the tests $00 (Always) and $04 (EnemyIdPresent, over the
    enemy ids `present`), with no block chosen before: the first block whose
    tests hold, its first action, and the target slot of a Self ($03) action."""
    at = start
    for number, (tests, actions) in enumerate(parts[0]):
        holds = True
        for t in tests:
            if t[0] == 0x00:
                continue
            if t[0] != 0x04:
                raise ValueError(f"test ${t[0]:02X} is not modelled")
            holds = holds and ((t[2] in present) == (t[3] == 0))
        action = at + 4 * len(tests) + 1
        if holds:
            a = actions[0]
            labels = ACTIONS[a[0]][1]
            target = a[1 + labels.index("target")] if "target" in labels else None
            return {"test": tests[-1][0], "result": 0, "block": number, "act": a[0], "action": action,
                    "target": 3 + entry if target == 0x03 else None}
        at = action + sum(len(a) for a in actions) + 1
    return None


# --- Synthetic vectors for the Swift twin ------------------------------------------------

class Lcg:
    """Deterministic numbers (no ROM data)."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self, n):
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.state >> 8) % n


# The length table as ChronoRET lists it (BattleFD_AiActLength), for synthetic scripts.
SYNTHETIC_LENGTHS = [4, 4, 6, 0, 0xFF, 0xFF, 4, 4, 4, 2, 3, 5, 4, 3, 2, 2, 4, 10, 16, 3, 10, 16, 12]


def synthetic_cases():
    rng = Lcg(0xE7)
    codes = [c for c, (_, labels) in ACTIONS.items() if labels is not None]
    cases = []
    for n in range(40):
        parts = []
        for _ in range(2):
            blocks = []
            for _ in range(rng.next(4) + (1 if n % 5 else 0)):
                tests = [bytes([rng.next(0x29)] + [rng.next(0xFE) for _ in range(3)]) for _ in range(1 + rng.next(2))]
                acts = []
                for _ in range(1 + rng.next(3)):
                    c = codes[rng.next(len(codes))]
                    acts.append(bytes([c] + [rng.next(0xFE) for _ in range(action_length(c, SYNTHETIC_LENGTHS) - 1)]))
                blocks.append((tests, acts))
            parts.append(blocks)
        data = assemble_parts(parts)
        cases.append({"bytes": data.hex(), "text": format_parts(parts)})
    bad = ["main\n  block\n    act $01 Attack id=$01 target=$03 arg=$00\nreaction\nend\n",
           "main\n  block\n    test $01 HpHalfOrLess target=$03 b2=$00\n    act $01 Attack id=$01 target=$03 arg=$00\n"
           "reaction\nend\n",
           "main\n  block\n    test $00 Always b1=$00 b2=$00 b3=$00\n    act $03 Nop03\nreaction\nend\n",
           "main\n  block\n    test $01 Chance target=$03 b2=$00 b3=$00\n    act $00 AnimTarget b1=$00 target=$03 "
           "anim=$00\nreaction\nend\n",
           "reaction\nmain\nend\n"]
    return {"schema": "ct-enemy-ai-vectors/1",
            "note": "synthetic scripts (no ROM data); text by re_workspace/tools/ct_enemies.py",
            "actLengths": SYNTHETIC_LENGTHS, "cases": cases, "rejected": bad}


def vectors_text():
    return json.dumps(synthetic_cases(), indent=1) + "\n"


VECTORS = WS.parent / "macos_studio" / "Tests" / "ChronoForgeCoreTests" / "Resources" / "enemies" / "ai_vectors.json"


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
    a = sub.add_parser("ai")
    a.add_argument("id", type=int, choices=range(ENEMIES))
    a.add_argument("--rom", default=str(ROM_PATH))
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(ROM_PATH))
    k.add_argument("--run", action="store_true", help="also run the ROM's loader and reward routine")
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
            raise SystemExit("vectors differ from ct_enemies.py; regenerate with --out")
        print(f"{len(synthetic_cases()['cases'])} synthetic AI scripts")
        return
    rom = read_rom(args.rom)
    if args.command == "decode":
        print(json.dumps(decode_all(rom), indent=1))
    elif args.command == "ai":
        script = decode_script(rom, args.id)
        print(script.get("text") or f"; not a script: {script['error']}", end="\n" if "error" in script else "")
    else:
        results = code_claims(rom) + data_claims(rom)
        results += region_claims(rom)
        if REF.exists():
            results += table_claims(rom) + asm_claims()
        if args.run:
            results += run_claims(rom)
        for name, ok, detail in results:
            print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f"  [{detail}]" if detail and not ok else ""))
        failed = [r for r in results if not r[1]]
        print(f"{len(results) - len(failed)} of {len(results)} enemy claims hold")
        if failed:
            sys.exit(1)


if __name__ == "__main__":
    main()
