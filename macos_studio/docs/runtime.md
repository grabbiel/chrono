# Embedded runtime (Story Mode Orchestrator, slices 2 and 3)

Play one ROM location in a native window: the location's event pack runs in
`CTEventVM`, the field frame in `CTFieldRuntime`, and the picture on the PPU
model's Metal view, with the story flags, the objects and breakpoints beside it.
Everything is read from your ROM; nothing from it is stored in the project.

| Part | File |
|---|---|
| Event VM (Evt_RunObjScriptSteps, the opcode handlers) | `ChronoForgeCore/CTEventVM*.swift` |
| Field frame (load, D-pad, A button, box, motion, warps, music commands) | `ChronoForgeCore/CTFieldRuntime.swift` |
| The leader's collision (`Map_Unk8A6D` and its probes, `Map_StepTileEffects`) | `ChronoForgeCore/CTFieldProbes.swift` |
| The camera (`Map_Unk9175`, `Map_Unk99DE`, `Map_Unk91AC`, layer 1 of `Map_Unk93E1`) | `ChronoForgeCore/CTFieldScroll.swift` |
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

The last full run: 19 families, 206 opcodes modelled, 203 verified on 2,670
operand sets, 9,978 of 9,980 cases agree and none disagree. `$3B`, `$3C` and
`$5D` are modelled but no pack uses them. Two `$83` cases (two states of the
same instruction) are unverifiable: the handler runs past the interpreter's
step limit. The per-family counts are in
`EVIDENCE` at the top of `ct_event_vm.py`; `test_event_vm.py` checks them
against the Swift family table. The modelled opcodes cover 140,700 of the
packs' 142,702 instructions. The cases run in a process pool (`--jobs`,
default the CPU count). The full run took 922 s with 8 jobs on 2026-10-23,
while other jobs loaded the machine. The serial run before slice 3 took about
2 h.

Slice 3 added these families:

| Family | Opcodes |
|---|---|
| membership | `$D2` `$D3` `$D4` `$CF` `$D0` `$D1` `$D6` |
| items | `$CA` `$CB` `$C9` `$C7` `$CC` `$CD` `$CE` `$D7` |
| gather | `$D9` `$DA` |
| maps (region copies) | `$E4` `$E5` |
| palettes | `$88` `$2E` `$33` |
| steps | `$7A` `$97` `$98` `$99` `$9A` `$9D` `$9E` `$9F` `$A1` |

`ct_event_vm.py unmodelled` lists the opcodes the packs use that are not
modelled, with their use counts. 17 remain, 2,002 of 142,702 instructions:

| Opcode | Uses | Handler |
|---|---|---|
| `$32` | 342 | `Evt_Op32_CreditsLine` |
| `$2F` | 318 | `Evt_Op2F_SetCreditsPos` |
| `$FF` | 248 | `Evt_OpFF_Misc` |
| `$2A` | 173 | `Evt_Op2A_Field54Bit2` |
| `$FE` | 157 | `Evt_OpFE_WinQuad` |
| `$DF` | 150 | `Evt_OpDF_WarpNowUnk1E` |
| `$EE` | 113 | `Evt_OpEE_WaitApuio3` |
| `$2B` | 111 | `Evt_Op2B_Field54Bit3` |
| `$C8` | 110 | `Evt_OpC8_EnterBankC2` |
| `$ED` | 79 | `Evt_OpED_WaitApuio1` |
| `$29` | 68 | `Evt_Op29_StartCredits` |
| `$2C` | 48 | `Evt_Op2C_SetLayer3Pos` |
| `$E1` | 43 | `Evt_OpE1_WarpNow` |
| `$F8` | 32 | `Evt_OpF8_BankC2Cmd06And07` |
| `$D5` | 6 | `Evt_OpD5_BankC2Cmd0A` |
| `$F9` | 2 | `Evt_OpF9_BankC2Cmd06` |
| `$FA` | 2 | `Evt_OpFA_BankC2Cmd07` |

### Field routines

`ct_event_vm.py routines` compares the field's routines the same way: the ROM
routine in the interpreter against `chronoforge runtime vectors` on seeded
states of the map page (`$7E:1D00`), the direct page, the objects and the
tile planes; X, the carry and every written byte must agree. The camera's
states are biased toward the map's limits. The probes' states are biased
toward a box offset from a tile edge, and toward exit records near the `$3F`
row limit. The last run, 2026-10-23:

| Routines | Cases each | Agree |
|---|---|---|
| `palAnimTick`, `palClaim`, `palRelease` | 200 | all |
| `mapInitOrigin`, `mapInitOriginX`, `mapInitOriginY`, `mapLeaderSteps` (`Map_Unk9175`), `mapCameraSteps` (`Map_Unk99DE`), `mapScrollAcc` (`Map_Unk91AC`), `mapScroll1XInc`/`XDec`/`YInc`/`YDec`, `mapRecentre` (`Field_Unk885A`) | 200 | all |
| `mapHitsObj` (`Map_ProbeHitsObj`), `mapEntryTile` (`Map_InitEntryTile`) | 200 | all |
| `mapLeaderProbes` (`Map_Unk8A6D`), `mapStepEffects` (`Map_StepTileEffects`) | 2,000 | all |

