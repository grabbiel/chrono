# Chrono Trigger event bytecode (location event packs)

ChronoForge can read, edit and write the event packs Chrono Trigger US 1.0
loads for each location, and can lower a subset of Studio scenes to that
bytecode. This page covers the static tooling; the embedded runtime
([runtime.md](runtime.md)) executes the packs: `CTEventVM` models 175 opcodes,
each checked against the ROM's handler, and stops an object on any other.

## Pack format

`Evt_PackPtrs` at `$FC:F9F0` holds 513 long pointers. Each location record
(`$F6:0000`, 14 bytes, field `+8`) names an entry; the entry is LZSS-unpacked
to `$7F:2000`:

```
byte 0            object count n
n × 16 words      function offsets, relative to Evt_Data ($7F:2001)
…                 scripts
```

Function 0 is the object's init: `Evt_RunObjInit` runs it to its `$00` and
the object then continues at the byte after that `$00`. Function 1 is the
action-button handler, 2 touch, 3+ cutscene routines (see
`re_workspace/manifests/event_vm_isa.json` for the VM and every opcode).

## How opcodes are decoded

Opcode sizes and control flow were not typed in. `re_workspace/tools/ct_event_packs.py
derive` traces each handler in the ROM with an abstract 65816 interpreter
(vendored from ChronoRET, MIT) and records, per opcode:

- **length**, or a rule: `counted` (a constant plus a word operand, e.g. `$4E`)
  or `kind` (a 256-entry table keyed on an operand: `$2E`, `$88`, `$F1`, `$FF`, and
  `$C9`/`$CC` whose flow depends on the operand — item 0 is never held);
- **flow**: `n` goes on, `s` stays (waits), `e` ends at an unknown position,
  `j` jumps to `offset + base + sign × operand`.

The kind tables were filled by tracing every value of the deciding byte; other
operand bytes were varied to show they do not change the shape. The table is
committed as `manifests/event_decode_table.json` and generated into
`Sources/ChronoForgeCore/CTEventISA.swift`.

Reachability starts at every function offset, follows `n` and `j`, and adds the
byte after each `$00` reached from a function 0. Bytes never reached are data.
A jump into another opcode's operands is an *inner* opcode sharing its bytes.

## Verification

All 462 packs (461 non-empty) were decoded twice: by the handler traces and by
the table. Both reach identical opcodes with identical lengths, and recomputing
every jump operand from its target reproduces the ROM bytes. Per-pack hashes
and counts are in `manifests/event_pack_verification.json` (no script bytes).
Swift checks the same records and that every pack's listing assembles back
byte-exact. The fixed lengths also match the byte counts in the handlers'
documentation for every documented opcode.

```sh
re_workspace/.venv/bin/python re_workspace/tools/ct_event_packs.py check
chronoforge event verify-rom ct_clean.sfc --manifest re_workspace/manifests/event_pack_verification.json
re_workspace/.venv/bin/python macos_studio/tools/verify_event_lowering.py
```

## Listings (`ct-events/1`)

```
@objects 1
@func 0 0 L_0020            ; $XXXX for an offset outside the scripts
L_0020:
    Op65_SetMemBit $02 $03
    Op16_IfMemByte $03 $04 $06 ->L_002E
    @inner +2 L_0022         ; a label inside the opcode above
@bytes 99 99                 ; data no opcode reaches
```

`chronoforge event list|disasm` read packs from your ROM; `event asm` assembles
a listing. The assembler resolves `->LABEL` jumps (0–255 bytes), checks every
opcode's length against its handler's shape in place, refuses unused opcodes,
and re-disassembles its output: data bytes reached as code, or code reached
inside an opcode without an `@inner` label, are errors. Listings are extracted
game data: keep them local.

## Lowering Studio scenes

`chronoforge event lower <project> <scene>... --out lowered.json` builds one
pack from scenes on distinct object slots. Slots without a scene get an object
that returns at once and halts.

| Studio | CT bytecode |
|---|---|
| function `n` | function slot `n`; ends `$00 Return`, `$B2 Halt` |
| `set_flag F` / `clear_flag F` | `$65` / `$66 bit m` (bit 7 of the bit byte: `$7F:0100` page) |
| `if F {…} else {…}` | `$16 m mask $06 ->else` (AND nonzero; bit 7 of `$06`: page), `$10 ->end` |
| `wait N` | `$AD n` repeated for each ≤ 255 (object runs; one per frame while active) |
| `text id` | `$BB index`; one `$B8` message-table pointer at object 0's init |
| `jump funcK` | `$10` / `$11` to that function's code |
| `nop` | nothing |
| `call_obj S#f mode level L` | `$02` start / `$03` retry / `$04` wait, `[object(S) × 2, L << 4 \| f]` |
| `call_pc p#f mode level L` | `$05` / `$06` / `$07`, `[p × 2, L << 4 \| f]` (`Party_ObjSlot` word index) |
| `ct op bytes…` | the opcode and bytes as written, if the derived table gives that length and the flow goes on (`n`, optionally `s`/`e`); jumps, pure ends and `$B8`/`$BB`/`$C0`–`$C4` are refused |
| `call map#n` | refused: ctproj/1 binds no map function to an object yet |

Flags must live in `$7F:0000–$7F:01FF` with bit 0–7 (`BitSet` at `$00:FF20`
is `01 02 … 80`). Jumps further than 255 bytes and more than 256 messages are
errors. Unused function slots point to a shared `$00 $B2`.

The `$B8` operand is a **relocation**: `lowered.json` lists its byte offset and
the message order; the [ROM builder](rom_builder.md) places the compiled message
table (see [text codec](text_codec.md)) and patches the pointer. An unpatched pack
stops the game at its first message, by design of `$BB`.

`verify_event_lowering.py` lowers two fixture scenes into one pack with the CLI,
decodes it with handler traces, and executes each `$65`, `$66`, `$16`, `$10`,
`$11`, `$02`, `$05` and `$B8` through the ROM's handler with concrete WRAM: bits
are set/cleared, the condition goes on when the bit is set and jumps otherwise,
a call points the target object's `Obj_ScriptPos` at the called function, sets
its level and saves its old position (the hardware product register is supplied,
the interpreter does not model the multiplier), and a patched pointer lands in
`Field_Unk2B`–`2D`. Call levels and the slot encoding (object × 2, party operand
0/2/4) agree with all 8,463 call opcodes in the ROM's packs.

## Limitations

- No dynamic execution: `$AD` timing, `$BB` message flow and object scheduling
  are taken from handler documentation, not emulated.
- Lowering covers the Studio statements above. Movement, animation, camera, sound
  and battle opcodes are reachable through `ct` with their raw operands; their
  semantics come from handler documentation, not from named Studio statements.
  A `ct` opcode with `e` in its flow (e.g. the walks, whose next position goes
  through a saved offset the tracer does not follow) is accepted because its
  normal path goes on. ROM packs are raised as `ct-scene/1` documents
  (objects, functions, offsets, calls; [Scene Director](scene_director.md#rom-locations-ct-scene1)),
  not into the Studio DSL.
- Writing packs into a ROM is the [ROM builder](rom_builder.md)'s job; it is
  limited to the confirmed free space of the 4 MB image.
- `$FF` sub-op `$A9` exceeds the tracer's step budget; it is recorded as
  unknown and refused by both decoders (no ROM pack uses it).
- Opcode names come from the matched disassembly; semantics marked "probably"
  in `event_vm_isa.json` remain unverified.
