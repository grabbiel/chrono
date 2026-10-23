# ROM builder (`.sfc`)

`chronoforge rom build` (and **Story → Build ROM…** or **Characters → Build ROM…**
in Studio) writes a project's event packs, songs, playable-character records,
tech tables, item tables, location maps, tilesets, enemies and the playable characters' sprites into a copy of the clean Chrono Trigger US 1.0 ROM and
fixes the header checksum. It starts from the unmodified ROM every time (SHA-256
`06d1c2b0…829a9`; a 512-byte copier header is dropped); a built ROM is refused as
a base. The output is game data: keep it local.

## Project settings

`project.json` gains an optional `rom` section:

```json
"rom": {
  "eventPacks": [
    { "entry": 23, "scenes": ["intro"] },
    { "entry": 30, "listing": "events/entry030.ctevents" }
  ],
  "songs": [
    { "song": 1, "listing": "audio/songs/song01.ctsong" }
  ],
  "characters": ["crono", "robo"],
  "techs": true,
  "items": true,
  "maps": ["loc_001", "loc_002"],
  "tilesets": ["t12_02", "t3_00", "pal_00"],
  "enemies": ["enemy_005", "enemy_009"],
  "sprites": ["crono", "magus"]
}
```

`sprites` names `sprites/<id>.sprite.json` files (playable characters' `ct-pc`
sets and enemies' `ct-enemy` battle sprites) imported from the ROM
(`rom.family` `ct-pc`). Each set is written in place: its frame records, the
sheet tiles that changed, its animation rows and colours 1–12. See
[sprites](sprites.md#writing-back).

`enemies` names `characters/<id>.json` files with an `enemy` record. For each
one, the builder writes the stat record, the reward record and (when changed)
the name over the base ROM's enemy `enemy.enemyId`, and its AI script when
`enemy.ai.text` differs from the base ROM's script. See [enemies](enemies.md).
`chronoforge enemies import` lists all 255. Studio sets the list with
**Characters → Enemies → Write to ROM**.

`maps` names `maps/<id>.map.json` files imported from the ROM (`chronoforge maps
import`); each is written over the location in its `rom.location`. `tilesets`
names `tilesets/<id>.tileset.json` files imported from the ROM (`chronoforge
tilesets import`, or with the maps): a Tileset12 (`t12_NN`), a Tileset3
(`t3_NN`) or a palette set (`pal_NN`). A tileset's characters come from its
sheet PNGs (`sheet`, `animSheet`). Both lists are set by hand in `project.json`
for now; see [maps](maps.md#writing-maps-back) and
[tilesets](tilesets.md#writing-back) for what can be written.

`items` writes each ROM item's record A and B, name and target mode, ItemBoosts
and (when a text changed) the description table (see [items](items.md));
`chronoforge items import` sets it and Studio sets it with **Items → Write items
to ROM**.

`techs` writes `tech_system.json`'s writable fields over the base ROM's tech
tables (see [techs](techs.md)); `chronoforge characters techs import` sets it and
Studio sets it with **Tech & Synergy Matrix → Write techs to ROM**.

`characters` writes each listed character's `pc` record and `growth` rows (see
[characters](characters.md)); `chronoforge characters import` lists all seven and
Studio sets them with **Characters → Write to ROM**.

`songs` replaces `Audio_SongTable` entries (0–82) with `ct-song/1` listings. See
[song sequences](music_sequences.md); Studio sets these rows in **Music → CT Songs**
(**New…** starts one from the template).

`samples` writes project samples into the sample tables, replacing one of the
62 or appending a new one, and adds each to the sample lists of the songs it
names. See [the SFX Lab](sfx_lab.md#a-project-sample-in-the-game-romsamples).
Studio sets these in **SFX → Use in game**. Every song the build writes or
lists a sample for must fit its budget: samples below the echo buffer, and
the sequence below `$4700`.

Each row replaces one `Evt_PackPtrs` entry (0–512) with either:

- **scenes**: Studio scenes on distinct object slots, lowered as in
  [event bytecode](event_bytecode.md). Their `text` messages are compiled with
  the project's ROM text profile into a message table for the pack.
- **listing**: a `ct-events/1` listing in the project (`chronoforge event disasm`
  exports one from your ROM to edit). Its `$B8` operands are kept as written, so a
  listing of a ROM pack keeps using its original message table.

`chronoforge rom locations <rom>` lists the events entry of each of the 512
locations (`LocRom.Events`, `$F6:0000` + 14 × location + 8). Several locations can
share an entry; replacing it changes all of them. 25 entries do not point at an
event pack (entry 0 points at a graphics pack, seven at an empty stream, the rest at
bytes that do not decode) and are refused.

Validate (gate 4) checks the rows: entries, duplicates, scenes that exist and
lower, listings that exist, and song listings that assemble. For `maps` and
`tilesets` it checks that each id exists and is listed once, that no location is
listed twice, and the same checks the builder makes before it writes (sizes,
ranges, the bit rules, the tileset a map names against its location record).

## What the builder does

1. Decodes every new pack with the derived opcode table and applies the game's
   own load checks (`LocLoad_CheckEvtData`): 1 to `$1700` unpacked bytes, and not
   13 objects with first script byte `$0A`.
2. Places each message table (16-bit addresses in the table's own bank, then the
   strings, identical strings shared; at most 256) and writes its 24-bit address
   into every `$B8` relocation of the lowered pack.
3. Packs each pack with the original packer (lz11) and places it, in order of
   preference: at its old stream's start, sharing an identical pack already
   placed, in the leftover span of another replaced stream, then in free space.
4. Places each song (length word, then data) with the same order of preference.
   A song stays at its old place only if it fits inside that place. Then the
   builder writes its `Audio_SongTable` pointer.
5. Writes each character's decoded record fields in place (`$CC:0000` + id ×
   `$50`; the undecoded bytes stay the base ROM's) and its HP, MP and stat growth
   rows, after the range and equipment checks in [characters](characters.md).
6. With `rom.techs`, writes each tech table's writable fields in place (TechInfo,
   TechRec parts and bits, PcTechAct script and frames, MpCost, the effect
   records, TechTpCost, the combination requirements, the new-game tech state and
   each record's +$02 bit 4), after the checks in [techs](techs.md).
7. With `rom.items`, writes each ROM item's record A, record B, name glyphs and
   target mode and the ItemBoosts table in place, and repacks the description
   table within its own span when a description changed, after the checks in
   [items](items.md).
8. With `rom.enemies`, writes each enemy's stat and reward records field by
   field in place (`$CC:4700` + id × 23, `$CC:5E00` + id × 7). It writes the
   name (`$CC:6500` + id × 11) only when it differs from the base ROM's. All of
   this happens after the checks in [enemies](enemies.md). Attack and tech
   records are never written.
   Right after the maps and tilesets (before anything else takes free space),
   it writes each listed enemy's edited AI script: in place when it fits the
   base script's span and no other script overlaps that span; else into bank
   `$CC`'s padding (`$CC:FC4F`–`$CC:FFFF`, 945 bytes), with the pointer
   (`$CC:8B08` + id × 2) rewritten. An unchanged script writes nothing; enemy
   127's unparsed pointer is kept. See
   [enemies](enemies.md#writing-scripts-back).
9. With `rom.sprites`, writes each playable character's set in place: the
   40-byte frame records, each changed tile (re-encoded from the sheet), the
   frame-id and duration rows and colours 1–12, after the checks and the
   re-decode in [sprites](sprites.md#writing-back). Then each listed enemy
   sprite, over that result ([enemy write-back](sprites.md#write-back)):
   - frame records, animation rows and colours 1–12 in place;
   - record bytes +4 to +9 (kept bits as they were);
   - the PC tile blocks of records `$F8`–`$FF` in place;
   - packed tiles re-packed with `LZSS.compress`, in place when no longer than
     the old stream, else into free space with the `$E4:2000` pointer
     rewritten.

   An edit to a part another record shows needs that record listed with the
   same edit (a PC set's part needs the PC set). The PC sets' pointer tables
   are never written.
10. With `rom.samples`, after the songs:
    - places each sample's bytes in place or in free space;
    - writes its table row; appending moves the four tables, one entry longer,
      to free space and patches the twelve operands that read them;
    - appends the sample to the named songs' `AudioRom_SongSamples` rows (after
      a listing's own `@samples`);
    - then refuses any written song over its budget (`CTSongBudget`).
11. Writes the `Evt_PackPtrs` entries and the checksum and complement.

Maps and tilesets are applied first, right after the free space is set up, so
the spans they free are known before the event packs are placed:

- **Maps** (`CTMapPatch`). Locations listed with the same content as their
  base `MapProps` entry keep it. Each distinct new content is packed (lz11) and
  takes the entry of the locations that all still share it, or, when only some
  locations sharing an entry changed, one of the 54 free `Map_PropsPtrs` slots
  (202–255, pointer 0 and named by no record). A pack goes into its old span if
  it fits and nothing else uses it, then into a reclaimed span, then into free
  space, never across a bank; then the builder writes the `Map_PropsPtrs`
  pointer and the 14-byte LocRom record. The `ExitRom` block (513 offset words
  and the records) is rebuilt for all 512 locations at once and grows only into
  the confirmed padding that follows it at `$E5:1A44`. Treasure records are
  written in place: a chest's flag is its record's position in `TreasureRom`,
  so a change in the number of records is refused, as are two maps sharing one
  treasure list with different chests and a first record on tile 0,0 (the
  redirect marker).
- **Tilesets** (`CTTilesetPatch`). Palette sets (210 bytes) and cycle lists
  (`FieldAnimListB`) are written in place; a list that grows, or that is shared
  with a palette set not in the build, is refused. Palette frames stay in their
  place or move within bank `$F6`. Metatile tables are repacked (lz11) and
  placed like map packs; the `$F6:2100`/`$F6:21C0` pointer is rewritten when
  they move. Edited characters are encoded back into the graphics packs the
  sheet's windows load from, each pack repacked in its own mode. A pack that
  other users need unchanged is forked into a free pack number (204–223: named
  by no loader, and their pointers do not unpack) and the lists that want the
  new content are repointed (`$F6:1C00`); a Tileset3 pack or a battle background
  pack (`BattleFx_BgSetPacks`, `$D1:ECDB`) cannot be forked and such an edit is
  refused. Before anything is placed, the builder loads every affected list's
  windows from the new packs and refuses a build where any sheet differs.
  Tile animations (`FieldAnimListA`) are rewritten in place with the same
  number of records and periodic steps. Lists A and B cannot move: other data
  follows them in bank `$FD`.

Nothing unchanged is written, so a project that imports every map and tileset
and lists them all rebuilds the clean ROM byte for byte.

Pack and table placement never crosses a bank (a song may): `Decomp_ToWram` reads a pack with DB = its bank
and a 16-bit index, and `TextWin_Init` reads the table's entries as addresses in
the table's bank.

**Free space** is the 66 padding rows (62,206 bytes) that ChronoRET's data survey
marks *confirmed* ("uniform fill; nothing points into it"), byte-verified in your
ROM by `re_workspace/tools/ct_rom_layout.py` (manifest `rom_layout.json`, Swift
twin `CTROMLayout.swift`); 12 *probable* rows are not used. A replaced stream's
span, or a replaced song's span, is reused only when nothing unchanged still
points at it. Message tables go
only into free space. Space runs out at about 62 KB plus the replaced packs:
a build that needs more stops with the sizes left; expansion to ExHiROM is not
implemented.

The report (`--report`, or `<name>.build.json` from Studio, schema
`ct-rom-build/1`) lists each pack's address, sizes, unpacked SHA-256 and
placement, each message table with each message's address and source text,
each song's address, size, data SHA-256 and placement, each character's record
address with the values written (and growth rows when written),
the tech tables written (`techs`, when built), the items and item tables
written (`items`, `itemTables`, when built), every byte range written (one
per changed character field, such as `character robo power`, and per changed
tech span, such as `tech $02 target` or `TechTpCost`, and per changed item span,
such as `item $5C record B`, `ItemBoosts` or `item descriptions`), and the free space left.
With maps or tilesets the report adds `maps` (each listed map's location,
`MapProps` entry, whether it is a new entry, address, sizes, unpacked SHA-256,
placement, LocRom record, exits and treasure), `tilesets` (each listed set's
kind, the parts written, the packed blocks placed and a Tileset12's pack list
after the build) and `relocations` (each block or table that moved or took a
new slot: what, from, to, size). The CLI prints one line per changed map,
tileset and relocation.

With enemies, the report adds `enemies`. It gives each listed enemy's file id,
enemy id, stat-record address, the record written and the name written (absent
when the name was left as it was). Each changed field is one write, such as
`enemy enemy_005 magic` or `enemy enemy_005 name`. The CLI prints how many
enemies are listed and which ones changed. A written AI script adds an
`enemyScripts` entry (file id, enemy id, address, size, `placement` `original`
or `free`, the base address `from`, the bytes' hash and the text as the parser
reads it back) and the writes `enemy enemy_098 AI script` and
`BattleRom_AiScriptPtrs[98]`; a moved script is also in `relocations`.

With sprites, the report adds `sprites`: per listed sprite its set, the parts
written (`tiles`, `frames`, `animations`, `palette`), the block addresses and
counts, the frames, animations and colours the set holds after the build, the
tile block's SHA-256, the changed tile numbers, and `sharedWith`: the other
sprite records (`$E4:F000`, `$E4:F600`) that name a changed part and so show
the edit too. Each changed record, tile or row is one write, such as
`sprite crono frame 12`, `sprite crono tile 37`, `sprite crono frame ids
r03.left` or `sprite crono durations r03`.

Enemy sprites add `enemySprites`: per listed sprite its record and layout, the
graphics, tiles' hash and changed tiles, the `pack` (address, `packedBytes`,
`budget`, unpacked size and hash, `placement` `original` or `free` and `from`),
the frames, animations, palette and record fields after the build, and
`sharedWith`. Writes are named like `sprite enemy_059 graphics 90 pack` and
`sprite enemy_209 $E4:2000[205]`; a moved pack is also in `relocations`.
`spriteWarnings` lists enemy records, not in `rom.sprites`, that show a part
the PC write-back changed (records `$F8`–`$FE` show the PC sets). Their
project files keep the old content. The CLI prints a line per changed enemy
sprite (its pack, budget, placement and sharers) and a `warning:` line for each.

## The packer

`libctcodec`'s `ct_lzss_compress` and Swift's `LZSS.compress` are the original
packer: Haruhiko Okumura's LZSS (1989) with Square's framing, identified by
ChronoRET (`tools/c3pack.py`, MIT). It rebuilds every packed block in the ROM byte
for byte: the 1,053 surveyed blocks and all 463 event-pack streams
(`re_workspace/tools/verify_lzss_corpus.py`). C, Swift and the Python transcription
agree on synthetic inputs too (window edges, partial groups, 64 KiB).

## Verification

- **Identical rebuild** (`CTROMBuilderTests`): all 488 event entries rebuilt from
  their own listings produce the clean ROM byte for byte, with no write reported.
- **Independent check** (`re_workspace/tools/ct_rom_check.py`, in the master gate
  via `macos_studio/tools/verify_rom_build.py`): a CLI build of a lowered scene
  (with three messages) and an edited listing that no longer fits its old place is
  checked without the Swift code: ChronoRET's `Decomp_ToWram` transcription
  unpacks every pack; the table-driven decoder decodes them; every changed byte is
  inside a report write and every write inside free space, a freed stream, a
  rebuilt pointer or the checksum; untouched entries unpack as before; `$B8`
  operands point at the table; the ROM's own `TextWin_Init` (run with ChronoRET's
  abstract interpreter) finds each message, whose bytes equal the source text
  encoded by ChronoRET's encoder; the checksum is valid. The build also writes two
  songs, one unchanged and one grown past its old place. The checker reads their
  pointers, hashes and walks with `ct_spc_seq.py` and requires every untouched
  song to be unchanged. Five deliberately damaged copies (with consistent
  checksums and report hashes) are each rejected.
- **Songs** (`CTSongTests`): all 83 songs rebuilt from their listings leave the
  ROM identical.
- **Samples** (`CTSamplePatchTests`, `macos_studio/tools/verify_audio_build.py`):
  - all 62 samples and 83 songs imported then rebuilt give the clean ROM;
  - for a replaced and an appended sample in a composed song,
    `ct_rom_check.py` re-reads the tables where the code reads them;
  - the ROM's `Audio_CmdLoadSong`, run in ChronoRET's interpreter, sends what
    the S-SMP driver received;
  - the driver keys the samples on, decodes their bytes and plays them at the
    sidecar's rate;
  - damaged copies are rejected and over-budget edits refused.
- **Characters** (`CTCharactersTests`, `macos_studio/tools/verify_character_build.py`):
  importing the seven records and building gives the clean ROM with no write; an
  edited build is checked by `ct_rom_check.py` (each record decoded independently
  and compared with the report, ranges, equipment against the clean ROM, undecoded
  bytes, unreported records and rows and ExpToLevel unchanged); five damaged copies
  are rejected.
- **Techs** (`CTTechsTests`, `macos_studio/tools/verify_tech_build.py`): importing
  the tech tables and building gives the clean ROM with no write; an edited build
  is checked by `ct_rom_check.py` (the tables decoded independently and compared
  with the report, read-only bytes, ranges, combination records, the new-game
  state and +$02), and the ROM's own `AwardTechPoints` learns from the built
  tables as the rule says; ten damaged copies are rejected.
- **Items** (`CTItemsTests`, `macos_studio/tools/verify_item_build.py`): importing
  the items and building gives the clean ROM with no write; an edited build is
  checked by `ct_rom_check.py`:
  - each reported item is decoded independently and compared with the report;
  - ranges, icons, ItemBoosts and the read-only stat tables are checked;
  - unreported items are unchanged;
  - each description pointer leads to the clean bytes or to the reference
    encoder's bytes for the new text.

  The ROM's own `Menu_BuildItemTables` and `Menu_RefreshAllChars` on the built
  ROM agree with the menu-stat rule. Eight damaged copies are rejected.
- **Maps and tilesets** (`CTMapTilesetBuildTests`,
  `macos_studio/tools/verify_map_tileset_build.py`): importing all 512 maps and
  every tileset and listing them all gives the clean ROM with no write; the
  encoders reproduce every location's MapProps content, LocRom record, the
  `ExitRom` block, every palette set and every metatile table byte for byte. An
  edited build (a cell in a shared entry, the same edit to two locations sharing
  one, a grown map, an added exit, chest contents, music, a colour, a cycle
  delay, a metatile, a character in an unshared and in a shared pack, a BG3
  pixel, animation steps) writes 20 ranges and 4 relocations, and is checked:
  - by `ct_rom_check.py`: every pointer table outside free space, `ExitRom`
    ending where the padding begins; each reported map's record, entry, pack
    (unpacked with the transcribed `Decomp_ToWram`), exits and treasure; each
    reported tileset's blocks, pointers, fork numbers and pack lists, with the
    parts it does not report unchanged; every unreported location, tileset,
    palette set and battle pack equal to the clean ROM;
  - by `ct_maps.py verify-import --content` (512 of 512) and `ct_tilesets.py
    verify-import` (207 of 207) against the project, and by `chronoforge
    tilesets verify` (154 of 154);
  - by the ROM's own routines run on the built ROM with ChronoRET's interpreter
    (`ct_maps.py`/`ct_tilesets.py` run claims): `LocLoad_UnkA33B` and
    `Map_LoadTreasureTiles` on 15 locations, `Decomp_ToWram` on the edited
    tables and packs (including the fork), both animation list loaders and
    `PalAnim_TickAll` (12 claims).

  Nine damaged copies are rejected and ten bad edits are refused.

- **Enemies** (`CTEnemiesTests`, `macos_studio/tools/verify_enemy_build.py`):
  importing all 255 enemies and building gives the clean ROM with no write. An
  edited build writes exactly the edited fields. Its checks:
  - `ct_rom_check.py` checks it: only reported enemies' records and names
    change, each decodes to the report and stays in range, and every other
    enemy table and AI script is unchanged;
  - `chronoforge enemies verify` accepts it against the project;
  - the ROM's own `BattleFD_UnkB438` and `BattleFD_AddEnemyRewards`, run on the
    built ROM in ChronoRET's interpreter, give the edited values.

  Five damaged copies are rejected and four bad edits are refused.

- **Enemy AI scripts** (`CTEnemiesTests`, `macos_studio/tools/verify_enemy_ai_build.py`):
  importing all 255 enemies with every script as text and building gives the
  clean ROM with no write. Three invented scripts (one in place, enemy 98's
  moved off the bytes it shares with enemy 97, one that grows) write exactly
  their spans and two pointers. Its checks:
  - `ct_rom_check.py` checks it: only reported pointers and spans change, each
    script re-decodes to the reported text and hash, a script in place stays
    in its own unshared span, a moved one in bank `$CC`'s padding, and every
    other script is unchanged;
  - `chronoforge enemies verify` accepts it (and rejects the clean ROM);
  - the ROM's own `BattleAi_RunMainPart` and `BattleAi_FindReactPart`, run on
    the built ROM in ChronoRET's interpreter, read the edited enemies' tests
    and choose the project script's block, action and target; enemy 97 and
    the other neighbours behave as on the clean ROM (27 runs).

  Six damaged copies are rejected and eleven bad scripts are refused.

- **Sprites** (`CTSpritePatchTests`, `macos_studio/tools/verify_sprite_build.py`):
  importing the seven playable characters' sets and building gives the clean
  ROM with no write. An edited build (a tile's pixels, a cell's tile and
  mirror, OBJ offsets, a frame id, a row's durations, colours) writes exactly
  the edited records, tiles and rows. Its checks:
  - `ct_rom_check.py` checks it: only reported sets' blocks change, the pointer
    tables and sprite records do not, and each set decodes to the report;
  - `ct_sprites.py verify-import --rom <built>` decodes the built ROM back to
    the edited project;
  - the ROM's own `Battle_DrawBattlerFrameAnyLayout`, run on the built ROM,
    gives the edited frames from tiles encoded independently from the sheet.

  Seven damaged copies are rejected and twelve bad edits are refused.

## Limitations

- No emulator run: the evidence is the ROM's own loader, decompressor and text
  routines as traced or transcribed, not a booted game.
- Only event packs, message tables, song sequences (with their per-song table
  rows), the playable characters' records and growth rows, the tech tables'
  writable fields, the item tables' writable fields, and the maps and tilesets
  of existing locations, enemies' stats, rewards and names, and the playable characters' sprite sets in place, the enemies' battle sprites (layouts 0–2; packs may move to free space), and song samples, are written. New locations, overworld maps, other sprites, sound effects, new items or item ids, new
  techs or tech names, sound-effect samples and drum kits, enemy AI scripts, attack and tech records, ExpToLevel and other tables are not.
  Enemies are written as their stat and reward records and names only.
- Lowered packs cover the Studio statements in `event_bytecode.md`; cross-map calls
  are refused.
- Maps keep their number of treasure records; animation lists keep their
  place and size; a Tileset3 or battle-background pack shared with an unedited
  user cannot be forked; at most 54 new `MapProps` entries and 20 forked packs.
  Empty palette-cycle records between filled ones are not kept (the list
  re-decodes the same).
- Free space is limited to the confirmed padding; ExHiROM (6/8 MB) expansion is not
  implemented.
