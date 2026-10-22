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
├── items/<id>.json               # weapons/helmets/armors/accessories/consumables
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
           "techs": true }
}
```
`rom` is optional: the event packs, songs and playable characters `chronoforge rom
build` writes into the base ROM (see [ROM builder](rom_builder.md),
[song sequences](music_sequences.md) and [characters](characters.md)). Any list may
be absent; `characters` names `characters/<id>.json` files that have a `pc` record.
`techs` (absent = false) writes `tech_system.json`'s tables ([techs](techs.md)).

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
   against the base ROM by `rom build`).
5. With a ROM text profile, every string compiles to a terminated CT message whose
   decode re-encodes byte-exactly; otherwise the placeholder codec round-trip (warning).
6. BRR encode → decode ≈ source WAV within SNES BRR error envelope; loop points
   on 16-sample (1 BRR block) boundaries.
