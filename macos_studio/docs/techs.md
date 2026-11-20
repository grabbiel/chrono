# Techs (Character & Party Architect, slices 2 and 5)

The tech system covers the single, double and triple techs, their parts and
targets, the combination table, the tech points and the new-game tech state.
Each part is decoded with evidence, imported into a project, edited in
**Characters → Tech & Synergy Matrix**, and written back by `chronoforge rom build`.

The Python reference, which also runs every claim's check, is
`re_workspace/tools/ct_techs.py`. The Swift twins are:
- `CTTechs.swift`: `TechSystemDef`, the codec `CTTechROM`, and the rule `CTTechPoints`;
- `CTTechTargets.swift`: target modes and area geometry;
- `CTTechCombos.swift`: combinations as the battle and field menus see them,
  the capacity, repurposing a record (slice 5);
- `CTTechText.swift`: names and descriptions (slice 5).

Slice 5's Python reference is `re_workspace/tools/ct_tech_combos.py`.

No ROM data is stored in the repository. The import reads your ROM into your
project's `tech_system.json`, and the tests use synthetic tables.

## Tech ids

| Ids | Kind | Notes |
|---|---|---|
| 0 | none | |
| $01–$38 | single | 8 per character; character c's first is 1 + 8c (`CharTechs`, and `$FD:A89D`, agree) |
| $39–$65 | double | Each of the 15 pair records in `ComboTechs` holds 3 |
| $66–$74 | triple | Each of the 10 trio records in `ComboTechs` holds 1; $70–$74 are in no record |

`TechRec` has 7 more records past $74 ($75–$7B, attack records whose parts are
numbers $39–$3B). The import and the builder cover ids 0–$74.

## The tables

All of them are in bank `$CC` except `PcTechAct`.

| Table | Address | Size | Use |
|---|---|---|---|
| TechNames | `$CC:15C4` | 11 B per id | An optional icon byte, then glyphs; `$EF` pads. Read-only. |
| TechInfo | `$CC:1ACB` | 2 B per id | Byte 0: the menu target mode (bits 6–0) and the field-menu bit (bit 7). Byte 1: the area number. |
| TechRec | `$CC:1BEB` | 11 B per id | User set and unlock bit, flags, element, 3 parts, 3 modifiers. |
| Effects | `$CC:213F` | 12 B per part (72) | What one part does. |
| UserSets | `$CC:249F` | 3 B per set (52) | The character ids that perform a tech; `$FF` means none. Read-only. |
| MpCost | `$CC:253B` | 1 B per part | |
| TechTpCost | `$CC:26FA` | 8 words per character | The tech points from single k to single k + 1. |
| CharTechs | `$CC:276A` | 2 B per character | First single id, and how many. Read-only. |
| ComboTechs | `$CC:2778` | 5 B per record, `$FF`-ended | Members' bits (`$80 >> id`), first id, count, and the bank-`$CC` address of 3 requirement bytes per tech. |
| Modifiers | `$CC:2A05` | 3 B per record (57) | Read-only. |
| AreaRecPtr | `$CC:2AB0` | 1 word per area (1–$0B) | Each record is a count byte, then 3-byte entries: shape, parameter set, size. Read-only. |
| PcTechAct | `$CD:45A6` | 7 B per id | The animation: script, graphics, frames, palette, object, argument. |
| Tech state | `$CC:0230` | 44 B | The eighth `MenuRom_CharRecordInit` record, copied to `$7E:2830` for a new game. |

## Fields and evidence

A field marked "verified" passes the checks below. The claims are in
`ct_techs.py`: `code_claims`, `data_claims`, `ASM_CLAIMS` and `MANIFEST_TYPES`.
`ct_techs.py check` re-derives each one three ways:
- from the ROM's code bytes;
- from ChronoRET's matched source;
- from the ROM's data.

Fields that the tech-point rule reads have a fourth check: they are *executed*.
The ROM's own `BattleSys_AwardTechPoints` runs in ChronoRET's 65816
interpreter and is compared with the rule (see below).

