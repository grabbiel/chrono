# Sprites (Sprite & Animation Studio, slice 1)

The seven playable characters' sprite sets: their frames, tiles, animations and
palettes, decoded with evidence, imported into a project, edited in **Sprites**,
and drawn through the SNES PPU model ([PPU](ppu.md)). The Python reference and
every claim's check is `re_workspace/tools/ct_sprites.py`; the Swift twin is
`CTSprites.swift` (`CTSpriteROM`, `SpriteSheet`, `SpriteScene`).

No ROM data is stored in the repository: the import reads it from your ROM
into your project. Writing sprites back to a ROM is the next slice (see the end).

## The data

Sets 0–6 are the playable characters, by character id (crono, marle, lucca,
robo, frog, ayla, magus). The battle and the field read them from the same
bank-`$E4` tables.

| Table | Address | Entry | Use |
|---|---|---|---|
| Tile pointers | `$E4:2000` | 3 B | Long pointer to the set's 4bpp tiles (32 B each). |
| Frame pointers | `$E4:2300` | 3 B | Long pointer to the set's frame records (40 B each). |
| Frame-id rows | `$E4:2600` | 2 B | Bank-`$E4` offset of the set's animation frame ids. |
| Duration rows | `$E4:2800` | 2 B | Bank-`$E4` offset of the set's animation durations. |
| Sprite records | `$E4:F000` | 5 B | Tiles, frames, palette, animation, size class. Records 0–6 are (c, c, c, c, 0). |
| Palettes | `$E4:0000` | `$18` B | Palette p at p × `$18`: 12 BGR555 colours, copied to colours 1–12. |

`RomE4_PtrInit` (`$E4:FFE0`) hands the field the same four table bases the battle
uses.

A set's blocks have no stored size. A block runs to the next higher pointer of
its table in the same bank, else to the bank's end. A frame block holds at most
256 records (a frame id is a byte), less trailing all-zero records: Robo's
block runs to the bank's end and is zero-filled after its last record. `check`
confirms these ends: every set's tile block ends exactly at the highest tile its
frames use, and every frame block ends at the highest frame id its animations
use.

### Frames

A frame record is 40 bytes:
- 16 tile words, 8 columns × 2 rows, row-major. Bits 0–10 are a tile of the
  set; tile 0 is a blank cell. Bit 14 mirrors the 8×8 tile left to right (each
  byte bit-reversed through `BitReverseTable`). The decoders test no other bit:
  bits 11–13 are never set, and bit 15 appears only in a few of Frog's cells.
- 4 (x, y) pairs of signed bytes: the offsets of the frame's four OBJs from the
  sprite's origin.

Both engines stream a frame's cells into a VRAM slot: row 0 to OBJ tiles
T…T+7 and row 1 to T+16…T+23. The four OBJs are 16×16 (OBSEL 0: 8×8 and
16×16), and OBJ n uses tile T + 2n, so it shows cells (0, 2n), (0, 2n+1),
(1, 2n), (1, 2n+1). T is 8 for battle slot 0 and for the field's leader (PC
slots 1 and 2 use 32 and 40). The lower OBJ is in front.

### Animations

A set has `rows` = (frame-id offset of set c+1 − that of set c) / 16 animation
rows of 4 entries, in each of 4 facings (0 up, 1 down, 2 left, 3 right).
- Entry k of row r, facing f: the frame id is at frame-id rows + f × 4·rows +
  4r + k.
