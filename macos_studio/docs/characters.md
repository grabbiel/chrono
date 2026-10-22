# Playable characters (Character & Party Architect, slice 1)

The seven playable characters' records, their growth and the game's level-up
rule: decoded with evidence, imported into a project, edited in **Characters**,
and written back by `chronoforge rom build`. The Python reference and every
claim's check is `re_workspace/tools/ct_characters.py`; the Swift twin is
`CTCharacters.swift` (`CTCharacterROM`, `CTLevelCurve`).

No ROM data is stored in the repository: the import reads it from your ROM
into your project.

## The data

| Table | Address | Size | Use |
|---|---|---|---|
| Character records | `$CC:0000` | 7 × `$50` | Ids 0–6, copied (with an eighth record) to `$7E:2600` for a new game by `Menu_InitNewGameData` (`$C2:956E`); a battle's `PcStatBlk` (`$7E:5E2D` + slot × `$80`) uses the same offsets. |
| HP growth | `$CC:258A` | 7 × 8 | Per id, 4 (top level, gain) pairs. |
| MP growth | `$CC:25C2` | 7 × 8 | The same, for MP. |
| Stat growth | `$CC:25FA` | 8 × 7 | Per id, the growth per level of each stat, in the growth order. |
| Exp to level | `$CC:2632` | 100 words | Entry L is the experience from level L to L + 1. Entry 99 is 0. |

Ids follow CT's standard order: crono, marle, lucca, robo, frog, ayla, magus.
ChronoRET names ids 3–6 ("inferred"). The code agrees:
- Ids 1 and 2 attack with hit (`Menu_AttackFormulaB`: a bow and a gun).
- Id 5 attacks with power alone, and `BankFF_LoadSlotPart` skips its weapon (fists).
- Id 6 starts at a late level.
- The starting weapons' names, decoded by the import, agree.

### Record fields

Offsets below are from the record start. "verified" means the claim holds three
ways:
- the ROM's code bytes (operands and constants of the routines that use the field);
- ChronoRET's matched source (the routine's lines, in order);
- the ROM's data (the 7 records are consistent with the tables).

The level-up fields also pass a fourth check: the ROM's own routine is executed.

| Offset | Size | Field | Status | Main evidence |
|---|---|---|---|---|
| +$00 | 1 | char id | verified | Indexes the growth rows (`BattleSys_GrowHpMp`, `BattleSys_LevelUpStep`), `BankFF_CharBits` (`Menu_CanEquip`) and the attack formula. Record n holds n. Never written. |
| +$01 | 2 | — | undecoded | Never written. |
| +$03 | 2 | HP | verified | Current HP (`BattlerStats.CurHp`). Equals max HP in the ROM. |
| +$05 | 2 | max HP | verified | `GrowHpMp` adds the gain, cap 999. |
| +$07 | 2 | MP | verified | Current MP. |
| +$09 | 2 | max MP | verified | `GrowHpMp`, cap 99. |
| +$0B | 1 | power | verified | Stat 0. `Menu_AttackFormulaA` 12 × stat 0; formula C 16 × stat 0. |
| +$0C | 1 | stamina | verified | Stat 1. Defence = stat 1 + helmet and armour. |
| +$0D | 1 | speed | verified | Stat 2. Menu cap 16 (`MenuRom_StatCaps`); a level-up does not recompute it (caps it at 50). |
| +$0E | 1 | magic | verified | Stat 3. Magic damage uses the derived stat 3 and the level. |
| +$0F | 1 | hit | verified | Stat 4. Formula B 2 × (stat 4 + weapon) / 3; the hit roll's caster byte. |
| +$10 | 1 | evade | verified | Stat 5. The hit roll's target byte; accessory `$A8` doubles it. |
| +$11 | 1 | magic defense | verified | Stat 6. `BattleSys_AdjustDefence` effect byte 6 = `$3C`. |
| +$12 | 1 | level | verified | `ApplyExpStep` increments it, cap 99. |
| +$13 | 3 | exp | verified | `AddExp`, 24-bit. Equals the sum of ExpToLevel[1 … level − 1]. |
| +$16 | 3 | tech points | partial | `BattlerStats.TechPtTotal` ("probably"). |
| +$19 | 14 | — | undecoded | Status and target bytes; zero in the ROM. Never written. |
| +$27 | 1 | helmet | verified | Item category 2. |
| +$28 | 1 | armor | verified | Item category 1. |
| +$29 | 1 | weapon | verified | Item category 0. |
| +$2A | 1 | accessory | verified | Item category 3. |
| +$2B | 2 | exp to next | verified | `ApplyExpStep` counts it down and reloads ExpToLevel[level] (0 at 99). |
| +$2D | 2 | tech points to next | partial | `BattlerStats.TechPtNeed` ("probably"). |
| +$2F | 7 | growth base | verified | Growth order. `LevelUpStep` and `Menu_ApplyStatItem` (the stat items) pair it with the same stats. ChronoRET's menu name `.StatCounts` is this block. |
| +$36 | 26 | derived | partial | The menu's copy of the stats with equipment, attack, defence and max HP. `$FF` in the ROM. Never written. |

