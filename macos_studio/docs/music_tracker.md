# Music tracker (the `ct-song/1` event model)

The Studio shows a CT song as a tracker grid and a piano roll, with an
instrument rack and an echo designer. All four edit the song's
[`ct-song/1` listing](music_sequences.md) and nothing else. So every edit
assembles back to the driver's own bytes through the same assembler, plays
through the emulated S-SMP/S-DSP, and builds into a ROM with `rom build`.

## The model

`CTSongDocument` (`CTSongModel.swift`) reads a listing as items: statements,
labels, `@track` lines, `@bytes` and text. Every line it does not change keeps
its text. So reading a listing and writing it back gives the same characters,
and therefore the same bytes. A line that is not a well-formed statement stays
text, and the assembler reports it.

`CTSongTimeline` plays each track the way the driver's `Spc_TrackStep` does
(ChronoRET `driver.asm`) and counts time in song steps:

- A note, tie or rest lasts `Spc_DurationTable[byte % 14]` steps, unless a
  `wait n` before it sets the next byte's length to `n` (any length from 1 to 255).
- A note's number is base + index + transpose − 10. `octave n` sets the base to
  12n, and `octave_up` / `octave_down` move it by 12. In drum mode (`drums_on`),
  the drum kit entry gives the sample, the note and the pan
  (`Spc_DrumNote`). The entry's sample stays the track's sample afterwards.
- Loops follow `Spc_SeqLoopStart` / `LoopEnd` / `LoopJump`. Each track has four
  slots that wrap. `loop_start n` plays n + 1 passes, and 0 or $FF loops
  forever. `loop_jump n` leaves on the nth pass.
- `branch v` jumps when `!Spc_SongCond` ≥ v & $0F. A song start sets that
  value to 0, so only `branch $00` (or $10, $20…) jumps. Game command $88
  changes the value; set `Options.songCondition` to model it.
- Legato: after `legato_on`, only the first note keys on. The look-ahead after
  a note or tie (`Spc_TrackLookAhead`) ends legato when it sees a rest,
  `sample`, $E4–$E7, or an end. `unk60_on` makes every note key on.
- `end` ($EB–$EF, $FE, $FF) stops the track. `sfx_track1/2` continue in the
  effects block, which is not modelled, so the track is reported as stopped
  there (`stop = "sfx"`; no ROM song does this).

The **song loop** is the first jump back to a statement already played after
which the track's events repeat with the same period until the end of a
150,000-step run (at least two periods). Exact driver-state equality would not
work here. Song $32's track 3 leaves a `loop_start` open on every pass, so its
slot index never repeats, even though the music does. Every ROM song now loops
or ends on every track.

`CTSongTempoMap` maps steps to main-loop passes. A pass is 42 timer-0 ticks of
125 µs, which is 5.25 ms. Each pass adds `!Spc_Tempo` to an accumulator, and
the song steps on the carry. A song starts with tempo 1 and the accumulator at
$FF, so step 0 falls in pass 0. `tempo t` sets the tempo to t + t × 20 / 256.
`tempo_fade` uses the driver's `Spc_FadeDelta` word arithmetic, one step per
song step. No host tempo adjustment (command $86) is applied. The Studio's
playback cursor uses this map to turn `AKAOAudioEngine.status.seconds` into a
step. Past the song's loop end, the cursor folds back into the loop.

## Edits (`CTSongEdits.swift`)

| Edit | What it writes |
|---|---|
| `setSemitone` | the note's index (0–11) |
| `setLength` | the note and its ties as table lengths, or `wait n` + note; the rests right after shrink or grow so later notes keep their steps (`shift: true` moves them instead) |
| `deleteNote` | the note and its ties become rests of the same lengths |
| `insertNote` | splits the rests at that step into rest + note (+ ties) + rest; `octave_up`/`octave_down` go around a note outside the octave in force. Refused when the rests are shared, labelled, or played more than once |
| `moveNote` | delete, then insert on the same track |
| `setControl` | `sample`, `volume`, `pan`, …: changes an equal command just before the note, or puts one there. The value then lasts until the next one, like a tracker's effect column |
| `setLoopPasses`, `insertLoop` | a `loop_start` operand; a new `loop_start` / `loop_end` pair |
| `setSongLoop` | the track's closing `jump` goes to a label before the chosen note |
| `setEchoDelay`, `setEcho`, `setTrackEcho` | the `@echo` row; the first `echo_volume` / `efb_fade` / `fir` statement (or a new one at the start of the first track); `echo_on` / `echo_off` at a track's start |

An edit to a statement inside a loop changes every pass. The note inspector
says how many times the statement runs.

