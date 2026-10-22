# Maps (Multi-Plane Map Editor, slice 1)

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
  ROM into your project. Writing maps back to a ROM is designed at the end of
  this page but not built.

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

## Writing maps back (next slice, design only)

`CTROMBuilder` does not write maps yet. The plan:

1. **Repack.** Pack each changed map's head, planes and triples with
   `packProps`, which uses runs for equal stretches of 2–256 triples, then
   LZSS-compress it in the entry's mode. A map that no longer ends early has
   `staleTiles` = 0.
2. **Share.** Locations that share a MapProps entry share the edit. A map
   edited away from its sibling needs a new entry: `Map_PropsPtrs` has 256
   slots and the ROM uses 197 of the first 201.
3. **Relocate.** Keep an entry in place if it fits there. Otherwise move it to
   free space reachable by the 24-bit pointer, and repoint `Map_PropsPtrs`
   (`$F6:1E00 + 3·entry`), then the `MapProps` word in each LocRom record that
   uses a new entry.
4. **Exits and treasure.** Rewrite the `ExitRom` and `TreasureRom` record
   blocks for all locations at once, since they are contiguous with word
   offsets. Recompute the 513 and 512 offset words. Keep redirects, and keep
   location 0's dummy record.
5. **Header.** Write the LocRom record (14 B) in place.
6. **Verify.** Run the interpreter checks (`check --run`) against the built
   ROM.

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
