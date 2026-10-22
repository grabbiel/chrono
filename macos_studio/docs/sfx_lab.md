# Character Sound & SFX Lab (Module 5)

The SFX Lab turns WAV files and synthesized sounds into SNES BRR samples and
plays them on the [native S-DSP](spc700.md) exactly as the hardware would:
loops snap to BRR blocks, the envelope you see is the one the S-DSP applies,
and pitch bends, vibrato and the noise channel are written to the DSP by a
small SPC700 program, as a sound driver would write them.

```sh
chronoforge sfx encode voice.wav --project My.ctproj --id voice --loop 4410:30870 --crossfade 64 --verify
chronoforge sfx synth fm --freq 880 --end-freq 220 --duration 0.3 --project My.ctproj --id blip
chronoforge sfx info My.ctproj voice --verify
chronoforge sfx render My.ctproj voice --out voice.wav --adsr 12,5,4,18 --key-off 150 \
    --vibrato 40,16,20 --envelope env.csv
```

In the Studio, Module 5 (SFX) lists the project's samples beside one editor:
the waveform, Encode, Synth (for generated samples), Envelope and Pitch,
vibrato and noise. Play (⌘P) plays the sample with the settings as edited,
unsaved changes included, through the live engine. Save (⌘S) writes
`audio/samples/<id>.brr`, its preview `<id>.wav` and its sidecar
`<id>.json`. Import WAV… and New synth… make new samples. `--select <id>`
picks a sample at launch, for example
`ChronoForgeStudioApp --open My.ctproj --module SFX --select voice`.

## BRR as the S-DSP decodes it

`BRR.decode` keeps the 16-bit recursion that `ct_audio.py` uses, and its
parity test pins it. The S-DSP works one bit lower (fullsnes "BRR Samples"):

- a nibble scales to `(n << shift) >> 1`;
- shifts 13–15 act as 12 with the nibble shifted right by 3;
- each filtered sample is clamped to 16 bits and kept as 15 bits, with
  wraparound.

`BRR.decodeDSP` is that recursion, the same arithmetic as `SDSP`'s decode.
`BRRParity.check` is the evidence that it is what plays. It plays the blocks
looping at pitch `$1000` through `SPCStream.sample`, with GAIN direct `$7F`
and full volume. It predicts every output frame from `decodeDSP`: the
Gaussian interpolator at index 0 (the only index pitch `$1000` reaches),
envelope `$7F0`, then voice and main volume. All frames must be equal. The
comparison starts at the frame that interpolates samples 0–3, because the
frames before it play with the envelope still at 0 after the key-on delay.
Samples 0–2 are still checked through that frame.

Results:

- synthetic signals, hand-made blocks with every shift and filter (including
  clamping and the 15-bit wrap), and looped imports all pass;
- all 62 of the game's own samples pass (local ROM test, 185,504 frames);
- `--verify` runs the same check from the CLI.

## Encoder

`BRREncoder` scores every candidate against `decodeDSP`, so the error it
minimises is the error you hear. For each block it tries:

- every filter, with shifts 0 to `maxShift`;
- for each nibble, the rounded estimate and its two neighbours, decoded
  exactly, so a clamp or a 15-bit wrap is never picked by accident.

Filters 1–3 make each block depend on the last two samples of the previous
one. With `beam` above 1, the encoder keeps that many candidate histories
(the cheapest per distinct history). A block may then take a slightly worse
fit when it leaves a better history. The default `beam` is 4; `beam 1` is
greedy.

Blocks in `filterZeroBlocks` use filter 0. Block 0 always does, and so does
an import's loop block. The loop block is entered from two histories: the
first pass, and the jump back from the loop end. With filter 0 it decodes the
same from both, so the seam cannot click. The import reports this as `seam
error` (0 means identical), and the Studio shows the seam error of whatever
loop you drag.

| Source (SNR of the S-DSP decode) | legacy `BRR.encode` | greedy | beam 4 |
| --- | --- | --- | --- |
| synthetic FM + saw + noise mix, 4,096 samples | 31.13 dB | 31.77 dB | 32.17 dB |
| the game's 62 samples, decoded, resampled to 28.8 kHz, 2,048 samples each (pooled) | 12.95 dB | 30.06 dB | 30.26 dB |

The legacy encoder minimises error against the 16-bit recursion. On loud
material, its output can clip or wrap in the S-DSP's 15-bit decode, which is
why it scores much lower on the game's samples. It is still used by
`Validator`'s round-trip gate, which compares within that recursion. The SFX
Lab never uses it.

## WAV import

`SFXImport` runs these steps:

1. **Resample** to the target rate (default: the source rate, up to 32 kHz),
   using a Blackman-windowed sinc with 16 zero crossings each side, cut off at
   95% of the lower Nyquist frequency.
2. **Snap the loop** to the nearest 16-sample blocks (at least one block
   long), and drop everything after it.
3. **Crossfade** (optional): blend the samples just before the loop start
   into the loop's end, so the jump back is continuous.
