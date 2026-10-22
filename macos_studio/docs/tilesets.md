# Tilesets (Tileset & Asset Workshop, slice 1)

Chrono Trigger's location tilesets: the graphics a location puts in VRAM, its
16×16 metatiles, its palette, and the tile and palette animations the field
runs. They are decoded with evidence, imported into a project, edited in
**Tilesets**, and drawn through the SNES PPU model ([PPU](ppu.md)). The Python
reference and the check for every claim is `re_workspace/tools/ct_tilesets.py`.
The Swift twin is `CTTilesets.swift` (`CTTilesetROM`, `CTTilesets`,
`TilesetScene`, `TilesetPlayer`, `PaletteCycler`, `TileAnimator`,
`TilesetBudget`).

No ROM data is stored in the repository: the import reads it from your ROM into
your project. Writing tilesets back to a ROM is the next slice (see the end).

## What a location picks

A location's `LocRom` record (`$F6:0000`, 512 × 14 B) holds three independent
values:

| Byte | Field | Loads |
|---|---|---|
| +1 | `Tileset12` | Layers 1/2: a pack list, a `Map_Meta12` table, and (`& $3F`) a tile-animation list. |
| +2 | `Tileset3` | Layer 3: one graphics pack and a `Map_Meta3` table. |
| +3 | `Palette` | Colours 1–15 of CGRAM rows 1–7, and a palette-animation list. |

`$FF` in `Tileset12` or `Tileset3` loads nothing. The ROM uses 53 `Tileset12`
values (0–53, all except 16), 18 `Tileset3` values (0–18), and 83 palette
sets. These are the project's `t12_NN`, `t3_NN` and `pal_NN`.

## Graphics

| Table | Address | Entry |
|---|---|---|
| `LocGfx_Lists` | `$F6:1C00` | 8 pack numbers per `Tileset12` (`$FF` = none). |
| `LocGfx_PackPtrs` | `$F6:2220` | 224 long pointers to Square-LZSS packs. |
| `LocGfx_Meta12Ptrs` | `$F6:2100` | 64 long pointers to lz11 tables of 512 metatiles (4096 B). |
| `LocGfx_Meta3Ptrs` | `$F6:21C0` | 32 long pointers to lz11 tables of 256 metatiles (2048 B). |

`LocLoad_Unk0960` (`$C0:0960`) loads layers 1 and 2:

- **Packs 0–5.** Each is unpacked to one stage at `$7E:3000`. Then the first
  `$1000` bytes of the stage are sent by DMA to VRAM word `$2000 + $800·k`
  (`$0F80` bytes for pack 5).
- **Short packs.** A pack shorter than its upload sends the rest of the stage,
  which is what an earlier pack of the list left there. This happens for
  `(Tileset12, slot)` = (29, 4) and (52, 5); both have an earlier pack below
  them.
- **Packs 6 and 7.** These go to `$7F:6000` and `$7F:7000` and are never
  uploaded. They are the tile animations' frames.

`LocLoad_Unk6DCF` (`$C0:6DCF`) unpacks the `Tileset3` pack to `$7F:5080` and
sends `$1000` bytes from there to VRAM `$5000`.

The field runs mode 1 with BG3 at high priority (`Ppu_SetBgLayout`,
`$FD:C0D7`). BG1/BG2 characters start at VRAM word `$1000` (BG12NBA `$11`) and
BG3's at `$5000` (BG34NBA `$05`):

- BG1/2 character *n* (4bpp) is at `$1000 + 16n`, so packs 0–5 fill
  characters 256–1019.
- BG3 character *n* (2bpp) is at `$5000 + 8n`, so its pack fills characters
  0–255.

Characters a tileset does not set hold whatever VRAM held before. Across all
2,585,344 map cells of the 495 locations with layers 1/2, 99.99% name only
characters their tileset sets. The rest are listed by `check`.

## Metatiles, and the bit order

A `Map_Meta12` or `Map_Meta3` entry is four 16-bit words: top left, top right,
bottom left, bottom right.

