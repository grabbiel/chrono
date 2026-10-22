# Techs (Character & Party Architect, slice 2)

The tech system covers the single, double and triple techs, their parts and
targets, the combination table, the tech points and the new-game tech state.
Each part is decoded with evidence, imported into a project, edited in
**Characters → Tech & Synergy Matrix**, and written back by `chronoforge rom build`.

The Python reference, which also runs every claim's check, is
`re_workspace/tools/ct_techs.py`. The Swift twins are:
- `CTTechs.swift`: `TechSystemDef`, the codec `CTTechROM`, and the rule `CTTechPoints`;
- `CTTechTargets.swift`: target modes and area geometry.

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
with no area. Byte 2 holds the size (bits 6–0) and the line variant (bit 7).

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
- a tech-point simulator: three slots, unlock bits and a list of awards.

The header shows the range check and a **Write techs to ROM** toggle
(`rom.techs`). **Build ROM…** writes the build.

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

Every other byte, including names, user sets, records, areas, modifiers and
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
  attributes, the animation's other bytes, the combination records' members,
  first id and count, user sets or areas.

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
  - the checker rejects 9 damaged copies;
  - the CLI refuses 6 out-of-range or read-only edits.

  The checker decodes the built tables independently. It compares them with
  the report and checks ranges, unchanged read-only bytes, the combination
  records and the new-game state, and +$02.

## Limitations

- There is no emulator run. The evidence is the ROM's code, its data and its
  own routine executed, not a booted game.
- Tech names, user sets, combination records, areas and modifier records are
  read-only. New techs, new combinations and renames are not supported.
- The effect bytes are edited raw. Only type, stat pair and power are decoded;
  the per-type meaning of the rest is partial.
- The line area's strip and box are inferred geometry. The Studio's preview uses
  sample positions.
- The Studio pane is compiled, not UI-tested. Its logic (the codec, the checks,
  the rule and the zones) is in Core and tested there.