4. **Normalize** the peak (default −1 dBFS).
5. **Encode.**

A one-shot ends on an added silent block. The S-DSP silences a non-looping
voice as soon as it fetches the end block, before that block plays, so
without the extra block the sound's last samples would be cut off.

The sidecar's `source` records the WAV, its rate, the settings, and the
measured SNR and maximum error. "Re-encode from source" in the Studio uses
the loop you dragged, converted back to source samples.

## Synthesis

`SFXSynth` renders these generators to 16-bit PCM:

- pulse (any duty) and saw, both PolyBLEP band-limited;
- triangle and sine;
- noise from a 15-bit LFSR, held at `frequency`;
- two-operator FM with a decaying index.

Options include an exponential frequency sweep, an amplitude decay and the
amplitude. A `loop` spec makes a sustained sample: it rounds the period to
whole samples and uses enough periods to fill whole blocks, so the loop is
exactly periodic. The spec is saved in the sidecar's `synth` field, so a
sample can be regenerated and re-encoded at another rate or beam.

## Envelope

`DSPEnvelope.Setting` covers ADSR and GAIN's five modes: direct, linear and
bent increase, and linear and exponential decrease. It maps them to the
ADSR1/ADSR2/GAIN register values. GAIN's increase and decrease modes start
from the current level, which is 0 at key-on. `startLevel` (sidecar
`fx.gainStart`) keys on with a GAIN direct level instead, and the chosen
mode takes over on the first tick.

The curve is not computed from a formula. `DSPEnvelope.render` plays a
full-scale DC sample (shift 12, filter 0, nibble 7) through the same preview
stream: the same key-on, GAIN hand-over and key-off ticks. It then reads each
output frame back into the level it was played at. The DC frame value is
strictly increasing in the level, so the inversion is exact. The curve is
therefore the envelope the S-DSP applied to the audio, frame by frame.

Reading the voice's level after a render chunk is one sample late whenever
the last SPC700 instruction runs past the DSP's envelope step. Inverting the
output frames avoids that. A test checks the inverted curve against the
internal level while the CPU is stopped, when a 1-frame render ends exactly on
the frame. Other tests check fullsnes' rates on the curve:

- GAIN linear increase rate 31 adds `$20` per sample and clips at `$7FF`;
- attack 15 adds `$400`;
- GAIN direct `$55` gives `$550`;
- exponential decrease subtracts 1 + level/256 per step.

## Pitch, vibrato, noise

The sidecar's `fx` sets these effects. `SFXPitch.curve` turns them into a
pitch register value per tick:

- a bend that moves linearly in semitones over `bendTicks`, then holds;
- a sine vibrato of `vibratoCents` with a period and a delay. With a vibrato,
  the curve ends with one whole period that repeats.

A tick is one timer-0 tick: `tickDivider`/8000 s, by default 32, which is 4 ms.

`SPCStream.sample` gives such a voice a 49-byte SPC700 program at `$0400` in
place of the STOP the plain preview uses. Each tick it reads a count and that
many (DSP register, value) pairs from a script after the BRR data, and writes
them through `$F2`/`$F3`. Count `$FE` jumps to the repeat point and `$FF`
stops. The script writes:

- the pitch for each tick;
- the envelope hand-over on tick 0;
- KOFF at `keyOffTick`.

With `noise`, NON plays the noise generator at the FLG noise clock (0–31, the
envelope rate table: 32 kHz / period) in place of the sample.

The preview stream ends after the key-off and the release. A release-build
render with a vibrato and a bend runs about 7× faster than real time. A
render of a 330 Hz sample bent up 2 semitones measures about 370 Hz.

## Sidecar fields