**Bit order (settled).** The word is the SNES tilemap word:

| Bits | Meaning |
|---|---|
| 0–9 | character |
| 10–12 | palette |
| 13 | priority |
| 14 | H flip |
| 15 | V flip |

The evidence is the code that builds the tilemap:

- `Map_WriteRow1` (`$C0:7612`) takes a map cell's metatile number × 8 as an
  index into `Map_Meta12TL`/`TR`, and writes the words byte for byte through
  WMDATA into `Map_BufC800`.
- `Map_WriteRow3` does the same for layer 3.
- `Map_UploadBuf_Tail` sends `Map_BufC800` to the VRAM tilemap with DMA mode 1.

Nothing between the table and VRAM touches bits 13–15, so they mean what the
PPU says they mean. The manifest's reading (13 = H flip, 15 = priority) is
wrong; the manifest itself was not edited.

**No 32×32 blocks.** A map holds one byte per 16×16 cell, and that byte indexes
the metatile table directly. For layers 1/2, `Map_TileHiBits` supplies bit 8.
There is no 32×32 block layer. `check` confirms that every map cell parses as a
metatile number below 512 (layers 1/2) or 256 (layer 3).

## Palettes

`LocPal_Rom` (`$F6:24C0`) holds 88 sets of 210 B. `LocLoad_Unk7084`
(`$C0:7084`) copies set *p*'s seven 30-byte rows to colours 1–15 of CGRAM rows
1–7 (`Pal_LocRows`, `$7E:2022`). Row 0 and colour 0 of each row are not the
location's.

## Animation

**Tile animations** come from `FieldAnimListA` (`$FD:F310`), whose 64 lists are
picked by `Tileset12 & $3F` through `$FD:F290`. A list holds 12 records. Each
record is one of:

- `$80`: an empty record;
- a full record: a kind, a VRAM word address, then the step bytes and the
  source words. The kind sets the frame count: 2 → 2, 4 → 4, anything else → 8.

`FieldFD_LoadAnimSetA` (`$FD:DE98`) writes 32 bytes per record at `$7F:0400`.
`FieldFD_UploadTileAnims` (`$FD:E022`) then works as follows:

1. Each record runs every other call.
2. It sends `$80` bytes (4 characters) from bank `$7F` to its VRAM address.
3. The frame is accumulator bits 9–11.
4. The accumulator then adds 4 × the frame's step.

Tileset 37 animates without a pack 6 or 7. Its frames are whatever an earlier
location left in bank `$7F`.

**Palette animations** come from `FieldAnimListB` (`$FD:FA77`), picked by the
palette through `$FD:F9C7`. Each list has 6 records. `PalAnim_TickAll`
(`$FD:E39C`) runs every frame:

1. Each record's counter goes up by one.
2. When the counter equals its `delay`, the record acts and the counter resets.
   A delay of 0 acts every 256 frames.

The kinds the locations use:

| Kind | Name | Effect |
|---|---|---|
| 1 | `rom-frames` | Copies frame *k* (`count` colours from `$F6:offset`) over colours `first…`. *k* runs 0 … low nibble. |
| 8 | `list-frames` | The same, but *k* comes from a byte list after the record. |
| 2 | `rotate-down` | Rotates colours `first … first+count` (count + 1 colours) by one; each takes the one above. |
| 3 | `rotate-up` | The same; each takes the one below. |

The ROM's location lists hold kind 1 ×30, 2 ×34, 3 ×8 and 8 ×34.

## In the project

The import (`chronoforge tilesets import`, or **Import Tilesets from ROM…** in
the Studio) writes three kinds of entry:

- **`t12_NN`** (`kind` "bg12", 4bpp). Its sheet is the whole BG1/2 character
  window, so sheet tile *k* is character *k* (1024 tiles, 16 per row). Tiles
  the tileset does not set are blank. It also gets 512 metatiles, `vram.slots`
  (the six uploads, with pack, source and own tiles) and `vram.known` (the
  characters it sets). If the list has packs 6/7, it also gets
  `tileAnimations` and `animSheet` (`$7F:6000–$7FFF`, 256 tiles).
