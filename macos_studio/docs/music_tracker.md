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
- Per-sample tuning and ADSR words are the ROM's global tables. A song can
  only choose which samples it loads, and override ADSR per track with
  sequence commands.
- The Studio views were checked by launching the app and capturing its window
  for each view. Mouse edits were not driven by automation. The edits they
  call are the tested `CTSongDocument` functions.

## Next slice: composing new songs (design)

New songs must fit the same limits as edited ones:

1. **Sequence budget.** Song data goes from `$2000` and must stop before
   `$4700`: at most 9,983 bytes (`CTSongISA.maxLength`). From `$0F00` bytes
   on, it overwrites the `$2F00` effects block while it plays. A composer
   should count bytes as it writes. Loops (`loop_start`/`loop_end`, which take
   2 bytes) and `jump` into shared phrases are the compression it has. The
   model can already measure how many steps each statement covers.
2. **Sample budget.** A song loads up to 16 samples from the 62 in the ROM.
   They go one after another from `$4700` + boot block 2 and must end below
   the echo buffer at `$F100 − EDL × $800`. The rack shows that number now. A
   new-song wizard should pick samples by role (lead, bass, drums kit), show
   the remaining bytes, and lower the EDL when the samples need the room.
3. **Drum kits.** The 36-byte `@drum` table maps 12 note indexes to
   sample/note/pan. A kit editor can audition each pad through
   `CTSongInstrument.audition`, with drum mode on in the generated listing.
4. **Template.** Start from a generated listing: a `tempo`, `echo_volume`,
   `efb_fade` and `fir` header on track 0, then each used track with `sample`,
   `volume`, `pan`, `octave`, one rest of the song's length, and
   `jump ->LOOP`. All piano-roll inserts then land in rests. This is the shape
   `insertNote` already supports.
5. **Import.** MIDI notes can be quantized to the 14 table lengths (or
   `wait`), mapped into octaves with `octave`, and turned into ties across
   rows. Channels beyond 8, and sounds held across loop points, need explicit
   choices.
6. **Checks.** Each composed song should be put through `verify-model`'s
   round trip, a driver trace (key-ons as composed), and `rom build` with
   `ct_rom_check.py`. That is the same evidence the ROM songs have now.