- The duration is at duration rows + 4r + k; the 4 facings share durations.
- A list runs until a zero duration (both engines go back to the start) or a
  `$FF` frame id (the field's `Anim_EndMarker`). Until then it runs on into the
  next row.
- A duration counts field frames: the object pass runs once a frame. The battle
  waits duration / 5 (at least 1) of its two-frame upkeep passes.

Rows that start with a zero duration, and the rows holding only the `$FF`
marker, are empty and are not imported. Every non-empty list is imported as an
animation `r<row>.<facing>`, for example `r00.down`.

### Palettes

Sprite record c's palette byte selects 12 colours, which go to colours 1–12 of
the OBJ palette. The battle puts PC slots in OBJ palettes 5–7 (`Battle_PcPalette0`),
and puts the equipped weapon's colours in 13–15 (`BattleRom_WeaponColours`).

### Evidence

Each field has two readers in ChronoRET's matched source, and each source claim
is matched line by line. The ROM's code bytes confirm the operands, the data
invariants hold for all seven sets, and the ROM's own frame decoder runs as the
decode does.

| Field | Battle reader | Field reader | ROM checks |
|---|---|---|---|
| Table bases | `Battle_InitScene` (`$CC:E000`) reads `$E4:2000/2300/2600/2800` by set | `Field_InitLoadState` loads `RomE4_PtrInit`; `Evt_LoadSpriteRec` indexes them | The four `LDA.l $E4xxxx,X` in `$CC:E000`; `PtrInit` = the battle's bases; records 0–6 = (c, c, c, c, 0) |
| Record size | `Battle_DrawBattlerFrameAnyLayout` (`$C1:1C55`) multiplies the frame by `BattleRom_FrameBytes[0]` | `Obj_BuildFrame4` (`$C0:CBDC`) multiplies by `Frame4_Bytes` | FrameBytes[0] = 40; `LDA #$28; STA WRMPYB` in `$C0:CBDC` |
| Cells 8 × 2 | `FrameLayout.Width/Height` | 16 `Spr_CopyTile` calls, second row at `+$100` words | Layout 0 is 8 × 2 with rows at 0 and `$200`; `ADC #$0100` in `$C0:CBDC` |
| Tile, blank, mirror | `AND #!Battle_FrameTileMask`, blank cell for 0, `AND #!Battle_FrameHFlip`, `BitReverseTable` | `Spr_CopyTile` / `Spr_CopyTileFlipped` | `AND #$07FF`, `AND #$4000`, `LDA.l $C0FD00,X` in `$C1:1C55`; tile 0 blank in every set |
| OBJ offsets | `FrameExtraCount` pairs, sign-extended into `Battler_FrameExtra`; `BattleCF_DrawBattler` adds them to the base position | `SprTileSrc.OfsX/OfsY` | ExtraCount[0] = 8; `LDA #$FF` sign extension |
| OBJ tiles and size | `BattleRom_SprRecInit`: tile T + 2n, attribute `$2A/$2C/$2E`; `Battle_HiTableLarge4` (all large) | `SprTileSrc.Tile` = `Obj_VramTile` + 2n | Slots' first tiles 8, 32, 40; their DMA puts row 0 at T and row 1 at T+16; OBSEL 0 written by `Ppu_SetBgLayout` (field; the battle's OBSEL write is not in matched code) |
| OAM order | `BattleCF_CopySprTiles`: record k to OAM entry k | — | Left/right first frames of a row are mirror images in at least 80% of rows per set |
| Animations | `Battle_TickPcSlots` (`$C1:2D9F`): AnimId × 4, facing × stride, duration / 5 | `Obj_AnimFrameLookup`, `Obj_AnimTickAndQueue` | Frame-id blocks = 16 × rows; duration rows end before the next set's; all ids in range |
| Palette | `Battle_PcPalette0`, weapon colours to 13–15 | `Obj_PalSlotFixed`: 12 colours by `MVN` | 12 BGR555 words, bit 15 clear |
| Tile layout | — | — | SNES planar, planes 0/1 interleaved per row: Crono's tiles are about 3× as coherent vertically as under the plane-after-plane reading |

`ct_sprites.py check --run` also runs `Battle_DrawBattlerFrameAnyLayout` in
ChronoRET's 65816 interpreter for every frame of every set. The interpreter is
given the hardware multiplier, which it lacks. The run's tile buffer and offset
words equal `decode_frame` with the set's tiles, mirrored cells bit-reversed,
blank cells zero.

## In a project

`sprites/<id>.sprite.json` keeps its original fields. Optional fields describe
the game's format (see [project schema](ctproj_schema.md)):
- `palettes`: the OBJ palettes, 16 hex BGR555 words each;
- `stream`: the VRAM slot a frame's `cells` stream into;
- `rom`: where the import read the set;
- per frame: `cells`, `hitbox` and `weapon`;
- per OBJ: `priority`;
- per animation: `row` and `facing`.

Sheet tile k is OBJ tile k, so a 16×16 OBJ shows tiles N, N+1, N+16 and N+17.
That is why sheets are 16 tiles (128 px) wide. A streamed frame's OBJ `tile`
counts from its slot.

```
chronoforge sprites import <rom.sfc> --project <project.ctproj> [--set N ...]
chronoforge sprites show <project.ctproj | rom.sfc> [sprite | set] [--frame N] [--onion N] [--png out.png] [--scale K]
```

`import` writes `sprites/<name>.png`, an indexed 4bpp sheet of the set's tiles:
- 16 tiles per row;
- the PLTE is colour 0, the 12 ROM colours, then 3 zeros.

It also writes `sprites/<name>.sprite.json`:
- every frame: 4 OBJs at the decoded offsets, slot tiles 0, 2, 4, 6, 16×16,
  OBJ palette 0, priority 2, and the 16 cells;
- every non-empty animation;
- `stream` {8, 2, baseTile 8};
- the `rom` source.

A sprite already imported from the same set is replaced. Its frames keep their
`hitbox` and `weapon`. A character of that id without a sprite gets this one.

`show` lists a project's sprites, or describes one frame:
- its OBJs and cells;
- its budget: OAM entries, OBJ tiles, streamed tiles, worst line against 32
  OBJs and 34 slivers.

With `--png`, `show` renders the frame through `PPUReferenceRenderer`, cropped
to the frame's OBJs. From a ROM it decodes a set (by name or 0–6) without
importing it.

