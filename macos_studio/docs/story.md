# Story Mode: flag registry and world graph

The first slice of Module 9 records how Chrono Trigger's event scripts use the
story memory, gives every flag a symbol the scene language can use, and builds a
world graph from the scripts' location changes. Everything is read from your ROM;
the project files it writes hold addresses, offsets and counts, never script bytes
or text. They are still game metadata: keep them local.

## Story memory

`Menu_FlagBlock7F` is the 512 bytes at `$7F:0000–$7F:01FF` a new game zeroes
(ChronoRET `ram_menu.inc`). The event opcodes reach it as follows (operand
meanings from each handler, `re_workspace/manifests/event_vm_isa.json`; `check`
cites the row and ChronoRET's handler line for every opcode):

| Opcode | Access | Address |
|---|---|---|
| `$65` SetMemBit / `$66` ClearMemBit | set / clear a bit | `m`, `+$100` when bit 7 of the bit operand is set; mask = BitSet[`bit & $0F`] |
| `$16` IfMemByte | test (Evt_CmpTable8 `cmp & $7F`) | `m`, `+$100` when bit 7 of `cmp` is set; an AND with one bit is a bit test |
| `$18` IfUnk7F0000Below, `$55`, `$5A` | test / read / write | `$7F:0000` (Eng_Unk7F0000) |
| `$1C`, `$53`, `$54` / `$56`, `$58`, `$59` | read / write byte or word | `m` (word), kept when below `$200` |
| `$48`, `$49` / `$4A`–`$4D` | read / write through a long pointer | kept when the pointer is in `$7F:0000–$01FF` |
| `$4E` CopyData | write a block | `dst` when the bank byte is not `$7E` |

The event words (`$4F`–`$7F`, `$12`–`$15`, …) live at `$7F:0200 + 2a` and are
cleared at each location load: they are not story memory.

## Cross-reference

`re_workspace/tools/ct_story.py` and `CTStory.scan` (Swift) walk all 461 event
packs with the handler-derived decode table and record, for every access: the
locations using the pack (`LocRom +8`), the pack's `Evt_PackPtrs` entry, the
object and functions reaching the instruction (function 0 includes the part
after its first `$00`, as `Evt_RunObjInit` runs it), the offset, the opcode and
set / clear / test / read / write.

| Total (US 1.0) | |
|---|---|
| instructions decoded | 142,702 |
| story references | 7,055 (set 1,136 · clear 432 · test 4,830 · read 112 · write 545) |
| distinct bits | 852 |
| bytes touched by events | 219 of 512 |
| location changes | 663 (`$E0` 415 · `$E1`/`$DF` 193 · `$DD`/`$DE` 50 · `$DC` 4 · `$E2` 1) |

Code outside the event VM is found two ways. ChronoRET's matched source gives
699 instructions naming a `$7F:0000–$01FF` symbol (the new-game initialiser,
menu, bank `$C2` scenes, bank `$FD`): **code-proven**. A scan of the ROM for
absolute-long instructions with operand `$7F:0000–$01FF` gives 639 byte patterns:
83 lie in a matched routine whose source has that instruction (**code-proven**),
4 lie in a matched routine that names the address otherwise (**in-routine**), and
552 lie outside matched code (**pattern-matched**: mostly data). A pattern match
alone never makes a byte "used".

### Checks

- `ct_story.py check --run`: the decoded instructions equal the verified
  per-pack counts (`event_pack_verification.json`); the opcodes that always
  address story memory have exactly one reference per instruction; warps equal
  their instructions; BitSet is `01 02 … 80`; and the ROM's own `$65`, `$66`
  and `$56` handlers, run in ChronoRET's 65816 interpreter with concrete WRAM on
  each of the 1,101 distinct operand sets the packs use, change exactly the
  recorded byte as recorded.
- `chronoforge story check <rom>`: the Swift scan reconciles the same way and
  gives the same totals as Python; all 852 registry flags resolve through the
  scene lowering; and the first straight-line ROM path that sets a flag is raised
  into the scene language (`set_flag`/`clear_flag` with registry symbols, other
  opcodes as `ct`), run in `EventPreview` and `EventScheduler` (both end with the
  flags its references record), and lowered back to the ROM's bytes.

## Registry (`story/flags.json`)

`chronoforge story import <rom> <project>` (or **Story → Import Story from ROM…**)
writes `ct-story-flags/1`:

```json
{ "schema": "ct-story-flags/1", "romSHA256": "…",
  "entries": [ { "symbol": "flag_7F00A6_1", "addr": "7F:00A6", "bit": 1,
                 "name": null, "notes": null,
                 "counts": { "set": 2, "test": 3 }, "locations": [20, 208, 464],
                 "references": [ { "site": { "entry": 1, "locations": [208], "offset": 972,
                                             "opcode": 101, "functions": [[11, 1]] },
                                   "access": { "kind": "set", "addr": 166, "bit": 1, "width": 1, "mask": 2 } } ],
                 "code": [ { "status": "pattern-matched", "where": "$E2:AD82", "mnemonic": "ADC ,X",
                             "addr": 166, "width": 1, "access": "read" } ] } ],
  "unused": ["7F:0005", "…"],
  "totals": { "packs": 461, "instructions": 142702, "references": 7055, "warps": 663, "codeReferences": 1338 } }
```

- One entry per bit (`flag_7FXXXX_b`) and per byte used as a whole
  (`var_7FXXXX`), plus a byte entry for bytes only proven code touches. Symbols
  come from the address, so they are stable across rescans.
- `name` and `notes` are the maintainer's and survive rescans. Nothing is named
  by the tools: give a name only with evidence. A name becomes a second project
  flag on the same bit; the generated symbol stays valid.
- `--code-evidence code.json` (from `ct_story.py code --out code.json`) adds the
  ChronoRET source lines and the patterns' statuses; without it the Swift import
  has the ROM patterns only, all pattern-matched.

Bit entries are written into `project.json`'s `flags` with `"origin": "story"`
(see the [schema](ctproj_schema.md)); a rescan replaces only those. Scenes,
Validate, `scene preview` and lowering resolve them like any flag.
`chronoforge story annotate <project> <symbol> --name NAME --notes TEXT` names one.

## World graph (`story/graph.json`)

Nodes are locations; each edge is one location change in a script, from each
location using the pack: destination (`Loc_IdMask` bits of the word), column,
row, and its **guards**: the memory tests (`$16`, `$18`) whose outcome holds on
every path from the function's entry to the warp (a forward must-analysis,
intersected over the functions reaching it). 718 edges, 384 guarded. `$E2`
takes its destination from event words and has no edge; `$DC` sets the
previous location and is not an edge.

