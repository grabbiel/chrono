# `.ctproj` — ChronoForge Studio project bundle schema (v1)

> Implementation status: this document includes target features that are not yet
> implemented. The native app builder and a playable runtime remain outstanding.
> The CT dialogue codec ([Text codec](text_codec.md)), event bytecode read/write and
> scene lowering ([Event bytecode](event_bytecode.md)), the playable characters'
> records and level curve ([Characters](characters.md)), the tech tables and
> tech-point rule ([Techs](techs.md)), their sprite sets (import and editing,
> [Sprites](sprites.md)) and an `.sfc` builder that writes event packs, message
> tables, songs, character records and tech tables
> ([ROM builder](rom_builder.md)) are implemented. Passing the validation gates verifies the
> current formats, not a complete or hardware-accurate game compiler.
> See [Scene Director](scene_director.md) for the implemented scene workflow and
> the repository README's status section for known gaps.

A `.ctproj` is a **directory bundle** (Git-friendly, text-first). Binary decodables
(PNG/BRR/WAV) sit next to their JSON sidecars; every JSON is UTF-8, 2-space indent,
keys ordered by the Studio on save. All SNES-facing values (BGR555 words, tile indices,
opcodes) round-trip through `libctcodec`.

```
MyGame.ctproj/
├── project.json                  # root manifest (schema below)
├── characters/<id>.json          # playable/NPC/enemy definitions (+ a PC's game record)
├── party.json                    # ct-party/1: exp table + equipment, from the ROM (optional)
├── sprites/<id>.sprite.json      # OAM sprite assemblies + animation sets
├── sprites/<id>.png              # indexed 16-col sheet (mode P, 4bpp) or 4-col (2bpp)
├── items/<id>.json               # weapons/helmets/armors/accessories/consumables (+ a ROM item's record)
├── item_tables.json              # ct-item-tables/1: ItemBoosts and the stat tables, from the ROM (optional)
├── techs/<id>.json               # single/dual/triple techs (legacy Studio format)
├── tech_system.json              # ct-techs/1: the game's tech tables, from the ROM (optional)
├── strings/dialogue.json         # UTF-8 strings; compiler emits CT text codec bytes
├── strings/ct-text-profile.json  # dictionary imported from the user's ROM (optional)
├── audio/samples/<id>.brr        # encoded samples (+ .json loop/ADSR/GAIN sidecar)
├── audio/samples/<id>.wav        # decoded preview (regenerable, gitignorable)
├── audio/tracks/<id>.akao.json   # tracker-format music scores
├── audio/songs/<name>.ctsong     # CT song sequences, ct-song/1 text (optional)
├── tilesets/<id>.tileset.json    # tile bank + metatiles + collision props
├── maps/<id>.map.json            # location header, layers, exits, triggers
├── scenes/<id>.event.dsl         # human-readable event script (canonical source)
├── scenes/<id>.event.json        # compiled AST + visual node layout
├── scenes/rom/packNNN.ctevt      # ROM event pack edited in the Scene Director (ct-events/1; rom.eventPacks listing)
├── story/flags.json              # story flag registry (ct-story-flags/1, docs/story.md)
├── story/graph.json              # world graph and inferred era groups (ct-story-graph/1)
└── build/                        # compiler output (gitignored): .sfc, .app
```

## `project.json`
```json
{
  "schema": "ctproj/1",
  "name": "My Game",
  "engine": { "base": "chrono-trigger-us-v1.0", "rom_sha256": "06d1c2b0..." },
  "start": { "map": "overworld", "x": 320, "y": 480, "era": "present" },
  "eras": [ { "id": "present", "name": "Present", "maps": ["overworld", "..."] } ],
  "flags": [ { "symbol": "MET_LAYLA", "bank": "story", "addr": "7F:0003", "bit": 2 } ],
  "encounters": [ { "id": "forest", "rate": 8, "enemies": ["rat_a"] } ],
  "rom": { "eventPacks": [ { "entry": 23, "scenes": ["intro"] },
                           { "entry": 30, "listing": "events/entry030.ctevents" } ],
           "songs": [ { "song": 1, "listing": "audio/songs/song01.ctsong" } ],
           "characters": ["crono", "robo"],
           "techs": true,
           "items": true,
           "maps": ["loc_001"],
           "tilesets": ["t12_02", "pal_00"],
           "enemies": ["enemy_005"],
           "sprites": ["crono"] }
}
```
`flags` entries name a bit of `$7F:0000–$7F:01FF` for scenes (`bit` 0–7). Two
optional keys: `"origin": "story"` marks flags the story registry writes
(`chronoforge story import`; a rescan replaces only those) and `notes`. Both are
omitted when absent, so older projects load and save unchanged. A registry flag
never replaces a maintainer's flag with the same symbol. See [Story Mode](story.md).

