# SNES PPU: CPU reference and Metal renderer

ChronoForge draws SNES pictures in two ways:

- `PPUReferenceRenderer` in `ChronoForgeCore/SNESPPU.swift` is pure Swift. It is
  the ground truth.
- `PPURenderer` in `ChronoForgeMetal/PPU.swift` runs on the GPU at 60 FPS.

Both read the same hardware-shaped input, a `PPUFrame`. They must produce
identical RGBA8 bytes, and the tests below enforce that.

The rules come from written documentation only, not from emulator code:

- nocash **fullsnes**: [problemkaputt.de/fullsnes.htm](https://problemkaputt.de/fullsnes.htm),
  "extracted from no$sns v1.5". We use its "SNES PPU …" chapters and the
  "Background Priority Chart".
- **SNESdev Wiki**, at these revisions:
  - [PPU registers](https://snes.nesdev.org/w/index.php?oldid=1507) (rev 1507)
  - [Backgrounds](https://snes.nesdev.org/w/index.php?oldid=1244) (rev 1244)
  - [Sprites](https://snes.nesdev.org/w/index.php?oldid=1204) (rev 1204)
  - [Color math](https://snes.nesdev.org/w/index.php?oldid=1387) (rev 1387)
  - [Timing](https://snes.nesdev.org/w/index.php?oldid=1467) (rev 1467)
  - [Windows](https://snes.nesdev.org/w/index.php?oldid=1167) (rev 1167)

## Input: `PPUFrame`

| Field    | Contents |
|----------|----------|
| `vram`   | 32K words. Word addresses wrap at 15 bits. |
| `cgram`  | 256 BGR555 words. Bit 15 is ignored. |
| `oam`    | 544 bytes: 128 four-byte entries, then the 32-byte high table. |
| `lines`  | One `PPURegisters` per visible line: 224 lines, or 239 with SETINI overscan. |

`lines` is the per-scanline register table, the state that HDMA produces. Every
register can change on every line. Index `i` is the state in effect while
visible line `i` is drawn.

`PPURegisters` stores what the CPU write ports produce:

- the BG scroll values after both writes;
- the fixed color that COLDATA writes build up (`writeCOLDATA` applies the
  channel-select bits);
- the character-base nibbles (`writeBG12NBA` and `writeBG34NBA` set them).

The registers are INIDISP, OBSEL, BGMODE, BGnSC, BG12NBA/BG34NBA, BGnHOFS/VOFS,
TM, TS, the window registers (W12SEL, W34SEL, WOBJSEL, WH0–WH3, WBGLOG,
WOBJLOG, TMW, TSW), CGWSEL, CGADSUB, COLDATA and the OBJ priority rotation
(`objFirst`).

## Rules and evidence

Each rule below names the CI test that checks it with hand-derived pixels. The
tests are in `Tests/ChronoForgeCoreTests/SNESPPUTests.swift`.

### Lines and the hidden first scanline

Visible line `i` is scanline `i + 1`. The Wiki says scanline 0 is hidden
(*Timing*; *PPU registers*, BGnVOFS: "the first line of rendering is always a
blank line").

- **BG:** a BG reads row `i + 1 + VOFS`, so with VOFS 0 the top BG row is hidden.
- **OBJ:** OBJs "appear 1 line lower than their Y value", so an OBJ at Y covers
  lines Y … Y+h−1 (*Sprites*).

Tests: `testTileFlipsPaletteAndHiddenFirstLine`, `testOBJYWrapPartialLeftAndFirstLine`.

### Tiles and tilemaps

These follow fullsnes "SNES PPU Video Memory (VRAM)" and "SNES PPU BG Control".

- **Planar tiles.** Planes 0 and 1 share one word per row: the low byte is
  plane 0 and bit 7 is the leftmost pixel. Planes 2 and 3 sit eight words later.
  A 2bpp tile is 8 words; a 4bpp tile is 16. Color 0 is transparent.
  `PPUFrame.storeTiles` writes this layout. (Test:
  `testPlanarTileLayoutFollowsFullsnes`.)
- **Tilemap entries.** An entry holds the tile in bits 9–0, the palette in
  12–10, the priority in 13, the X flip in 14 and the Y flip in 15.
- **Screen base and size.** The BGnSC base is in 1K-word steps. The size is one
  of 32×32, 64×32, 32×64 or 64×64 tiles, laid out as `SC0 SC1 / SC2 SC3`.
- **Character base.** It is in 4K-word steps.
- **Scroll.** Scroll registers are 10 bits, and tile coordinates wrap at 64
  tiles. (Test: `testScrollWrapsAndScreenSizes`.)
- **16×16 BG tiles.** These are BGMODE bits 4–7. They use tiles N, N+1, N+16 and
  N+17, with carry, and the flips swap the halves. (Test:
  `testSixteenPixelTilesUseNPlus1AndNPlus16`.)
- **Mode 1** draws BG1 and BG2 at 4bpp (CGRAM `pal*16+c`) and BG3 at 2bpp
  (`pal*4+c`).
- **Mode 0** draws four 2bpp BGs. BG n uses CGRAM `n*32 + pal*4 + c` (*Backgrounds*,
  Mode 0; fullsnes "CGRAM Palette Indices").

### Priority

These ranks come from the fullsnes "Background Priority Chart". The Wiki's
*Backgrounds* priority table and its BGMODE row agree.

| Setting | Front → back |
|---|---|
| Mode 1, BG3 bit clear | S3 1H 2H S2 1L 2L S1 3H S0 3L |
| Mode 1, BG3 bit set ($2105 bit 3) | **3H** S3 1H 2H S2 1L 2L S1 S0 3L |
| Mode 0 | S3 1H 2H S2 1L 2L S1 3H 4H S0 3L 4L |

The tests place every pair of slots from different layers in its own 8×8 block,
and the front slot must show:

- `testMode1PriorityOrder`
- `testMode1BG3PriorityBitMovesOnlyHighBG3TilesToTheFront`
- `testMode0PriorityOrder`

`testMode1BG3PriorityBitPerLine` changes the BG3 bit mid-frame.

### OBJ

These rules come from fullsnes "SNES PPU Sprites (OBJs)" and the Wiki's
*Sprites* page.

- **OAM fields.** An entry holds X (9 bits; the high bit is in the high table),
  Y, the tile (9 bits), the palette (pixels use CGRAM `128 + pal*16 + c`), the
  priority, the flips, and the small/large bit. OBSEL selects the size pair
  (including the undocumented settings 6 and 7 that fullsnes lists), the base
  (8K-word steps) and the gap (tiles 100h and up start `(gap+1)*4K` words after
  the base).
- **Tile numbering.** Tiles inside a large OBJ use N+1 to the right and N+16
  downward, with no carry between nibbles (fullsnes "16x16 (and bigger) Tiles").
  Tests: `testOBJSizesFlipsAndNameWrapping`, `testOBJNameSelectGap`.
- **Draw order.** Within the OBJ layer, the lowest OAM index (after rotation) is
  in front, whatever its priority. That OBJ's priority then decides OBJ versus
  BG, so a low-priority OBJ can hide a higher-priority one behind the BG
  ("cookie cutter").
- **Priority rotation.** It makes `objFirst` the front OBJ (fullsnes OAMADDH
  bit 7). Test: `testOBJOrderCookieCutterAndRotation`.
- **32 OBJs per line.** The PPU takes the first 32 in-range OBJs in priority
  order and drops the rest. An OBJ at X = −256 counts although it is not
  visible. Test: `testThirtyTwoOBJsPerLine`.
- **34 slivers per line.** The PPU evaluates the kept OBJs in reverse, each one
  left to right on screen. Only on-screen 8-pixel slivers count, except that all
  slivers of an OBJ at X = −256 count. When the limit is reached, the rest are
  dropped, so low-index OBJs lose their right side first. Test:
  `testThirtyFourSliversCountedFromTheLastOBJ`.
- **Y wraps** at 256 (fullsnes OBSEL caution).

`PPUOBJEvaluator.evaluate` produces each line's sliver list, front to back.
Both renderers use it. Its output and the pixels drawn from it are tested here.
The Metal kernel decodes the sliver pixels from VRAM itself.

### Main and sub screens, color math

These rules come from fullsnes "SNES PPU Color-Math" and the Wiki's
*Color math*, CGWSEL and CGADSUB.

- **Layer selection.** TM and TS enable layers on the main and sub screens. Each
  screen shows its front-most opaque pixel. The main screen falls back to the
  backdrop, CGRAM 0. The sub screen falls back to the fixed color (COLDATA).
- **Math enable.** CGADSUB bits 0–5 enable math for the layer the main pixel came
  from. OBJs use math only with palettes 4–7 on the main screen. On the sub
  screen, any OBJ palette is an addend.
- **Addend.** CGWSEL bit 1 selects the addend: the sub screen, or the fixed color.
  fullsnes calls the same bit "Sub Screen BG/OBJ Enable (0=Backdrop only)".
  With it clear, the sub screen is only its backdrop, the fixed color, so the two
  descriptions have the same effect.
- **Arithmetic.** For each channel, the PPU adds or subtracts, optionally halves,
  then clamps to 0…31. Subtraction below 0 gives 0.
- **When half is skipped.** Half is skipped on pixels where the main screen is
  forced black. It is also skipped when the sub-screen addend is selected and the
  sub screen is transparent (fixed-color backdrop). With the fixed-color addend,
  half applies.
- **CGWSEL regions.** These are the main "force black" region (bits 7–6) and the
  math-prevent region (bits 5–4), each meaning nowhere, outside the color window,
  inside it, or everywhere. With no color window enabled, every pixel is outside
  it (Wiki CGWSEL). fullsnes names bits 5–4 "Color Math Enable" (0=Always,
  1=MathWindow, 2=NotMathWin, 3=Never); the Wiki names them the sub-screen
  "transparent region" that masks math. Both map the four values the same way.
- **Forced black.** A forced-black main screen keeps its layer identity, so math
  still applies to it.

`testColorMathPerLine` checks 19 configurations, one per line:

- clamp, half, subtract, and subtract with half;
- the fixed color with and without half;
- a transparent sub screen;
- per-layer enables;
- every CGWSEL region value;
- backdrop math;
- a layer combined with itself.

`testOBJMathOnlyForPalettes4To7OnMain` covers the OBJ palette rule.

### Windows

These rules come from the Wiki's *Windows* page and its PPU registers window
section; fullsnes "SNES PPU Window" agrees.

- **Window edges.** Window 1 is WH0…WH1 and window 2 is WH2…WH3, both edges
  inclusive. A window whose left edge is greater than its right edge covers
  nothing.
- **Per-area settings.** Each area (BG1–BG4, OBJ, and the color window) has, per
  window, an enable bit and an invert bit (W12SEL, W34SEL, WOBJSEL). A disabled
  window has no effect, whether or not its invert bit is set. An inverted empty
  window covers everything.
- **Combining.** When both windows are enabled for an area, they combine with
  that area's logic: OR, AND, XOR or XNOR (WBGLOG, WOBJLOG). When one is enabled,
  it is used as is. When none is, the area is not covered.
- **Applying.** TMW and TSW apply the windows to the main and sub screen layers:
  a covered layer is removed from that screen at that pixel, and the next layer
  shows. For OBJ, the whole OBJ-layer pixel is removed.
- **The color window** decides "inside" for the CGWSEL regions.

Tests: `testWindowEdgesInvertAndEmpty`, `testWindowLogic`,
`testWindowsOnSubScreenOBJAndColour`, and `testPerLineWindowShape` (an
HDMA-style per-line shape).

### Output

- **Forced blank** is black (fullsnes "Forced Blank Color").
- **Channel expansion.** Each 5-bit channel becomes 8 bits as `(c << 3) | (c >> 2)`.
- **Master brightness** `b` gives `c8 * (b + 1) / 16`, and `b = 0` is black
  (fullsnes INIDISP).

Tests: `testBrightnessForcedBlankAnd239Lines`, `testCOLDATAWritesFromTheWikiExamples`
(the Wiki's COLDATA examples), and `testPerLineScrollAndFixedColour` (per-line
HOFS and COLDATA, as HDMA gradients use).

## Choices the documents leave open

1. **Sub-screen priority in math.** fullsnes wonders whether math also requires
   the sub pixel to have the same or higher priority (marked "XXX"). The Wiki has
   no such condition. We do not apply it: math depends only on the main pixel's
   layer and the CGWSEL regions.
2. **Half on forced black.** fullsnes says half is ignored "if Force Main Screen
   Black is used". We apply this per pixel, on pixels inside the force-black
   region.
3. **5- to 8-bit levels.** The documents do not give DAC output levels. We use
   the project convention `(c << 3) | (c >> 2)` (`BGR555.srgb`).
4. **Brightness scale.** fullsnes gives `*(N+1)/16` with 0 as black. The Wiki
   says only "linear steps". We apply fullsnes's formula to the 8-bit value,
   rounding down. We ignore the Wiki's brightness ramp (not instant on 1-chip
   consoles) and its INIDISP early-read glitch.
5. **16×16 BG tile carry past 3FFh.** The tile number wraps within 10 bits.
6. **OBJ timing.** The hardware evaluates a line's OBJs during the previous
   line. We evaluate line `i` with line `i`'s OBSEL and `objFirst`.
7. **Priority rotation** makes `objFirst` the front OBJ. The Wiki describes
   the 32-OBJ and 34-sliver evaluation in OAM index order and notes that
   OAMADD rotation adjusts the order. It does not say whether rotation also
   moves where that evaluation starts. We evaluate in the rotated order, so the
   OBJs dropped first are the last ones in priority order. No other rotation
   quirk is modelled.
8. **Rectangular OBJ sizes 6 and 7** flip as rectangles. No documented source
   describes a different vertical flip for them.
9. **Range over** is decided when a 33rd in-range OBJ is found. Time over is
   decided when a 35th sliver needs counting. Both are reported in `PPUOBJLine`
   and are not displayed.
10. **Default OAM.** `PPUFrame()` puts every OBJ at Y = 240, which is off-screen
    for heights up to 16. The hardware has no power-on OAM guarantee.
11. **Per-line granularity.** Registers change between lines, never mid-line. The
    caller decides which value HDMA would have written before each line.

## Not implemented

These are the remaining work:

- mosaic;
- BG modes 2–7, offset-per-tile, direct color, Mode 7 and EXTBG;
- hi-res (modes 5/6 and pseudo-512), interlace, and OBJ interlace;
- mid-frame VRAM, CGRAM and OAM writes;
- the overscan border.

For modes 2–7, BGs are transparent; OBJs and the backdrop still draw with the
mode 1 OBJ ranks.

## Metal renderer

`PPURenderer` keeps two textures:

- **VRAM:** 256×128 `r16Uint`.
- **CGRAM, as the palette LUT:** 256×1 `r16Uint` of raw BGR555.

The compute kernel `ppu_frame` runs one thread per output pixel. It repeats the
reference pipeline in integer arithmetic:

1. BG fetch;
2. OBJ sliver lookup;
3. windows, then rank-table layering for the main and sub screens;
4. color math;
5. brightness.

It writes an RGBA8 texture of 256 × 224 or 256 × 239. The register table goes in
a buffer of 32 words per line. The OBJ slivers go in 34 `uint4` per line.

`sync` uploads only the memory that changed:

- **Palette cycling** rewrites CGRAM, so only the 512-byte LUT is uploaded and
  the tile data is untouched. `vramUploads` and `paletteUploads` count the
  uploads, and `testPaletteCyclingRewritesOnlyTheLUT` asserts this.
- **`SNESPPUView`** renders `picture` at 60 FPS. Its `tick` hook animates the
  picture before each frame (palette cycling, scroll, per-line tables). The view
  presents the picture at the largest integer scale that fits, with nearest
  sampling.

### Parity tests

`Tests/ChronoForgeMetalTests/PPUParityTests.swift` compares the whole frame with
`PPUReferenceRenderer`. The comparison must be byte-exact.

| Test | Covers |
|---|---|
| `testParityLayeredScene` | mode 1, the mode 1 BG3 bit, mode 0, 16×16 tiles, a mode without BGs |
| `testParityColorMath` | 224 CGWSEL/CGADSUB/COLDATA combinations, also with an empty sub screen |
| `testParityPerLineScrollModeAndBrightness` | per-line scroll, mode, BG3 bit, brightness, forced blank, rotation |
| `testParityOBJLimits` | 128 OBJs with range and time over, X = −256, five OBSEL settings |
| `testParityWindows` | per-line window shapes over 224 select, logic, TMW/TSW and CGWSEL combinations |
| `testParity239Lines` | the 239-line picture |
| `testParityRandomFrames` | eight seeded random frames: random VRAM, CGRAM and OAM, and per-line random registers (windows included) over the supported space |
| `testPaletteCyclingRewritesOnlyTheLUT` | parity after a palette rotation, with no VRAM upload |

Changing one rule in the shader alone fails every parity test that exercises
it. The rules tried were half on a transparent sub screen, OBJ X flip,
brightness 0, XNOR window logic, and TSW.

These tests need a Metal device. On hosted runners without one they skip, and
they are listed as `may-skip` in `scripts/ci/expected_skips.txt`.

## Studio previews

`PPUPreviewScenes` in ChronoForgeCore builds the Studio's tileset and map
previews as real PPU pictures. `MetalViews.swift` shows them in `SNESPPUView`,
and the scroll wheel pans through HOFS and VOFS.

- **Tile bank.** Up to 1024 tiles sit on BG1, 32 per row, in a 32×64 tilemap.
  Entries past the last tile point at a blank tile.
- **Maps.** Map layers go on BG1–BG3 in mode 1. The 32×32-metatile window at
  the camera is written into 64×64 tilemaps, the way a game streams a large
  map. Tile 1023 (BG1/BG2) and tile 511 (BG3's 2bpp copy) stay blank for empty
  cells.

The project format has no palettes yet, so the previews use gray ramps.
`PPUPreviewScenesTests` checks the layouts through the reference renderer.

## Real locations

`LocationScene` (`CTLocationRender.swift`) gives a [map](maps.md) the field's
own register setup, as traced in the ROM. The interpreter runs of
`Ppu_SetBgLayout` and `Ppu_ApplyMapScreens` back these values (`ct_maps.py
check --run`).

| Register | Value | Source |
|---|---|---|
| BGMODE | $09: mode 1, BG3 priority high | `Ppu_SetBgLayout` ($FD:C0D7) |
| BG12NBA / BG34NBA | $11 / $05: BG1/2 characters at $1000, BG3's at $5000 | `Ppu_SetBgLayout` |
| BG1SC–BG3SC | $61, $69, $71: tilemaps at $6000, $6800 and $7000, each 64×32 | `LocLoad_DrawMap` (HDMA) |
| TM / TS / CGADSUB | From the map's `Screens` and `ColorMath`; layer 3 is off without a Tileset3 | `LocLoad_UnkA33B`, `Ppu_ApplyMapScreens` ($C0:A509) |
| CGWSEL / COLDATA | $02 (sub screen as the second operand) / $E0 (black) | `Ppu_SetBgLayout` |
| MOSAIC | 0 | `Ppu_ApplyMapScreens` |
| BGnHOFS / BGnVOFS | The layer's scroll, VOFS minus 1 | the field's scroll |

How a frame is built:

- **Characters.** The location tileset's tiles go in at $1000, and the first
  256 `t3` tiles (2bpp) at $5000.
- **Tilemaps.** The visible cells are streamed into the 64×32 tilemaps the
  way the field streams them. A cell past the edge of a 48-cell layer is
  blank.
- **Scroll.** Layer 2 at half rate scrolls at half the camera
  (`Map_InitOrigin`). Layers 2 and 3 add their own step every frame
  (`Map_Unk91AC`).
- **Treasure.** Each chest gets a 16×16 OBJ ring at priority 2, as a
  placeholder.
- **Output.** `LocationScene.render` stitches frames over layer 1's area.

These pictures are checked on two kinds of data:

- **Synthetic tables.** The tilemap words equal the metatile chips cell by
  cell, and the characters equal the sheet (`CTMapsTests`).
- **The ROM.** Locations 1, 47, 109, 378 and 386 render as recognisable
  rooms, through the reference renderer with colour math (`chronoforge maps
  render`).
