# Dialogue box preview (Item, Gear & Lore Database, slice 2)

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
- `CTDialogueBox.swift`: `CTDialogueBox`.

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

## CLI

```
chronoforge text preview <rom> <TABLE:INDEX | --text "..."> [--page N | --frame F] [--png out.png]
                         [--frames] [--layout-json] [--press N] [--place 1|2] [--style 0-7]
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
- a warning for any line past the frame.

It reads the ROM from the Scenes/Music ROM (`--rom`). It appears in two
places:

- **Items:** the item description editor shows it under the analyzer's byte
  savings. In the game, descriptions are drawn by the menu's own help line, so
  this shows how the text would look in a dialogue box.
- **Scenes:** the statement inspector shows it for `OpBB` and `OpC0`–`OpC4`.
  The table is the last `OpB8_SetMsgPtr` before the statement. `OpC2` and
  `OpC4` put the box at the bottom.

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
- **Tests.** `re_workspace/tests/test_dialogue.py`, and `CTDialogueTests`,
  which runs the Python vectors (`dialogue_vectors.json`) and renders a
  hand-made font and frame through `PPUReferenceRenderer`, pixel by pixel.

## Limitations

- **Outside the band.** Lines outside the band show the backdrop. In the game
  they show the map, and the last band line uses the map's colour math.
- **Choices.** `OpC0`/`OpC3`/`OpC4` previews draw the text, not the choice
  cursor.
- **The box's place.** `OpBB` and `OpC0` are shown at the top. Their real place
  depends on `Field_Unk30`, which is not traced.
- **Item descriptions.** They are previewed in the dialogue box, not in the
  menu's help line.
- **Real names and numbers.** The preview uses placeholder names, party,
  item and arguments, not a save file's.
