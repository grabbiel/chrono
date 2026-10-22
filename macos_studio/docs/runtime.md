# Embedded runtime (Story Mode Orchestrator, slice 2)

Play one ROM location in a native window: the location's event pack runs in
`CTEventVM`, the field frame in `CTFieldRuntime`, and the picture on the PPU
model's Metal view, with the story flags, the objects and breakpoints beside it.
Everything is read from your ROM; nothing from it is stored in the project.

| Part | File |
|---|---|
| Event VM (Evt_RunObjScriptSteps, the opcode handlers) | `ChronoForgeCore/CTEventVM*.swift` |
| Field frame (load, D-pad, probes, exits, A button, box, motion, warps) | `ChronoForgeCore/CTFieldRuntime.swift` |
| Picture (objects' frames as OBJs, the dialogue box band) | `ChronoForgeCore/CTFieldPicture.swift` |
| Flag log and breakpoints | `ChronoForgeCore/CTFieldDebugger.swift` |
| Play window and inspector | `ChronoForgeStudioApp/RuntimeWindow.swift`, `Panes/RuntimeInspectorViews.swift`, `ProjectStore+Runtime.swift` |
| CLI | `chronoforge/RuntimeCommand.swift` |
| ROM-handler evidence | `re_workspace/tools/ct_event_vm.py` |

## Event VM

`CTEventVM` runs a `CTEventPack` as the ROM does: `Evt_InitObjects` (the object
tables' initial values, every object's function 0 up to its first `$00`),
`Vblank_Unk59D9`'s queue (kind 0 at the head, the others at the tail) and
`Evt_RunObjScriptSteps` (up to `Field_Unk68` opcodes while each handler returns
C=1). Call levels use `Obj_Unk1C00` and the `$7F:0580` save tables.

Each modelled opcode is a Swift twin of its handler. **Unmodelled opcodes stop
the object** with the opcode's name as the reason; the rest of the location
keeps running, and the inspector, the CLI and `summary()` show the reason.

### Evidence

`ct_event_vm.py check` runs every modelled opcode two ways on the same WRAM:

- the ROM's handler (from `Evt_OpcodeTable`, `$C0:5D6E`) in ChronoRET's 65816
  interpreter, entered as `Evt_RunObjScriptSteps` enters it (M=1, X=0,
  DP=`$0100`, DB=0, Y = the opcode's offset);
- `chronoforge runtime vectors`, the model.

The operand sets are the distinct instructions the ROM's packs use (24 per
opcode, sampled when there are more), each over seeded random states of the
object tables, story bytes, event words, the field's direct page, pad latches
and tile attributes. A case agrees when X, the carry and every WRAM byte either
side wrote are equal (the handlers' DP scratch left out). Five ROM routines run
as external calls (their code byte zeroed): `Audio_DriverCommand` (`$C7:0004`),
the field's party routines `$C0:9E29`, `$C0:A26B`, `$C0:A2CE`, and
`Evt_StartTargetFunc2` (`$C0:3154`); the model records the same requests.

The per-family counts of the last full run are in `EVIDENCE` at the top of
`ct_event_vm.py` and in the hand-over note; `test_event_vm.py` checks them
against the Swift family table. `ct_event_vm.py unmodelled` lists the opcodes
the packs use that are not modelled, with their use counts.

## Field frame

`CTFieldRuntime.step(input:)` is `GameLoop_FrameBody` for the field, in the
ROM's order. It names only what the routines show:

1. **Field_SceneChangeTick**: with `SceneFlags` bit 7, the warp: `Loc_Return*`
   from the leader, `Loc_Id` and the entry from `Loc_Dest*`, then the load of
   the destination. **WRAM is kept**, so story bytes set in one location are
   seen in the next.
2. **Field_FrameUpdate**: the push step, then the D-pad (gated by `Unk62`,
   `ControlEnabled` and `Field_Unk38`): `±$10` a frame, `±$20` with B. With
   `Field_Unk20` set, `Map_Unk8A6D`'s probes: an object in the way
   (`Map_ProbeHitsObj`, `$E0` near, solid with `Obj_Unk1B01` bit 0, which sets
   `Field_UnkEB`), two tile probes on the leading edge
   (`Map_ProbeTileLevel`'s halves, slopes from the ROM's tables, split shapes and
   the stair shape), then `Map_StepTileEffects` at the foot: a blocked level stops
   the step; exits (`Map_TileExitIdx`) set the warp. The limits come last.
3. **Field_ActionButton**: a new A press starts the target's function 1
   (`Evt_StartTargetFunc1`) when the leader is touching an object, or else the
   object in front (`Field_FindObjInFront`, `$1C0` ahead and `$C0` aside).
4. **Field_Unk1F87**: the dialogue box. A message opcode sets `Field_Unk29`;
   the runtime lays the message out with `CTDialogueLayout` (the
   [dialogue box](dialogue.md)'s pacing) and holds at each key wait until a new A
   press, then clears `Field_Unk29`.
5. **Field_EndOfFrame**: the queue, the scripts, then `Vblank_UnkA810`'s motion
   (`Obj_MoveStep` in-tile and cross modes, arcs with gravity, the view flags and
   `Obj_AnimTickAndQueue`).

The party-control opcodes `$AF`/`$B0` ask the field to run the leader
(`Party_LeaderAnim`'s rows and facing from the pad) and the touch check, as the
ROM's routines they call do. The camera follows the leader inside the map's
limits.

## Studio: Play

**Play** in the Maps toolbar (the selected map's ROM location), **Play…** in the
Scenes pane's ROM mode, and **Play** in the Story pane open the Play window
(`--play N` at launch). It needs the ROM set in Scenes (as for scene previews).

- The location on a Metal `SNESPPUView`: the map's layers from the imported
  tilesets, the objects' frames as OBJs, and the dialogue box over it.
- Keys: arrows walk, **X** is A (talk, next page), **Z** is B (run), **A**/**S**
  are Y/X, Return is Start. **Space** plays and pauses, **.** steps a frame;
  **Step 10** and **Restart** beside them.
- **Objects**: per object its kind, function and offset, call level, tile and
  position, facing, movement and wait, its last instruction, its call stack and
  why it stopped.
- **Flags**: the story bytes by registry symbol (Story → Import Story from ROM),
  or every byte by address. A flag that changed in the last 120 frames is
  highlighted with the frame, object, offset and opcode that changed it. Edits
  set the flags the next run starts with (**Restart with these flags**).
- **Breakpoints**: on a flag (the pause button beside it; a whole byte or one
  bit) or on an instruction offset, in one object or any. A hit pauses the run
  at the end of its frame and says what hit.
- **Changes**: the log of every story-byte change.

Music is not played: `AKAOAudioEngine` is not driven by the runtime's sound
opcodes yet (they are recorded and listed by the CLI).

## CLI

```sh
chronoforge runtime run <rom.sfc> <location> [--frames N] [--input script] [--trace]
                        [--json out.json] [--party 0,1,2] [--entry x,y[,facing]]
                        [--flag addr=value ...] [--png out.png [--project p.ctproj]]
chronoforge runtime vectors <rom.sfc> <cases.json> --out <results.json>
re_workspace/.venv/bin/python re_workspace/tools/ct_event_vm.py check [--ops AF,B0] [--per-op N] [--json report.json]
re_workspace/.venv/bin/python re_workspace/tools/ct_event_vm.py unmodelled
```

`<location>` is decimal, `$hex`, `0x…` or `loc_NNN`. An input script is
`FROM[-TO] BUTTON[+BUTTON]` entries separated by `;` or newlines (`#` starts a
comment), for example `0-19 up; 20 a`. `run` prints each object's state (and
`STOPPED: reason`), the messages and the warps; `--trace` prints every
instruction; `--json` writes the summary; `--png` draws the last frame (map
layers from the project's tilesets when `--project` is given).

## Limitations

- Leader probes: `Map_Unk8A6D`'s four straight cases without the corner slides;
  a diagonal runs the X case then the Y case.
- Camera: centred on the leader inside the limits, not `Map_Unk91AC`'s scroll.
- `Evt_PushTarget` (pushing objects) and treasure opening are not run.
- The box is `CTDialogueLayout`'s; the D-pad is held while it is open; a choice
  answers its first line.
- The frame-build queue is drained every frame, so every object animates.
- `Party_LeaderAnim` has no idle or stair rows; followers hold their place.
- No battles, menus, fades, palettes or music; overworld destinations and
  special warps stop the run with a reason.
- The opcodes `ct_event_vm.py unmodelled` lists stop their object.
