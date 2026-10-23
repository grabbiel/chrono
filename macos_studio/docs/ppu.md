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
  - [Offset-per-tile](https://snes.nesdev.org/w/index.php?oldid=1439) (rev 1439)
  - [Mode 7 transform](https://snes.nesdev.org/w/index.php?oldid=1410) (rev 1410)

fullsnes chapters used for slice 2: "SNES PPU BG Control" (BGMODE, MOSAIC),
"SNES PPU Rotation/Scaling" (M7SEL, the matrix, the formula, EXTBG), "SNES PPU
Control" (SETINI), "SNES PPU Resolution" (its "Hires Notes"), and "SNES PPU
Color Palette Memory (CGRAM) and Direct Colors" (direct color, the screen
border). Its "Offset-Per-Tile Mode" chapter is a stub, so offset-per-tile
follows the Wiki page alone.

## Input: `PPUFrame`

| Field    | Contents |
|----------|----------|
| `vram`   | 32K words. Word addresses wrap at 15 bits. |
| `cgram`  | 256 BGR555 words. Bit 15 is ignored. |
| `oam`    | 544 bytes: 128 four-byte entries, then the 32-byte high table. |
| `lines`  | One `PPURegisters` per visible line: 224 lines, or 239 with SETINI overscan. |
| `writes` | Mid-frame memory writes, each effective from a line (default: none). |
| `field`  | The interlace field drawn, 0 or 1 (default 0). |

`lines` is the per-scanline register table, the state that HDMA produces. Every
register can change on every line. Index `i` is the state in effect while
visible line `i` is drawn.

`PPURegisters` stores what the CPU write ports produce:

- the BG scroll values after both writes;
- the fixed color that COLDATA writes build up (`writeCOLDATA` applies the
  channel-select bits);
- the character-base nibbles (`writeBG12NBA` and `writeBG34NBA` set them).

The registers are INIDISP, OBSEL, BGMODE, MOSAIC, BGnSC, BG12NBA/BG34NBA,
BGnHOFS/VOFS, M7SEL, M7A–M7D, M7X/M7Y, M7HOFS/M7VOFS (stored apart from BG1's
scroll, as fullsnes says the hardware keeps them), TM, TS, the window
registers (W12SEL, W34SEL, WOBJSEL, WH0–WH3, WBGLOG, WOBJLOG, TMW, TSW),
CGWSEL, CGADSUB, COLDATA, SETINI and the OBJ priority rotation (`objFirst`).
New registers default to values that change nothing (MOSAIC 0, SETINI 0, the
identity matrix), so slice 1 callers render as before.

## Output

- `PPUReferenceRenderer.render(_:)` and `PPURenderer.render(_:)` return
  256 × height RGBA8, as in slice 1. On a hi-res line they show the main
  screen's (odd) half-pixels.
- `renderImage(_:options:)` returns a `PPUImage`. With
  `PPURenderOptions.highResolution` (the default) a frame with any hi-res
  line is 512 wide, and its other lines repeat each pixel. With
  `overscanBorder` the image is the 239-line display area (see "The overscan
  border").
- `PPUImage.weave(even:odd:)` interleaves two interlace fields into one
  picture of twice the height.

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

### Mid-frame memory writes

`PPUFrame.writes` holds CGRAM, VRAM and OAM writes. A write tagged with line
`i` takes effect before visible line `i` is drawn and stays for the rest of
the frame. Writes on the same line apply in queue order; a write tagged
before line 0 applies before line 0. `memoryByLine()` gives every line its
memory. These are what HDMA CGRAM gradients and palette effects produce, and
what CPU writes during forced-blank lines produce.

- **CGRAM** changes the colors of every later line: BG, OBJ, backdrop.
- **VRAM** changes tiles and maps from that line on.
- **OAM** reaches the OBJ evaluation of that line (both renderers share
  `PPUOBJEvaluator`).

The documents say when the CPU can reach each memory (fullsnes INIDISP:
VRAM, OAM and CGRAM are accessible during V-Blank or forced blank). The
renderers do not enforce this: the caller supplies the writes that took
effect (choice 12).

Tests: `testMidFrameCGRAMWritesMakeAGradient`,
`testWritesTakeEffectFromTheirLineInLineThenQueueOrder`,
`testMidFrameVRAMAndOAMWrites`.

### Mosaic

These rules come from fullsnes MOSAIC and the Wiki's MOSAIC register.

- **Blocks.** MOSAIC bits 7–4 give the block size minus 1 (1×1 … 16×16);
  bits 0–3 enable BG1–BG4. Each block shows its top-left pixel.
- **Horizontal.** The first block starts at the left edge of the screen: x
  becomes `x − x mod size`.
- **Vertical.** The first block starts on the top visible line. fullsnes:
  vertical mosaic subtracts the line's index within its block from BGnVOFS,
  so a BG reads row `line + 1 − index + VOFS`.
- **Size changes.** When the size changes mid-frame, the current block is
  finished with the old size; the new size applies from the next block.
  `PPUMosaic.verticalIndices` computes each line's index.
- **1×1** changes nothing, except in true hi-res (below).

Tests: `testMosaicBlocksShowTheirTopLeftPixel`,
`testMosaicSizeChangeFinishesTheCurrentBlock`.

### BG modes 2–6

These rules come from fullsnes BGMODE and its "Background Priority Chart",
and the Wiki's *Backgrounds* mode table.

| Mode | BG1 | BG2 | BG3 | Front → back |
|---|---|---|---|---|
| 2 | 4bpp | 4bpp | offset-per-tile | S3 1H S2 2H S1 1L S0 2L |
| 3 | 8bpp | 4bpp | – | S3 1H S2 2H S1 1L S0 2L |
| 4 | 8bpp | 2bpp | offset-per-tile | S3 1H S2 2H S1 1L S0 2L |
| 5 | 4bpp, hi-res | 2bpp, hi-res | – | S3 1H S2 2H S1 1L S0 2L |
| 6 | 4bpp, hi-res | – | offset-per-tile | S3 1H S2 S1 1L S0 |

- **8bpp tiles** are 32 words: planes 0/1, 2/3, 4/5 and 6/7 at +0, +8, +16
  and +24 words. The pixel is the CGRAM index; the tile's palette bits are
  unused (except with direct color). `storeTiles(bpp: 8)` writes this layout.
- **4bpp and 2bpp BGs** in modes 2–6 use `pal*16+c` and `pal*4+c`; only mode
  0 adds `n*32`.
- **Direct color** (CGWSEL bit 0) applies to the 8bpp BG1 of modes 3, 4 and
  7. The pixel `BBGGGRRR` and the tile's palette bits `bgr` form
  `BBb00 GGGg0 RRRr0`; pixel 0 is still transparent (fullsnes "Direct Color
  Mode"; Wiki *Backgrounds*).

Tests: `testModes2To5PriorityOrder` and `testMode6PriorityOrder` (every pair
of slots in its own block, as slice 1), `testBitDepthsAndPaletteIndices`,
`testDirectColorInModes3And4`, and `testMode3ReadsBG1TilesAt8bpp`.

### Offset-per-tile

These rules come from the Wiki's *Offset-per-tile* page (rev 1439).

- In modes 2, 4 and 6, BG3's tilemap holds scroll entries for BG1 and BG2.
  Bit 13 applies an entry to BG1, bit 14 to BG2.
- **Rows.** The PPU reads the row at BG3VOFS (low 3 bits ignored) for HOFS
  entries, and the row 8 lines below it for VOFS entries. The screen line does
  not change which row is read. Mode 4 reads one row; its bit 15 says whether
  an entry is horizontal (0) or vertical (1).
- **Columns.** The leftmost tile column keeps the BG's own scroll. Column `c`
  (counted with the BG's fine scroll, `(x + (HOFS & 7)) >> 3`) uses entry
  `c − 1` to the right of BG3HOFS's tile (low 3 bits ignored).
- **Values.** A HOFS entry replaces bits 9–3 of HOFS and keeps the fine
  scroll; a VOFS entry replaces VOFS.
- BG3's screen size and 16×16 tiles shape the offset map as they would a
  tilemap; the VOFS row may come from the next screen down.

Tests: `testOffsetPerTileReplacesScrollFromTheSecondColumn`,
`testMode4OffsetPerTileBit15PicksTheDirection`.

### Mode 7 and EXTBG

These rules come from fullsnes "SNES PPU Rotation/Scaling" and the Wiki's
*Mode 7 transform* page.

- **Memory.** The map is 128×128 tiles in the low bytes of VRAM words
  0–3FFFh; tile `t`'s 8×8 8-bit pixels are in the high bytes of words
  `t*64 …`. BGnSC, the character base and the tile-size bits are ignored.
  `storeMode7Tiles` and `setMode7Tile` write this layout.
- **The formula** (fullsnes, with its truncations):
  - `ORG = (M7HOFS − M7X)` with bits 10–12 replaced by its sign (the same for Y);
  - `VRAM.X = ((A·ORG.X) & ~3Fh) + ((B·ORG.Y) & ~3Fh) + M7X·100h + ((B·SY) & ~3Fh) + A·SX`;
  - `VRAM.Y = ((C·ORG.X) & ~3Fh) + ((D·ORG.Y) & ~3Fh) + M7Y·100h + ((D·SY) & ~3Fh) + C·SX`.
  - `SX` is x and `SY` is the scanline `line + 1`; M7SEL bits 0 and 1 XOR them
    with FFh (screen flips).
  - A–D are signed 8.8; M7X, M7Y, M7HOFS and M7VOFS are signed 13-bit.
  - Every register can change per line (`testMode7PerLineMatrixMosaicAndDirectColor`).
- **Coordinates.** `VRAM >> 8` gives texel coordinates: bits 0–2 pick the
  pixel, 3–9 the map cell, and bits above that mean "outside the map".
- **Screen over** (M7SEL bits 7–6): 0 and 1 wrap; 2 makes the outside
  transparent; 3 fills it with tile 0.
- **Mosaic.** The block's x, and `SY − index`, are taken before the flips
  (fullsnes MPY notes: `(SCREEN.Y−MOSAIC.Y) XOR (yflip*FFh)`).
- **Direct color** applies to BG1, with palette bits 0.
- **EXTBG** (SETINI bit 6) makes BG2 the same pixel as BG1, with bits 6–0 as
  its color and bit 7 as its priority. It never uses direct color (Wiki
  *Backgrounds*).
- **Priority** (fullsnes chart): S3 S2 2H S1 BG1 S0 2L.

Tests: `testMode7IdentityScrollScaleAndFlips`,
`testMode7ShearAndTheSixBitTruncation` (a case where `& ~3Fh` moves a pixel
by one texel), `testMode7ScreenOverAndTheMap`,
`testMode7PerLineMatrixMosaicAndDirectColor`, `testMode7EXTBGPriorityAndOrder`.

### Hi-res: modes 5 and 6, and pseudo 512

These rules come from the Wiki's SETINI and BGMODE (*PPU registers*), its
*Backgrounds* "High resolution" section, and fullsnes "Hires Notes".

- **Columns.** A hi-res line has 512 half-pixel columns. The sub screen
  draws the even columns and the main screen the odd ones (choice 17).
- **Modes 5 and 6.** BGs are drawn at 512 columns. Tiles are always 16
  half-pixels wide (tiles N and N+1); the BGMODE size bits choose 8 or 16
  rows. HOFS counts in 2 half-pixels.
- **Pseudo 512** (SETINI bit 3) works in any mode: BGs stay 256 wide, and the
  sub and main screens still alternate columns.
- **Backdrop.** A transparent sub-screen column shows CGRAM 0, not the fixed
  color (fullsnes).
- **Full pixels.** OBJs, windows and mosaic count in 256-wide pixels. In
  modes 5/6 a mosaic block shows the even half-pixel of its first pixel, so
  1×1 acts as 2×1 half-pixels (fullsnes).

Tests: `testModes5And6DrawSixteenHalfPixelTiles`,
`testHiresPutsTheSubScreenOnEvenColumns`, `testHiresMosaicCountsFullPixels`.

### Interlace

- **Fields.** A `PPUFrame` is one field (`field` 0 or 1). It has 224 or 239
  lines, and `PPUImage.weave` combines two fields.
- **Modes 5/6 with SETINI interlace** read half-lines: row
  `(line + 1)·2 + field + VOFS`, so vertical scroll moves in half-lines (Wiki
  SETINI; fullsnes "Vertical BG Scrolling is counted in half-pixels").
- **OBJ interlace** (SETINI bit 1): OBJ rows advance two per line starting at
  `field`, so OBJs appear half as tall (Wiki SETINI; fullsnes SETINI).
- Other modes draw both fields alike.

Tests: `testInterlacedModes5And6UseHalfLines`, `testOBJInterlaceHalvesOBJHeight`,
`testWeaveInterleavesFields`.

### The overscan border

- **Color.** The screen border is always black, whatever CGRAM and the fixed
  color hold (fullsnes "Screen Border Color").
- **Placement.** The Wiki's SETINI says overscan "automatically shifts
  everything up 8 lines". So in the 239-line display area, a 224-line picture
  starts on line 8, with 8 black lines above it and 7 below. A 239-line
  picture fills the area.

Test: `testOverscanBorderIsBlackAroundThePicture`.

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
12. **Memory access windows.** Mid-frame writes apply as given, between lines.
    The renderers do not drop writes the hardware would refuse outside
    V-Blank, H-Blank or forced blank.
13. **OAM writes** reach the evaluation of the line they are tagged with
    (consistent with choice 6).
14. **The mosaic counter** runs on every line whether or not a BG enables
    mosaic, and writing MOSAIC does not restart it. fullsnes gives only the
    first block's position and the size-change rule.
15. **Mosaic and offset-per-tile.** The offset column comes from the mosaic
    block's x.
16. **Offset-per-tile in mode 6.** A BG3 entry covers 8 screen pixels (16
    half-pixels). The Wiki says mode 6 treats the 8×8 setting as 16×8 for
    BG3, and those 16 half-pixels are 8 screen pixels.
17. **Hi-res column order.** The Wiki's SETINI (rev 1507) puts the sub screen
    on even columns. fullsnes SETINI says pseudo 512 shifts the sub screen
    "half dot to the left". The Wiki's *Backgrounds* page (rev 1244) says the
    main screen is on even columns. We follow the two sources that agree.
18. **Color math in hi-res.** fullsnes says modes 5/6 "don't support screen
    addition/subtraction". The Wiki's *Color math* says fixed-color math works
    in hi-res. We apply math to the main (odd) columns, with the sub-screen
    pixel of the same 256-pixel column as the addend. The even column shows the
    sub-screen pixel as is: no math, no force-black.
19. **A transparent sub screen in hi-res.** Its column shows CGRAM 0 (fullsnes).
    As a math addend it is still the fixed color without half (slice 1 rule).
20. **Mosaic with interlaced modes 5/6.** A mosaic BG drops the field bit, so a
    block covers both fields. fullsnes says 1×1 acts as 2×2 half-pixels
    "reportedly".
21. **OBJ interlace** applies whenever SETINI bit 1 is set. fullsnes describes
    it under interlace; the Wiki describes it on its own.
22. **EXTBG outside Mode 7** shows garbage on the hardware (fullsnes). We
    ignore it.
23. **EXTBG and mosaic.** BG2 computes its Mode 7 pixel with its own mosaic
    enable (bit 1). The documents do not say whether BG2 follows BG1's.
24. **13-bit Mode 7 fields** are the low 13 bits of their `Int16`, sign-extended.
25. **SETINI overscan** (bit 2) does not change a frame's line count;
    `PPUFrame.height` does.

## Not implemented

- **Mid-line changes.** Registers and memory change between lines only.
- **Hi-res details.** The reported hi-res window glitch (fullsnes: "reportedly
  with an odd glitch") and any hi-res sub-screen color math beyond choice 18.
- **Interlace.** Interlace in modes other than 5/6 changes nothing but the
  field number. There is no PAL timing and no 264-line PAL picture.
- **External sync** (SETINI bit 7).
- **The rest of the console.** The Mode 7 multiplier's MPY results, and
  timing, are outside the renderers.

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

It writes an RGBA8 texture of 256 or 512 × 224 or 239 lines (239 with the
overscan border). The register table goes in a buffer of 64 words per line
(the slice 1 words, then MOSAIC, the line's mosaic index, M7SEL, SETINI, the
Mode 7 registers, the line's CGRAM row and its VRAM slice). The OBJ slivers go
in 34 `uint4` per line.

Mid-frame writes:

- **VRAM** is a 2D-array texture. Without VRAM writes it has one slice, the
  synced VRAM. With them, each stretch of lines with the same VRAM gets its
  own slice of a second array, and each line names its slice.
- **CGRAM.** With CGRAM writes, a 256 × 239 texture holds every line's CGRAM
  and each line names its row. Without them, lines read the LUT.
- **OAM** goes through the shared OBJ evaluator, per line.

`vramSegmentUploads` and `lineCGRAMUploads` count frames drawn this way. A
CGRAM gradient uploads no VRAM.

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

`Tests/ChronoForgeMetalTests/PPUFeatureParityTests.swift` covers slice 2. It
compares `renderImage` at the same options, byte for byte.

| Test | Covers |
|---|---|
| `testParityMidFrameWrites` | per-line CGRAM writes on every line, VRAM writes into maps and tiles, OAM writes, a write before line 0; a gradient uploads no VRAM |
| `testParityMosaic` | per-line sizes and enables in modes 1 and 0 |
| `testParityModes2To6OffsetPerTileAndDirectColor` | modes 2–6 × 8/16-pixel tiles × direct color, random offset rows with every bit 13–15 combination, per-line BG3VOFS |
| `testParityMode7AndEXTBG` | a perspective per-line matrix, all screen-over settings, flips, EXTBG, mosaic, direct color, extreme register values |
| `testParityHiresAndInterlace` | modes 5/6 with 8/16-row tiles, sub-screen columns, hi-res mosaic, interlaced fields, OBJ interlace, pseudo 512 lines, 256-wide output |
| `testParityOverscanBorder` | the border around 224- and 239-line pictures |
| `testParityRandomFeatureFrames` | twelve seeded random frames: every mode, per-line random registers (mosaic, SETINI, Mode 7, CGWSEL included), random CGRAM, VRAM and OAM writes, a random field and output options |

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

### Feature demos

`PPUPreviewScenes.Demo` (`PPUFeatureDemos.swift`) builds a synthetic picture
for each slice 2 feature. Its tiles, maps and palettes are generated in
code. `animate` moves each demo per frame:

| Demo | What it shows |
|---|---|
| HDMA CGRAM gradient | a sky from a CGRAM 0 write before every line, and a shimmering color from line 112 |
| Mosaic | a mosaic transition on BG1 only, the size climbing 1 → 16 and back |
| Offset-per-tile | mode 2: a sine of VOFS entries and a sawtooth of HOFS entries for BG1 |
| Direct color | mode 3: all 256 pixels with their palette bits; the lower half through CGRAM |
| Mode 7 | a rotating perspective floor from a per-line matrix, under a CGRAM sky |
| Mode 7 EXTBG | rings with pixel bit 7 set, passing in front of low-priority OBJs |
| Hi-res (mode 5) | half-pixel stripes and checkers at 512 columns |
| Pseudo 512 | mode 1, with BG1 on the main screen and BG2 on the sub screen in alternate columns |
| Interlace | mode 5 with interlace and OBJ interlace, the field alternating every frame |
| Overscan border | the gradient scene inside the black 239-line border |

- **The Studio.** The Window menu's "PPU Demos" (or `--ppu-demo <slug>` at
  launch) opens them in `SNESPPUView`. Its `renderOptions` choose 512 columns
  and the border; a 512-column picture keeps the 256-pixel aspect.
- **The CLI.** `chronoforge ppu demos --out DIR [--frame N] [--gpu]` writes
  one PNG per demo. `--gpu` draws through Metal and fails if any byte
  differs from the reference.
- **Tests.** `PPUFeatureDemosTests` checks each demo's size, that it uses its
  feature, and that it animates.

## Chrono Trigger evidence

ChronoRET's disassembly shows where Chrono Trigger uses these features:

- **A per-line Mode 7 matrix.** `C2Scene_SwirlInit` ($C2:6F92) points HDMA
  channels 2–5 (indirect, one register written twice) at M7A, M7D, M7B and
  M7C, and fills 224 lines from the ROM's sine table ($C0:F900):
  `M7A = M7D = cos(a)`, `M7B = M7C = sin(a + 80h)`, with `a` advancing 4 per
  line. `C2Scene_SwirlStep` scrolls the table up one line per frame.
- **Per-line MOSAIC and SETINI in battle.** `BattleCD_NmiSetup` ($CD:09F1)
  sets HDMA channel 5 to CGWSEL–SETINI and channel 6 to BGMODE/MOSAIC.
  `BattleCD_FxOpMosaic` ($CD:2EF7) steps channel 6's MOSAIC byte.
- **Mosaic off on the field.** `Ppu_ApplyMapScreens` writes MOSAIC 0 (see
  "Real locations").
- fullsnes lists Chrono Trigger among the offset-per-tile programs (the title
  screen, and the Black Omen appearing) and the interlace programs (the
  crash into Lavos).

`CTPPUEvidenceTests` is ROM-gated (it skips without the local ROM). It does
not use ROM pixels:

- **`testSwirlProgramsHDMAForAPerLineMode7Matrix`** finds the four HDMA
  channel setups and both trig calls in the routine's bytes.
- **`testSwirlFrameFromTheROMSineTable`** builds the swirl's 224 per-line
  matrices from the ROM table, over a synthetic map, and checks invariants:
  - the values stay within ±255, with A = D and B = C;
  - A < 0 (a mirrored map) exactly on lines 65–191;
  - every pixel is drawn;
  - along each line with |A| near 1, the tile column steps +1 where A > 0
    and −1 where A < 0.

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
