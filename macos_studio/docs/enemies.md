# Enemies (Character & Party Architect, slices 3 and 4)

Enemy stat records, rewards, names, attack and tech records, and AI scripts.
Each one is decoded with evidence, imported into a project as
`characters/<id>.json` with `kind: "enemy"`, and edited in **Characters →
Enemies**. `chronoforge rom build` writes the stats, rewards, names and edited
AI scripts back.

- The Python reference, with the check for every claim, is
  `re_workspace/tools/ct_enemies.py`.
- The Swift twin is `CTEnemies.swift` (`CTEnemyROM`), `CTEnemyAI.swift`
  (`CTEnemyAI`) and, for writing scripts, `CTEnemyAIPatch.swift`.

The repository stores no ROM data. The import reads the enemies from your ROM
into your project. The Swift tests use synthetic vectors
(`Tests/ChronoForgeCoreTests/Resources/enemies/ai_vectors.json`, written by
`ct_enemies.py vectors --out`).

## The data

Enemy ids run from 0 to 255. A battle's `!Battler_UnkAF0A` entries hold them,
and id `$FF` is `!Battle_EntryNone` (no enemy). The import covers ids 0–254.

| Table | Address | Size | Read by |
|---|---|---|---|
| Stats | `$CC:4700` | 256 × 23 | `BattleFD_UnkB438` (`$FD:B438`), which copies the record into the enemy's BattlerStats block |
| Rewards | `$CC:5E00` | 256 × 7 | `BattleFD_AddEnemyRewards` (`$FD:ABA2`); the steal code; `Battle_SetupBattle` |
| Names | `$CC:6500` | 251 × 11 | `TextWin_ExtEnemyName` (`$C2:5AD0`): ids 0–250, glyphs, `$EF` a blank and the padding |
| Enemy techs | `$CC:6FC9` | 256 × 11 | TechRec's layout (`BattleSys_UnkD7C4`) |
| Effects A | `$CC:7AC9` | 256 × 12 | the techs' effect records |
| Tech targets | `$CC:86C9` | 256 × 2 | target mode, area |
| Attacks | `$CC:88C9` | 23 × 11 | TechRec's layout (`BattleSys_UnkD8D1`) |
| Effects B | `$CC:89C6` | 12 each | the attacks' effect records |
| AI pointers | `$CC:8B08` | 256 × 2 | `BattleAi_RunMainPart`, `BattleAi_FindReactPart`: each script's bank-`$CC` address |

The tables meet end to end. `ct_enemies.py check` derives each size from the
next table's start.

### Stat record (23 bytes)

`BattleFD_UnkB438` computes the record address as id × 23 and copies it into
the enemy's BattlerStats block. The *Block* column gives the offset from
`.Unk2D`; a PC's `PcStatBlk` uses the same offsets.