| Field | Status | Evidence |
|---|---|---|
| TechInfo byte 0 bits 6–0, target mode | decoded | `BattleSys_UnkC1DD` ANDs `$7F`; it indexes `BattleTgt_ModeTable`, which has 33 handlers (see [Targets](#targets)). Every tech is ≤ $20. |
| TechInfo byte 0 bit 7, field menu | decoded | The menu's flag for techs usable outside battle. |
| TechInfo byte 1, area | decoded | The `AreaRecPtr` index in `UnkC1DD`; 0 means none. Every tech is ≤ $0B. |
| TechRec byte 0 bits 6–0, user set | verified | `LoadTechUsers` uses it as a `UserSets` index. A single's set is its owner alone. A combination tech's set holds exactly its record's members. |
| TechRec byte 0 bit 7, needs unlock | verified, executed | `TryNextTech` and `LearnComboTechs` test it against the character's bit `1 << id` of `$7F:01E0`. In the ROM, a character's first single that needs it costs 0 TP. |
| TechRec byte 1, flags | partial | Bits 6 and 5 go to `Battle_UnkB2CA`; bits 2–0 are a merge count. Read-only. |
| TechRec byte 2 | partial | ORed with the user slot. The same value in every tech. Read-only. |
| TechRec byte 3 bits 7–4, element | decoded | Lightning, shadow, water, fire, in that bit order. `HitModUnk6CScale` picks the target's resistance byte by the first bit set. The elemental singles' names agree, and at most one bit is set. |
| TechRec byte 3 bits 3–0 | partial | Not traced. Read-only. |
| TechRec byte 4 | undecoded | 0 in every tech; not read. Read-only. |
| TechRec bytes 5–7, parts | decoded | User k's part number (bit 7 = none). It indexes MpCost (`TechMpCost1-3`) and Effects (`RunTechParts`). |
| TechRec bytes 8–10, modifiers | partial | User k's modifier record, below 57. |
| Effects byte 0, type | decoded | `BattleSys_EffectTable` handler, below 45. |
| Effects bytes 3–4, 9 | decoded | The hit roll's caster and target stat offsets; the damage power. |
| Effects other bytes | partial or undecoded | Arguments, damage formula, defence byte, flags, immunity. The editor shows the 12 bytes by name, and each must be 0–255. |
| MpCost | decoded | `BattleSys_PayTechMp`. In the ROM every part a tech runs costs at most 99 MP. |
| TechTpCost | verified, executed | `SpendTechPoints` reads word id × 16 + count × 2. |
| CharTechs | verified, executed | The next single is first + count; at `count` singles, record +$02 bit 4 is set. |
| ComboTechs | verified, executed | Masks are matched against `BuildComboMasks`. `LearnComboTechs` counts the id up and compares each member's single count with the requirement bytes. The requirements follow the records in order: 1–8 per member, and `$FF` as a pair's third byte. |
| PcTechAct script, frames | decoded | `BattleAct_LoadTech`. The script indexes `PcTechScripts` (128 entries); frames are below 80. |
| PcTechAct other bytes | partial | Graphics, palette, object, argument. Read-only. |
| Tech state | verified, executed | 7 counts (`Battle_TechCount`), then 7 bytes of single bits (`TechBits1`, top bits = count), then 30 combination bytes. Bytes 0–14 are one per pair record, with 3 doubles from bit 7. Bytes 15–29 are one per triple, in bit 7; the last five are $70–$74, which have no record. `Menu_InitNewGameData` copies `$280` bytes from `$CC:0000`. |
| Record +$02 bit 4 | verified, executed | "All singles learned" (`Battle_Unk2FAllTechs`). `AwardTechPoints` skips such a PC, and `LearnSingleTech` sets the bit. The rest of +$02 is not decoded. |
| Record +$16, tech points | verified, executed | 24-bit total; the award is added and capped. |
| Record +$2D, to next tech | verified, executed | The remaining need. In every ROM record it equals the next single's TechTpCost. |

The manifest proposal (`ct_schemas.py techs-update`) carries these statuses
into `items_and_techs_schema.json`.

## The tech-point rule

After a won battle, `BattleSys_AwardTechPoints` (`$C1:F205`) runs once with the
battle's award (0–65535). The rule is `CTTechPoints.award`, a twin of
`ct_techs.award_tech_points`.

1. **Each PC slot** without +$02 bit 4 spends the award (`SpendTechPoints`):
   - `TryNextTech` finds the next single: first + count.
     - If that tech needs the unlock and the character's bit is clear, nothing
       is paid.
     - If the need (+$2D) is at most the amount, it is paid: need = amount − need.
     - Otherwise the need drops by the amount, and the loop ends.
   - Each paid need learns the single (`LearnSingleTech`): the next bit, count + 1,
     and +$02 bit 4 at `CharTechs` count. Then it loads the next cost T:
     - if T is at least the leftover L, the need becomes T − L;
     - otherwise the leftover is stored as the amount and the need becomes T.
   - The award is added to the 24-bit total (+$16) and capped (see the quirks).
2. **Combinations.** `BuildComboMasks` sorts the three slots' bits in ascending
   order and forms the three pairs and the trio. For each mask that has a
   `ComboTechs` record, each of the record's techs is learned when all hold:
   - it is not learned yet;
   - every member's single count is at least its requirement byte;
   - the tech does not need the unlock.

Quirks, as coded:
- **Double payment.** After a cost T ≥ L, the loop runs `TryNextTech` again with
  the same amount. So the award, or a leftover stored earlier, is paid a second
  time against the new need.
- **The cap.** The total becomes `$98:967F` (9,999,999) only when the low word
  is ≥ `$967F` and the high byte is ≥ `$98`. A total with a high byte past `$98`
  and a lower low word is not capped.
- **The eighth single.** After it, the next cost read is the word that follows
  the rows (`CharTechs[0]`), and `TryNextTech` pays once more. The editor and
  the builder leave that word alone.
- **The unlock.** A single that needs the unlock, and every single after it,
  waits until the character's bit is set: `TryNextTech` pays nothing towards it
  meanwhile, and the award still goes to the total.

**Executed.** `ct_techs.py check --run` (and `test_techs.py`) runs the ROM's
`AwardTechPoints`, with `SpendTechPoints`, `TryNextTech`, `LearnSingleTech`,
`BuildComboMasks` and `LearnComboTechs`, in ChronoRET's 65816 interpreter.
`RomTechPoints` sets up the state, the slots' battle blocks, the unlock byte
and the award.
- From the ROM's starting state: 7 parties, each with and without every
  unlock bit, for 24 awards each.
- From 12 synthetic cases, with their TP rows, unlock bits and combination
  records patched into a copy of the ROM, for 10 awards each. These cover the
  double payment, the cap, a full character, locked singles and empty slots.

Each run must equal the rule state for state. A rule that pays the leftover
only once disagrees with the ROM. The Swift twin equals the Python vectors
(`Tests/.../techs/tp_vectors.json`).

## Targets

`CTTechTargets` names the 33 target modes (`BattleTgt_ModeTable`) and the area
shapes and parameter sets, and reproduces the area routines' tests on screen
positions:

| Area shape (entry byte 0) | Routine | Test |
|---|---|---|
| 0, 4 | `BattleTgt_AreaLine` | A strip of half-width size × 8 px from the source towards the aimed battler. With the variant bit, a box that ends at the aimed battler. The geometry is inferred from the corner wedges. |
| 1, 2 | `BattleTgt_AreaCircle` | dx² + dy² ≤ size in 16-pixel cells, with the 8-bit sum wrapping, as coded. |
| 3, 5 | `BattleTgt_AreaPartyTriangle` | Enemies inside the triangle formed by PC slots 0–2. |
| 6 | `BattleTgt_AreaRow` | y within ±`$20` of the centre's, inclusive and clamped. |

Entry byte 1, bits 6–0, picks the centre and the aim (`BattleSys_AreaParamTable`):
user 1 or 2, the target, or the caster. Bit 7 makes the entry a position query
with no area. Byte 2 holds the size (bits 6–0) and the line variant (bit 7);
only sets 0 and 6 pass the variant on (`BattleSys_UnkC1DD`).

The scanned side is user 0's slot for set 3. For the other sets it is DP `$0A`,
which the target-mode handler sets for the caster and mode. `CTTechTargets`
approximates it by the target's side.

The menu's area modes all scan the enemy side:
- the lines `$0B`–`$0D` use size 2;
- `$0F` is the row;
- the radii `$11`–`$14`, `$1A` and `$1B` use sizes `$09`, `$10` or `$19`;
- `$18` is the party triangle.

The Studio draws these over a sample battle layout. The positions are
illustrative; the game's come from the battle.

## In a project

- `tech_system.json` (`ct-techs/1`, `TechSystemDef`) holds the techs, parts,
  `tpCost`, combination records, the new-game `learned` state, `userSets` and
  `areas`. Fields marked read-only are decoded for the editor and must keep the
  base ROM's values.
- `project.json` `rom.techs: true` makes `rom build` write the tables. The flag
  is absent when false, so older projects load and save unchanged.

```
chronoforge characters techs import <rom.sfc> --project <project.ctproj>
chronoforge characters techs show <project.ctproj | rom.sfc> [<character>] [--json]
chronoforge characters techs tp <project.ctproj | rom.sfc> --party <c,c,c> --award <n[,n…]> [--unlock <mask>] [--json]
```

- `import` writes `tech_system.json` and sets `rom.techs`.
- `show` lists a character's singles (MP, TP, target, area, element, unlock)
  and the combinations it takes part in, with their requirements.
- `tp` runs the rule from the new-game state and the characters' records.
  - Use `-` for an empty slot.
  - `--unlock` is the `$7F:01E0` mask.
  - `--json` prints `{"awards", "states"}`.
  - A project needs the characters imported.

**Studio → Characters → Tech & Synergy Matrix.** **Import Techs from ROM…**
fills the project. The matrix shows:
- each character's 8 singles, with MP, TP to learn (editable), target, area,
  element and unlock, plus the number learned at a new game;
- a 7 × 7 matrix of the dual-tech records (techs per pair and how many are
  learned), and the triple techs. Each record's requirements (1–8 per member)
  and new-game bits can be edited;
- one tech at a time: target mode, field menu, area, element, unlock, parts and
  modifiers, animation script and frames, and each part's MP and 12 effect bytes;
- a target-zone preview: the menu mode's zone (dashed) and the area record's
  zone (filled) over a sample layout, with what they take in;
- a tech-point simulator: three slots, unlock bits and a list of awards;
- **Help line**: the selected tech's description as the menu draws it
  (`Menu_TechDescText`, BG3 rows 21-22) through the PPU, with a fits /
  overflows indicator and the project's character names. Tech descriptions are
  not part of the project, so the draft field there is a preview only.
  See [dialogue box](dialogue.md#the-menus-help-line).

The header shows the range check and a **Write techs to ROM** toggle
(`rom.techs`). **Build ROM…** writes the build.

## Combinations end to end (slice 5)

A dual or triple tech is reached by four routines, each run in ChronoRET's
interpreter over every combination record of the ROM by
`ct_tech_combos.py check --run` (the counts are the runs it makes):

| Path | Routines | Runs |
|---|---|---|
| Battle menu | `BattleSys_UnkCA1A` (doubles $39–$65: 3 ids per state byte, at most 6 entries, partner `$F0` &#124; the other slot), `BattleSys_UnkCCCB` (triples $66–$74 from entry 18), `StoreMpCost` (the `$A2`/`$A3` accessory cuts) | 900 |
| Learning | `AwardTechPoints` → `BuildComboMasks` → `LearnComboTechs` | 175 |
| Field menu | the pair and trio lists, drawn from the menu's own copies | 780 |
| Rocks | `Menu_Unk834D` → `BankFF_UnkF958` (the `$04A4` flags) → `Menu_Unk82E1` | 40 |

Each run compares the routine's output with the model in `ct_tech_combos.py`
(`model_battle_entries`, `model_field`, the tech-point rule). Mutation runs
(a damaged table, a damaged model) fail, so the runs are not vacuous. 33 data
claims and the code and ChronoRET-source claims hold.

**The field menu keeps its own copies.** The battle reads ComboTechs; the field
menu reads separate tables in bank `$CC`:
- `MenuRom_TechByteMembers` ($CC:2963): the member mask of each state byte.
  Bytes 7–21 are the pair records. The routine reads 37 bytes; bytes 22–36
  overlap `MenuRom_TechLineBits` ($CC:2979, the trio records' masks) and then
  `MenuRom_ComboMembers`.
- `MenuRom_TechMenuTiles` ($CC:28DB): 6 bytes per pair record, the MpCost
  index of each member for its 3 techs.
- `MenuRom_TechLineTiles` ($CC:2935): 3 bytes per trio record.
- `MenuRom_TechMenuRec` ($CC:24B3) is not a table of its own: it is the user
  sets from set 6 on. Pair record i's two cost columns are user set 7 + i's
  first two ids, in that set's order.

In the ROM, the field menu's MP equals the battle's MP for 117 of the 120
members. It differs on techs $5E, $67 and $6A, where the menu's index is not
the battle part. The project keeps the menu's indexes (`menuCosts`) as they are,
and the Studio marks the members that differ.

**Learning.** `LearnComboTechs` never tests the `$7F:01E0` unlock for a
combination: a combination whose TechRec has bit 7 set is never learned.
The Validator warns about it.

**Rocks.** The five triples $70–$74 come from the rocks. `MenuRom_ComboNeeds`
($CC:2953) holds 3 singles per rock and `MenuRom_ComboMembers` ($CC:2983) the
members. At every menu exit, `Menu_Unk82E1` zeroes the 5 state bytes ($2857)
and sets `$80` when a member wears accessory `$AE + r`. They are read-only
(`rocks` in the project).

### Capacity: no new combination

The tech state holds 30 combination bytes. The first 15 are the pair records:
`BattleSys_UnkCA1A` and `Menu_TechFirstIds` fix 3 ids per byte, so they cover
the 45 doubles $39–$65, all used. The other 15 are one triple each, $66–$74.
Records 0–24 use 25 bytes. Bytes 25–29 ($70–$74) are the rocks, which
`Menu_Unk82E1` rewrites, so a 26th record has no byte to keep it learned. There
is no free id either: $75 is past the last.

So the builder refuses a 26th record, or a record past the rocks, naming this
limit. A combination is made by **repurposing** an existing record instead:
`CTTechCombos.repurpose` sets its members and moves the user sets with them.
A pair stays a pair, and a trio stays a trio.

### Editing a combination

Writable now:
- each record's members, which are written to ComboTechs, the field menu's
  member byte, the TechRec member bytes and the record's user set (the
  "combination $XX members", "menu members" and "user set N" writes);
- each member's battle part (TechRec, through the parts editor) and MP (the
  part's MpCost);
- the field menu's MP index ("menu MP");
- the requirements (needed singles) as before.

`CTTechCombos.check` refuses:
- more than 25 records;
- a mask with a bit past character 6;
- a pair in a trio's place, or the reverse;
- two records with the same members;
- a first id or count that differs from the base;
- changed members without their user set;
- a user set shared by two records;
- user set 0;
- any change to the rocks.

### Names

`TechNames` ($CC:15C4) has 11 bytes per id. Magic names start with the icon
`$2F`; the rest are glyphs, `$FF` blank and `$EF` padding.
`Menu_TechDrawName` draws all 11 tiles and `TextWin_ExtTechName` stops at
`$EF`. So a name is at most 11 glyphs, or 10 after the icon, and contains no
`$EF`. A changed name is written in place ("tech $XX name") with its icon kept.
A name that does not fit, or has a character with no glyph, is refused with its
length and room. The Studio shows "used/room tiles fits" or "overflows" as you
type.

### Descriptions

`MenuRom_TechTextTable` ($CC:3A09) holds 121 bank-`$CC` pointers: tech ids
0–$74, then the menu's page titles. Both `BattleCD_ShowTechInfo` and
`Menu_TechTextSetup` read it. The strings are at $CC:3B0D–$CC:43AE, in the
dialogue codec.

The import decodes each tech's description (`description`). When one changes,
the builder repacks the whole table in its own span:
- unchanged strings keep their bytes;
- identical strings share one copy;
- the rest of the span is zero-filled;
- the 18 bytes between the table and the strings ($CC:3AFB) are untouched.

These are the "tech descriptions" and "tech descriptions text" writes. A table
that no longer fits is refused with its size. The Studio's help line edits the
description and shows it live through `Menu_TechDescText`'s rows, with fits or
overflows. Revert brings back the ROM's text.

## Building

With `rom.techs`, the builder writes each writable field in place over the base
ROM's tables:
- TechInfo;
- TechRec bytes 0 (bit 7 only), 3 (bits 7–4 only) and 5–10;
- PcTechAct's script and frames;
- MpCost and the effect records;
- TechTpCost's 56 words;
- each combination's requirement bytes;
- the 44-byte new-game state;
- each record's +$02 bit 4, set when the new-game count is 8.

Slice 5 adds the names, the description table, and each combination's members
with its field-menu copies and user set ([above](#combinations-end-to-end-slice-5)).
Every other byte, including the other user sets, the rocks, areas, modifiers and
the word after TechTpCost, stays the base ROM's. So importing and building an
unmodified ROM gives the clean ROM byte for byte, with no write. Each changed
span is its own report write, for example `tech $02 target`, `part 1 MP`,
`TechTpCost`, `combination $39 requirements`, `new-game tech state` or
`record 4 all-singles bit`.

The builder (and `CTTechROM.check`) refuses:
- a schema other than `ct-techs/1`, or techs 0–$74 or parts 0–71 that are
  missing or out of order;
- a target mode above $20;
- an area that is not 0 and not an area with entries;
- an unknown element;
- a part number 72 or above (bit 7 aside), or a modifier 57 or above;
- an animation script 128 or above, or frames 80 or above;
- a part's MP outside 0–99 (255 is allowed on unused parts), an effect type
  45 or above, or an effect byte outside 0–255;
- tech points outside 0–65535;
- a requirement outside 1–8 for a member, or anything but `$FF` for a pair's
  third byte;
- a new-game count outside 0–8, single bits that are not the count's top bits,
  or a combination bit past its record's techs;
- any read-only field that differs from the base ROM's: kind, user set, flags,
  attributes, the animation's other bytes, the combination records' first id
  and count, the user sets of singles, the rocks or areas;
- a combination edit that `CTTechCombos.check` refuses, a name that does not
  fit, or a description that does not compile or fit.

`chronoforge validate` (gate 4) runs the same range check. It reports
`rom.techs` without `tech_system.json` as an error, and warns when a
character's +$2D is not its next single's cost.

## Verification

- `re_workspace/tests/test_techs.py` has two kinds of test:
  - ROM-free: the rule's edge cases (double payment, cap, unlock, a full
    character, the eighth single, the combination masks), the codec's writable
    bytes, the vectors file, the manifest proposal on a hand-written manifest,
    and the checker's write zones.
  - Local: every code, data and source claim; the ROM's routine against the
    rule (the ROM's state and the patched synthetic cases); a rule without the
    double payment caught by the ROM; and the manifest proposal on the real
    manifest.
- `CTTechsTests` has two kinds of test:
  - ROM-free: the Swift rule equals the vectors; the rule's quirks; the codec on
    a synthetic ROM; refusals; old projects; the Validator; target zones.
  - Local: import then build is identical; an edit changes only its bytes;
    builder refusals.
- `macos_studio/tools/verify_tech_build.py` is in `verify_all.sh`, alongside
  `ct_techs.py check --run`. It checks that:
  - the CLI import equals the Python decode;
  - 8 CLI tech-point runs, from the project and from the ROM, equal the Python
    rule;
  - the unmodified build is the clean ROM;
  - an edited build (11 writes) passes `re_workspace/tools/ct_rom_check.py`;
  - the ROM's own `AwardTechPoints`, run on the built ROM, learns as the rule
    does on the edited tables;
  - the checker rejects 10 damaged copies;
  - the CLI refuses 6 out-of-range or read-only edits.

  The checker decodes the built tables independently. It compares them with
  the report and checks ranges, unchanged read-only bytes, the combination
  records and the new-game state, and +$02.

- `re_workspace/tests/test_tech_combos.py` (slice 5): ROM-free, the helpers
  and the id layout; local, every claim and the four interpreter run sets.
- `CTTechCombosTests` (slice 5): ROM-free, the menu copies' round trip,
  repurposing (exactly 6 bytes change), refusals, names; local, the unchanged
  build, and a repurposed, renamed and described build whose help line is
  drawn from the built ROM.
- `verify_tech_build.py` also repurposes record 14, edits a menu MP index,
  renames tech 1 and describes tech 2. It expects 10 writes, runs the battle
  menu, learn and field-menu routines on the built ROM, has the checker reject
  7 more damaged copies (members, menu copies, names, the description table)
  and the CLI refuse 5 more edits.
- `ct_rom_check.py` decodes the combinations, names and descriptions of the
  built ROM independently (`ct_tech_combos.build_problems`) and adds their
  write zones.

## Limitations

- There is no emulator run. The evidence is the ROM's code, its data and its
  own routine executed, not a booted game.
- Areas and modifier records are read-only. New techs and new combinations are
  not supported (see the capacity); a record is repurposed instead. The rocks
  are read-only.
- The effect bytes are edited raw. Only type, stat pair and power are decoded;
  the per-type meaning of the rest is partial.
- The line area's strip and box are inferred geometry. The Studio's preview uses
  sample positions.
- The preview's scanned side follows the target, an approximation of the
  side the target-mode handler sets. Its triangle is exact, where the routine
  compares 8-bit angles, so an enemy on an edge may differ.
- The Studio pane is checked at window level only: `--module Characters
  --tech 63` opens the matrix on a tech's editor. Its logic (the codec, the
  checks, the rule and the zones) is in Core and tested there.
