# Maps (Multi-Plane Map Editor)

Chrono Trigger's location maps are decoded with evidence: the header, the three
tile planes, the tile-property plane, exits and treasure. They are imported
into a project, edited in **Maps**, and drawn through the SNES PPU model with
the field's own register setup ([PPU](ppu.md#real-locations)).

- **References.** The Python reference, and the check for every claim, is
  `re_workspace/tools/ct_maps.py`. The Swift twin is `CTMaps.swift`
  (`CTMapROM`, `CTTileProps`, `CTTilePropsPlane`, `CTMaps`) together with
  `CTLocationRender.swift` (`LocationScene`).
- **Tilesets.** A location's tilesets and palette are the ones in
  [Tilesets](tilesets.md). A map import also imports any of them the project
  lacks.
- **ROM data.** None is stored in the repository: the import reads it from your
  ROM into your project. `chronoforge rom build` writes maps back
  ([Writing maps back](#writing-maps-back)).

## The location header

`LocRom` (`$F6:0000`) holds 512 records of 14 B. `CTMapROM.header` reads them.

| Byte | Field | Notes |
|---|---|---|
| +0 | `music` | |
| +1 | `Tileset12` | `$FF` loads nothing. |
| +2 | `Tileset3` | `$FF` loads nothing, and `Field_UnkBB` is set (see Screens). |
| +3 | `Palette` | |
| +4 | `MapProps` (16-bit) | An index into `Map_PropsPtrs` (`$F6:1E00`, 3 B each). |
| +6 | `Unk06` | Always 0 in the ROM, kept raw. |
| +7 | `Events` (16-bit) | The location's event pack (see [Event bytecode](event_bytecode.md)). |
| +9 | `LimitLeft`, `LimitTop`, `LimitRight`, `LimitBottom` | The camera limits in tiles. With `LimitLeft` bit 7 set, the limits are layer 1's edges instead (`Map_InitMasksAndLimits`). |

Seventeen locations have both tilesets set to `$FF`: 0, 37, 82, 88, 91–95,
108, 239, 240, 271, 306, 400, 433 and 460.

- **What they contain.** Every one is 16×16 of metatile 0 with `Screens` =
  `$08`, so only OBJ is on the main screen.
- **In a project.** They use the empty tileset `t12_none`, which has one
  chip-less metatile and no tiles. The validator requires every map to have a
  tileset.

## MapProps: the planes

`LocLoad_UnkA33B` (`$C0:A33B`) unpacks a MapProps entry with LZSS to
`$7E:B500`. `Map_UnpackTilePlanes` (`$C0:A521`) then reads it as follows.

### The 6-byte head

| Byte | Field | Meaning |
|---|---|---|
| +0 | `Size1` | Layer 1 is ((n & 3) + 1)·16 wide and ((n & $C) + 4)·4 high. Layer 2 is (n & $30) + 16 wide and (n & $C0)/4 + 16 high. |
| +1 | `Size3` | Bits 0–3 give layer 3's size, the same way as layer 1. Bit 4: layer 2 takes its own step only. Bit 5: the same for layer 3. Bit 6: layer 2 scrolls at half rate (`Map_Unk0BC9` = $80). Bit 7: a layer-3 plane follows. |
| +2 | `Move2` | Layer 2's own step per frame, in 1/16 px. Bits 0–2 give n, the X step is 1 << (n − 1), and bit 3 makes it negative. Bits 4–7 give Y the same way. |
| +3 | `Move3` | The same for layer 3. |
| +4 | `Screens` | TM and TS (see Screens below). |
| +5 | `ColorMath` | CGADSUB. |

Sizes are 16, 32, 48 or 64. The wrap mask is $3F for 64 and 48, $1F for 32 and
$0F for 16 (`Map_InitMasksAndLimits`).

### The planes and the triples

- **Planes.** Layer 1 comes first, then layer 2, then layer 3 if `Size3` bit
  7 is set. Each is one byte per cell, read row by row.
- **Tile properties.** Over layer 1's size come the triples (HiBits, AttrA,
  AttrB). A HiBits byte with bit 7 set starts a run instead: the bytes after
  it are the triple's three values and then a count, where 0 means 256.
- **In WRAM.** Rows are $100 apart. Layer 1 is at `$7E:3000`, layer 2 at
  +$40, layer 3 at +$80 and HiBits at +$C0. AttrA is at `$7E:7000`, AttrB at
  `$7040`, the exit index at `$7080` and the treasure index at `$70C0`.
- **Short maps.** Five MapProps entries (29, 58, 98, 191 and 193; nine
  locations use them) end before their triples cover layer 1. The game then
  reads whatever WRAM held. The decoder reads those tiles as 0 and records
  how many in `rom.staleTiles`.

## Tile properties

These are the bits the code reads. Bits nobody reads are kept raw.

| Byte | Bits | Meaning | Reader |
|---|---|---|---|
| HiBits | 0 / 1 | Bit 8 of the layer-1 / layer-2 metatile | `Map_WriteRow1` / `Map_WriteRow2` |
| HiBits | 2–7 | Shape: 0 half A; 1 half B; 2–$17 slopes; $18–$1D half B in a half or quarter (left, top, bottom-left, bottom-right, top-right, top-left); $1E stair (cuts the Y step); higher acts as half A | `Map_ProbeTileLevel` |
| AttrA | 0–1 | Push direction: 0 up, 1 down, 2 left, 3 right | `Map_StepTileEffects` |
| AttrA | 2–3 | Push speed: $08, $10 or $20 (1/16 px a frame); 0 is off | `Map_StepTileEffects` |
| AttrA | 4 | Animation trigger | `Map_StepTileEffects` |
| AttrA | 6 | OAM priority of a sprite's low half (overhead): `AttrA >> 2 & $10` gives priority 3 instead of 2 | `Map_ProbeTileLevel` |
| AttrA | 5, 7 | Not read | |
| AttrB | 0–1 / 3–4 | The level of half A / half B | `Map_ProbeTileLevel` |
| AttrB | 2 / 5 | Half A / half B has no level | `Map_ProbeTileLevel` |
| AttrB | 6 | OAM priority of the high half (overhead), the same way | `Map_ProbeTileLevel` |
| AttrB | 7 | Blocks objects moved by events | `Obj_SetVelocityChecked`, `Evt_PushTarget` |

`Map_ProbeLevelBlocked` decides what blocks:

- level 0 blocks;
- level 3 lets anyone through;
- level 1 or 2 lets through a leader on the same level or on level 3;
- a half with no level blocks only a leader on level 3.

A treasure tile blocks the leader (`Map_ProbeTileAttrs`). The painter's
colours follow these rules: level 1 is "plane 1", level 2 "plane 2", level 3
"transition", level 0 "solid", and no level is "neutral".

## Exits

`ExitRom_LocOfs` (`$E5:0000`) holds 513 words. Location i's 7-byte records run
from word i to word i + 1. There are 814 records in all.

| Byte | Field |
|---|---|
| +0, +1 | `x`, `y` (tiles) |
| +2 | `span`: bits 0–6 count the extra tiles; bit 7 means down the column instead of along the row |
| +3, +4 | `dest`: 9 bits (byte 4 bit 0 is bit 8); `facing` is byte 4 bits 1–4; byte 4 bit 7 is kept as `facingBit7` |
| +5, +6 | `destX`, `destY` |

- **The tiles.** `Map_LoadExitTiles` writes the record number into
  `Map_TileExitIdx` for each tile the exit covers. Along a row only the column
  wraps (an 8-bit AND). Down a column the row wraps too.
- **World-map destinations.** 127 exits go to $1F0 or higher, which are the
  world maps. In a project these point at `loc_496` and above, which are
  LocRom records of their own.

## Treasure

`TreasureRom_LocOfs` (`$F5:F000`) holds one word per location, pointing at
4-byte records in bank $F5: the tile (x, y) and the contents.

- **Redirects.** If the first record's tile is 0, its contents word names
  another location whose list is used (unmasked: the code does an ASL with no
  mask). Five locations redirect: 109→302, 300→297, 303→110, 490→305 and
  495→245.
- **Contents.** Bit 15 means gold, with an amount of bits 0–14 × 2. Otherwise
  bit 14 means empty. Otherwise bits 0–8 are an item.
- **Counts.** There are 244 records: 228 items and 16 gold. One of the gold
  records is location 0's dummy ($2F2F, $FFFF), which lies outside the map.
- **Taken chests.** `Map_LoadTreasureTiles` marks the tiles. For a chest
  already taken, it steps the layer-1 metatile $FE→$FF or $E0→$E1 on tiles
  whose HiBits bit 0 is set.

## Chests

A chest's taken state is one bit of `Treasure_Flags` (`$7F:0001`, 64 bytes,
`Treasure_FlagByteMask` $3F: 512 flags). Its number is its record's place in
`TreasureRom`: `(offset − word 0) / 4`, counted from `Map_TreasureRec0`
(`$1D06`, set from word 0 by `Map_LoadTreasureTiles`).