## Studio

**Music → CT Songs**: choose a listing. A segmented control then switches its
view:

- **Listing**: the text editor, as before.
- **Tracker**: one row per 3–48 steps and one column per track. Each cell shows
  the note, the sample operand, the volume, and ⌒ for legato. `===` marks a
  rest, `~~~` a tie, and ⟲ the loop start. The row that is playing is
  highlighted and followed.
- **Piano Roll**: one track at a time, with the other tracks faint. Notes that
  repeat in a loop are teal, and green dashes mark the song loop. Double-click
  to add a note, drag to move one, drag its right edge to resize it, and ⌫ to
  delete it. The grid snaps to 3–48 steps.
- The note inspector below both views sets the note, length, instrument and
  volume, and lists the track's loops with their pass counts.
- **Instruments**: the `@samples` row (the ROM sample in each slot $20–$2F),
  each sample's tuning (`Audio_SampleParamA`, shown as the pitch factor
  `Spc_NotePitch` gives), its ADSR (`ParamB`), and its BRR length and loop.
  The rack also shows how many notes use each slot and the per-track envelope
  commands. **Audition** plays one note on that slot through the driver, using
  a one-track listing with the song's tables (`CTSongInstrument.audition`).
  The summary line compares the sample bytes with the room between `$4700` +
  boot block 2 and the echo buffer.
- **Echo**: the controls set EDL (the `@echo` row; the buffer is
  `$F100 − EDL × $800`), EVOL and EFB, choose one of the driver's four FIR sets
  (`Spc_FirSets`, read from the ROM), and turn echo on or off per track. The
  view plots the FIR's frequency response and a one-second impulse response of
  the echo path. Custom taps are for analysis only: the driver can play only
  its four sets.

Every edit is saved at once and can be undone (⌘Z, through
`ProjectStore.editSong`). **Play** (⌘P) plays the listing as edited, in place
of the target song. To open a view at launch:

```sh
ChronoForgeStudioApp --open my.ctproj --module music --song song01.ctsong --music-view tracker
```

## CLI

```sh
chronoforge music events <rom.sfc> 1                 # each track's statements by step, to its loop
chronoforge music events song01.ctsong --json        # the same from a listing, as JSON
chronoforge music events <rom.sfc> 1 --steps 4000    # run 4000 steps, through loops
chronoforge music edit song01.ctsong roundtrip       # model → text and bytes identical
chronoforge music edit song01.ctsong length 120 36 --out song01.ctsong
chronoforge music edit song01.ctsong insert 2 96 C#4 24 --out song01.ctsong
chronoforge music verify-model <rom.sfc>             # all 83 songs through the model
chronoforge music verify-model <rom.sfc> --driver-steps 3000   # and against the driver
```

## Evidence

- `music verify-model`: all 83 ROM songs go listing → model → listing with
  identical text and identical assembled bytes and table rows. Every track ends
  at a song loop or an end. `CTSongModelTests.testEveryROMSongRoundTripsThroughTheModel`
  checks the same.
- `CTSongDriverTrace` runs a song on the emulated driver. It counts song steps
  at `Spc_StepTracks`' `.song` entry ($0399, checked to be `mov x,#$00`) and
  passes at its own entry ($0377). It records every nonzero KON write by its
  step: the KON shadow is written at the top of the next pass, before that
  pass can step. `compare` then checks the model's key-on steps for each voice,
  and the tempo map's pass for every step.
- `verify-model --driver-steps 3000` over every ROM song: all 82 songs with
  tracks match. That is 28,718 key-ons on the same steps, and every step in
  the same pass. Song $00 has no tracks.
- `testModelKeyOnsAndStepTimingMatchTheDriver` checks songs $01 (legato,
  unk60, wait), $08 (legato, drums, loop_jump), $18 (branch) and $1D (tempo
  fades, wait) over 160 steps. `verify_all.sh` runs the same four songs over
  600 steps.
- `testEditedSongPlaysAsTheModelSays` puts a note into a rest of song $02. The
  song is built in place of the ROM song (`CTROMBuilder`), and the new note's
  key-on reaches the driver at the step the model gives.

## Limitations

- Only the song tracks (set A, voices 0–7) are modelled. The effects block at
  $2F00 is not, and no sound effects play during a trace.
- The model keeps time in steps and key-ons. It does not model pitch slides,
  vibrato, tremolo, volume or pan fades, or the S-DSP envelope. Playback plays
  them, because playback is the driver itself.
- The piano roll inserts and moves notes only into rests that are played once
  and that no other track shares. Edits inside shared or looped statements
  must be made in the listing.