- **`t3_NN`** (`kind` "bg3", 2bpp). The same for the BG3 window: 256
  metatiles.
- **`pal_NN`** (`kind` "palette"). `palettes` (8 rows × 16 hex words) and
  `paletteCycles`. A palette entry is its own tileset entry because the game
  picks the palette apart from the graphics.

`preview` links a `t12` entry to the palette and layer-3 set its locations use
most. `rom` records where the import read each entry. The JSON is in the
[schema](ctproj_schema.md#tilesetsidtilesetjson).

The import needs the unmodified US 1.0 ROM (the SHA-256 check the other imports
use). A reimport keeps each tileset's `collision`.

## CLI

```
chronoforge tilesets import <rom.sfc> --project <p.ctproj> [--t12 N ...] [--t3 N ...] [--pal N ...]
chronoforge tilesets show <p.ctproj> [id] [--palette pal_NN] [--frame N] [--png out.png] [--scale K]
chronoforge tilesets verify <rom.sfc> --project <p.ctproj>
```

- `show` lists the entries, with their VRAM budgets. Given an id, it prints the
  slots, known characters, animations, cycles and ROM provenance.
- `show --png` draws all the metatiles through the PPU reference renderer at
  field frame N, with palette cycles and tile uploads advanced.
- `verify` checks the project against a fresh decode.

## Studio (Module 3)

- **Metatiles.** The tileset is shown on `SNESPPUView` with its preview
  palette, with both animations running as the field runs them: cycles every
  frame, a tile upload every other frame. The scroll wheel moves through the
  metatiles. The composer picks a metatile and a quadrant, then a character
  from the bank, and sets the quadrant's palette, priority and flips. It shows
  the resulting tilemap word.
- **Tile bank.** This reuses the sprite canvas (`SheetPicker`, `TilePainter`)
  in any CGRAM row. The VRAM budget bar marks, for each of the 1024
  characters, whether the tileset sets it, the upload sends stale stage bytes,
  or an animation rewrites it. The bar also lists the slots and counts the
  characters the metatiles name that the tileset does not set.
- **Animation.** Edits each tile animation's frame steps and shows its frames.
- **Palette entries.** Open a CGRAM row editor (5-bit channels) and the cycle
  editor (kind, range, delay, frame order), previewed live on a tileset that
  uses the palette.
- **Launch arguments.** `--open <p.ctproj> --module Tilesets --select t12_02`
  opens straight onto an entry.

## Evidence

`ct_tilesets.py check` holds 91 claims, all confirmed against ChronoRET
`af992bd`:

- **Routine order.** Each routine below contains the listed instructions in
  order:

  | File | Routine (line) |
  |---|---|
  | `asm/bankC0/bankC0.asm` | `LocLoad_Unk0960` (7538), `LocLoad_UploadPack` (7690), `LocLoad_UnpackPacks67` (7731), `LocLoad_Unk09DD` (7608), `LocLoad_Unk0A14` (7647), `LocLoad_Unk6DCF` (7794), `LocLoad_Unk7084` (7889) |
  | `asm/bankC0/bankC0.asm` | `Map_WriteRow1` (16461), `Map_WriteRow3` (17564), `Map_UploadBuf_Tail` (17886) |
  | `asm/bankFD/bankFD.asm` | `Ppu_SetBgLayout` (3394), `FieldFD_LoadAnimSetA` (6915), `FieldFD_UploadTileAnims` (7142), `FieldFD_LoadAnimSetB` (7471), `PalAnim_TickAll` (7629), `PalAnim_CopyRomFrame` (7735), `PalAnim_RotateUp` (7851), `PalAnim_RotateDown` (7901) |

- **Constants.** 34 constants in `constants_engine.inc`, `ram_engine.inc` and
  `hardware.inc`.
- **Code bytes.** The operands above, read from the ROM's own code: the ×8 and
  `$1C00` list index, the six VRAM addresses and `$0F80`, `$5000`/`$1000`, the
  metatile destinations, the `$D2` palette stride and the 30-byte rows,
  BG12NBA `$11` and BG34NBA `$05`, the WMDATA writes, the list addresses, the
  `$0E00` frame mask with the `$80`-byte upload, and bank `$F6` colours.
- **Data, ROM-wide.**
  - Every used pack and metatile table unpacks, with the packed size, unpacked
    size and mode that ChronoRET's `data_assets.csv` gives.
  - No list names a pack in slot 7.
  - The short packs are listed.
  - Every animation record's target is a 16-word-aligned BG1/2 character, and
    its frames lie inside the unpacked packs 6/7 (tileset 37 excepted, above).
  - The animation lists end before the next table.
  - Every location palette animation stays inside rows 1–7.
  - The maps parse as metatile numbers, and the character-coverage figures
    above hold.

`check --run` adds 4 claims, which run the ROM's own routines in ChronoRET's
65816 interpreter (with the multiplier and WMDATA port modelled):

- `Decomp_ToWram` (`$C3:0557`) gives the same bytes as this decoder for 71
  metatile tables and 202 graphics packs.
- `FieldFD_LoadAnimSetA` gives the same records and `$7F:0400` data for all 64
  sets.
- `FieldFD_LoadAnimSetB` gives the same records for all 88 sets.
- `PalAnim_TickAll` gives the same CGRAM as `CycleState` over 1920 ticks.

95 of 95 hold; the run takes about 3 minutes.

The Swift decode matches the Python vectors (synthetic tilesets in the real
tables' places) on every field. `TilesetScene` is checked pixel by pixel
against a direct decode of the tilemap words: on the vectors, and with the
local ROM on t12_02, t12_37 and t3_00. On the ROM, `tilesets verify` passes
154 of 154 and `ct_tilesets.py verify-import` 207 of 207 on a CLI import.

## Limits

- The sheets hold only what the tileset sets. In the game, characters 0–255
  of BG1/2 (and anything past a short BG3 pack) hold other data, which the
  preview draws blank.
- CGRAM row 0 is not a location colour. The preview fills it, and any row a
  palette entry lacks, with a gray ramp.
- Collision (`Map_TileProps`' other planes), map import and the overworld
  tilesets are not part of this slice.
- The fade kinds 4–7 of `FieldAnimB` are not used by location lists. They are
  named but not simulated.

## Next slice: writing back

This is a design only; the ROM builder (`CTROMBuilder`) belongs to the other
worker.

1. **Palettes.** Each 210-byte set is written in place (fixed size). A cycle
   list rewrite stays in place if its length is unchanged. Otherwise the list
   moves within bank `$FD` (16-bit offsets from `$FD:FA77`, before `$FD:FF29`),
   and its `$FD:F9C7` entry is repointed. Kind 1/8 frames go to bank `$F6`.
2. **Metatiles.** Pack lz11 with a real packer. Keep a table in place when it
   fits its old packed size; otherwise use free space and repoint the
   `$F6:2100` / `$F6:21C0` entry.
3. **Characters.** Map each edited character to the slot and pack that own it
   (`vram.slots[].ownTiles`). Rebuild the pack's bytes with the planar encoder
   (`TileDecoder`), repack it in its original mode, and repoint its
   `$F6:2220` entry.
   - Packs are shared between lists. A pack edited differently by two
     tilesets must be forked into a free pack number, and the list
     (`$F6:1C00`) updated; otherwise the import must refuse.
   - Stale-tail characters (past `ownTiles`) cannot be written back through
     their slot.
4. **Tile animations.** Record steps and frames are rewritten in place in
   `FieldAnimListA`. Frame pixels go back into packs 6/7 by the same rule as
   characters.
5. **Interface.** A `CTTilesetPatch` returns (address, bytes) edits and
   free-space requests for `CTROMBuilder`. The built ROM is then checked by
   `ct_tilesets.py verify-import` and `check` against the project, as the
   sprite and character slices do.
