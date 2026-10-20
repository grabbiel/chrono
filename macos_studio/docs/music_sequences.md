# Song sequences (`ct-song/1`)

The [native SPC700 CPU and SPC snapshot codec](spc700.md) now provide the first
playback components. The CPU passes all 256,000 instruction cases. APU devices,
DSP, CT song loading and audible playback remain unfinished. `music spc-info`
inspects existing snapshots.

Chrono Trigger's music is 83 song sequences (`Audio_SongTable`, `$C7:0D18`)
played by the SPC700 sound driver that ChronoRET transcribes
(`refs/ChronoRET/asm/spc700/driver.asm`, MIT). Studio reads them, writes them as
editable text listings, assembles the text back to the driver's bytes, and the
[ROM builder](rom_builder.md) writes edited songs into a copy of the ROM.

```sh
chronoforge music list <rom.sfc>                         # index, address, size, tracks
chronoforge music disasm <rom.sfc> 1 --out song01.ctsong # a song as a listing
chronoforge music asm song01.ctsong --out song01.bin     # back to bytes
chronoforge music verify-rom <rom.sfc>                   # all 83, byte for byte
```

In Studio, **Music → CT Songs** lists the project's `audio/songs/*.ctsong`,
imports a song from your ROM (pick the index, then **Import from ROM…**),
assembles the text as you type (size, tracks, statements, notes, or the first
error), and **Build into song $NN** adds the listing to `rom.songs`. Listings of
ROM songs are game data: keep them local.

## What a song is

Each `Audio_SongTable` entry is a long pointer to a 16-bit length followed by the
song's data. `Audio_SendSongData` copies the data to ARAM `$2000`. The data
starts with a 36-byte header (`Spc_StartSong`):