- **Readers and writers.** `re_workspace/tools/ct_chests.py check` proves it
  from ChronoRET's source and the code bytes. `Field_CheckTileInFront`
  (`$C0:1DF4`) is the opener: it reads and sets the bit (`LDA.l`/`STA.l
  $7F0001,X` at `$C0:1E3E` / `$C0:1E48`) and gives the item or gold
  (`JSL $C1:8003` services 1 and 4). `Map_TreasureTaken` (`$C0:A7BC`) reads it
  when a map loads. No event op among 142,702 instructions in the 461
  non-empty event packs addresses `$7F:0001–0040` (the lowest event address in
  that page is `$7F:0050`). The other code reading `$7F:0000,X` is the window
  tables and the Mode 7 scenes' save and restore of the whole page. So a
  renumbering needs no other rewrite.
- **Limits.** 512 records in all (the five redirect records and location 0's
  dummy take numbers too) and 128 in one list (`Map_TreasureIdx` keeps 7 bits;
  bit 7 is "none"). The ROM uses 249 records: 263 flags are left.
- **Placement.** The block stays in place while it fits. When it grows it takes
  free space right after it, or any free span in bank $F5 (the records are
  read from bank $F5). The ROM has no such span (bank $F5's only padding,
  `$F5:FE04`, 508 bytes, is too small and not next to the records), so the
  builder moves the smallest bank-$F5 MapProps pack this build does not write
  out to free space, byte for byte, repoints every `Map_PropsPtrs` entry naming
  it, and puts the records in its span. The old record span is reclaimed. The
  report's `treasureRom` gives the address, placement, records, flags left,
  chests renumbered and the moved pack (`evicted`).