`rom` is optional: the event packs, songs and playable characters `chronoforge rom
build` writes into the base ROM (see [ROM builder](rom_builder.md),
[song sequences](music_sequences.md) and [characters](characters.md)). Any list may
be absent; `characters` names `characters/<id>.json` files that have a `pc` record.
`techs` (absent = false) writes `tech_system.json`'s tables ([techs](techs.md)).
`items` (absent = false) writes the ROM items and `item_tables.json` ([items](items.md)).
`maps` names `maps/<id>.map.json` files with a `rom.location`, each written over
that location ([maps](maps.md#writing-maps-back)). `tilesets` names
`tilesets/<id>.tileset.json` files with a `rom` source: Tileset12, Tileset3 or
palette sets ([tilesets](tilesets.md#writing-back)). Both are omitted when empty.
`enemies` names `characters/<id>.json` files with an `enemy` record. Each
enemy's stats, rewards and name are written over its `enemy.enemyId`
([enemies](enemies.md)). The list is omitted when empty.
`sprites` names `sprites/<id>.sprite.json` files with a `rom` source of family
`ct-pc`; each set is written in place ([sprites](sprites.md#writing-back)). The
list is omitted when empty.

## `characters/<id>.json`
```json
{
  "id": "robo", "name": "Robo", "kind": "playable", "level": 10,
  "pc": {
    "charId": 3, "level": 10, "exp": 0, "expToNext": 0,
    "hp": 0, "maxHp": 0, "mp": 0, "maxMp": 0,
    "stats":      { "power": 0, "stamina": 0, "speed": 0, "magic": 0, "hit": 0, "evade": 0, "magicDefense": 0 },
    "growthBase": { "power": 0, "stamina": 0, "speed": 0, "magic": 0, "hit": 0, "evade": 0, "magicDefense": 0 },
    "equipment": { "weapon": 0, "armor": 0, "helmet": 0, "accessory": 0 },
    "techPoints": 0, "techPointsToNext": 0
  },
  "growth": {
    "hp": [ { "toLevel": 0, "gain": 0 }, "… 4 steps" ],
    "mp": [ { "toLevel": 0, "gain": 0 }, "… 4 steps" ],
    "stats": { "power": 0, "stamina": 0, "speed": 0, "magic": 0, "hit": 0, "evade": 0, "magicDefense": 0 }
  }
}
```
(Values elided; `chronoforge characters import` fills them from your ROM.)
`id`, `name`, `kind`, `sprite`, `level`, `stats` (`hp, mp, atk, def, mag, spd`) and
`palette` are the original fields; files with only those still load and save
unchanged. `pc` is the decoded part of the game's record (`$CC:0000` + `charId` ×
`$50`) and `growth` its HP/MP steps and per-level stat growth; both are absent for
characters that are not PC records. The import keeps `level` equal to `pc.level`.

An enemy (`kind: "enemy"`) can have an `enemy` record instead. It holds:

- the decoded stat and reward records: `enemyId`, `hp`, `level`, `status`,
  `stats`, `affinity`, `immunity`, `flags15`, `attackId` and `reward`;
- `ai`, its AI script as text (or the parse error);
- `attack`, its plain attack record.

`chronoforge enemies import` writes `enemy_000` … `enemy_254`. See
[enemies](enemies.md) for the layout. `ai` and `attack` are shown but never
written. The import keeps `level` equal to `enemy.level`, and a placeholder name
`Enemy NNN` (for an enemy without a ROM name) is not written.

## `sprites/<id>.sprite.json`
```json
{
  "id": "crono", "sheet": "sprites/crono.png", "bpp": 4,
  "frames": [
    { "tiles": [ { "x": -8, "y": -32, "tile": 0, "hflip": false, "vflip": false, "pal": 0,
                   "size16": true, "anchor": false, "priority": 2 }, "… 4 OBJs" ],
      "cells": [ 0, "… 16 tile words" ],
      "hitbox": { "x": -8, "y": -32, "w": 16, "h": 32 }, "weapon": { "x": 6, "y": -12 } }
  ],
  "animations": [ { "id": "r00.down", "frames": [0], "durations": [8], "loop": true, "row": 0, "facing": 1 } ],
  "palettes": [ [ "0x0000", "… 16 BGR555 words" ] ],
  "stream": { "columns": 8, "rows": 2, "baseTile": 8 },
  "rom": { "family": "ct-pc", "set": 0, "tiles": "$D2:0000", "tileCount": 0, "frames": "$DC:0000",
           "frameCount": 0, "palette": "$E4:0000", "frameIds": "$E4:0000", "durations": "$E4:0000", "rows": 0 }
}
```
(Values elided; `chronoforge sprites import` fills them from your ROM.)
`id`, `sheet`, `bpp`, `frames[].tiles` (`x, y, tile, hflip, vflip, pal, size16,
anchor`), `frames[].large` and `animations` (`id, frames, durations, loop`) are the
original fields; files with only those still load and save unchanged.
- Sheet tile k is OBJ tile k (OBSEL 0: 8×8 and 16×16, name base 0): a 16×16 OBJ
  shows tiles N, N+1, N+16, N+17, so sheets are 16 tiles wide.
- `palettes[k]` is OBJ palette k (CGRAM 128 + 16k); without it, palette 0 is the
  sheet's PLTE.
- `stream`: each frame's `cells` (columns × rows tile words: bits 0–10 a sheet
  tile, 0 blank; bit 14 mirrors it) are copied to OBJ tiles baseTile + 16r + c
  before the frame shows, and an OBJ's `tile` counts from baseTile.
- `priority` is the OAM priority (absent: 2). `row` and `facing` (0 up, 1 down,
  2 left, 3 right) place an animation in the game's tables. `durations` are 60 Hz
  frames.
- `hitbox` and `weapon` are Studio fields about the origin; they are not
  written to the ROM.
- `rom` records where the import read the set (see [Sprites](sprites.md)).
  An enemy's battle sprite (`sprites/enemy_NNN.*`) has `rom.family` `ct-enemy`,
  `rom.set` the enemy id, `rom.layout` its frame layout (0–2) and `rom.packed`
  (tiles unpacked from a pack); its `stream` is 8 × 2, 16 × 2 or 8 × 6 at
  baseTile 64. It is read-only: `rom.sprites` takes only `ct-pc` sets
  ([Enemy sprites](sprites.md#enemy-sprites)).

## `tilesets/<id>.tileset.json`
```json
{
  "id": "t12_02", "kind": "bg12", "sheet": "tilesets/t12_02.png", "bpp": 4, "tileCount": 1024,
  "metatiles": [ { "chips": [ { "tile": 300, "pal": 2, "priority": false, "hflip": false, "vflip": false },
                              "… 4 chips: TL, TR, BL, BR" ] } ],
  "collision": [],
  "vram": { "charBase": 4096,
            "slots": [ { "slot": 0, "vram": 8192, "firstTile": 256, "tiles": 128, "pack": 0,
                         "source": "$E0:0000", "ownTiles": 128 } ],
            "known": [ { "firstTile": 256, "tiles": 764 } ] },
  "tileAnimations": [ { "tile": 297, "tiles": 4, "steps": [64, "… 8"], "frames": [0, "… 8"] } ],
  "animSheet": "tilesets/t12_02_anim.png",
  "preview": { "palette": "pal_02", "layer3": "t3_01" },
  "rom": { "family": "ct-loc12", "index": 2, "table": "$ED:0000", "packedBytes": 0,
           "list": "$F6:1C10", "animations": "$FD:F310", "locations": [1, 2] }
}
{
  "id": "pal_02", "kind": "palette", "bpp": 4, "tileCount": 0, "metatiles": [], "collision": [],
  "palettes": [ [ "0x0000", "… 16 BGR555 words" ], "… 8 rows" ],
  "paletteCycles": [ { "kind": "list-frames", "first": 65, "count": 2, "delay": 3,
                       "frames": [ [ "0x0000", "… count words" ] ], "order": [0, 1], "source": "$F6:0000" } ],
  "rom": { "family": "ct-locpal", "index": 2, "table": "$F6:2664", "animations": "$FD:FA77", "locations": [1, 2] }
}
```
(Values elided; `chronoforge tilesets import` fills them from your ROM.)

- **The original fields.** `id`, `sheet`/`blob`, `bpp`, `tileCount`,
  `metatiles` and `collision` are the original fields. Every other field is
  optional, so files with only the original fields still load and save
  unchanged.
- **A chip is a SNES tilemap word.** `tile` is bits 0–9, `pal` 10–12,
  `priority` 13, `hflip` 14 and `vflip` 15. Chrono Trigger's `Map_Meta12`/`Meta3`
  words use exactly this order; see [Tilesets](tilesets.md).
- **`kind`.**
  - `"bg12"`: layers 1/2, 4bpp. Characters are at VRAM word
    `vram.charBase` (`$1000`).
  - `"bg3"`: layer 3, 2bpp, at `$5000`.
  - `"palette"`: palettes and cycles only, with no sheet.
  - Absent: a plain tile bank.
- **Sheet tiles.** In a `bg12`/`bg3` sheet, tile *k* is character *k* (16 per
  row, 1024 tiles). `vram.known` lists the characters the tileset sets. The
  others are blank in the sheet; the game shows whatever VRAM holds there.
- **`vram.slots`.** These are the uploads. `ownTiles` < `tiles` means the
  upload's tail is an earlier pack's stage bytes.
- **`palettes[r]`.** This is CGRAM row *r* (16 hex BGR555 words). A location
  sets colours 1–15 of rows 1–7. `paletteCycles` kinds:
  - `rotate-down` / `rotate-up` turn colours `first … first+count` by one.
  - `rom-frames` copies frame *k* of `frames` to colours `first…`, with *k*
    stepping 0, 1, ….
  - `list-frames` does the same with *k* taken from `order`.

  Each cycle acts every `delay` frames (0 means 256). Colours are CGRAM
  indices (16 × row + colour).
- **`tileAnimations`.** Four characters from `tile` show `animSheet` tiles
  `frames[f]…+3`. The accumulator increases by 4 × `steps[f]` per upload, and
  f is accumulator bits 9–11. There is one upload every other frame.
- **Provenance.** `preview` names the entries the Studio previews with, and
  `rom` records where the import read the entry.

## `maps/<id>.map.json`
```json
{
  "id": "loc_001", "name": "Location 001", "tileset": "t12_02", "width": 64, "height": 64,
  "layers": [ { "bg": 1, "metatiles": [12, "… width x height"] },
              { "bg": 2, "metatiles": [0, "…"], "width": 64, "height": 64 },
              { "bg": 3, "metatiles": [0, "…"], "width": 64, "height": 64 } ],
  "exits": [ { "x": 10, "y": 13, "map": "loc_496", "toX": 55, "toY": 35,
               "span": 1, "vertical": false, "facing": 1, "facingBit7": false } ],
  "triggers": [],
  "location": { "music": 30, "tileset12": 2, "tileset3": 1, "palette": 2, "events": 323, "unk06": 0,
                "limits": [0, 0, 15, 13] },
  "settings": { "screens": 75, "colorMath": 3, "move2": 0, "move3": 0,
                "halfRate2": false, "ownStep2": false, "ownStep3": false },
  "tileProps": { "width": 64, "height": 64, "hiBits": "00…", "attrA": "00…", "attrB": "01…" },
  "treasure": [ { "x": 6, "y": 5, "contents": 291 } ],
  "rom": { "location": 1, "record": "$F6:000E", "mapProps": 60, "packedAt": "$F1:325B",
           "packedBytes": 5879, "unpackedBytes": 16745, "staleTiles": 0,
           "exitsAt": "$E5:…", "treasureList": 1, "treasureAt": null }
}
```
(Values elided or illustrative; `chronoforge maps import` fills them from your ROM.)

- **The original fields.** `id`, `name`, `tileset`, `width`, `height`,
  `layers` (`bg`, `metatiles`), `exits` (`x`, `y`, `map`, `toX`, `toY`) and
  `triggers` are the original fields. Every other field is optional, so
  hand-made maps still load and save unchanged.
- **Layers.** `width` and `height` are layer 1's size in 16×16 metatiles. A
  layer with its own `width`/`height` (layers 2 and 3 of an imported map) has
  that size. `metatiles` index the map's tileset: `t12_NN` for BG1/BG2,
  0–1023, and the location's `t3_NN` for BG3, 0–255.
- **`tileProps`.** One byte per layer-1 cell for each of HiBits, AttrA and
  AttrB, as lowercase hex, row by row. HiBits bits 0/1 must equal bit 8 of the
  layer-1/layer-2 metatile. The bits are listed in [Maps](maps.md#tile-properties).
- **`exits`.**
  - `span` counts the extra tiles, and `vertical` runs them down the column.
  - `facing` is 0–15.
  - `facingBit7` is the record's byte 4 bit 7.
  - A `map` of `loc_496` or above is a world map.
- **`location`.** The LocRom record. `limits` is left, top, right and bottom
  in tiles; left bit 7 means layer 1's edges.
- **`settings`.** The MapProps head: `screens` and `colorMath` give TM, TS and
  CGADSUB, and the steps are explained in [Maps](maps.md#the-6-byte-head).
- **`treasure`.** This location's chest list, taken from the redirected list
  where there is one. `contents` bit 15 means gold (bits 0–14 × 2), bit 14
  means empty, and otherwise bits 0–8 are an item.
- **`rom`.** Where the import read the map, for write-back. `staleTiles`
  counts the tile-property triples the ROM's map lacks; they are 0 in the
  project.
- **`t12_none`.** Locations without either tileset use the empty tileset
  `t12_none` (one chip-less metatile, `tileCount` 0).

## `party.json`
```json
{ "schema": "ct-party/1",
  "expToLevel": [0, "… 100 entries: [L] = experience from level L to L + 1"],
  "equipment": [ { "id": 1, "name": "…", "slot": "weapon", "equipMask": 128 } ] }
```
Written by the character import from your ROM; the Studio's level curve and
equipment pickers read it. The builder checks equipment against the base ROM, not
this file, and does not write `expToLevel`.

## `tech_system.json`
```json
{ "schema": "ct-techs/1",
  "techs": [ { "id": 1, "name": "…", "kind": "single", "targetMode": 0, "fieldMenu": false, "area": 0,
               "userSet": 0, "needsUnlock": false, "flags": 0, "element": "…", "attr": 0,
               "parts": [0, 128, 128], "modifiers": [0, 0, 0],
               "anim": { "script": 0, "gfxA": 0, "gfxB": 0, "frames": 0, "pal": 0, "obj": 0, "arg": 0 } },
             "… ids 0-$74" ],
  "parts": [ { "id": 0, "mp": 0, "effect": { "type": 0, "arg1": 0, "arg2": 0, "casterStat": 0, "targetStat": 0,
               "formula": 0, "defence": 0, "flags": 0, "flags2": 0, "power": 0, "immunity": 0, "arg11": 0 } },
             "… parts 0-71" ],
  "tpCost": [[0, "… 8 per character"], "… 7 rows"],
  "combos": [ { "mask": 0, "first": 0, "requirements": [[0, 0, 0], "… one row per tech"] } ],
  "learned": { "counts": [0, "… 7"], "bits1": [0, "… 7"], "comboBits": [0, "… 30"] },
  "userSets": [[0, 0, 0], "… 52 sets"],
  "areas": [[], [ { "shape": 0, "param": 0, "size": 0 } ], "… areas 0-$0B"] }
```
(Values elided; `chronoforge characters techs import` fills them from your ROM.)
`name` and `icon` are never written. `kind`, `userSet`, `flags`, `attr`, the
animation's graphics bytes, the combination records' `mask`, `first` and row
count, `userSets` and `areas` are read-only: the builder refuses values that differ
from the base ROM's. `element`
is absent for none. See [techs](techs.md) for each field's meaning and evidence.

## `items/<id>.json` and `item_tables.json`
```json
{ "id": "5c_…", "name": "…", "kind": "armor", "price": 0,
  "stats": { "defence": 0, "modifier": 0, "modifierOn": 0 },
  "rom": { "itemId": 92, "icon": 0, "flags": 0, "equip": 0, "boost": 0, "elementBonus": 0 },
  "description": "…" }
```
```json
{ "schema": "ct-item-tables/1",
  "boosts": [ { "stats": [], "amount": 0 }, { "stats": ["…"], "amount": 0 }, "… 23 entries" ],
  "statOrder": ["… 7 stat names"], "statCaps": [0, "… 7"], "char5Attack": [0, "… 100"] }
```
(Values elided; `chronoforge items import` fills them from your ROM.) `id`,
`name`, `kind`, `price`, `effect` and `stats` are the original item fields; `rom`
and `description` are optional. A file without `rom` is a project-only item and
is never built. For a ROM item, `stats` holds record B under the category's keys
(`attack`, `byte1`, `critical`, `modifier`, `modifierArg`; `defence`,
`modifier`, `modifierOn`; `battleFlags`, `special`, `specialArg`, `specialBits`;
`useKind`, `restores`, `amount`, `byte3`). `rom.equip` is absent on consumables;
`rom.boost` and `rom.elementBonus` appear only on weapons, armour and helmets;
`rom.targetMode` only on consumables. `rom.icon`, `statOrder`, `statCaps` and
`char5Attack` are read-only: the builder refuses values that differ from the base
ROM's. See [items](items.md) for each field's meaning and evidence.

## `audio/samples/<id>.json`

The sidecar of `audio/samples/<id>.brr` (`[u16 LE byte length][9-byte BRR
blocks]`; bare blocks also load). `<id>.wav` beside it is the S-DSP decode,
written by the SFX Lab for preview; it can be regenerated. See
[the SFX Lab](sfx_lab.md).

| Field | Meaning |
| --- | --- |
| `brr` | project-relative path of the BRR file |
| `rate` | sample rate in Hz; the preview pitch is `rate × $1000 / 32000` |
| `loop`, `loopStartSample`, `loopEndSample` | loop on 16-sample block boundaries; the sidecar, not the data's flags, decides looping |
| `adsr` | `[ADSR1, ADSR2]` register bytes (ADSR1 bit 7 set) or `[attack 0-15, decay 0-7, sustain level 0-7, sustain rate 0-31]`; other values are ignored |
| `gain` | GAIN register byte, used when `adsr` is absent |
| `synth` | optional generator spec (`wave`: pulse, saw, triangle, sine, noise or fm; `frequency`, `endFrequency`, `duration`, `duty`, `fmRatio`, `fmIndex`, `fmDecay`, `decay`, `amplitude`, `rate`, `seed`, `loop`); missing keys take defaults |
| `source` | optional WAV import record: `wav`, `sourceRate`, `normalizeDBFS`, `crossfade`, `beam`, and the measured `snrDB` and `maxError` |
| `fx` | optional voice effects: `tickDivider` (1-256, default 32 = 4 ms ticks), `bendSemitones`/`bendTicks`, `vibratoCents`/`vibratoPeriodTicks`/`vibratoDelayTicks`, `noise`/`noiseClock` (0-31), `gainStart` (GAIN direct level at key-on, 0-127), `keyOffTick` (preview release) |

`synth`, `source` and `fx` are absent from older sidecars, which load and save unchanged.

## Conventions (binding for all modules)
- **Color**: stored as hex BGR555 word `"bgr555": "0x7FFF"` + derived `"srgb": [r,g,b]`
  (regenerated on load; BGR555 is authoritative).
- **Coordinates**: SNES native pixels; map coords in 1/16-chip units where the ROM uses them.
- **Sprites**: `frames[] -> tiles[] {x, y, tile, hflip, vflip, pal(0-7), size8|16, anchor}`
  mapping 1:1 onto OAM entries (512 max per frame enforced by the validator);
  sheet tile k is OBJ tile k. Tiles are SNES planar (planes 0/1 interleaved per
  row), as in VRAM.
- **Metatiles**: 16x16 chips = 4 subtiles `{tile, pal, hflip, vflip, priority}`;
  32x32 blocks = 4 chips. Collision props: `{plane1: walk|solid|water|...,
  plane2: ..., plane_swap: bool, zmask: bool, conveyor: none|dir(0-7)}`.
- **Dialogue**: UTF-8 source. With `strings/ct-text-profile.json`, text uses CT
  tags (`{wait 03}`, `{char0}`, `{page}`, newline = `{line}`) and compiles to
  TextWin bytes: substring dictionary (0x21-0x9F) + glyphs (0xA0-0xFF), with byte
  savings reported (see `text_codec.md`). Without a profile the legacy placeholder
  escapes (`\{name:robo}`, `\{wait}`, `\{br}`) apply and are not ROM text.
- **Music**: `.akao.json` = `{tempo, tracks: [{voice, program, pan, adsr_override,
  events: [{t, dur, note, ...}]}], echo: {edl, efb, evoll, evolr, fir[8]}}` (the
  Studio's own score format). `.ctsong` = the game's own song sequences as text
  (`ct-song/1`, [song sequences](music_sequences.md)); the two are not converted.
  The Studio's tracker, piano roll, instrument rack and echo designer edit a
  `.ctsong` listing in place and save it after every edit, with undo; nothing
  else is stored ([music tracker](music_tracker.md)).
- **Event DSL (implemented)**: one object slot (`obj 0..15`) per scene, unique
  functions `func 0..15`, and the Studio statements described in `scene_director.md`.
  DSL is authoritative; `.event.json` caches the AST and `{node_id, x, y}` graph
  positions (node IDs are function indices). The internal `.cfscene` archive is
  not ROM bytecode. `chronoforge event lower` lowers scenes to CT event packs
  (`event_bytecode.md`); validation warns when a scene uses statements that
  cannot be lowered yet, such as map calls.
- **Build targets**: `.sfc` event-pack, song, character-record and tech-table repack within the 4 MB
  HiROM is implemented (`chronoforge rom build`, [ROM builder](rom_builder.md)). Not implemented: a native
  `.app` (embedded Swift/Metal runtime), other asset kinds, and ExHiROM 6/8 MB
  expansion.

## Validation gates (enforced by `chronoforge validate` and Swift unit tests)
1. Every referenced id exists; every PNG is mode P with ≤16 (4bpp) / ≤4 (2bpp) colors.
2. OAM budget per frame ≤ 512 entries (1024 for large-sprite modes) — engine rule.
3. Tile bank VRAM budget per BG layer enforced against SNES tile-cache limits.
4. Event scripts compile → bytecode → decompile → AST equality (round-trip gate);
   `rom.eventPacks` rows name event-pack entries and existing, lowerable scenes or
   existing listings; `rom.songs` rows name song indices 0–82 and listings inside the
   project that assemble; `rom.characters` rows name files with a `pc` record, no
   record twice, in the game's ranges (equipment with `party.json`); `rom.techs`
   needs `tech_system.json` in the game's ranges (read-only fields are checked
   against the base ROM by `rom build`); `rom.sprites` rows name sprite files of
   family `ct-pc`, one per set, in the format the set can carry (the build adds
   the base ROM's addresses, counts and the re-decode).
5. With a ROM text profile, every string compiles to a terminated CT message whose
   decode re-encodes byte-exactly; otherwise the placeholder codec round-trip (warning).
6. BRR encode → decode ≈ source WAV within SNES BRR error envelope; loop points
   on 16-sample (1 BRR block) boundaries.