Single mutations of the camera and probe ports each make the comparison
fail. Among the probe mutations:
- the ADC without CLC in the corner slide;
- the hit test's carry;
- the 8-bit index after a pending warp;
- the `$3F` exit row limit.

## Field frame

`CTFieldRuntime.step(input:)` is `GameLoop_FrameBody` for the field, in the
ROM's order. It names only what the routines show:

1. **Field_SceneChangeTick**: with `SceneFlags` bit 7, the warp: `Loc_Return*`
   from the leader, `Loc_Id` and the entry from `Loc_Dest*`, then the load of
   the destination. **WRAM is kept**, so story bytes set in one location are
   seen in the next.
2. **Field_FrameUpdate**: the push step, then the D-pad (gated by `Unk62`,
   `ControlEnabled` and `Field_Unk38`): `±$10` a frame, `±$20` with B. With
   `Field_Unk20` set, `Map_Unk8A6D` (`CTFieldProbes.swift`). The leader's box
   is X ±`$70` and up to `$70` above the foot. It probes for an object in the
   way (`Map_ProbeHitsObj`: `$E0` near, solid with `Obj_Unk1B01` bit 0, which
   sets `Field_UnkEB`), then the tiles on the leading edge
   (`Map_ProbeTileLevel`: the tile's halves, slopes from the ROM's tables,
   split shapes and the stair shape). A blocked corner turns the step into a
   `$10` slide along the edge, with the ROM's own carries. A diagonal probes
   its leading corner and the two edges' other corners. `Map_StepTileEffects`
   commits a kept step at the foot: a blocked level stops it, and an exit
   (`Map_TileExitIdx`, the map's record) sets the warp. It also sets the
   level, the priorities, the tile animation and the push. Then the camera:
   `Map_Unk9175` limits the leader's steps at the map's edges,
   `Map_Unk99DE` drops the camera's steps until the leader is past the
   screen's middle, `Map_Unk91AC` runs the scroll-to (`$E7`), the shake and
   the accumulators, and `Map_Unk93E1` moves layer 1. The camera is
   `TileOriginX × 8 + fine`. A map redraw (`$E5`) first steps it to a
   16-pixel boundary (`Field_Unk885A`).
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
ROM's routines they call do.

The load runs `LocLoad_AudioSetup`. With `Audio_Unk7F01ED` clear it sends
`$81` (0, `$FF`, `$FF`), then the location's music (`LocRom.Music`; bit 7 means
no change), and keeps it in `Menu_Config1E`; with it set, it plays
`Menu_Config1E` again. `$EA` sends `Audio_CmdPlayMusic` too. `music` is the
last track asked for.

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
- **State**: the party (`Menu_PartyOrder`'s active and reserve places), gold,
  the items, and the log of the opcodes' party, item and gold changes. It also
  shows the palette animator's live records (kind, frame, tick, raw bytes),
  swatches of every colour the palette opcodes wrote, and each stopped object
  with why it stopped.
- **Changes**: the log of every story-byte change.
- **Music**: the song the field last asked for (at load, or by `$EA`) plays
  through the Studio's `AKAOAudioEngine` (`SPCStream.ctSong` from the ROM).
  A new song replaces it; the same song asked for again keeps playing. The
  **Music** button mutes it, and closing the window stops it.
  `--play-music off` starts muted.

## CLI

```sh
chronoforge runtime run <rom.sfc> <location> [--frames N] [--input script] [--trace] [--trace-frames]
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
instruction (`--trace-frames` prefixes each line with its frame, `load` for
`Evt_InitObjects`, as the [Scene Director's VM timeline](scene_director.md#vm-timeline-ctscenerun)
checks it); `--json` writes the summary; `--png` draws the last frame (map
layers from the project's tilesets when `--project` is given).

## Hooks for the Scene Director

`CTFieldRuntime` has opt-in switches that leave the default run unchanged:
`packOverrides` (a location's pack replaced, e.g. an edited scene),
`runsScrollTo` (`$E7` scrolls the camera as `Map_Unk91AC` does; the camera
holds there until the leader walks past the screen's middle, then follows).
`romAnimLoops` is on by
default: the duration evidence (`ct_scene_run.py durations`) found that the
ROM's `Obj_AnimTickAndQueue` takes **2** off a loop count of 3 or more
(`DEC`, `DEC`, `STA`) where `animTick` took 1 (24 of 24 animation cases
agree with the ROM's rule, 12 of 24 with the old one). Turning it off only
replays traces taken before 2026-10-23.

## Limitations

- Camera: layer 1 only. Layers 2 and 3's scroll, their own steps and the edge
  builders are not run. The redraw's own frames after `Field_Unk885A`
  (`Field_BuildC800Mode*`) are not counted.
- `Evt_PushTarget` (pushing objects) and treasure opening are not run.
- The box is `CTDialogueLayout`'s; the D-pad is held while it is open; a choice
  answers its first line.
- The frame-build queue is drained every frame, so every object animates.
- `Party_LeaderAnim` has no idle or stair rows; followers hold their place.
- No battles, menus or fades. The location's own palette animation records
  (`FieldFD_LoadAnimSetB`) are not loaded. Overworld destinations and special
  warps stop the run with a reason.
- Music: only `Audio_CmdPlayMusic` is played. The other sound commands
  (effects, `$81`, volume and fades) are logged, not played.
- The opcodes `ct_event_vm.py unmodelled` lists stop their object.