| Offset | Field | Block | Status | Evidence |
|---|---|---|---|---|
| `+$00` | HP (u16) | `+$03`, `+$05` | verified | Stored as both CurHp and MaxHp. `BattleFD_RestoreEnemies` halves or quarters it. |
| `+$02` | level | `+$12` | verified | The caster's level in `BattleSys_CalcDamage`'s magic formula, as for a PC. |
| `+$03`–`+$07` | status bytes | `+$22`–`+$26` | partial | `.Unk4C+3..7`; bytes 6 and 7 are also copied to `+$20`/`+$21`. If `+$07` bit 7 is set, `BattleAi_PickScript` uses the fixed script `$CC:8D08`. Byte `+$04` bit 2 interacts with Status2 in the same routine. Not named. |
| `+$08` | stamina | `+$37` | partial | `BattleSys_ListHandler1` adds it to the reload of turn list 1. |
| `+$09` | speed | `+$38` | verified | `BattleFD_UnkB7EB` starts the turn gauge from it, capped at 16. |
| `+$0A` | magic | `+$39` | verified | `BattleSys_CalcDamage` kind 3 (× 12). Revive HP = magic × 5. |
| `+$0B` | hit | `+$3A` | verified | The caster byte of the hit roll (`BattleSys_EffRecStatPair`). |
| `+$0C` | evade | `+$3B` | verified | The target byte of the same roll. |
| `+$0D` | magic defense | `+$3C` | verified | `BattleSys_AdjustDefence` (byte 6 = `$3C`): × 5 / 2. |
| `+$0E` | attack | `+$3D` | partial | `BattleSys_CalcDamage` kind 4's caster stat; a PC's weapon attack. |
| `+$0F` | defense | `+$3E` | verified | `BattleSys_AdjustDefence` (byte 6 = `$3E`). |
| `+$10`–`+$13` | affinities | `+$3F`–`+$42` | decoded | Lightning, shadow, water, fire. See below. |
| `+$14` | immunity | `+$19` | partial | `BattleSys_EffRecArg10Unk46`: the status-hit immunity test against effect byte 10. |
| `+$15` | flags | `+$1A` | partial | Bits 0–1 go to `!Battle_UnkA020` (`BattleFD_UnkB121`); bit 1, inverted, to `!Battler_Unk9F29`. |
| `+$16` | attack id | `+$1B` | verified | `BattleAi_RunAttack` with id 1 makes it `!Battle_UnkB18C`, the Attacks record. In the ROM it is always below 23. |

**Affinities.** `BattleSys_HitModUnk6CScale` scales an elemental hit by
4 / divisor, using the byte for the hit's element:

- bit 7: absorb (the hit heals);
- bits 5–0: the divisor;
- bit 6: subtract 2 from the divisor.

`$04` is normal, which is a PC's value (`BattleFD_UnkB3FE`). The Studio and
`enemies show` print each byte as `x4/<divisor>`.

### Reward record (7 bytes)

| Offset | Field | Evidence |
|---|---|---|
| `+0` | exp (u16) | Added to `!Battle_UnkB28C`, the amount `BattleSys_AddExp` gives each PC. |
| `+2` | gold (u16) | Added to `!Battle_RewardGold`. |
| `+4` | drop | An item id (0 = none). It drops 90% of the time, or always when it equals the charm. It is also the steal's plain item. |
| `+5` | charm | An item id: the steal's better item. |
| `+6` | tech points | Added to the 24-bit `!Battle_UnkB2DB`, which `BattleSys_SpendTechPoints` pays out. |

### Evidence

`ct_enemies.py check` re-derives each claim three ways:

- from the ROM's code bytes: load sites, multipliers and the destinations in
  battle RAM;
- from ChronoRET's matched source (MIT): the routines named above;
- from the ROM's data: ranges, encode(decode) giving the same bytes, and the
  tables meeting end to end.

`check --run` also runs the ROM's own `BattleFD_UnkB438` and
`BattleFD_AddEnemyRewards` in ChronoRET's 65816 interpreter for all 256 ids.
It compares the resulting battle RAM with the decode: the block for each
enemy entry, and exp, gold, tech points and the certain drop from two
starting states. Result: 55 of 55 claims hold. Records with odd values are
allowed: 13 placeholder records have level 0 and 1 HP, and two enemies have
speed 17 (capped to 16).

## AI scripts

An AI script has two parts: a main part (`BattleAi_RunMainPart`, `$C1:AFD2`)
and a reaction part (`BattleAi_FindReactPart`, `$C1:B488`).

- Each part is a list of blocks, ended by `$FF`.
- A block is one or two 4-byte tests, then `$FE`, then action records, then
  `$FE`.
- An action record's length comes from `BattleFD_AiActLength` (`$FD:BA4A`),
  indexed by its code. Code 4 is the exception: it is the code byte alone
  (`BattleAi_ChooseByChance` steps one byte). Codes 3 and 5 cannot be stepped:
  the table holds 0 and `$FF` for them.
- The game finds the ends by scanning for `$FE` and `$FF`. The parser
  therefore refuses a test or action whose bytes contain either one.

The dispatch tables give each code's handler:

- `BattleAi_TestTable` (`$C1:B80D`): 41 tests;
- `BattleAi_ChooseTable` (`$C1:B85F`) and `BattleAi_RunTable` (`$C1:B88D`):
  23 actions;
- `BattleAi_TargetTable` (`$C1:B8BB`): 57 target modes.

Names come from what the handler is proven to read (ChronoRET's labels and
headers). A byte with no proven meaning is shown as `b1`, `b2` and so on. A
test shows the target mode it names as a comment.

```
main
  block
    test $17 Chance percent=$32 b2=$00 b3=$00
    act $01 Attack id=$01 target=$06 arg=$00  ; NearestPc
reaction
end
```

The text above is a synthetic example. `CTEnemyAI.assemble(text:)` and
`ct_enemies.py`'s `ai_assemble` turn the text back into bytes:

- `;` starts a comment;
- each name must match its code;
- arguments are `label=$hh` or bare `$hh`.

In the ROM, 255 of the 256 pointers lead to a script that parses. Enemy 127's
pointer does not lead to a script; the import keeps the parse error. Every
parsed script's bytes, and its text, assemble back to the same bytes (Python
`check`, Swift `testEveryROMScriptRoundTrips`). Some scripts overlap: two
enemies can share one.

Attack records and tech records are **shown, not written**. Scripts are
written back; see [Writing scripts back](#writing-scripts-back).

## Writing scripts back

### Where scripts live

`ct_enemies.py check` proves each fact below (`region_claims`):

- **The pointer.** Only `BattleAi_RunMainPart` and `BattleAi_FindReactPart`
  read the pointer table. Both do `REP #$20; ASL A; TAX; LDA.l $CC8B08,X`: a
  u16 per id at `$CC:8B08` + id × 2, for ids 0–255. Bank `$C1` holds the long
  operand `$CC8B08` exactly twice, and ChronoRET's source has no other reader.
- **The bank.** Every script byte the battle code reads (171 sites in
  ChronoRET's source) is `LDA.l !BattleRom_ScriptBank+k,X` with k from 0 to
  15 and a 16-bit X. A script is therefore addressed by its 16-bit offset in
  bank `$CC` and must lie inside `$CC:0000`–`$CC:FFFF`. The scans for `$FE` and
  `$FF` step X with `INX`; a script that ran off the bank's end would wrap to
  `$CC:0000`. There is no other bound on a script's length.
- **The region.** The two fixed scripts (`$CC:8D08`, `$CC:8D1E`) and the 255
  parsed scripts fill `$CC:8D08`–`$CC:CBC8` (16,065 bytes), except the 50
  bytes at enemy 127's pointer (`$CC:A3E0`), which do not parse as a script.
  `BattleRom_ScriptMsgStrings` starts at `$CC:CBC9`, so the region cannot grow
  in place.
- **Sharing.** No two pointers share a start. Two pairs of scripts overlap,
  where one script's tail is the next one's head: enemies 97 and 98 (13
  bytes), and 244 and 245 (25 bytes). Editing either script of a pair in
  place would change the other enemy.
- **Free space.** `Padding_CCFC4F` (`$CC:FC4F`–`$CC:FFFF`, 945 × `$FF`) is the
  only confirmed padding in bank `$CC`. It is a confirmed free region of
  `manifests/rom_layout.json` (`CTROMLayout`), and it ends exactly at the end
  of the bank.
- **The ends.** `BattleAi_FindReactPart` takes the first `$FF` after a
  script's start as the main part's end. A test record holding `$FF` would
  move the reaction part. No ROM script has one, and none has a target code
  past `BattleAi_TargetTable`.
- **The length table.** The ROM's `BattleFD_AiActLength` equals the table
  ChronoRET lists (`CTEnemyAIPatch.listedLengths`). The Validator and Studio
  use it to check a script without the ROM.

### How a script is written

`rom build` assembles `enemy.ai.text` for each listed enemy
(`CTEnemyAIPatch`):

- **Unchanged.** Bytes equal to the base ROM's script write nothing. An
  unedited import therefore rebuilds byte for byte, and enemy 127's unparsed
  pointer is kept.
- **In place.** When the script fits its old span and no other script
  overlaps that span, it is written at the same address. Bytes left over at
  the end of a shorter script are left as they were; nothing reads past the
  reaction part's `$FF`.
- **Moved.** A script that is shared, or that grows, goes into bank `$CC`'s
  padding, and its pointer is rewritten. The old bytes stay where they were,
  so an enemy that shared them (97 for 98) keeps its script byte for byte.
  The scripts are placed right after maps and tilesets, before any other
  write can take that padding.

Before writing, the builder refuses:

- text the parser does not accept: `$FE` or `$FF` inside a record, codes 3
  and 5 (the length table cannot step them), unknown test or action codes,
  a wrong number of bytes, a block without one or two tests;
- text without an `end` line;
- a test byte `$FF`;
- a target code past `BattleAi_TargetTable` (`$39` or more);
- moved scripts that do not fit the 945 bytes;
- a script for an enemy whose pointer is not a script in the base ROM (enemy
  127): its pointer is kept as it is;
- an enemy id outside 0–254, and the same enemy twice.

The import also records each script's `size`, `shared` (the enemies whose
scripts overlap it) and `sha256`. With these, the Validator and Studio know
which edits would move, and how much of the 945 bytes they take, without the
ROM.

### Evidence on the built ROM

`macos_studio/tools/verify_enemy_ai_build.py` checks the write-back three
ways:

1. **The builder.** An unedited import, with all 254 parseable scripts listed
   as text, builds the clean ROM with no writes. Three invented scripts are
   then built:
   - one in place (the first unshared enemy whose span is long enough);
   - enemy 98's script, moved off the bytes it shares with enemy 97;
   - one that grows past its span, which is moved too.

   Exactly their spans and the two moved pointers are written.
2. **The independent check.** `re_workspace/tools/ct_rom_check.py`
   (`check_enemy_scripts`) re-decodes each reported script with the Python
   twin and checks:
   - the text, size and hash are as reported;
   - the reaction part is where `FindReactPart`'s scan finds it;
   - a script in place stays in its own unshared span, and a moved one in the
     padding;
   - only reported pointers change, and every other script is unchanged;
   - nothing is written outside these spans.

   `chronoforge enemies verify` accepts the built ROM and rejects the clean ROM
   for the three edited scripts.
3. **The game's code.** `ct_enemies.RomAi` runs the ROM's own
   `BattleAi_RunMainPart` and `BattleAi_FindReactPart` on the built ROM in
   ChronoRET's 65816 interpreter. Battle RAM is zeroed, PCs 0–2 are present,
   and the enemy is entered as entry 0 and as entry 5. For each edited enemy
   the run checks that:
   - it reads only the new script and its pointer;
   - it reads the test of every block up to the chosen one;
   - it chooses what the script says (`expected_main`): the block whose test
     holds, its first action's code and address, and the target slot of a
     Self action;
   - `FindReactPart` finds the new reaction part.

   Enemy 97 (the sharer), enemies 244 and 245 (the other pair) and the edited
   enemies' neighbours behave identically on the built and clean ROMs: the
   same outcome, the same bytes read, the same RAM written. In all, 27 of 27
   runs match.

The checker rejects six damaged copies, and the CLI refuses eleven bad
scripts and writes nothing.

## Project

`characters/<id>.json` gains an optional `enemy` record:

```json
{
  "id": "enemy_005", "name": "…", "kind": "enemy", "level": 0,
  "enemy": {
    "enemyId": 5, "hp": 0, "level": 0, "status": [0, 0, 0, 0, 0],
    "stats": { "stamina": 0, "speed": 0, "magic": 0, "hit": 0, "evade": 0, "magicDefense": 0, "attack": 0, "defense": 0 },
    "affinity": { "lightning": 4, "shadow": 4, "water": 4, "fire": 4 },
    "immunity": 0, "flags15": 0, "attackId": 0,
    "reward": { "exp": 0, "gold": 0, "drop": 0, "charm": 0, "techPoints": 0 },
    "ai": { "address": "$CC:0000", "text": "main\n…", "size": 0, "shared": [], "sha256": "…" },
    "attack": { "id": 0, "flags": 0, "elementBits": 0, "part": 255, "effect": null }
  }
}
```

The values above are elided; the import fills them from your ROM.

- Files without `enemy` load and save unchanged.
- The import matches an existing file by `enemy.enemyId`, or else by the id
  `enemy_NNN`. It sets `kind`, `name` and `level`.
- An enemy without a ROM name gets the placeholder name `Enemy NNN`, which is
  never written.
- `project.json`'s `rom.enemies` lists the files `rom build` writes. The
  import lists all 255.
- `Encounter.enemies` ids resolve to these files. Validate warns when an
  encounter names a character whose kind is not `enemy`.

## CLI

```
chronoforge enemies import <rom.sfc> --project <p.ctproj>
chronoforge enemies show <p.ctproj | rom.sfc> [<enemy>] [--json]
chronoforge enemies verify <p.ctproj> <rom.sfc>
```

- `show` prints the stats, affinities, status bytes, rewards (with item
  names), the attack record and the AI script.
- `verify` checks that a ROM's stat records, rewards, names and AI scripts
  equal the project's enemies, for example after `rom build`.

## Studio

**Characters → Enemies** lists the enemies by id, with a filter. Each enemy has
editors for:

- level and HP;
- the eight stats;
- the four affinities, with how each reads;
- the status and flag bytes, and the attack id;
- rewards, with item pickers;
- the name.

The attack record is read-only. The AI script is an editable text listing:

- a parse or write error shows under it as you type, with its line number;
- the line under it says how many bytes the script is and where a build would
  put it: unchanged, in place, or moved (and why);
- a bar shows how much of bank `$CC`'s 945 bytes the moved scripts take.

**Tidy** rewrites the text with every record's names and labels, and **Apply**
saves it to the project. The script view lists the enemy techs the script
names. **Write to ROM** adds the enemy to `rom.enemies`. A range problem shows
under the header before a build. `--select enemy_NNN` selects an enemy at
launch.

The view shows the enemy's battle sprite at rest once **Sprites → Import Sprites
from ROM…** has imported it (`sprites/enemy_NNN.*`, read-only;
[Enemy sprites](sprites.md#enemy-sprites)); until then a placeholder stands in.

## Write-back

`rom build` writes each listed enemy's stat and reward records field by field,
in place, and the name when it differs from the base ROM's. An edited AI
script is written as described in
[Writing scripts back](#writing-scripts-back). Before writing, it
refuses an enemy that:

- has an id outside 0–254, or a name for an id above 250;
- has HP above 32767 (target handler `$08` starts its lowest-HP search at
  `$7FFF`);
- has a level outside 0–99, or a byte outside 0–255;
- has an attack id of 23 or more;
- has a drop or charm that is not an item id (`$F2` or more);
- has a name longer than 11 glyphs, or a glyph the font lacks;
- repeats an id or a file.

An unedited import rebuilds byte for byte.
`re_workspace/tools/ct_rom_check.py` checks each built ROM independently:

- only reported enemies' records and names change;
- each changed record decodes to the report;
- the values stay in range;
- the other enemies, the attack, tech and effect tables, and the AI pointers
  and scripts the report does not write are unchanged.

`macos_studio/tools/verify_enemy_build.py` runs the CLI end to end:

1. The import equals the Python decode.
2. `enemies verify` accepts the clean ROM.
3. An identical rebuild gives the clean ROM.
4. Edits to HP, magic, an affinity, exp, gold, the name, a level, the drop and
   the charm produce exactly the expected writes and pass `ct_rom_check`.
5. The ROM's own loader and reward routine, run on the built ROM, give the
   edited values.
6. Five damaged copies are rejected.
7. Four out-of-range edits are refused, and no output is written.