- The echo impulse response is a floating-point model of the echo path
  (integer clamps and the buffer's halving are not modelled). The preview
  plays the real S-DSP.
- Per-sample tuning and ADSR words are global tables. A song chooses which
  samples it loads and can override ADSR per track with sequence commands.
  Project samples bring their own words through `rom.samples`.
- The Studio views were checked by launching the app and capturing its window
  for each view. Mouse edits were not driven by automation. The edits they
  call are the tested `CTSongDocument` functions.

## Composing new songs

```sh
chronoforge music new --project My.ctproj --song 2 --samples 7,63 --tracks 0:5,1:4 --steps 384
chronoforge music edit My.ctproj/audio/songs/song02.ctsong insert 0 0 C5 96 --out My.ctproj/audio/songs/song02.ctsong
chronoforge music budget built.sfc --songs 2
```

**Template** (`CTSongTemplate`). The generated listing has:

- `@samples` from the given numbers (63 on for appended project samples);
- `@echo` with the chosen EDL and song volume `$FF`, and `@drums none`;
- on track 0, a `tempo`, `echo_volume`, `efb_fade` and `fir` header;
- per track: `sample $20 + slot`, `volume`, `pan`, `octave` and
  `transpose $0A`, then a loop label;
- each track's length as rests, longest first (lengths from the duration
  table), and a `jump` back to the loop label.

Every piano-roll or `music edit insert` note therefore lands in a rest that
plays once. `music new` writes the listing and its `rom.songs` row. In the
Studio, **Music → CT Songs → New…** does the same for the song number in the
stepper: sample list, 1–8 tracks, bars of 96 steps, tempo and EDL.

**Budgets.** The instrument rack shows the song as the build will load it,
with the playback ROM's samples and the project's `rom.samples`:

- sample bytes from `$4700` + boot block 2, and the room left below the echo
  buffer (`$F100 − EDL × $800`);
- the sequence's bytes, out of 9,983, and whether it reaches the `$2F00`
  effects block (from `$0F00` bytes on).

The build refuses a song over either budget (`CTSongBudget`). The rack's
**Project sample** menu loads a sample that `rom.samples` writes into a slot,
with its own tuning and ADSR words. Auditions play it before any build: see
"Project-sample auditions" below.

**Evidence** (`macos_studio/tools/verify_audio_build.py`, ROM tests in
`CTSamplePatchTests`). A song from the template, with a note inserted on each
of its two tracks, is built with a replaced and an appended sample. On the
built ROM, the S-SMP driver keys both samples on at the inserted notes, and
the voices' pitch registers are the driver's formula for those notes.

**Song volume.** The `@echo` row's byte 1 is the song command's Arg1, which
the driver keeps in `Spc_Unk4D` and multiplies into every song voice's
volume: at `$00` the song is silent. No ROM song uses `$00` and `$FF` is the
most common value. Templates written before this slice had `@echo $EDL $00`;
change the second byte to `$FF`. The Validator warns about a `$00`.

## Drum kits

`@drum` rows are the song's `AudioRom_SongExtra` row, sent to ARAM `$F120`
(36 bytes, 12 pads of 3 bytes). In drum mode (`drums_on`, `$FB`), the driver's
`Spc_DrumNote` (`driver.asm` `$0720`) takes a note's index (byte / 14, so
C = pad 0 to B = pad 11) and reads its pad:

- byte 0: the directory entry to play, through `Spc_SetTrackSample`
  (`$20` + slot for the song's samples; 0 on an unused pad);
- byte 1: the note, plus the track's transpose − 10 (at the template's
  `transpose $0A`, the note number itself);
- byte 2: below `$80`, the pan, doubled into the track's pan as `Spc_SeqPan`
  does; `$80` or more keeps the track's pan.

In the ROM, 41 songs have a kit: samples `$20–$2A`, notes 0–77, pans below
`$80`, and no pad past its song's sample list.