**Era groups are inferred.** `GameLoop_Main` sends locations `$1F0` and up to
bank `$C2` (`Loc_FirstBankC2`). Each such location the scripts reach (8:
`$1F0`–`$1F7`) seeds a group; every other location joins the seed nearest over
undirected event edges, ties and unreached locations stay ungrouped (120
locations grouped). Edges between groups (4) are marked **cross-group**: a
candidate time-travel transition. Locations whose neighbours lie in three or
more groups are **hubs** (11). Groups have no names until the maintainer gives
them; the tools never assign era names from game knowledge.

Map exits (`ExitRom`, decoded by the Maps module) and the overworld's exits are
not event scripts and are not in this graph yet: most locations join it through
them. Time-gate and Epoch transitions are not identified beyond cross-group
edges; no script or flag shows them as such yet.

## Studio

**Story → Flag Registry**: search symbols, names, addresses and notes; filter by
bits, bytes, named entries, a location or an inferred group; each entry's event
references (locations, pack, object.function, offset, opcode, kind) and code
evidence; edit the name and notes. ROM scripts are not Studio scenes, so the
Scenes pane cannot open them (it exposes no selection API either); **Copy
command** gives the `chronoforge event disasm` line for the pack.

**Story → Era Graph**: locations in group columns, guarded edges dashed,
cross-group edges orange, hubs purple. Click a location for its edges and guards;
**Flags here** opens the registry filtered to it. Name groups on the right.

Launch with `--open <project> --module Story --select registry|graph|<symbol>`.

## CLI

```sh
chronoforge story flags <rom.sfc> [--location N] [--addr 7F:XXXX] [--json out.json]
chronoforge story graph <rom.sfc> [--json out.json]
chronoforge story check <rom.sfc>
chronoforge story import <rom.sfc> <project.ctproj> [--code-evidence code.json]
chronoforge story annotate <project.ctproj> <symbol> [--name NAME] [--notes TEXT]
re_workspace/.venv/bin/python re_workspace/tools/ct_story.py xref|graph|code|check [--run] [--out file.json]
```

## Limitations

- Static: guards are the memory tests on every path inside one function; a flag
  set by another object, a call level or a previous visit is not followed.
  Other conditions (items, party, event words) are not guards.
- Code references are addresses, not paths: an indexed access (`,X`) is recorded
  at its base address, and code that reaches the block with DB = `$7F` and
  absolute addressing is found only through ChronoRET's symbols.
- The bank `$C3` module is packed in the ROM: its two source references are
  code-proven, but the ROM scan cannot see them.
- Era groups come from event edges alone (see above).

## Later slices (design)

### Embedded runtime

Built in slice 2: see [runtime.md](runtime.md). `CTEventVM` runs the ROM packs
with each opcode family checked against its handler, `CTFieldRuntime` runs the
field frame, and the Studio's **Play** window (from the Maps, Scenes or Story
pane) shows the story flags by registry symbol with the instruction that
changed them, breakpoints on a flag or an instruction, and flags editable
before a run. Music is not played yet.

### `.app` and `.sfc` compiler

- **`.sfc`**: `CTROMBuilder` already writes event packs, message tables, songs,
  characters, techs and items into the 4 MB image, within `CTROMLayout`'s
  confirmed free regions. Larger projects need **ExHiROM**: the image grows past 4 MB, the first
  4 MB stays at banks `$C0–$FF` and the rest is read through banks `$40–$7D`
  (PC `$400000`+). Banks `$00–$3F` `$8000–$FFFF` then map to PC `$400000`+ too,
  so everything the game reads through them (the reset and interrupt vectors, the
  header at `$00:FFC0`, BitSet at `$00:FF20`, code entered in bank `$00`) must be
  copied to PC `$40xxxx`; the header gets map mode `$35` and the new size byte,
  and `CTROMLayout` gains the new banks as free regions. Pointer tables read
  long (`Evt_PackPtrs`, `Audio_SongTable`, message tables) can point there
  directly; code that reads data bank-relative must be listed and patched first,
  so the expansion needs a ChronoRET-backed audit of every `PHB/PLB` and
  fixed-bank read before any data moves. The checksum covers the image as SNES
  headers define it for a non-power-of-two size.
- **Story compile step**: scenes refer to registry symbols; the builder resolves
  them through the project flags (already the case), and Validate should check
  that a renamed or removed registry symbol is not still used (a Validator gate
  is not part of this slice).
- **`.app`**: bundle the runtime above with a built `.sfc` image and the
  project's Studio assets (`tools/bundle_app.sh` packages Studio today); the app
  launches straight into the runtime at `project.start`.