- **Seen in the game's code.** On built ROMs, `Map_LoadTreasureTiles` and
  `Field_CheckTileInFront` run in ChronoRET's interpreter. An added gold chest
  and an added item chest set their new flags and give 200 G and the item. A
  removed chest's tile is no chest any more ($80). A later chest (location 449
  on) sets its moved flag. A taken chest gives nothing.

```
chronoforge maps chest list P [loc_026]
chronoforge maps chest add P loc_026 --at 20,20 (--item '$A5' | --gold 200 | --empty) [--index 1]
chronoforge maps chest move P loc_026 1 --at 21,20 [--item N | --gold G | --empty]
chronoforge maps chest remove P loc_013 0
```

## New locations

Eight location numbers are never loaded by the game: 448, 452–455 and 461–463.
`ct_chests.py unused-locations` proves each one:

- no exit names it;
- no event warp names it (ops $DC–$E1). The one warp with a computed number
  (`$E2` in event pack 361 at $023F) reads `$7F:0166`, which packs 324, 325
  and 337 set only to $01, $0C and $75;
- no world-map exit list names it (`C2SceneRom_ListPacks`, `$C6:FFC0`) and no
  world-map script word does;
- its record is the placeholder (MapProps 0, Tileset12 18, Tileset3 $FF,
  palette 75, no exits, no treasure), and its Events entry is not an event pack.

`chronoforge maps new-location P --from loc_029 --number 448 --entrance loc_028
--at 46,9 --to 6,6 --facing 11 [--list]` writes `maps/loc_448.map.json`, a copy
of the source with `rom.createdFrom` set, and adds an exit to the entrance map.

- **What it copies.** It copies the source's layers, tile properties,
  settings, header and exits, so the way back works. The record runs the
  source's event pack (its Events entry).
- **What is its own.** Its MapProps takes a free `Map_PropsPtrs` slot when
  built, and its chests are its own list, with flags of their own.
- **Refusals.** The build refuses a created location whose number is not one
  of the eight, or whose Events entry is not an event pack. It refuses an exit
  to one of the eight that this build does not create. It refuses an edit to
  one of the eight that was not created.
- **Seen in the game's code.** On the built ROM, `LocLoad_UnkA33B` loads 448
  exactly as the decode says and as location 29 loads (planes, HiBits, AttrA,
  AttrB, sizes, limits, TM/TS/CGADSUB), on MapProps entry 202. Location 28's
  `Map_TileExitIdx` puts the new exit on tile (46, 9), leading to 448.

## Listing maps in a build

`chronoforge maps rom-list P [id …] [--remove] [--base rom.sfc]` puts maps in
`rom.maps` (or takes them out) and prints the list. With `--base`, it runs a
dry build and prints the free space left, the TreasureRom placement, the flags
left, the moved pack and each listed map's chest flags, or the build's
refusal. Nothing is written. The Studio's **ROM Build Maps…** sheet shows the
same thing.

## Not map data