**Studio → Sprites.** **Import Sprites from ROM…** fills the project. For a sprite,
the editor has three parts.
- **Pixel canvas.** Paints the sheet's tiles with the indexed palette, shown as
  BGR555 swatches. A streamed frame's cell picker chooses each cell's tile and
  mirror. **Save Sheet** writes the PNG.
- **OAM assembler.** Shows the frame on the PPU at integer scale over the
  origin's anchor grid. OBJs can be dragged, added and removed. Each OBJ sets
  its tile, size (8×8 or 16×16), flips, palette and priority. A budget line shows
  VRAM tiles, OAM entries and the per-line limits.
- **Timeline.** Each animation's frames and durations in 60 Hz frames, with
  play, step and onion skin (the previous frame dimmed behind, in OBJ palette 7).
  Each frame has `hitbox` and `weapon` anchor fields.

Every preview is a `PPUFrame` drawn by `SNESPPUView`, so it shows what the
hardware would: OBJ order, 16×16 tile wrap, per-line limits and palettes.

## Tile layout fix

`TileDecoder` read plane p of row r at byte p × 8 + r, a plane-after-plane
layout that no SNES graphics use. It now reads byte 2r + (p & 1), plus 16 for
planes 2–3 (fullsnes; the layout `PPUFrame.storeTiles` writes). `encodePlanar`
was fixed the same way.

Impact:
- `render-tileset` (ROM smoke test) and `CTProject.tileIndices` now show
  ROM-extracted tile blobs correctly. They were scrambled before.
- No project file changes: nothing writes blobs with `encodePlanar`.
- The golden index files were regenerated by `tools/gen_fixture_assets.py` with
  the corrected reference. Their random blobs and every other fixture are
  byte-identical.

## Verification

- `re_workspace/tests/test_sprites.py` has two kinds of test:
  - ROM-free: tile layout, record codec, OBJ cell order, blank and mirrored
    cells, OAM front order, block ends, animation end rules, and the vectors
    file.
  - Local: every source, code and data claim; the ROM's frame decoder run
    against the decode for every frame; the same decoder fed the synthetic sets
    patched into a copy.
- `CTSpritesTests` has two kinds of test:
  - ROM-free: decode equals the Python vectors; the PPU scene draws the vectors'
    composed frames pixel for pixel; onion skin; PNG round trip; old files load;
    budget.
  - Local: the import validates, and the PPU shows imported frames as an
    independent composition of the decoded cells.
- `verify_all.sh` runs `check --run` and a CLI import checked by
  `ct_sprites.py verify-import`.

## Limitations

- Only the playable characters' sets are decoded. Enemy sprites (`$E4:F600`,
  10-byte records, other frame layouts) and NPC sets are not.
- The weapon colours (13–15) are not imported, and the import uses OBJ palette 0
  where the battle uses 5–7.
- `hitbox` and `weapon` are Studio metadata. They are not decoded from the game
  and not written to it.
- OBJ priority is per object, not per frame. The field gives an OBJ whose y
  offset is −24 or less (`Spr_UpperOfsY`) the object's "high" priority, and the
  others its "low" one. Both start at 2 (`EvtSpr_PrioInit`), which the import
  uses for every OBJ.
- The game's frames use no OAM flips: a facing's mirror is in its cells. The
  assembler allows flips, which the write-back will refuse for a streamed sprite.
- No emulator run. The evidence is the ROM's code, data and its own decoder
  executed, not a booted game.
- The Studio pane is compiled; its logic is in Core and tested there.

## Next slice: write-back (design)

`CTROMBuilder` gains a sprites step for the sprites listed in a new
`rom.sprites`. For each sprite with `rom.family == "ct-pc"`:
1. **Checks.** Refuse:
   - a set outside 0–6, or a frame count above the base block's;
   - a cell tile at or above the base tile count;
   - cell bits 11–13;
   - an OBJ that is not one of 4 16×16 OBJs at slot tiles 0, 2, 4, 6;
   - OAM flips or a palette other than 0;
   - offsets outside −128…127;
   - durations above 255, or a frame id at or above the frame count or equal to
     `$FF`;
   - more colours than 12 + 0.
2. **Frames.** Rewrite the 40-byte records in place at `rom.frames` (same
   count; no relocation in this slice).
3. **Tiles.** Re-encode the sheet's first `tileCount` tiles with
   `TileDecoder.encodePlanar` over the base block. Only changed tiles are
   written, each as its own write.
4. **Animations.** Write the frame-id and duration rows back in place. A list
   must keep its row's length and terminator, so the shape of the rows cannot
   change yet.
5. **Palette.** Write colours 1–12 at `rom.palette`.

Growing a set (more tiles or frames) needs free-space relocation and pointer
updates in `$E4:2000/2300`. That is a later step, as are enemy sprites.