The full evidence for each field is the `FIELDS` table and the `code_claims`,
`data_claims` and `ASM_CLAIMS` checks in `ct_characters.py`.

**The growth order.** Growth byte k (of a StatGrowth row and of the growth base)
belongs to these stats, in order:

| k | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|
| Stat | power | stamina | speed | hit | evade | magic | magic defense |

So k → stat is 0 → 0, 1 → 1, 2 → 2, 3 → 4, 4 → 5, 5 → 3, 6 → 6.

**Equipment.** A slot holds an item of its category (`Menu_ItemCategoryBounds`).
The character can equip it when the item's mask has bit `$80 >> id`:
`Menu_CanEquip` ANDs `Menu_ItemEquipChars[item]` (record A, byte 3) with
`BankFF_CharBits[id]`. Every weapon names exactly one character.

## The level-up rule

A won battle runs `BattleSys_AwardExpAndTp`:
- `BattleSys_AddExp` adds the experience;
- `BattleSys_LevelUpStep` repeats until the amount is used up (a KO'd PC is skipped).

One level, when the amount covers exp to next:
1. **Experience** (`AddExp`, `$C1:F908`): exp += amount, 24-bit. Then, if the
   top byte is `$98` or more, it becomes `$98`. If the low word is then `$9680`
   or more, it becomes `$967F` (9,999,999).
2. **Level** (`ApplyExpStep`, `$C1:F7B9`): level + 1. Exp to next becomes
   ExpToLevel[new level], or 0 at 99.
3. **HP and MP** (`GrowHpMp`, `$C1:F871`): max HP += the gain of the first HP pair
   whose top level is at least the new level (cap 999). The same for max MP (cap 99).
4. **Stats** (`LevelUpStep`, `$C1:F623`): for each growth byte k except speed,
   stat = growth base[k] + growth[k] × (new level − 1) / 100, as an 8-bit sum.
   Then every stat is capped at 99, and speed at 50.

Quirks, as coded:
- The experience cap compares only the low word after a carry. So a large
  amount at the cap can leave 9,999,998.
- The 8-bit stat sum wraps before the cap: base 99 with growth 255 at level 71
  gives 21.
- A growth row with no pair reaching the new level makes the game read past the
  row's 8 bytes. The builder refuses such rows: each must reach level 99.
- Speed is never grown by levels, only capped at 50.
- Several starting records hold stats off their curve (`offCurve`; ids 1, 2, 3
  and 6), and id 6 holds a later level's exp-to-next entry. The first level-up
  recomputes the stats. The import keeps the records as they are.

`ct_characters.py check --run` executes `AddExp` then `LevelUpStep` from the ROM
in ChronoRET's 65816 interpreter (`refs/ChronoRET/tools/absint.py`), and compares
the result with the rule:
- the 7 records, each from its own level to 99;
- 24 synthetic cases with their growth rows and experience table patched into
  a copy of the ROM. These cover the wrap, the speed cap, the experience cap and
  levels 1, 2, 98 and 99.

## In a project

- `characters/<id>.json` gains `pc` (the record's decoded fields) and `growth`
  (the HP/MP steps and the stat growth). Older files without them load unchanged
  (see [project schema](ctproj_schema.md)).
- `party.json` (`ct-party/1`) holds the experience table and the equipment
  catalog (id, name, slot, mask) the editor offers.
- `project.json` `rom.characters` lists the characters `rom build` writes.

```
chronoforge characters import <rom.sfc> --project <project.ctproj>
chronoforge characters show <project.ctproj | rom.sfc>
chronoforge characters curve <project.ctproj | rom.sfc> <character> [--json]
```

`import` updates the character whose `pc.charId` matches (else the file named
after the character, else a new one). It sets the legacy `level`, writes
`party.json`, and lists all seven in `rom.characters`. `curve --json` prints
`{"columns", "rows"}` exactly as `ct_characters.py curve` does.

**Studio → Characters.** **Import Characters from ROM…** fills the project. For a
character with a record, the editor shows:
- level (changing it sets the experience to the start of that level) and the
  experience fields;
- HP and MP;
- each stat with its growth base and growth per level, with off-curve stats
  marked;
- the HP and MP growth steps;
- equipment pickers limited to the slot and to items the character can equip;
- tech points.

The editor also shows a range check, the level curve to 99 (chart and table),
and a **Write to ROM** toggle (`rom.characters`). **Build ROM…** writes the build.

## Building

For each character in `rom.characters`, the builder writes:
- each decoded writable field over the base ROM's record `pc.charId`;
- the character's three growth rows.

The other bytes of the record (+$00–$02, +$19–$26, +$36–$4F) stay the base
ROM's, so importing and building an unmodified ROM gives the clean ROM byte for
byte, with no write. ExpToLevel is not written.

The builder refuses:
- an unknown or duplicate character, or a duplicate record;
- level outside 1–99, or exp above 9,999,999;
- HP above max HP, or max HP above 999;
- MP above max MP, or max MP above 99;
- a stat or growth base above 99;
- tech points that do not fit their field;
- an item of the wrong category, or one the character cannot equip in the base ROM;
- an HP or MP row that does not reach 99;
- growth values above 255.

The report lists each character's record address and values. Each changed field
is its own write, for example `character robo power`.

## Verification

- `re_workspace/tests/test_characters.py` has two kinds of test:
  - ROM-free: the field table, the codec, the rule's edge cases, and the vectors file.
  - Local: every code, data and source claim; the ROM routine against the rule;
    and a rule without the 8-bit sum disagreeing with the ROM.
- `CTCharactersTests` has two kinds of test:
  - ROM-free: the Swift curve equals the Python vectors; the codec; old files
    load; checks on a synthetic ROM.
  - Local: import then build is identical; an edit changes only its bytes and
    the checksum; refusals.
- `macos_studio/tools/verify_character_build.py` is in `verify_all.sh`. Starting
  from a CLI import:
  - it must equal the Python decode;
  - 14 CLI curves (from the project and from the ROM) must equal the Python rule;
  - the unmodified build must be the clean ROM;
  - an edited build must pass `re_workspace/tools/ct_rom_check.py`.

  The checker decodes each record independently, compares it with the report,
  and checks ranges, equipment against the clean ROM, unchanged undecoded bytes,
  unchanged unreported records and rows, and an unchanged ExpToLevel. It rejects
  five damaged copies, one of which claims equipment the character cannot use.

## Limitations

- No emulator run. The evidence is the ROM's code, data and its own routine
  executed, not a booted game.
- +$01–02, +$19–26 and +$41–4F are not decoded. Tech points and the derived
  block are partial.
- ExpToLevel is shown and used, but not written. Item stats and names are not edited.
- The Studio pane is compiled; its logic is in Core and tested there.
- `chronoforge validate` does not yet check `rom.characters`.
