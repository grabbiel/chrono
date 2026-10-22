# Scene Director

The Scenes pane now creates, edits, validates, saves and previews the Studio's
`ctproj/1` scene language. This is an authoring and logical execution tool; it
does not emulate the game's VM. Scenes can be lowered to Chrono Trigger event
bytecode (see [Chrono Trigger bytecode](#chrono-trigger-bytecode)).

Open a `.ctproj` with Command-O, select Scenes and choose a scene (or New Scene).
Edit the script on the left. Syntax errors show line/column diagnostics, and
unknown flags, strings or maps block Apply & Save. Format normalizes the source.
Drafts survive changing scenes or Studio panes for the currently open project;
apply them before reopening the project or quitting the application.

The Function Graph shows one draggable card per function, with arrows for local
jumps. Arrange restores a grid. Branches appear inside each function's script.
Apply & Save writes the graph positions with the scene. This is a function graph,
not yet a statement-node editor or actor choreography canvas.

Execution Timeline lets you select an entry function and initial story flags.
Run Preview records statements, chosen branches, dialogue and logical frame
positions. Wait advances frames; text records dialogue without guessing how long
the player takes to dismiss it. Jump transfers to a local function and discards
its predecessor's remaining statements. External map calls stop the preview:
`ctproj/1` does not yet define which scene/object a map function targets.
In single-scene mode, `call_obj`, `call_pc` and `ct` are recorded and the scene
goes on. Enable **All scenes as objects** to execute cross-object calls in the
multi-object scheduler. Each scene needs a distinct object slot. Only the chosen
entry function starts automatically; other objects start idle. Objects run in
slot order with up to five statements each per logical frame. Calls can preempt,
queue, retry or wait for completion; interrupted functions resume with their
wait state intact. The timeline shows scene, slot, call level and final object
states, including deadlocks. Optional party slots (for example `3,1,2`) bind
party members 0–2 for `call_pc`; malformed or duplicate slots are rejected.
Unbound party calls and raw `ct` opcodes are recorded without simulation.
Loops stop after 1,000 statements or 10,000 frames in the UI. These are logical
frames, not cycle-accurate SNES timing. This is not a playable game runtime.

## Language

```text
# A comment at the start of a line
obj 0 {
  func 0 {
    if MET_LAYLA {
      text shop
    } else {
      text greeting
      set_flag MET_LAYLA
    }
    wait 60
    jump func1
  }
  func 1 {
    clear_flag MET_LAYLA
    call overworld#1 // external call, preview stops here
    nop
  }
}
```

- One object per scene, slots 0–15; unique functions 0–15.
- `nop`, `wait <0–65535>`, `set_flag <symbol>`, `clear_flag <symbol>`,
  `text <string-id>`, `call <map-id>#<function>`, `jump func<function>`.
- `call_obj <scene-id>#<function> [start|retry|wait] [level <0–6>]` runs a
  function of the object another scene occupies; both scenes must be lowered
  into the same event pack. `call_pc <0–2>#<function> …` does the same on a party
  member's object. Defaults: `wait`, `level 4` (canonical output spells both out).
  `start` never waits, `retry` waits until the target can take the call, `wait`
  also waits for the function to end; level 0 is the most urgent (idle objects
  rest at 7).
- `ct <opcode> <$XX>…` is one Chrono Trigger event opcode, as `$94` or by name
  (`Op94_WalkToObj`), with its operand bytes: movement, animation, facing, sound,
  music, palette, battle and other opcodes. Lowering checks its length against
  the opcode table derived from the ROM and refuses jumps, ends and message
  opcodes (use `if`/`jump`/`call_obj`/`text`).
- `if <symbol> { ... }` with optional `else { ... }`; maximum nesting 64.
- Identifiers can be bare or JSON-quoted, including escaped quotes, Unicode and
  whitespace. Canonical output quotes every identifier. Identifiers must occupy
  1–255 UTF-8 bytes. `//` comments are supported; `#` comments must be the first
  non-whitespace content of the line so they don't conflict with call syntax.
- Source limit: 1 MiB. Both LF and CRLF files are accepted.

## Persistence and compatibility

`scenes/<id>.event.dsl` is authoritative when present. The matching
`.event.json` contains the cached AST, scene ID and graph layout. Loading an
externally changed DSL uses its semantics and clears old layout when function
contents differ. A JSON-only scene remains supported; saving generates its DSL.
Malformed DSL fails loading with a diagnostic rather than falling back silently
to stale JSON. A scene's JSON ID must match its filename.

Saving validates all scenes before touching any project file, writes canonical
DSL and JSON, and uses atomic replacement per file. Comments and custom
whitespace are not retained on save. Saving the whole bundle is not a
transaction: an I/O failure between file replacements can leave mixed versions;
retain backups/version control for important projects. Layout node IDs correspond
to function indices. Layout stays in JSON, not the compiled archive.

`EventBytecode.compile` now throws on invalid data instead of clamping integers
or emitting malformed string lengths. Existing valid internal payloads remain
compatible, including corrected decoding of conditionals without `else`.
The internal opcodes are unrelated to the ROM ISA in `event_vm_isa.json`.

## Chrono Trigger bytecode

The CT Bytecode tab lowers the current script, saved or not, to a Chrono
Trigger event pack and shows its listing, or the reason it cannot be lowered.
`chronoforge event lower` does the same for saved scenes. The mapping, its
evidence against the ROM's handlers and its limits are in
[Event bytecode](event_bytecode.md); map calls are refused there too. When a
scene uses `call_obj`, Validate lowers it together with the scenes it calls.

## ROM locations (ct-scene/1)

The Scenes pane's **ROM Locations** mode opens the event pack a location loads
(LocRom field `+8`, an index into `Evt_PackPtrs` at `$FC:F9F0`) as a scene
document. Pick a location by number or from the project's imported maps and,
if needed, the ROM with **Choose ROM…** (the same ROM the Music pane plays
from; `--rom` at launch overrides it). The document is `CTSceneDocument`
(`ChronoForgeCore/CTSceneDocument.swift`): the pack's `CTEventProgram` with
every function entry, statement and its absolute offset, the object
continuations (function 0 goes on past its first `$00`) and the cross-object
calls `$02`–`$07` with their member, level and mode. Packs hold up to 64
objects (the `Obj` tables are `$80` bytes of words), not 16. Lowering the
document gives the pack's bytes back; `scene verify-rom` checks that for every
non-empty pack, through the `ct-scene/1` JSON form as well.

Four views share one selection (object, function, statement offset):

- **Listing**: the pack as `ct-events/1` text with `; ── obj K func F (role)`
  headings. The cursor selects the statement on its line; **Apply Listing**
  reassembles the edited text through the verifier.
- **Node Graph**: one column per object and one node per function (functions
  that share an entry are one node, "+n"), plus each object's continuation.
  Arrows are calls, coloured by mode (wait, retry, start) and labelled with
  the call level and, for `$05`–`$07`, the party member.
- **Timeline**: the pack run through `EventScheduler` (`CTSceneTimeline`):
  all objects start their startup functions; an optional trigger starts one
  function at a chosen level. One lane per object over logical frames; `$AD`
  and `$B9`/`$BA`/`$BC`/`$BD` waits are bars, other statements ticks coloured
  by category. Clicking an event selects its statement.
- **Map**: the location's picture through the PPU renderer when the project
  has imported that location (Maps), otherwise a tile grid. Objects are drawn
  at their `$8B`/`$8D` placement, PCs with frame 0 of their sprite set.
  Paths are the `$96` (walk, solid) and `$A0` (move, dashed) targets in
  order; `$E7` camera keyframes show a 16×14-tile frame. Tools: Select
  (drag a point to move it), Walk/Move/Camera (click to add a point after the
  selected statement), Place (set or insert the object's `$8B`) and Copy
  Object (`duplicateObject`, a placed copy in a free slot). Chests come from
  `TreasureRom` and are edited in Maps.
- **Objects**: each object's kind, placement, markers and functions.

The inspector below shows the selected statement. **Set Operands**, **Remove**
and **Insert after** (any non-jump opcode with its operands) reassemble the
pack; a failed edit changes nothing. `$D8` battles show their flag bits and
`$C8` the menu the argument opens. **Save** (⌘S) writes
`scenes/rom/packNNN.ctevt` and points `rom.eventPacks` at it, so the ROM
builder replaces that pack; **Revert** drops the row; **Reraise from ROM**
discards edits.

Map objects are named only from handler evidence:

| Kind | Evidence |
|---|---|
| save point | `$C8` with a nonzero argument, bits 7 and 0 clear → BankC2 argument 6 → menu mode `$0B` (`Menu_Mode0BH1` → `Menu_Mode06H1Confirm` → `Menu_SaveToSlot`) |
| encounter | `$D8 a b`: `Battle_Unk2989` = a, `FieldBtl_EvtFlags` = b; bit 5 `FieldBtl_EvtNoReset`, bit 6 `FieldBtl_EvtKeepMusic`, bit 7 `FieldBtl_EvtUnk80` |
| battle object | `$7E` sets `FieldBtl_ObjUnk1A81Bit` (carried into `FieldBtlObj.Flags`) |
| PC n | `$57`/`$5C`/`$62`/`$6A`/`$68`/`$6C`/`$6D` (characters 0–6) or `$80 n` |
| sprite | `$81` (record), `$82` (WRAM sprite), `$83` (enemy sprite) |
| chest | not an object: `TreasureRom`, checked by the field engine (`Field_CheckTileInFront`, `$C0:1DF4`) |

Other `$C8` arguments: 0 → argument 5 (mode `$07`); bit 0 → argument 0 (mode
`$0E`); bit 7 → bits 7–6 give argument 2 or 3 (mode `$0C` shop, `$0D`), with
bits 5–0 as X. An "encounter" is an object that starts a battle; many are
controllers running a scripted fight. Which formation `a` selects is not
identified.

Timeline limits: conditions fall through (their jumps are not taken) and a
revisited offset ends a walk; moves, animations and messages are instants; a
trigger at frame 0 runs alongside the startups, which the game runs at load
first; the party is an assumption (the first three PC objects by default).
Direction moves (`$92`/`$9C`) are not drawn on the map, and the camera frame's
anchor is not established.

## CLI

From the repository root:

```sh
swift build --package-path macos_studio
macos_studio/.build/debug/chronoforge scene compile \
  macos_studio/Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj/scenes/intro.event.dsl \
  --project macos_studio/Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj \
  --out /tmp/intro.cfscene
macos_studio/.build/debug/chronoforge scene decompile /tmp/intro.cfscene
macos_studio/.build/debug/chronoforge scene preview /tmp/intro.cfscene \
  --project macos_studio/Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj \
  --flag MET_LAYLA --entry 0 --steps 1000
macos_studio/.build/debug/chronoforge scene run /tmp/intro.cfscene \
  --project macos_studio/Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj \
  --entry 0 --steps 1000 --frames 10000
```

ROM locations (the ROM stays where it is; nothing is written next to it):

```sh
macos_studio/.build/debug/chronoforge scene raise re_workspace/ct_clean.sfc 29 [--json] [--out f]
macos_studio/.build/debug/chronoforge scene graph re_workspace/ct_clean.sfc 29 [--json]
macos_studio/.build/debug/chronoforge scene timeline re_workspace/ct_clean.sfc 29 \
  [--trigger 5.6 --level 1] [--frames 600] [--steps 5000] [--party 1,2,3] [--json]
macos_studio/.build/debug/chronoforge scene verify-rom re_workspace/ct_clean.sfc \
  --manifest re_workspace/manifests/event_pack_verification.json
```

`--pack entry` overrides the location's pack. `raise --json` is the
`ct-scene/1` document plus its analysis; `verify-rom` prints
`N of N non-empty event packs raise to ct-scene/1 and lower back byte-exact`.
Output of these commands is extracted game data; keep it local.

Inputs: `.dsl`, `.event.json`, `.cfscene`. Compile requires a `.cfscene` output;
decompile emits canonical DSL, preview emits JSON. `--out` redirects either to
an atomically replaced file. `--project` checks all references and supplies
preview dialogue. Without it, compilation checks syntax/structure only.
`--flag` is repeatable; `--steps` accepts 1–100000. Input cannot equal output.
Usage errors exit 2; parse/validation/I/O errors exit 1; successful operations
exit 0. The preview result's `stopReason` distinguishes completion, external
calls and the execution limit; a bounded trace itself is a successful operation.

`scene run` requires `--project` and executes the multi-object scheduler. The
input replaces the project scene with the same filename stem (removing only
`.event.dsl`, `.event.json` or `.cfscene`, preserving dots within the ID).
`--frames` accepts 1–1000000; optional `--party` takes 1–3 distinct slots in
0–15. Its JSON includes per-object final state and distinguishes all-idle,
deadlock, frame limit, step limit and external map-call stops.

Archive bytes: ASCII `CFSC`, version byte `1`, object byte, then the legacy
Studio function payload. Unsupported versions, bad UTF-8, invalid function IDs,
unknown opcodes, unmatched delimiters, truncation and trailing bytes are rejected.
This archive is not the CT format; see the CT Bytecode section above.

## Verification

```sh
swift test --package-path macos_studio
python3 macos_studio/tools/verify_scene_cli.py
macos_studio/.build/debug/chronoforge scene verify-rom re_workspace/ct_clean.sfc \
  --manifest re_workspace/manifests/event_pack_verification.json
bash re_workspace/tools/verify_all.sh
```

Tests include independent golden bytes, malformed/truncated payloads, missing
else branches, nested references, both preview branch outcomes, bounded loops,
external calls, source/JSON persistence, and prevention of writes after compile
failure. The CLI integration test executes the real compiled binary and is
part of the master gate. The bundled release CLI can be tested by passing its
path as the script's first argument. `CTSceneDocumentTests` uses a synthetic
two-object pack; its three ROM tests (every pack raised and lowered, every
pack run on the timeline, locations to packs and map objects) skip without a
local ROM.

## Message preview

With a ROM chosen, the statement inspector shows a message statement (`OpBB`,
`OpC0`–`OpC4`) in the in-game dialogue box: the table is the last
`OpB8_SetMsgPtr` before it, and `OpC2`/`OpC4` place the box at the bottom. It
uses `DialoguePreviewView` (page stepping, frame-by-frame play, overflow
warnings); see [dialogue box](dialogue.md). `--scene-statement 0340` at launch
selects a statement by offset.
