# ROM builder (`.sfc`)

`chronoforge rom build` (and **Story → Build ROM…** in Studio) writes a project's
event packs and songs into a copy of the clean Chrono Trigger US 1.0 ROM and
fixes the header checksum. It starts from the unmodified ROM every time (SHA-256
`06d1c2b0…829a9`; a 512-byte copier header is dropped); a built ROM is refused as
a base. The output is game data: keep it local.

## Project settings

`project.json` gains an optional `rom` section:

```json
"rom": {
  "eventPacks": [
    { "entry": 23, "scenes": ["intro"] },
    { "entry": 30, "listing": "events/entry030.ctevents" }
  ],
  "songs": [
    { "song": 1, "listing": "audio/songs/song01.ctsong" }
  ]
}
```

`songs` replaces `Audio_SongTable` entries (0–82) with `ct-song/1` listings. See
[song sequences](music_sequences.md); Studio sets these rows in **Music → CT Songs**.

Each row replaces one `Evt_PackPtrs` entry (0–512) with either:

- **scenes**: Studio scenes on distinct object slots, lowered as in
  [event bytecode](event_bytecode.md). Their `text` messages are compiled with
  the project's ROM text profile into a message table for the pack.
- **listing**: a `ct-events/1` listing in the project (`chronoforge event disasm`
  exports one from your ROM to edit). Its `$B8` operands are kept as written, so a
  listing of a ROM pack keeps using its original message table.

`chronoforge rom locations <rom>` lists the events entry of each of the 512
locations (`LocRom.Events`, `$F6:0000` + 14 × location + 8). Several locations can
share an entry; replacing it changes all of them. 25 entries do not point at an
event pack (entry 0 points at a graphics pack, seven at an empty stream, the rest at
bytes that do not decode) and are refused.

Validate (gate 4) checks the rows: entries, duplicates, scenes that exist and
lower, listings that exist, and song listings that assemble.

## What the builder does

1. Decodes every new pack with the derived opcode table and applies the game's
   own load checks (`LocLoad_CheckEvtData`): 1 to `$1700` unpacked bytes, and not
   13 objects with first script byte `$0A`.
2. Places each message table (16-bit addresses in the table's own bank, then the
   strings, identical strings shared; at most 256) and writes its 24-bit address
   into every `$B8` relocation of the lowered pack.
3. Packs each pack with the original packer (lz11) and places it, in order of
   preference: at its old stream's start, sharing an identical pack already
   placed, in the leftover span of another replaced stream, then in free space.
4. Places each song (length word, then data) with the same order of preference.
   A song stays at its old place only if it fits inside that place. Then the
   builder writes its `Audio_SongTable` pointer.
5. Writes the `Evt_PackPtrs` entries and the checksum and complement.

Pack and table placement never crosses a bank (a song may): `Decomp_ToWram` reads a pack with DB = its bank
and a 16-bit index, and `TextWin_Init` reads the table's entries as addresses in
the table's bank.

**Free space** is the 66 padding rows (62,206 bytes) that ChronoRET's data survey
marks *confirmed* ("uniform fill; nothing points into it"), byte-verified in your
ROM by `re_workspace/tools/ct_rom_layout.py` (manifest `rom_layout.json`, Swift
twin `CTROMLayout.swift`); 12 *probable* rows are not used. A replaced stream's
span, or a replaced song's span, is reused only when nothing unchanged still
points at it. Message tables go
only into free space. Space runs out at about 62 KB plus the replaced packs:
a build that needs more stops with the sizes left; expansion to ExHiROM is not
implemented.

The report (`--report`, or `<name>.build.json` from Studio, schema
`ct-rom-build/1`) lists each pack's address, sizes, unpacked SHA-256 and
placement, each message table with each message's address and source text,
each song's address, size, data SHA-256 and placement,
every byte range written, and the free space left.

## The packer

`libctcodec`'s `ct_lzss_compress` and Swift's `LZSS.compress` are the original
packer: Haruhiko Okumura's LZSS (1989) with Square's framing, identified by
ChronoRET (`tools/c3pack.py`, MIT). It rebuilds every packed block in the ROM byte
for byte: the 1,053 surveyed blocks and all 463 event-pack streams
(`re_workspace/tools/verify_lzss_corpus.py`). C, Swift and the Python transcription
agree on synthetic inputs too (window edges, partial groups, 64 KiB).

## Verification

- **Identical rebuild** (`CTROMBuilderTests`): all 488 event entries rebuilt from
  their own listings produce the clean ROM byte for byte, with no write reported.
- **Independent check** (`re_workspace/tools/ct_rom_check.py`, in the master gate
  via `macos_studio/tools/verify_rom_build.py`): a CLI build of a lowered scene
  (with three messages) and an edited listing that no longer fits its old place is
  checked without the Swift code: ChronoRET's `Decomp_ToWram` transcription
  unpacks every pack; the table-driven decoder decodes them; every changed byte is
  inside a report write and every write inside free space, a freed stream, a
  rebuilt pointer or the checksum; untouched entries unpack as before; `$B8`
  operands point at the table; the ROM's own `TextWin_Init` (run with ChronoRET's
  abstract interpreter) finds each message, whose bytes equal the source text
  encoded by ChronoRET's encoder; the checksum is valid. The build also writes two
  songs, one unchanged and one grown past its old place. The checker reads their
  pointers, hashes and walks with `ct_spc_seq.py` and requires every untouched
  song to be unchanged. Five deliberately damaged copies (with consistent
  checksums and report hashes) are each rejected.
- **Songs** (`CTSongTests`): all 83 songs rebuilt from their listings leave the
  ROM identical.

## Limitations

- No emulator run: the evidence is the ROM's own loader, decompressor and text
  routines as traced or transcribed, not a booted game.
- Only event packs, message tables and song sequences are written. New locations,
  maps, graphics, samples, per-song tables, sound effects, items and other tables
  are not.
- Lowered packs cover the Studio statements in `event_bytecode.md`; cross-map calls
  are refused.
- Free space is limited to the confirmed padding; ExHiROM (6/8 MB) expansion is not
  implemented.