See [the schema](ctproj_schema.md#audiosamplesidjson). Every SFX Lab field is
optional, and older sidecars load unchanged.

## A project sample in the game (`rom.samples`)

```sh
chronoforge sfx use My.ctproj lead --replace 7 --adsr '$E0FF'      # takes over ROM sample 7
chronoforge sfx use My.ctproj bass --root 48 --songs 2,'$1A'        # appended: sample 63
chronoforge sfx import-rom ct.sfc --project My.ctproj               # the ROM's 62, written back as they are
chronoforge rom build My.ctproj --base ct.sfc --out built.sfc --report report.json
chronoforge music sample-check ct.sfc built.sfc 2 63                # the driver plays it (JSON)
```

In the Studio, the editor's **Use in game** box does the same. It sets the
slot (append, or replace ROM sample 1–62), the songs whose lists load the
sample, the root note and an optional ADSR word. It shows the tuning word
and each named song's budget, and saves the entry to `rom.samples`. The
build reads the saved `.brr` and sidecar, so save the sample first. See
[the schema](ctproj_schema.md#projectjson).

**Tables.** `Audio_SampleTable` (`$C7:0AEA`) has 62 long pointers to
`[u16 length][BRR]`. `Audio_SampleLoop`, `Audio_SampleParamA` (tuning) and
`Audio_SampleParamB` (ADSR1 low, ADSR2 high) follow it back to back, then
`Audio_SongTable`. Twelve `LDA`/`ADC long,X` instructions in bank `$C7` read
these tables (`CTSampleTables.sites`).

- **Replacing a sample** rewrites its row. The new bytes go in place when
  they fit and the old span is not shared; otherwise they go in free space.
- **Appending a sample** (63 on) moves all four tables, one entry longer,
  into free space as one block of 9 × count bytes, and points the twelve
  operands at them. The code derives the count as
  (loops − pointers) / 3, so nothing else changes.

`Audio_UploadSample` sends three bytes per step. Whole 9-byte blocks are
always a multiple of 3. A sample is refused when:

- its end flag is not only on its last block;
- the loop offset is not a block start inside the bytes;
- ADSR1 bit 7 is clear (the driver plays ADSR only, so a GAIN sidecar needs
  an `adsr` word);
- or a song's list would exceed 16 samples.

ROM imports are written back `asIs`. Thirty ROM samples have loop flags on
middle blocks, and sample 59's loop word points past its data.

**Tuning.** `Spc_NotePitch` (driver `$06BD`) computes the pitch:

```
P = PitchTable[n mod 12]               (4096 × 2^((k − 11)/12), rounded down; $1000 at B)
t = (tuning low byte + fine tune) mod 256,  h = tuning high byte
Q = P.hi × t + (P.lo × t) >> 8
if h ≠ 0:  Q += ((Q >> 8) × h) >> 8
if t < $80: Q += P
pitch = Q shifted left by (octave − 4), or right by (4 − octave)
```

- Pitch `$1000` plays one BRR sample per 32 kHz output sample.
- With transpose 10, octave *o* and note index *i* sound note number 12*o* + *i*.
- One tuning word scales the pitch by ×0.5 to ×1.5, so a rate is reachable
  only from roots in a range of about one octave.
- `CTSampleTuning.solve(rate:rootNote:)` searches the words for the best
  pitch. `sfx use` lists the feasible roots when a root is out of range.
- A 32 kHz sample at root 60 gets `$FFF1` (pitch `$0FFE`, −0.8 cents); so
  does a 16 kHz sample at root 48.

Evidence: the formula equals the driver's own code in 15,136 S-SMP runs from
`$06BD` across notes, tuning words and fine tunes (ROM test
`testPitchFormulaIsTheDriversNotePitch`). On a built ROM, the voice's pitch
register equals it and plays within 0.2% of the sidecar's rate.

**In the driver.** `music sample-check <clean> <built> <song> <sample>`:

1. Boots the driver from the clean ROM and loads the built ROM's song with
   its transfer plan.
2. Checks ARAM's BRR bytes, the directory entry (`$1E80` + 4 × slot), and the
   tuning and ADSR words (`$1F40`, `$1FC0` + 2 × slot).
3. Runs the song until a voice keys on with SRCN `$20` + slot.
4. Checks that the key-on fetch starts at the directory's address, that the
   voice's decoded samples equal the S-DSP decode of the sample's bytes, and
   that the pitch register is `Spc_NotePitch`'s value for the track's note.

`re_workspace/tools/ct_samples.py load` runs the ROM's own `Audio_CmdLoadSong`
(`$C7:01A1`) in ChronoRET's 65816 interpreter. Its transfers equal the plan's
byte for byte: song 2 on the clean ROM, and the edited song in
`macos_studio/tools/verify_audio_build.py`.

**Budgets** (`CTSongBudget`, `music budget <rom>`):

- **Samples.** A song's samples load from `$4700` + boot block 2's length
  (`$4901`) and must end at or below the echo buffer, `$F100 − EDL × $800`.
  Every US 1.0 song fits, and song `$27` leaves 16 bytes. The build refuses
  a song whose samples would reach the echo buffer.
- **Sequence.** The sequence loads at `$2000` and must stay below `$4700`
  (at most 9,983 bytes); the song builder refuses longer ones. From `$0F00`
  bytes on, the sequence overwrites the `$2F00` effects block while it plays.
  The game sends that block again on the next load, so the budget reports
  this rather than refusing it. One ROM song already does it.

The rack in the Music pane shows the same budget for the listing being
edited.

`ct_rom_check.py` checks a built ROM as follows:

- it re-reads the tables where the code reads them;
- every reported sample's bytes, words and BRR are checked;
- every other sample must be unchanged;
- sample lists must be exactly as reported;
- the budgets are recomputed.

`verify_audio_build.py` runs the whole path end to end:

- an identical rebuild of every imported sample and song;
- a replaced and an appended sample in a song from the template;
- the interpreter and driver runs;
- six damaged copies, which must be rejected;
- six refused edits.

**Not yet:**

- a drum-kit editor (`@drum` rows are written as listed);
- MIDI import;
- auditioning a project sample in the rack before a build (the audition
  plays the playback ROM's samples).
