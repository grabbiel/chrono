# Sprites (Sprite & Animation Studio, slice 1)

The seven playable characters' sprite sets: their frames, tiles, animations and
palettes, decoded with evidence, imported into a project, edited in **Sprites**,
and drawn through the SNES PPU model ([PPU](ppu.md)). The Python reference and
every claim's check is `re_workspace/tools/ct_sprites.py`; the Swift twin is
`CTSprites.swift` (`CTSpriteROM`, `SpriteSheet`, `SpriteScene`).

No ROM data is stored in the repository: the import reads it from your ROM
into your project. `rom build` writes the sets back in place (see
[Writing back](#writing-back)). The enemies' battle sprites are decoded,
imported and written back too (see [Enemy sprites](#enemy-sprites)).

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
- Enemy sprites: `test_sprites.py` adds ROM-free tests (the literal-only
  Decomp stream, OBJ assembly, the synthetic enemies, the enemy vectors file)
  and local ones (source, code and data claims; the ROM's unpacker and frame
  decoder for five enemies). `CTEnemySpritesTests` checks the decode and the PPU
  scene against `enemy_sprite_vectors.json`, the OBJ assembly, the Enemies
  view's hook and (local ROM) the import of every enemy.
- Enemy write-back: `CTEnemySpritePatchTests` (synthetic image: no write for an
  unedited request, edits decode back, a pack that outgrows its span moves to
  free space, shared packs need every sharer, PC parts follow their set,
  refusals and the ROM-free checks, the Validator; local ROM: import then
  build is identical). `test_sprites.py` covers the sharer, measured-entry and
  span helpers. `macos_studio/tools/verify_enemy_sprite_build.py` is the
  real-ROM evidence ([Write-back](#write-back)).

## Limitations

- The playable characters' and the enemies' sets (layouts 0–2) are decoded and
  written back ([Enemy sprites](#enemy-sprites)); NPC sets are not decoded.
- The weapon colours (13–15) are not imported, and the import uses OBJ palette 0
  where the battle uses 5–7.
- `hitbox` and `weapon` are Studio metadata. They are not decoded from the game
  and not written to it.
- The write-back keeps each set's size and shape: no new tiles, frames or
  animation rows, and no shorter or longer lists.
- OBJ priority is per object, not per frame. The field gives an OBJ whose y
  offset is −24 or less (`Spr_UpperOfsY`) the object's "high" priority, and the
  others its "low" one. Both start at 2 (`EvtSpr_PrioInit`), which the import
  uses for every OBJ.
- The game's frames use no OAM flips: a facing's mirror is in its cells. The
  assembler allows flips, which the write-back refuses.
- No emulator run. The evidence is the ROM's code, data and its own decoder
  executed, not a booted game.
- The Studio pane is compiled; its logic is in Core and tested there.

## Writing back

`rom.sprites` in `project.json` lists the sprites `chronoforge rom build`
writes. This section is the playable characters' sets (`rom.family` `ct-pc`,
`CTSpritePatch`); enemy sprites (`ct-enemy`) are in
[Enemy sprites: write-back](#write-back). A set keeps its place and its shape:

1. **Checks.** The build refuses, before writing anything:
   - a set outside 0–6, a set listed twice, or a `rom` source that is not
     where the base ROM has the set (re-import);
   - a frame count other than the block's (no relocation in this slice);
   - a cell that is not a 16-bit word, uses bits 11–13, or names a tile at or
     above the set's tile count;
   - a frame that is not 4 16×16 OBJs at slot tiles 0, 2, 4, 6, an OAM flip
     (mirror the cells instead), a palette other than 0, a priority other
     than 2 (the game sets it), or an offset outside −128…127;
   - an animation without a row and facing, a row or facing outside the set's,
     one listed twice, `loop: false`, a duration outside 1–255, or a frame id
     at or above the frame count (or `$FF`, the field's end marker);
   - a palette that is not one of 16 BGR555 colours with 0 and 13–15 zero
     (colour 0 is transparent; 13–15 are the weapon's);
   - a sheet that is not 4bpp, has fewer tiles than the set, or paints tile 0
     (the blank cell: the battle draws zeros for it whatever it holds).
2. **Frames.** The 40-byte records are rewritten in place at `rom.frames`.
3. **Tiles.** The sheet's first `tileCount` tiles are re-encoded with
   `TileDecoder.encodePlanar`. Only the tiles that differ from the base ROM's
   are written, one write each.
4. **Animations.** Each animation sets its row's entries in its facing's
   frame-id row and in the shared duration row, over the base bytes. The rows
   are written back in place, one write per facing row and per duration row.
5. **Palette.** Colours 1–12 are written at `rom.palette`.

Then the set is decoded from the result (`CTSpriteROM.decode`) and must give
the sprite back: the same block ends, frames and animations. That is what
keeps an animation's shape: a list keeps its row's length and terminator (a
shorter list would need a zero duration the other facings would read too),
and the 4 facings of a row share its durations, so they must agree.

Only what changes is written, so an unedited import rebuilds the base ROM
byte for byte. The report's `sprites` entry gives the parts written, the
frames, animations and colours the set holds, its tile block's hash and the
changed tiles. Its `sharedWith` names the other sprite records (`$E4:F000`,
and the 10-byte `$E4:F600` records, whose first five bytes are laid out the
same way) that name a changed part, so they show the edit too: NPC records
use the PCs' palettes, and `$E4:F600` records 248–251 use Robo's and Magus's
tiles and frames. All-zero records are left out. `validate` checks
`rom.sprites` without the ROM: the ids exist, one per set, family `ct-pc`, and
the checks above that need no ROM.

Evidence (`macos_studio/tools/verify_sprite_build.py`, with the ROM):
- an import of all seven sets with every set listed rebuilds the clean ROM
  with no write;
- an edited build writes exactly the edited tile, frame records, frame-id
  row, duration row and palettes, and `ct_rom_check.py` accepts it: only the
  reported sets' blocks change, the pointer tables and sprite records do not,
  and each set decodes to the report;
- `ct_sprites.py verify-import --rom <built>` decodes the built ROM back to
  the edited project;
- the ROM's own frame decoder, `Battle_DrawBattlerFrameAnyLayout`, run on the
  built ROM, gives each edited frame from tiles encoded independently from
  the edited sheet (`ct_sprites.encode_tile`);
- seven damaged copies are rejected and twelve edits the format cannot carry
  are refused, with nothing written.

Growing a set (more tiles or frames) needs free-space relocation and pointer
updates in `$E4:2000/2300`; that is a later step.

## Enemy sprites

An enemy's battle sprite is a record of `RomE4_EnemySprRec` / `BattleRom_EnemySpr`
(`$E4:F600`, 10 bytes, one per enemy id 0–254). It names a graphics pack, a frame
set, a palette and an animation set in the PC tables above, plus a frame layout.

| Byte | Field | Reader |
|---|---|---|
| +0 | graphics: `$E4:2000` pointer index | `Evt_Op83_InitEnemySprite` (`$C0:46DF`): below `$F8` the pack is unpacked by `Decomp_ToWram` to `$7F`; from `$F8` up the ROM tiles are used as they are |
| +1 | frame set (`$E4:2300`) | `Battle_InitScene` (`$CC:E000`) by enemy id |
| +2 | palette (`$E4:0000` + 24 × p, 12 colours) | `Evt_Op83` to `Obj_PalSrc`; the battle takes it from the field object's attribute |
| +3 | animation set (`$E4:2600/2800`) | both, as for a PC |
| +4 | bits 0–1 frame layout (`Obj_SprSize`), bits 2, 3, 5, 7 flags | `FieldBtl_SaveObj` keeps the layout in `FieldBtlObj.Flags`; `Battle_InitScene` uses `Flags & 7` |
| +5…+9 | screen offset x, y, half width, height, move speed (bits 0–2) and delay (bits 4–7) | `Battle_InitScene` by enemy id |

Frame layouts (from `BattleRom_FrameLayout`, `FrameBytes` and `LayoutSprBytes`):

| Layout | Cells | Record | OBJs (16×16) | Enemies |
|---|---|---|---|---|
| 0 | 8 × 2 | 40 B | 4 | 150 |
| 1 | 16 × 2 | 80 B | 8 | 77 |
| 2 | 8 × 6 | 120 B | 12 | 25 |
| 3 | 96 × 1 | 240 B | 24 | 3 (111, 147, 215) |

A frame record is the cell words (as for a PC: bits 0–10 a tile, 0 blank, bit 14
mirrors) then one signed (x, y) pair per OBJ. OBJ n shows cells (2p, 2q),
(2p, 2q+1), (2p+1, 2q), (2p+1, 2q+1) with p, q = divmod(n, columns / 2): the OBJs
run along row pairs. This comes from the battle's DMA tables and OBJ records
(`BattleRom_SprTileListPtr`: slot s's OBJs start at `Battle_SprRec` record 4s;
layout 2 in slot 3 uses the fixed DMA words of `Battle_InitSceneGfx`, elsewhere
the row order of layout 5) and holds for layout 0 in all 8 enemy slots, layout 1
in slots 3, 5, 7 and 9 and layout 2 in slots 3 and 6. No slot gives layout 3 an
assembly, so those three records are not imported.

### Evidence

`ct_sprites.py check` matches `Evt_Op83_InitEnemySprite`, `FieldBtl_SaveObj`,
`Battle_InitScene`, `Battle_InitSceneGfx`, `Battle_DrawBattlerFrameAnyLayout` and
`BattleCF_BuildSprites` line by line in ChronoRET's source, the constants they
use, the ROM's code bytes at `$C0:46DF`, `$CC:E000` and `$CC:ED87`, and these
data claims: the layout table above; the 96 packs records 0–247 name unpack to
whole 4bpp tiles; records `$F8`–`$FF` name only PC tile blocks; palettes have
bit 15 clear; animation sets are below 255.

`check --run` runs, in ChronoRET's 65816 interpreter, the ROM's `Decomp_ToWram`
(`$C3:0557`) on all 96 packs (equal to the Python unpacker) and its frame decoder
(`$C1:1C55`) on every frame of the 114 distinct (graphics, frame set, layout)
sprites in layouts 0–2: 3015 frames, in slot 3 and, for layout 2, slot 6. Each
equals the decode. The run does not cover `Battle_InitScene` itself.

### Import

`chronoforge sprites import` (and the Studio's **Import Sprites from ROM…**)
writes `sprites/enemy_NNN.sprite.json` and `.png` for the 252 records of
layouts 0–2 (`--enemy N` for some only; `--set` alone imports no enemies):

- `rom.family` is `ct-enemy`, `rom.set` the enemy id, `rom.layout` the frame
  layout and `rom.packed` whether the tiles were unpacked.
- `stream` is columns × rows at OBJ tile `$40` (slot 3); OBJ n is a 16×16 at
  tile 32p + 2q, palette 0, priority 2.
- The palette is colour 0, the 12 ROM colours, then three zeros. The sheet holds
  the pack's tiles, 16 per row.
- `rom.packedBytes` is the pack's stream length (its in-place budget), and
  `battle` the record's fields: `flags` (byte +4 without the layout bits),
  `screenOffsetX`, `screenOffsetY`, `halfWidth`, `height`, `moveSpeed` and
  `moveDelay` (byte +9, bits 0–2 and 4–7).
- An enemy character (`enemy.enemyId`) without a `sprite` is linked to its sprite;
  the Enemies view shows the sprite's rest frame (its first animation's first
  frame) through the PPU model.

`ct_sprites.py verify-import` checks the import against `decode_enemy` for every
record. Packs shared by several enemies are copied into each sprite's sheet.

### Write-back

`rom.sprites` takes `ct-enemy` sprites too (`CTEnemySpritePatch`). They are
written after the PC sets, over the ROM as the PC write-back leaves it.

**Record readers.** A scan of the whole ROM for long-addressed reads of
`$E4:F6xx` finds two readers. `Evt_Op83_InitEnemySprite` (`$C0:46DF`) reads
+0 to +4 and masks +4 with 3. `Battle_InitScene` (`$CC:E000`) reads +1 and +3
to +9: it copies +4 whole into `Enemy_SprFlags`, which the battle tests for
`$04`, `$08`, `$20` and `$80`. Bits 4 and 6 have no reader (bit 6 is set in 26
records), so the build keeps them as the base ROM has them, along with the
layout bits. +5 to +8 are whole bytes (0–255). For +9, `AND #7` gives the speed
and four `LSR`s the delay; the move interval is
`BattleRom_EnemyMoveInterval[(delay / 2) × 4 + speed / 2]` (`$CC:F544`, 32
entries), so speed 0–7 and delay 0–15 stay inside the table. Bit 3 is not read
and is kept.

**What is written.** Each listed sprite is checked like a PC set (the frame
count, cells, OBJs at 32p + 2q, palette, animations, sheet tile 0) and then:

1. **Frames**: the frame records in place (40, 80 or 120 bytes each).
2. **Animations**: the frame-id and duration rows, as for a PC set.
3. **Palette**: colours 1–12 at `$E4:0000` + 24p.
4. **Record**: bytes +4 to +9 from `battle`, when it differs.
5. **Tiles**: the PC tile blocks of records `$F8`–`$FF` are written in place, one
   write per changed tile.

   Packed tiles (records below `$F8`) are re-packed with `LZSS.compress` in the
   pack's own mode. All 96 enemy packs are lz12, and the packer rebuilds each one
   byte for byte. The pack goes in place when it is no longer than the old
   stream (`packedBytes`). Otherwise it goes into free space (the confirmed
   padding, see [ROM builder](rom_builder.md)) and its `$E4:2000` pointer is
   rewritten as `$C0:0000 | pc`.

   A relocation is refused if it would change the measured end of any raw tile
   block: the PC sets 0–6, the graphics of records `$F8` and up, and the
   graphics of every non-empty NPC record (`$E4:F000` 7–255). A raw block's size
   is the distance to the next pointer in its bank. The old span is not
   reclaimed.

Cells past the graphics or with bits 11–13 are refused, unless the base ROM's
cell holds the same word: records 117 and 253 have such cells, and the build
leaves them unchanged.

Before any write, every sprite is decoded back from a scratch image of the
result (`CTEnemySprites.decode`, which uses the Swift `Decomp_ToWram`). The
decode must give the edited tiles, frames, animations, palette and record
fields. Only changes are written, so an unedited import rebuilds the base ROM
byte for byte.

**Sharing: every sharer is listed.** A part is one of a record's tile pack or
block, frame set, palette, animation set or record. Enemies share parts widely:
70 packs are named by more than one record, and records `$F8`–`$FE` show the PC
sets. The build lets an edit change a part only when everything that shows it
agrees:

- The PC sets' parts are the tiles, frames and animations of entries 0–6, plus
  the palettes their `$E4:F000` records name. If an enemy changes one of them,
  that PC set must be in `rom.sprites` with the same result, because the PC
  write-back is what writes it. Otherwise the build refuses: "belong to
  playable set c" or "differ from sprite X's as built".
- For any other part, every enemy record naming it (0–254, all-zero records
  included, since each id is an enemy the battle can show) must be listed with
  identical content, or the build refuses and names the sharers. An NPC record
  naming it blocks the edit. So do the layout-3 records (111, 147 and 215),
  which cannot be listed: their parts, such as palette 208, which records 110
  and 216 also use, stay frozen.

A PC write-back still changes the parts `$F8`–`$FE` show. The build does not
update those enemies' project files. Instead it lists each unlisted enemy
record that shows a changed PC part in `report.spriteWarnings`, and the CLI
prints those lines. The Validator warns when a listed `ct-pc` sprite has a
project `ct-enemy` sprite showing its parts that is not listed. Re-import after
the build to refresh them.

**Report.** `report.enemySprites` gives one entry per listed sprite:

- its id, record, layout and whether it was `packed` or `changed`;
- the graphics index, tile count, tiles' SHA-256 and changed tiles;
- `pack`: the address, `pc`, `packedBytes`, `budget`, unpacked size and hash,
  `placement` (`original` or `free`) and `from`;
- the frame set, frames and frame records;
- the animation set, frame ids, durations, rows and animations;
- the palette index and colours, and the record fields;
- `sharedWith`, its listed sharers.

Writes are named like `sprite enemy_059 graphics 90 pack`,
`sprite enemy_209 $E4:2000[205]`, `sprite enemy_059 frame 3`,
`sprite enemy_059 palette` or `sprite enemy_059 record`. `ct_rom_check.py` has
an enemy-sprite zone. It checks:

- that every reported record decodes to its claim from the built ROM;
- the `$E4:2000` pointers (only relocated ones moved);
- the measured ends;
- that relocated packs lie inside free space;
- that every unreported enemy decodes as before, unless it shows a changed PC
  part.

**Evidence** (`macos_studio/tools/verify_enemy_sprite_build.py`, with the ROM):

- **Identical rebuild.** An import of every sprite (259) with all of them listed
  rebuilds the clean ROM with no write.
- **Edited build.** Each edit's writes are exactly the expected ones:
  - enemy 59 (solo pack, re-packed in place);
  - enemy 209 (its pack grows past its span and moves from `$D7:BBB6` to free
    space);
  - enemies 51 and 52 together (pack 94, shared, grows and moves);
  - Magus (a PC edit that records 249–251 show, giving three warnings).

  `ct_rom_check.py` accepts the build.
- **Interpreter runs** in ChronoRET's 65816 interpreter on the built ROM:
  - `Decomp_ToWram` on every rewritten pack gives the edited tiles;
  - the frame decoder `$C1:1C55` on every frame of the edited sprites (slot 3,
    and slot 6 for layout 2) gives `expected_enemy_buffer` built from the
    edited sheet.
- **Refusals.**
  - The checker rejects eight damaged copies of the built ROM: a frame cell,
    the moved pack, a palette colour, an unread record bit, a record field, a
    write outside free space, the `$E4:2000` pointer and a duration row.
  - Fifteen edits the format or the sharing rule cannot carry are refused,
    with nothing written:
    - sharing: an unlisted sharer, a layout-3 sharer, an NPC sharer, a PC
      part;
    - record fields: the kept flag bits, a speed of 8, the layout bits;
    - cells: a cell past the graphics, bits 11–13, a misplaced OBJ, a short
      cell list, a missing frame;
    - the source: a stale `rom` source, layout 3, a painted blank tile 0.

`Battle_InitScene` itself is not run in the interpreter. The record fields are
checked by decoding the built bytes and by the reader ranges above.

**Studio.** For a `ct-enemy` or `ct-pc` sprite, the editor shows:

- a **Write to the ROM (rom.sprites)** toggle;
- for a packed enemy, the pack's size against its in-place budget (orange when
  the build will move it);
- the project sprites sharing its parts;
- for an enemy, the battle record's fields: steppers, and toggles for the
  `$04`, `$08`, `$20` and `$80` flags.

The sprite list has an All / PC / Enemy / Other filter. `--select <id>` and
`--family <name>` choose them at launch.

### Limitations

- The write-back keeps each record's size and shape: the same tile, frame and
  animation counts, layout and parts (no re-pointing a record to another pack
  or palette). Packs may grow into free space; frame sets may not.
- An edit to a shared part needs every sharer listed with the same edit
  ([Write-back](#write-back)). Parts that NPC records or layout-3 records show
  cannot change.
- An imported enemy sprite is a snapshot of the clean ROM. A PC write-back
  warns about records `$F8`–`$FE` (`spriteWarnings`) but does not update their
  project files.
- Layout 3 (records 111, 147 and 215) is not imported or written. No slot's DMA
  and OBJ tables give it an assembly.
- Records 117 and 253 have cells past their graphics. They show as blank in the
  Studio. In the game they read past the pack. Records 26, 27 and 254 have
  animations naming frames past the frame set; the import leaves those
  animations out.
- The battle's palette slot is not imported. Flag bits 4 and 6 and move bit 3
  have no reader and are kept as they are.
- A relocated pack's old span is not reclaimed.
- No emulator run: the evidence is the ROM's code, data and its own unpacker and
  frame decoder executed.
