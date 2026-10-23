# Dialogue box preview (Item, Gear & Lore Database, slices 2-3)

The in-game dialogue box for any message: the ROM's variable-width font, the
window's frame and colours, and how the field lays the text out and paces it,
line by line and frame by frame. Everything is read from your ROM and drawn
through the SNES PPU model ([PPU](ppu.md)).

The evidence lives in the Python reference, `re_workspace/tools/ct_dialogue.py`,
which also checks every claim. It cites the matched ChronoRET routines:
`TextWin_*` in bank `$C2`, `Field_*` in bank `$C0` and the HDMA builders in bank
`$FD`. The Swift twin is in three files:

- `CTDialogueFont.swift`: `CTDialogueROM`, `CTDialogueMemory`, `CTDialogueFont`
  and `CTDialogueWindow`.
- `CTDialogueLayout.swift`: `CTDialogueSettings` and `CTDialogueLayout`.
- `CTDialogueBox.swift`: `CTDialogueBox`, with the box over a field picture.
- `CTDialogueChoice.swift`: `CTBoxPlace`, `CTChoice` and `CTChoiceCursor`
  (evidence: `ct_boxchoice.py`).
- `CTDialogueOverMap.swift`: a project location's field picture behind the box.
- `CTDialogueNames.swift`: the names from the project's characters.
- `CTHelpLine.swift`: the menu's help line (evidence: `ct_helpline.py`).

No ROM bytes, glyphs or dialogue are stored in the repository. The tests use an
invented font and invented strings.

## Font

`TextWin_DrawGlyph` (`$C2:5DC4`) draws glyphs that are 12 × 12 pixels at 2 bpp.

- **Glyph codes.** A message can draw `$A0`–`$FF`, plus `$0100`–`$02FF` after
  the prefix codes `$01` and `$02`. That makes 608 glyphs.
- **Left 8 pixels.** These are 24 bytes at `$FF:2060 + 24 g`: plane 0 and plane
  1 for each of rows 0–11.
- **Right 4 pixels.** These come from 24 bytes at `$FF:3860 + 24 (g >> 1)`. An
  even g uses the high nibble and an odd g the low nibble.
- **Addresses.** Both addresses are 16-bit sums in bank `$FF`.

**Widths.** The pen advance is entry `(g & $FF) − $A0` (mod 256) of
`TextWin_GlyphWidths` (`$C2:60E6`). The table has 96 entries, so a wide glyph's
low byte reads past its end. That is the ROM's own behaviour, and the model
keeps it. The pen is 8 bits and wraps.

**Blit.** `TextWin_Blit2bpp` writes into the 1 KB line buffer `$7E:F000`. A
line is two rows of 32 2bpp tiles, laid out as `TextWin_TileOfs2bpp` shows:
columns 0–15 start at `$000`, columns 16–31 at `$200`, and the lower tile row
`$100` further on. The buffer is drawn as follows:

- Glyph row 0 lands on buffer line 4. Rows 8–11 go to the lower tile row.
- When the pen sits on a tile boundary, the glyph is stored, not ORed.
- Pen shifts 1–4 store the next tile and OR the pen's own tile.
- Pen shifts 5–7 spill into a third tile.

## Window

| | |
|---|---|
| Text upload | The line being written goes to VRAM `$5800 + line × $200` (`Field_UploadUnk5800`): BG3 characters `$100`–`$1FF`. |
| Tilemap | `$1C00`. Rows 0–7 are the text grid (`Field_Unk2B78`, high byte `$29`: BG3 palette 2, priority). Rows 8–17 are the frame (`Field_Unk29F7`, BG1 tiles `$F0`–`$FF` and `$3FC`–`$3FF`). |
| Frame style | `Menu_Config01` bits 0–2 pick one of 8 sets of frame graphics at `$FF:9E10 + $280 k` (`Field_UploadUnk1F00`: `$200` bytes to `$1F00` and `$80` to `$4FC0`). |
| Colours | `Pal_LoadUnkRow0` sets CGRAM row 0, colours 1–15, from `$FF:B210 + 2 + 16 k`. It forces colours 9–11 (the text) to `$0C63`, `$18C6` and `$739C`. |
| Band | The box is a band of 2n lines (n = `Field_Unk27`, 0–40, opened and closed 4 a frame). It is centred on line 48 (top) or 171 (bottom). |
| Band registers | `EngFD_UnkC124` sets BG1SC = BG3SC = `$1C`, the scroll (BG1 V `$37` / `−$44`, BG3 V `−$0F` / `−$8A`), and TM (BG1 on the edge lines, BG1+BG3 on the middle ones). |
| Colour math | `EngFD_UnkD52D` builds a gradient on BG1: 8 steps that add `$E8`…`$E1`, then subtracting steps up to `$E9`. |