`CTDrumKit` reads and writes the 12 rows; `CTSongDocument.drumKit` and
`setDrumKit` edit them in place. **Instruments** shows the kit under the rack:
per pad a sample menu (the song's slots, named after their project sample),
the note, "track's pan" or a pan, how many notes play it, and **Audition**
(one note in drum mode through the driver). **Add a kit** writes 12 empty rows
and **Clear kit** empties them. The Validator reports pads whose sample is
past the song's list or below `$20`, and notes outside C0–B7.

```sh
chronoforge music kit song02.ctsong                          # the kit as rows
chronoforge music kit song02.ctsong set 1 '$21' '$50' '$10' --out song02.ctsong
chronoforge music kit song02.ctsong clear 1 --out song02.ctsong
chronoforge music drum-check <clean.sfc> <built.sfc> 2 --listing song02.ctsong --steps 600
```

**Evidence.** `CTDrumKitTrace` runs a song on the driver and compares every
drum-mode note's key-on with the kit: the voice's SRCN, the note in the
driver's RAM (`$F3A0+1` per track) and, where the pad sets one, the pan byte
(`$F280+1`). On the clean ROM, songs `$04`, `$06`, `$0A` and `$0B` match all
56, 23, 63 and 16 drum notes in 400 steps (`testTheROMsKitsAreSpcDrumNote`;
`$0C` matches 36 more). `testAnEditedKitBuildsAndPlays` and
`verify_drums_midi.py` build an edited kit through `rom.songs` and confirm
the driver keys the edited pad with its sample, note and pan.

## MIDI import

```sh
chronoforge music import-midi tune.mid --song 5 --project My.ctproj --rom <clean.sfc> \
    --programs 0:7,33:63 --drums 36:7:60,38:1:72:16 --grid 3 --report import.json
```

In the Studio: **Music → CT Songs → Import → MIDI File…** opens a sheet with
the same choices and a live conversion report; **Import** writes
`audio/songs/<name>.ctsong` and its `rom.songs` row.

Mapping (`CTMIDIImport`):

- **Voices.** Each MIDI channel with notes becomes one track, in channel
  order. More than 8 channels is refused, listing them. Chords keep their
  highest note, and a note ends where the next one starts.
- **Time.** Steps are 24 per quarter note (96 a bar). Starts and ends are
  rounded to the grid (3 steps by default, 3–96). Lengths are written with
  the duration table; a note longer than one entry continues as ties, and so
  does a note that crosses a tempo change. The report gives the largest and
  mean rounding error in steps and milliseconds. The song is padded to a
  whole bar and loops (`--no-loop` ends it).
- **Notes.** The driver's note number is the MIDI key + `--transpose`,
  written with `octave` and the note names (number = 12 × octave + index at
  `transpose $0A`); a key outside 0–95 after the transpose is refused, with
  the list.
- **Instruments.** Program changes map through an explicit table
  (`--programs P:S`, a sample number). A program with no entry is refused
  unless `--default-sample` is given. Channel 10 is drums: `--drums
  KEY:SAMPLE[:NOTE[:PAN]]` puts each key on a pad and the track in drum mode;
  an unmapped key is refused.
- **Tempo.** `Spc_SeqTempo` stores t + t × 20 / 256; each 5.25 ms pass adds
  it to an 8-bit counter and the song steps on each carry. At 24 steps a
  quarter, the driver tempo is about 0.5376 × BPM: 120 BPM is `$3D`, which
  plays 120.9. Each MIDI tempo change becomes a `tempo` row on track 0.
- **Budgets.** The result is assembled and its samples and sequence checked
  with `CTSongBudget` as the build would load them; a song past `$4700` or
  whose samples reach the echo buffer is refused with the numbers.

**Evidence.** `CTMIDIImportTests` covers parsing, the tempo formula,
voices/notes/programs/drums and each refusal, on MIDI files written by the
tests. `testAnImportedSongPlaysOnTheDriver` builds an import into a ROM and
checks the driver's key-ons per voice. `verify_drums_midi.py` writes a
MIDI file, imports, builds and checks it with `ct_rom_check.py`, and the
driver keys all 20 of its notes on the steps the file gives, with the kit's
samples on channel 10.

## Project-sample auditions

The rack's and the kit's **Audition** buttons play through a scratch ROM
built in memory: `CTROMBuilder.audioScratch` applies only the project's
`rom.samples` and the one-track audition listing in place of the target song,
then the SPC transfer loads it into `AKAOAudioEngine` (`CTProjectAudition`).
Nothing is written to disk. Without `rom.samples`, the audition plays the
playback ROM as before. `CTProjectAuditionTests` checks that the voice decodes
the project sample (`CTSampleProbe`), that the stream's ARAM holds its BRR,
and that no file is written.

## Launch arguments

```sh
ChronoForgeStudioApp --open my.ctproj --module music --music-new yes
ChronoForgeStudioApp --open my.ctproj --module music --import-midi tune.mid
ChronoForgeStudioApp --open my.ctproj --module music --song song02.ctsong --music-view instruments
```

## Not yet

- The importer keeps one note per channel at a time (the highest of a
  chord); it does not split chords across free voices.
- Velocity, pitch bend, controllers and pan are not imported.
- The Music detail is wider than a 1080-pt window in every view; the right
  edge is clipped until the window is widened.