Save points, encounters and the chests' opening are event objects in the
location's event pack, not part of MapProps. The treasure records give only
the positions and contents. Placing and editing these belongs to the event
and scene tools ([Scene Director](scene_director.md)).

## Screens and the field's registers

`Ppu_ApplyMapScreens` (`$C0:A509`) writes the shadows `$0BD7`, `$0BD8` and
`$0BDF` to TM, TS and CGADSUB, and 0 to MOSAIC. `LocLoad_UnkA33B` sets those
shadows from `Screens` and `ColorMath`:

- TM = bits 0–2, plus bit 4 (OBJ) from bit 3;
- TS = bits 4–6, plus bit 4 from bit 7;
- with `Tileset3` = $FF, both are ANDed with $13 (layer 3 off).

The rest of the field setup is fixed. It is listed in
[PPU › Real locations](ppu.md#real-locations).

## The project

`chronoforge maps import` writes every location to `maps/loc_NNN.map.json`
(see [ctproj schema](ctproj_schema.md#mapsidmapjson)):

- the layers, each with its own size where it differs from layer 1;
- `tileProps`: HiBits, AttrA and AttrB as hex over layer 1's size;
- exits with span, direction and facing;
- the header (`location`) and the MapProps head (`settings`);
- treasure;
- a `rom` block that records where everything came from.

A reimport keeps a map's name and triggers.

## Evidence and checks

`ct_maps.py check` lists every claim, and `check --run` adds the run claims.

- **Source claims (92).** The ChronoRET source of 18 routines contains the
  instructions each field rests on (`asm_claims`). This also covers 74 named
  constants.
- **Code claims (17).** The ROM bytes at those routines match the source.
- **Data claims (19).** These cover table sizes and ranges, the 814 exits,
  the 244 treasure records, the five redirects, the five short maps, the
  locations without a Tileset3 or a layer-3 plane, and agreement with the
  ChronoRET data map.
- **Run claims (8).** `LocLoad_UnkA33B` and `Map_LoadTreasureTiles` run in
  ChronoRET's 65816 interpreter (`MapRunner`). Their WRAM equals the decode
  for **all 512 locations**: planes, triples, sizes, masks, limits, half rate,
  own steps, TM, TS and CGADSUB, the exit tiles, the treasure tiles, and the
  taken-chest metatiles (252 tiles). `Ppu_SetBgLayout` and
  `Ppu_ApplyMapScreens` run as well. The full run takes about 400 s.

Cross-checks between the two implementations:

- `chronoforge maps verify <rom> --project P` compares every imported map
  with a fresh Swift decode and runs the structural checks.
- `ct_maps.py verify-import P` checks the same import against the Python
  decode, field by field.
- Both pass on all 512 locations.

The tests:

- **ROM-free.** `CTMapsTests` and `test_maps.py` check the decoder against
  `Resources/maps/map_vectors.json`. These are synthetic tables that
  `ct_maps.py vectors` writes: 4 locations sharing 3 maps, with a layer-3
  plane, a half-rate layer 2, own steps, edge limits, a treasure redirect,
  wrapping exits and stale tiles.
- **With the ROM.** The tests import, verify and render every location.

## The editor (Studio › Maps)

- **Canvas.** The field picture at the camera, rendered by the PPU model at
  1–4× zoom.
  - Checkboxes switch BG1, BG2, BG3, sprites and colour math.
  - Drag (Pan tool) or scroll to move the camera.
  - Palette cycles and tile animations run live.
  - **Frame** sets how far layers 2 and 3 have drifted by their own step.
  - Treasure shows as a ring placeholder (OBJ) and as a circle in the overlay.
- **Collision.** The overlay shows:
  - plane 1 in dark blue, plane 2 in light blue, transition in gray and solid
    in pink;
  - half B over its part of the tile (slopes are drawn as a triangle, not
    their exact `Map_SlopeShift` profile);
  - stairs as lines, overhead tiles as **Z**, push tiles as arrows, and object
    walls as a red corner.

  The brushes set a level on half A or half B, a push, the overhead bits or
  the object-wall bit, or clear the flags.
- **Metatiles.** Pick a metatile from the tileset sheet (`t3` for BG3) and
  paint on the chosen layer, where that layer scrolls. Painting keeps HiBits
  bits 0 and 1 in step with the metatile's bit 8.
- **Exits.** Click a tile to select the exit on it, or click an empty tile to
  add one. Edit its position, span, direction, destination, arrival tile and
  facing.
- **Chests.** Click a chest to select it, or an empty tile to add one; drag a
  chest to move it. The form sets what it holds (an item, gold or nothing) and
  deletes it. Each chest shows the flag a build of the whole project gives it
  (`#235`), and the tool line counts the flags in use out of 512. A refusal
  (tile 0,0, a tile already used, 128 chests in a map, more than 512 flags, a
  map showing another location's list) goes to the status line.
- **Toolbar.** **List in ROM Build** puts the selected map in `rom.maps` (or
  takes it out). **New Location from…** makes a location the game never loads
  from it ([New locations](#new-locations)). **ROM Build Maps…** lists
  `rom.maps` and runs a dry build ([Listing maps in a build](#listing-maps-in-a-build)).
- **Launch arguments.** `--module Maps --select loc_448 --map-tool Chests
  --map-chest 0` opens the chest tool on a chest; `--map-sheet new-location`
  or `--map-sheet rom-list` opens a sheet; `--rom ct_clean.sfc` names the base
  ROM for the dry run (else the playback ROM).
- **Inspector.** It shows:
  - the tile under the pointer (metatiles, shape, levels, raw bytes, flags,
    exit);
  - the header, registers, scroll and treasure;
  - the structural checks.

  **Apply** saves the map.

The CLI renders the same pictures:

```
chronoforge maps render P loc_001 --out a.png [--frame N] [--camera X,Y] [--hide bg3,obj,math]
```

## Writing maps back

List the maps in `project.json`'s `rom.maps` and run `chronoforge rom build`
(see [ROM builder](rom_builder.md)). Each map is written over the location in
its `rom.location`; its `tileset` must be the one its location record loads.

1. **Repack.** The builder packs the head, planes and triples with
   `packProps` (runs for equal stretches of 2–256 triples), then compresses them
   with the original packer (lz11). An unedited map packs to its old bytes.
2. **Share.** Locations whose content still equals their base entry keep it.
   When all the locations sharing an entry are listed with the same new content,
   the entry is rewritten. When only some of them change, the changed ones take
   a free `Map_PropsPtrs` slot (202–255: pointer 0, no record names them; 54 in
   all) and their LocRom `MapProps` word is rewritten.
3. **Place.** A pack stays in its old span if it fits and no unchanged entry
   uses it; otherwise it goes into a reclaimed span or free space, never across
   a bank, and `Map_PropsPtrs` (`$F6:1E00 + 3·entry`) is repointed. The report
   lists each move under `relocations`.
4. **Exits.** The `ExitRom` block (513 offset words and every location's
   records) is rebuilt at once. It may grow into the confirmed padding that
   begins right where it ends (`$E5:1A44`, 1,468 bytes). Unused bits stay 0, as
   in every ROM exit.
5. **Treasure.** `TreasureRom` is rebuilt as a whole: its 513 offset words and
   every location's records, one list after another ([Chests](#chests)). Adding
   or removing a chest renumbers every later chest's flag. Two maps sharing one
   list must agree. The five redirects and location 0's dummy record are kept;
   a record on tile 0,0 (the redirect marker) is refused.
6. **Header.** The 14-byte LocRom record is written in place.

**Checks.** Validate (gate 4) runs the same checks before a build. After it,
`ct_rom_check.py` compares each reported map with the built ROM and every
unreported location with the clean ROM; `ct_maps.py verify-import --content`
decodes the built ROM against the project (the `--content` flag leaves out the
`rom` provenance, which a build moves); and the ROM's own `LocLoad_UnkA33B` and
`Map_LoadTreasureTiles` run on the built ROM in ChronoRET's interpreter
(`macos_studio/tools/verify_map_tileset_build.py`).

## Limitations

- **Slopes.** The painter draws slope shapes 2–$17 schematically; their exact
  per-row profiles (`Map_SlopeShift`) are not drawn.
- **Camera and own-step layers.** The camera is treated as the location's
  entry origin. The canvas does not follow an own-step layer's lag behind the
  camera after entry, only its drift with **Frame**.
- **Placeholders.** Sprites are ring placeholders for treasure only; event
  objects are not drawn.
- **World maps.** Exits to world maps point at `loc_496`+ records; the world
  maps themselves (mode 7 and the overworld tilesets) are not part of this
  slice.
- **No undo.** The Studio has no undo stack for painting: edits stay in the
  editor until **Apply**.
- **Old saves.** Renumbering changes which chests an existing save file has
  opened: a chest's taken state is its flag number, not its place.
- **New locations.** A created location runs its source's event pack (its own
  pack is a Scene Director slice), and only the eight numbers the game never
  loads can be created. A dummy that is loaded (both tilesets $FF: cutscene
  locations) is not one of them.
- **Chest opening.** The chests' graphics and the opening animation are the
  field's; the editor draws a ring placeholder.