At full size the box covers lines 8–87 (top) or 131–210 (bottom). It is 4
lines of 16 pixels, and glyph rows sit at pixels 4–15 of each line. The pen
starts at x 8 (indent `$14`), and the frame's inner edge is x 248.

## Layout and pacing

`Field_Unk1F87` runs every frame, calling `Field_MsgStep`, `TextWin_Step` and
the NMI's line upload. The field always sets `TextWin_StepCount` to 1, so the
game's text speed is fixed at **one glyph a frame**: no setting changes it. The
model transcribes these state machines byte for byte, buffer included. Codes
are named only by what their handlers do, and every other code keeps its raw
value:

| Code | Effect in the box |
|---|---|
| `$05` / `$06` | New line, pen 8 / `$14`. A new line from the 4th line turns the page without waiting for a key. |
| `$07` / `$08` | The same, after a key. |
| `$09` / `$0A` | New page. |
| `$0B` / `$0C` | New page after a key. |
| `$03 n` | Waits 15 n frames. `$03 00` ends the message without a key: the window closes. |
| `$00` | The end, after a key. The window then closes. |
| `$04`, `$10` | A frame with nothing drawn. |
| `$21`–`$9F`, `$12 e≥8` | A dictionary entry (`$DE:FA00`). |
| `$12 00` / `$12 01` | A tech or enemy name, by the next argument byte. |
| `$13`–`$19`, `$1A`, `$20` | Character names 0–6, name 0 and name 7 (`$7E:2C23`, 6 bytes each, at most 5 drawn). |
| `$1B`–`$1D`, `$11` | A party member's name, or a name by argument. |
| `$1E`, `$1F` | "Nadia" (`$C2:6146`) and the treasure item's name. |
| `$0D` / `$0E` / `$0F` | 8-, 16- and 24-bit numbers from the argument bytes at `$0200`, in decimal, or in hex with `TextWin_NumHex` (except `$0F`). |

The preview fills names, the party, the item and the arguments with
placeholders (`CTDialogueSettings.placeholder`): names "A"–"H", party 0–2, item
1, and arguments `$12`, `$34`, …. The key is pressed a chosen number of frames
after each wait begins.

## The box's place

`Field_Unk1F87` picks the place on the first frame of state 5. The message
opcodes set `Field_Unk30`: `OpBB` and `OpC0` 0, `OpC1` and `OpC3` 1, `OpC2` and
`OpC4` 2. With 1 the band is centred on line 48 (the top), with 2 on line 171
(the bottom). With anything else it reads the low byte of the speaker's
`Obj_ScreenY` (`$0A80` + `Field_Unk2E`, the object that ran the opcode): below
`$80` (the upper half of the screen) the box goes to the bottom, from `$80` on
to the top. The high byte is not read.

## Choices

`OpC0`, `OpC3` and `OpC4` carry a choice byte (`Evt_MsgChoiceStart`): bits 2-3
are the first choice line (`Field_Unk64`) and bits 0-1 the last
(`Field_Unk65`). When the text has ended (state 7, `TextWin_Status` 0), the
cursor `Field_Unk63` starts on the first line. `Sub_1ADF` moves it each frame:

- Down goes one line on, and past the last line back to the first.
- Otherwise Up goes one line back; from line 0, or below the first line, it
  goes to the last.
- Otherwise the confirm button (`Pad_Unk00F8` bit 7) makes the choice.

The opcode stores the line in the object's `ObjX_Unk7F0A80`.

`Irq_DrawChoiceCursor` draws the cursor as 2 × 2 tiles of the text grid at
`$1C00`: words `$28FC $28FD` over `$28FE $28FF` (BG3 characters `$0FC`-`$0FF`,
palette 2) at columns 2-3 of the line's two map rows. It puts the grid's own
words back on the other three lines. The four characters are the 64 bytes
`Field_UploadUnk57E0` sends from `$FF:9260` to VRAM `$57E0`; it runs at every
field load. Rendered, they are the game's pointing hand. Line 0 loses the
cursor's top 4 lines, as it does the text's: the band shows BG3 only from its
11th line.