| Offset | Field |
|---|---|
| `$00` | origin: the address the song's pointers are written for |
| `$02` | "no track": a track pointer equal to it means an unused voice |
| `$04` | set A: 8 track pointers |
| `$14` | set B: 8 track pointers (which set plays is the command's choice, `$10`/`$11`) |
| `$24` | the sequence bytes |

The driver moves every pointer by `$2024 − origin` with a 16-bit add, so an
address `a` is song offset `((a − origin) & $FFFF) + $24`. Jump operands use the
same space.

Sequence bytes (`Spc_TrackStep`):

- `$00–$A7`: a note. `byte / 14` is the semitone (0–11) above the track's base
  note (`octave n` sets it to 12 × n), and `byte % 14` picks the length from
  `Spc_DurationTable`: 192, 96, 64, 72, 48, 32, 36, 24, 16, 12, 8, 6, 4, 3 steps.
- `$A8–$B5`: a tie, and `$B6–$C3`: a rest, with the same lengths.
- `$C4–$FF`: commands. `Spc_SeqOperandCounts` gives each one's operand count.

## The listing

```text
@origin $8B18
@notrack $8FB3
@samples 33 5 16         ; the song's sample list (optional; see below)
@echo $04 $C0            ; its echo word (optional)
@drums none              ; or 12 lines "@drum 0-11 $SAMPLE $NOTE $PAN" (optional)
@track A 0 L_8B18        ; 16 lines: set A/B, track 0-7, a label or -
...
L_8B18:
    tempo $46
    octave $05
    note C# 48           ; semitone name, length in steps
    tie 24
    rest 96
    loop_start $02
    note E 12
    loop_end
    branch $01 ->L_8B18  ; address operands take a label
    jump ->L_8B18
@bytes EB                ; bytes no track reaches
```

The names count semitones up from the octave base (C is 0). How high a note
sounds depends on the sample and the tuning, which this format does not change.
A label `L_XXXX` is named after its address in the origin's space. Any identifier
can be a label. Comments start with `;`.

Commands, named after their handlers in `Spc_SeqCmdTable` (operand bytes in brackets):

| Byte | Name | | Byte | Name | | Byte | Name |
|---|---|---|---|---|---|---|---|
| C4 | volume [1] | | D8 | octave_down | | EC–EF | end_ec … end_ef |
| C5 | volume_fade [2] | | D9 | transpose [1] | | F0 | tempo [1] |
| C6 | pan [1] | | DA | transpose_add [1] | | F1 | tempo_fade [2] |
| C7 | pan_fade [2] | | DB | fine_tune [1] | | F2 | echo_volume [1] |
| C8 | pitch_slide [2] | | DC | sample [1] | | F3 | echo_volume_fade [2] |
| C9 | vibrato [3] | | DD | attack [1] | | F4 | song_volume [1] |
| CA | vibrato_off | | DE | decay [1] | | F5 | loop_jump [n, address] |
| CB | tremolo [3] | | DF | sustain_level [1] | | F6 | jump [address] |
| CC | tremolo_off | | E0 | sustain_rate [1] | | F7 | efb_fade [2] |
| CD | pan_lfo [2] | | E1 | adsr_reset | | F8 | fir [2] |
| CE | pan_lfo_off | | E2 | loop_start [1] | | F9 | marker [1] |
| CF | noise_clock [1] | | E3 | loop_end | | FA | branch [v, address] |
| D0 | noise_on | | E4 | legato_on | | FB | drums_on |
| D1 | noise_off | | E5 | null_e5 | | FC | drums_off |
| D2 | pmon_on | | E6 | unk60_on | | FD | volume_scale [1] |
| D3 | pmon_off | | E7 | null_e7 | | FE, FF | end_fe, end_ff |
| D4 | echo_on | | E8 | wait [1] (the next note's length) | | | |
| D5 | echo_off | | E9 | sfx_track1 [1] | | | |
| D6 | octave [1] | | EA | sfx_track2 [1] | | | |
| D7 | octave_up | | EB | end | | | |

## Per-song tables

Three tables in bank `$C7` hold one row per song, apart from the sequence. A
listing may set any of them. If a listing leaves one out, `rom build` leaves
that row as it is. `music disasm` and Studio's import write all three.

- `@samples`: `AudioRom_SongSamples` (`$C7:0E11`, 16 words per song, 0-ended).
  It lists the samples (1–62, `Audio_SampleTable`) that a song load uploads.
  `Audio_CmdLoadSong` puts them in the song's directory entries `$20–$2F`. A
  sequence's `sample $20` uses the first one, `sample $21` the second, and so on.
  Operands below `$20` are directory entries the song load does not set. One ROM
  song (`$13`) also uses `$69`, which is past its own list. `@samples none` is an
  empty list.
- `@echo`: `AudioRom_SongEcho` (`$C7:241D`, a word per song).
  `Audio_StartSong` sends byte 0's low nibble as the echo delay and byte 1 as the
  song command's Arg1. The driver keeps Arg1 in `Spc_Unk4D` and uses it as a
  volume factor (a song volume, probably).
- `@drum` / `@drums none`: `AudioRom_SongExtra` (`$C7:1871`, 36 bytes per song,
  sent to ARAM `$F120` at each load). It is the song's drum kit: in drum mode
  (`drums_on`), a note's semitone picks one of 12 entries (`Spc_DrumNote`). Each
  entry gives the sample, the note to play, and a pan; a pan of `$80` or more
  keeps the track's pan. 41 ROM songs have one.

## Disassembly

The disassembler follows each track from its pointer. It continues past every
statement except `jump`, the ends (`$EB–$EF`, `$FE`, `$FF`) and `sfx_track1/2`,
which continue in the effects block. It also follows the addresses of `jump`,
`loop_jump` and `branch`. Bytes that no track reaches stay as `@bytes`; there are
2 such bytes in the ROM, a lone `$EB` in each of songs `$16` and `$4D`.

## Assembling

`CTSongListing.assemble`, and the Python twin `re_workspace/tools/ct_spc_seq.py`,
refuse a listing when:

- a statement is unknown, a note has a length that is not in the table, or a
  command has the wrong number of operand bytes;
- an address operand is not a label, or a label is undefined or defined twice;
- a track lacks a line, or a track label equals the `@notrack` word;
- a track reaches bytes written as `@bytes`, runs past the end, or jumps inside a
  statement;
- the song is too long. `Audio_SendSongData` sends length / 3 + 1 three-byte
  steps from `$2000`, and they must stop before boot block 2 at `$4700`, where the
  sample slots begin. That allows at most 9,983 bytes. A song of `$0F00` bytes or
  more overwrites the effects block at `$2F00` while it plays, and the game sends
  that block again at the next load (`Audio_BlockDirty`). Only song `$3F`, at
  4,818 bytes, does this in the ROM.

## Building into a ROM

```json
"rom": { "songs": [ { "song": 1, "listing": "audio/songs/song01.ctsong" } ] }
```

The builder checks each song against the same rules. It writes the song (length
word, then data) at its old place when it fits there and no other song uses that
place. Otherwise it shares an identical song already placed, or uses the span of
a replaced song or event pack, or free space. Then it rewrites the song's
`Audio_SongTable` pointer. A song may cross a bank, because `Audio_SendSongData`
steps the bank. Song `$18` does so in the ROM, and its old place is reused
across the bank boundary.

## Verification

- `ct_spc_seq.py` reads the driver's operand counts and lengths from the ROM and
  checks them against ChronoRET's `driver.asm`. It renders each of the 83 songs
  with its table rows and assembles the listing back byte for byte, both the song
  and the rows (71,783 statements; manifest
  `re_workspace/manifests/spc_sequences.json`, which holds only addresses, sizes,
  counts and hashes).
- `macos_studio/tools/verify_music.py`: the Swift CLI's listing for every song is
  identical, byte for byte, to the Python twin's (by listing hash).
- `CTSongTests`: listing round trips, the assembler's refusals, the transfer
  limit, the validator rows, and a rebuild of all 83 songs that leaves the ROM
  identical. They also edit a song so it moves and check that it is placed and
  pointed to while every other song stays unchanged.
- `verify_rom_build.py` builds two songs with the CLI (one unchanged, one grown
  past its old place). `ct_rom_check.py` checks them independently: pointers,
  data hashes, the walk, the `$4700` limit, untouched songs, and that writes stay
  in allowed places. The grown song also gets a new echo word and a longer sample
  list, and the checker compares those rows with the report. It rejects a damaged
  song and a damaged table row.

## Limitations

- No playback or SPC700 emulation. The listing is the driver's data, not audio.
- Loop counts and `branch` conditions are not modelled.
- Samples themselves (BRR data, loop points, tuning and ADSR words) are not
  written; a song can only list the ROM's 62 samples.
- The effects block at `$2F00` (sound-effect tracks, reached by `sfx_track1/2`)
  is not decoded or written.
- The tracker-score format (`.akao.json`) is the Studio's own and is not converted
  to or from `ct-song/1`.
