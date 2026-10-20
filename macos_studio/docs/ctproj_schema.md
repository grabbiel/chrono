# `.ctproj` — ChronoForge Studio project bundle schema (v1)

> Implementation status: this document includes target features that are not yet
> implemented. The native app builder and a playable runtime remain outstanding.
> The CT dialogue codec ([Text codec](text_codec.md)), event bytecode read/write and
> scene lowering ([Event bytecode](event_bytecode.md)) and an `.sfc` builder that
> writes event packs and message tables ([ROM builder](rom_builder.md)) are
> implemented. Passing the validation gates verifies the
> current formats, not a complete or hardware-accurate game compiler.
> See [Scene Director](scene_director.md) for the implemented scene workflow and
> the repository README's status section for known gaps.

A `.ctproj` is a **directory bundle** (Git-friendly, text-first). Binary decodables
(PNG/BRR/WAV) sit next to their JSON sidecars; every JSON is UTF-8, 2-space indent,
keys ordered by the Studio on save. All SNES-facing values (BGR555 words, tile indices,
opcodes) round-trip through `libctcodec`.

```
MyGame.ctproj/
├── project.json                  # root manifest (schema below)
├── characters/<id>.json          # playable/NPC/enemy definitions
├── sprites/<id>.sprite.json      # OAM sprite assemblies + animation sets
├── sprites/<id>.png              # indexed 16-col sheet (mode P, 4bpp) or 4-col (2bpp)
├── items/<id>.json               # weapons/helmets/armors/accessories/consumables
├── techs/<id>.json               # single/dual/triple techs
├── strings/dialogue.json         # UTF-8 strings; compiler emits CT text codec bytes
├── strings/ct-text-profile.json  # dictionary imported from the user's ROM (optional)
├── audio/samples/<id>.brr        # encoded samples (+ .json loop/ADSR/GAIN sidecar)
├── audio/samples/<id>.wav        # decoded preview (regenerable, gitignorable)
├── audio/tracks/<id>.akao.json   # tracker-format music scores
├── audio/songs/<name>.ctsong     # CT song sequences, ct-song/1 text (optional)
├── tilesets/<id>.tileset.json    # tile bank + metatiles + collision props
├── maps/<id>.map.json            # location header, layers, exits, triggers
├── scenes/<id>.event.dsl         # human-readable event script (canonical source)
├── scenes/<id>.event.json        # compiled AST + visual node layout
└── build/                        # compiler output (gitignored): .sfc, .app
```

## `project.json`
```json
{
  "schema": "ctproj/1",
  "name": "My Game",
  "engine": { "base": "chrono-trigger-us-v1.0", "rom_sha256": "06d1c2b0..." },
  "start": { "map": "overworld", "x": 320, "y": 480, "era": "present" },
  "eras": [ { "id": "present", "name": "Present", "maps": ["overworld", "..."] } ],
  "flags": [ { "symbol": "MET_LAYLA", "bank": "story", "addr": "7F:0003", "bit": 2 } ],
  "encounters": [ { "id": "forest", "rate": 8, "enemies": ["rat_a"] } ],
  "rom": { "eventPacks": [ { "entry": 23, "scenes": ["intro"] },
                           { "entry": 30, "listing": "events/entry030.ctevents" } ],
           "songs": [ { "song": 1, "listing": "audio/songs/song01.ctsong" } ] }
}
```
`rom` is optional: the event packs and songs `chronoforge rom build` writes into
the base ROM (see [ROM builder](rom_builder.md) and [song sequences](music_sequences.md)).
Either list may be absent.

## Conventions (binding for all modules)
- **Color**: stored as hex BGR555 word `"bgr555": "0x7FFF"` + derived `"srgb": [r,g,b]`
  (regenerated on load; BGR555 is authoritative).
- **Coordinates**: SNES native pixels; map coords in 1/16-chip units where the ROM uses them.
- **Sprites**: `frames[] -> tiles[] {x, y, tile, hflip, vflip, pal(0-7), size8|16, anchor}`
  mapping 1:1 onto OAM entries (512 max per frame enforced by the validator).
- **Metatiles**: 16x16 chips = 4 subtiles `{tile, pal, hflip, vflip, priority}`;
  32x32 blocks = 4 chips. Collision props: `{plane1: walk|solid|water|...,
  plane2: ..., plane_swap: bool, zmask: bool, conveyor: none|dir(0-7)}`.
- **Dialogue**: UTF-8 source. With `strings/ct-text-profile.json`, text uses CT
  tags (`{wait 03}`, `{char0}`, `{page}`, newline = `{line}`) and compiles to
  TextWin bytes: substring dictionary (0x21-0x9F) + glyphs (0xA0-0xFF), with byte
  savings reported (see `text_codec.md`). Without a profile the legacy placeholder
  escapes (`\{name:robo}`, `\{wait}`, `\{br}`) apply and are not ROM text.
- **Music**: `.akao.json` = `{tempo, tracks: [{voice, program, pan, adsr_override,
  events: [{t, dur, note, ...}]}], echo: {edl, efb, evoll, evolr, fir[8]}}` (the
  Studio's own score format). `.ctsong` = the game's own song sequences as text
  (`ct-song/1`, [song sequences](music_sequences.md)); the two are not converted.
- **Event DSL (implemented)**: one object slot (`obj 0..15`) per scene, unique
  functions `func 0..15`, and the Studio statements described in `scene_director.md`.
  DSL is authoritative; `.event.json` caches the AST and `{node_id, x, y}` graph
  positions (node IDs are function indices). The internal `.cfscene` archive is
  not ROM bytecode. `chronoforge event lower` lowers scenes to CT event packs
  (`event_bytecode.md`); validation warns when a scene uses statements that
  cannot be lowered yet, such as map calls.
- **Build targets**: `.sfc` event-pack and song repack within the 4 MB HiROM is implemented
  (`chronoforge rom build`, [ROM builder](rom_builder.md)). Not implemented: a native
  `.app` (embedded Swift/Metal runtime), other asset kinds, and ExHiROM 6/8 MB
  expansion.

## Validation gates (enforced by `chronoforge validate` and Swift unit tests)
1. Every referenced id exists; every PNG is mode P with ≤16 (4bpp) / ≤4 (2bpp) colors.
2. OAM budget per frame ≤ 512 entries (1024 for large-sprite modes) — engine rule.
3. Tile bank VRAM budget per BG layer enforced against SNES tile-cache limits.
4. Event scripts compile → bytecode → decompile → AST equality (round-trip gate);
   `rom.eventPacks` rows name event-pack entries and existing, lowerable scenes or
   existing listings; `rom.songs` rows name song indices 0–82 and listings inside the
   project that assemble.
5. With a ROM text profile, every string compiles to a terminated CT message whose
   decode re-encodes byte-exactly; otherwise the placeholder codec round-trip (warning).
6. BRR encode → decode ≈ source WAV within SNES BRR error envelope; loop points
   on 16-sample (1 BRR block) boundaries.