## Over the map

Outside the band the field shows the location. Inside it,
`EngFD_UnkC124`'s HDMA records write:

- BG1SC = BG3SC = `$1C`;
- HOFS 0 for BG1 and BG3 (each scroll pair's first word), and the VOFS pair;
- TM 5 or 1, with TS = TMW = TSW = 0;
- the gradient's CGADSUB/COLDATA on every line but the last, which keeps the
  map's CGADSUB.

`CTDialogueBox.frame(_:at:over:)` composes the box over a
`LocationScene.frame` picture. It adds the box's own VRAM (the frame set at
`$1F00`/`$4FC0`, the tilemaps at `$1C00`/`$1D00`, the cursor characters at
`$57E0`, the text from `$5800`) and colours 1-15. The map keeps everything
else, including CGRAM 0 and 16-255.

## The menu's help line

The item and tech menus draw a description in one line of BG3, not in a box.
`Menu_DrawDescText` (`$C2:F2F3`; items, table `$CC:2EB1`, 242 entries) and
`Menu_TechDescText` (`$C2:BE33`; techs, table `$CC:3A09`, ids 0-`$75`) both use
`Menu_StartDescText` and `Menu_TextStepLoop`.

**How it draws.**

- The decoder is the dialogue box's own (`TextWin`, mode 0), stepping one step
  a frame. It draws into the glyph buffer `$7E:5E00`, which goes to VRAM
  `$7800`.
- Tile words start at `$3101` (palette 4, priority). The lower row uses the
  same words with bit 4 set.
- They go to BG3 map rows 2-3 for items (VRAM `$6840`) and rows 21-22 for
  techs (`$6AA0`).
- Screen x is the pen + 16. Colours 16-19 come from `$FF:9C78`.

**The routine's limits.**

- A new line (`$05`) moves the drawing two rows on, but only the first two rows
  are ever sent: a description has one visible line. A third line lands back
  on the first, because the column is 8-bit.
- A pen past 240 puts tile words past column 31, into the next map row.
- A pen reset without a new line (`$06`-`$0C`), or a pen wrap past 255, makes
  the next tile count wrap, and the routine would write 65536 words.

"Fits" means none of these happen. Every real description fits: the widest end
at pen 219 (items) and 207 (techs). The menu's window frame (BG1/BG2) behind
the line is not drawn.

## CLI

```
chronoforge text preview <rom> <TABLE:INDEX | --text "..."> [--page N | --frame F] [--png out.png]
                         [--frames] [--layout-json] [--press N] [--place 1|2] [--style 0-7]
                         [--opcode BB|C0-C4 [--speaker-y Y]] [--choice K] [--location N --project P [--camera X,Y]]
chronoforge text preview <rom> --help-line item|tech <N | --text "..."> [--png out.png] [--layout-json]
chronoforge text font <rom> [--json]
chronoforge text fit <rom> <message.txt | dialogue.json> [--json]
```

- **`preview`** lays a message out. The message is either a pointer-table index
  (e.g. `D8D000:12`) or codec text compiled with the ROM's dictionary. It
  reports each page and line, the codes and the overflows.
- **`--png`** renders page N, or frame F.
- **`--frames`** prints the frame-by-frame timeline: state, opening, page, key
  waits and glyphs.
- **`--layout-json`** prints the numbers that `ct_dialogue.py` compares.
- **`--opcode`** places the box as that opcode does. For `OpBB` and `OpC0` it
  uses the speaker's screen Y (`--speaker-y`).
- **`--choice K`** draws a choice message's cursor on box line K from the end
  wait.
- **`--location N`** draws the box over location N of a project
  (`chronoforge maps import`), with the camera at X,Y.
- **`--help-line`** lays out description N (or `--text`) in the menu's help
  line. It reports the glyphs, pens, frames and fits / overflows, and writes a
  256 × 16 PNG of the two rows through the PPU.
- **`font`** prints the font, widths, frame and colour digests and the box
  geometry.
- **`fit`** is report-only. It lists the lines of a `dialogue.json` (or of one
  message) that run past the frame or wrap the 8-bit pen, and it always exits
  0.

## Studio

`DialoguePreviewView` shows the box. It renders through ChronoForgeMetal's
`SNESPPUView`, or through the reference renderer when there is no Metal. It
has:

- page stepping;
- a play button that runs the message frame by frame at the field's own pace,
  scaled by a viewer speed of ¼× to 4×;
- a choice of the 8 frame styles;
- the frame count;
- a warning for any line past the frame;
- the place: as the caller set it, top, bottom, or by the speaker's screen Y;
- a choice cursor: a **Choice** toggle with the first and last lines; ↑ and ↓
  move the cursor (click the picture to focus it);
- the party (names from the project's characters, else the game's defaults);
- **Behind**: an imported location of the project behind the box (camera at its
  centre), when the caller passes the project.

It reads the ROM from the Scenes/Music ROM (`--rom`). It appears in two
places:

- **Items:** the item description editor shows it under the analyzer's byte
  savings. In the game, descriptions are drawn by the menu's own help line, so
  this shows how the text would look in a dialogue box.
- **Scenes:** the statement inspector shows it for `OpBB` and `OpC0`–`OpC4`.
  The table is the last `OpB8_SetMsgPtr` before the statement. `OpC2` and
  `OpC4` put the box at the bottom.

`HelpLinePreviewView` shows the menu's help line, with a fits / overflows
indicator. It appears in the item description editor (**In the menu**, live as
you type) and under the Tech matrix's tech editor (**Help line**).

## Verification

- **Static claims.** `ct_dialogue.py check` holds 52: 32 source-line claims, 12
  claims about the ROM's code operands and 8 about data shapes.
- **Run claims.** `ct_dialogue.py check --run` adds 7, run in ChronoRET's 65816
  interpreter:
  - `TextWin_DrawGlyph` on all 608 glyphs at all 8 pen shifts, compared byte
    for byte with `blit` and `width`;
  - both window tilemaps;
  - the band records and the gradient;
  - `Field_Unk1F87` frame by frame on real messages: 68 of 68 runs by default,
    and 610 of 610 with `--messages 300` (55,392 frames). Each run compares
    pens, lines, pages, waits and every upload of the line buffer;
  - the synthetic messages that use the codes no real message uses (`$04`
    `$07` `$08` `$0F` `$10` `$11` `$12`): 16 of 16 runs.
- **The CLI.** `ct_dialogue.py verify-cli` compares the CLI's `text font --json`
  and `text preview --layout-json` with the Python decode: 94 of 94 message
  layouts.
- **Help line.** `ct_helpline.py check --run` holds 35 claims. The run claims
  cover every item description (242 of 242, 2143 frames) and every tech
  description (118 of 118, 2711 frames) through `Menu_TextStepLoop` with every
  queued upload compared. They also cover 20 synthetic runs, plus 4 the model
  stops as runaways.
- **Place and choices.** `ct_boxchoice.py check --run` holds 40 claims.
  - The place: `Field_Unk1F87`, 324 of 324 cases over `Field_Unk30`, the screen
    Y bytes and the object.
  - `Sub_1ADF`: 3360 of 3360 cases.
  - `Irq_DrawChoiceCursor`: 7 of 7, with the VRAM port recorded.
  - `ct_dialogue.py check` includes both tools' claims.
- **Tests.** `re_workspace/tests/test_dialogue.py`, `test_helpline.py`,
  `test_boxchoice.py`; `CTHelpLineTests` and `CTDialogueChoiceTests` (their
  vectors `helpline_vectors.json`, `choice_vectors.json`, the cursor and the
  composition over a map), and `CTDialogueTests`,
  which runs the Python vectors (`dialogue_vectors.json`) and renders a
  hand-made font and frame through `PPUReferenceRenderer`, pixel by pixel.

## Limitations

- **The Scenes inspector** passes only the place (`OpBB` and `OpC0` show at the
  top). The speaker's screen Y, the choice byte and the event pack's location
  are not passed yet, because the inspector is the Scenes worker's file. The
  preview's own controls set them.
- **The map picture** is the location at a still camera (its centre in the
  Studio), without the objects' sprites.
- **The choice cursor** shows from the end wait. The layout then runs the key
  wait and close of a plain message, not the wait for a choice.
- **The help line** does not draw the menu's window frame. Tech descriptions
  are not in the project, so they are previewed, not saved.
- **Numbers** (item and arguments) are still placeholders.
