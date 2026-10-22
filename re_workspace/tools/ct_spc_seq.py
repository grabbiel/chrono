#!/usr/bin/env python3
"""Chrono Trigger SPC700 song sequences: decode, `ct-song/1` listings, assemble.

The facts, each read from the ROM and checked against ChronoRET's driver
transcription (refs/ChronoRET/asm/spc700/driver.asm, bankC7.asm; MIT):

- Audio_SongTable ($C7:0D18): Audio_SongCount ($C7:0AE9 = $53) long pointers;
  each song is a u16 length, then the bytes Audio_SendSongData copies to ARAM
  $2000 (!AudioAram_Song), 3 bytes per step, length / 3 + 1 steps. A length
  of !Audio_SongRoom ($0F00) or more overwrites the effects block at $2F00,
  which the next load sends again (Audio_BlockDirty; song $3F does it); the
  data must stop before boot block 2 at $4700 (!AudioAram_Block4700), after
  which the sample slots begin.
- The song header (Spc_StartSong): origin word, "no track" word, two sets of
  8 track pointers (!Spc_SongHeaderSet picks one). The driver moves each
  pointer by $2024 - origin, 16-bit (addw wraps), so song offset =
  ((pointer - origin) & $FFFF) + $24.
- Sequence bytes (Spc_TrackStep): $00-$A7 a note (index byte / 14, length
  Spc_DurationTable[byte % 14]), $A8-$B5 a tie, $B6-$C3 a rest, $C4-$FF
  commands with Spc_SeqOperandCounts operands (Spc_RunSeqCommand).
- Flow: $F6 lo hi jumps (Spc_SeqJump), $F5 n lo hi and $FA v lo hi may jump
  (Spc_SeqLoopJump, Spc_SeqBranch), $E9/$EA continue in the effects block
  (Spc_SeqSfxTrack1/2), $EB-$EF/$FE/$FF end the track (Spc_SeqEndTrack);
  their addresses are in the origin's space too. $E2/$E3 loop in place.
- Per-song tables, indexed by song: AudioRom_SongSamples ($C7:0E11, 16
  words, 0-ended: samples 1-62 (more in a built ROM that appends), loaded to the song's directory entries $20-$2F),
  AudioRom_SongEcho ($C7:241D, a word: byte 0's low nibble the echo delay, byte
  1 the song command's Arg1, Spc_Unk4D) and AudioRom_SongExtra ($C7:1871, 36
  bytes sent to ARAM $F120: the drum kit, 12 x sample/note/pan, Spc_DrumNote).

`derive` writes manifests/spc_sequences.json (addresses, sizes, counts and
hashes only; no song bytes); `check` re-derives it; `listing N` prints song
N's listing (local use; the text is game data).
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
REF = WS / "refs" / "ChronoRET"
MANIFEST = WS / "manifests" / "spc_sequences.json"

SONG_TABLE_PC, SONG_COUNT_PC = 0x070D18, 0x070AE9        # Audio_SongTable, Audio_SongCount
OPERAND_COUNTS_PC, DURATIONS_PC = 0x073891, 0x074078     # Spc_SeqOperandCounts, Spc_DurationTable
SAMPLES_PC, ECHO_PC, EXTRA_PC = 0x070E11, 0x07241D, 0x071871  # AudioRom_SongSamples/Echo/Extra
SAMPLE_MAX = 62                                          # Audio_SampleTable entries in the US 1.0 ROM
SAMPLE_NUMBER_MAX = 255                                  # a built ROM may append (ct_samples.py checks the count)
HEADER, SONG_ROOM = 0x24, 0x0F00                         # !SpcSong_Data, !Audio_SongRoom
SONG_ARAM, BLOCK_4700 = 0x2000, 0x4700                   # !AudioAram_Song, !AudioAram_Block4700
FIRST_TIE, FIRST_REST, FIRST_CMD = 0xA8, 0xB6, 0xC4
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# Command names from the driver's handler labels (Spc_SeqCmdTable).
COMMANDS = {
    0xC4: "volume", 0xC5: "volume_fade", 0xC6: "pan", 0xC7: "pan_fade",
    0xC8: "pitch_slide", 0xC9: "vibrato", 0xCA: "vibrato_off", 0xCB: "tremolo",
    0xCC: "tremolo_off", 0xCD: "pan_lfo", 0xCE: "pan_lfo_off", 0xCF: "noise_clock",
    0xD0: "noise_on", 0xD1: "noise_off", 0xD2: "pmon_on", 0xD3: "pmon_off",
    0xD4: "echo_on", 0xD5: "echo_off", 0xD6: "octave", 0xD7: "octave_up",
    0xD8: "octave_down", 0xD9: "transpose", 0xDA: "transpose_add", 0xDB: "fine_tune",
    0xDC: "sample", 0xDD: "attack", 0xDE: "decay", 0xDF: "sustain_level",
    0xE0: "sustain_rate", 0xE1: "adsr_reset", 0xE2: "loop_start", 0xE3: "loop_end",
    0xE4: "legato_on", 0xE5: "null_e5", 0xE6: "unk60_on", 0xE7: "null_e7",
    0xE8: "wait", 0xE9: "sfx_track1", 0xEA: "sfx_track2", 0xEB: "end",
    0xEC: "end_ec", 0xED: "end_ed", 0xEE: "end_ee", 0xEF: "end_ef",
    0xF0: "tempo", 0xF1: "tempo_fade", 0xF2: "echo_volume", 0xF3: "echo_volume_fade",
    0xF4: "song_volume", 0xF5: "loop_jump", 0xF6: "jump", 0xF7: "efb_fade",
    0xF8: "fir", 0xF9: "marker", 0xFA: "branch", 0xFB: "drums_on",
    0xFC: "drums_off", 0xFD: "volume_scale", 0xFE: "end_fe", 0xFF: "end_ff",
}
BY_NAME = {name: op for op, name in COMMANDS.items()}
JUMPS = {0xF6: 0, 0xF5: 1, 0xFA: 1}                      # operand index of the address's low byte
STOPS = set(range(0xEB, 0xF0)) | {0xFE, 0xFF, 0xF6, 0xE9, 0xEA}


def word(data, at):
    return data[at] | data[at + 1] << 8


def pc_of(long_pointer):
    return (long_pointer >> 16 & 0x3F) << 16 | long_pointer & 0xFFFF


def driver_tables(rom):
    """Operand counts and note lengths, checked against the driver source."""
    counts = rom[OPERAND_COUNTS_PC:OPERAND_COUNTS_PC + 60]
    durations = rom[DURATIONS_PC:DURATIONS_PC + 14]
    asm = (REF / "asm" / "spc700" / "driver.asm").read_text()

    def table(label, rows):
        body = asm.split(label + ":\n", 1)[1].split("\n")[:rows]
        values = []
        for line in body:
            for v in line.split(";")[0].replace("db", "").split(","):
                v = v.strip()
                values.append(int(v[1:], 16) if v.startswith("$") else int(v))
        return bytes(values)

    if counts != table("Spc_SeqOperandCounts", 5) or durations != table("Spc_DurationTable", 1):
        raise SystemExit("ROM driver tables differ from refs/ChronoRET driver.asm")
    return counts, durations


class Song:
    """One song's data (the bytes after the u16 length)."""

    def __init__(self, data, counts):
        if len(data) < HEADER:
            raise ValueError("song shorter than its header")
        self.data, self.counts = bytes(data), counts
        self.origin, self.notrack = word(data, 0), word(data, 2)
        self.tracks = [word(data, 4 + 2 * i) for i in range(16)]

    def offset(self, address):
        return ((address - self.origin) & 0xFFFF) + HEADER

    def address(self, offset):
        return (self.origin + offset - HEADER) & 0xFFFF

    def length_at(self, o):
        b = self.data[o]
        return 1 + (self.counts[b - FIRST_CMD] if b >= FIRST_CMD else 0)

    def target(self, o):
        b = self.data[o]
        return self.offset(word(self.data, o + 1 + JUMPS[b])) if b in JUMPS else None

    def walk(self):
        """Reached instruction offsets -> length; raises on a bad path."""
        seen, work = {}, [self.offset(a) for a in self.tracks if a != self.notrack]
        while work:
            o = work.pop()
            while o not in seen:
                if not HEADER <= o < len(self.data):
                    raise ValueError(f"a track reaches ${self.address(o):04X}, outside the song")
                n = self.length_at(o)
                if o + n > len(self.data):
                    raise ValueError(f"the command at ${self.address(o):04X} runs past the end")
                seen[o] = n
                t = self.target(o)
                if t is not None:
                    work.append(t)
                if self.data[o] in STOPS:
                    break
                o += n
        starts = sorted(seen)
        for a, b in zip(starts, starts[1:]):
            if a + seen[a] > b:
                raise ValueError(f"${self.address(b):04X} is reached inside the command at ${self.address(a):04X}")
        return seen


def fits(length):
    """Audio_SendSongData writes length / 3 + 1 triples from $2000."""
    return SONG_ARAM + 3 * (length // 3 + 1) <= BLOCK_4700


MAX_LENGTH = max(n for n in range(0x10000) if fits(n))


def label(address):
    return f"L_{address:04X}"


def statement(b, operands):
    if b < FIRST_TIE:
        return f"note {NOTE_NAMES[b // 14]}"
    if b < FIRST_REST:
        return "tie"
    if b < FIRST_CMD:
        return "rest"
    return COMMANDS[b]


def song_tables(rom, i):
    """The song's per-song table rows: sample list, echo word, drum kit."""
    words = [word(rom, SAMPLES_PC + 32 * i + 2 * k) for k in range(16)]
    return {"samples": words[:words.index(0)] if 0 in words else words,
            "echo": bytes(rom[ECHO_PC + 2 * i:ECHO_PC + 2 * i + 2]),
            "drums": bytes(rom[EXTRA_PC + 36 * i:EXTRA_PC + 36 * i + 36])}


def table_rows(tables):
    """(pc offset of row 0, row size, row bytes) for each table a listing sets."""
    rows = []
    if "samples" in tables:
        rows.append((SAMPLES_PC, 32, b"".join(s.to_bytes(2, "little") for s in tables["samples"]).ljust(32, b"\0")))
    if "echo" in tables:
        rows.append((ECHO_PC, 2, tables["echo"]))
    if "drums" in tables:
        rows.append((EXTRA_PC, 36, tables["drums"]))
    return rows


def render_tables(tables):
    lines = []
    if "samples" in tables:
        lines.append("@samples " + (" ".join(map(str, tables["samples"])) or "none"))
    if "echo" in tables:
        lines.append("@echo " + " ".join(f"${x:02X}" for x in tables["echo"]))
    if "drums" in tables:
        d = tables["drums"]
        if not any(d):
            lines.append("@drums none")
        for k in range(12) if any(d) else ():
            lines.append(f"@drum {k} " + " ".join(f"${x:02X}" for x in d[3 * k:3 * k + 3]))
    return lines


def render(song, durations, title=None, tables=None):
    seen = song.walk()
    targets = {song.offset(a) for a in song.tracks if a != song.notrack}
    targets |= {t for o in seen if (t := song.target(o)) is not None}
    lines = [f"; {title}"] if title else []
    lines += ["; ct-song/1 — CT SPC700 song sequence; see macos_studio/docs/music_sequences.md",
              f"@origin ${song.origin:04X}", f"@notrack ${song.notrack:04X}"]
    lines += render_tables(tables or {})
    for i, a in enumerate(song.tracks):
        lines.append(f"@track {'AB'[i // 8]} {i % 8} " + ("-" if a == song.notrack else label(a)))
    o, n = HEADER, len(song.data)
    while o < n:
        if o in targets:
            lines.append(label(song.address(o)) + ":")
        if o in seen:
            b, k = song.data[o], seen[o]
            words = [statement(b, song.data[o + 1:o + k])]
            if b < FIRST_CMD:
                words.append(str(durations[b % 14]))
            else:
                ops = [f"${x:02X}" for x in song.data[o + 1:o + k]]
                if b in JUMPS:
                    j = JUMPS[b]
                    ops[j:j + 2] = ["->" + label(word(song.data, o + 1 + j))]
                words += ops
            lines.append("    " + " ".join(words))
            o += k
            continue
        z = o + 1
        while z < n and z not in seen and z not in targets:
            z += 1
        for s in range(o, z, 16):
            lines.append("@bytes " + " ".join(f"{x:02X}" for x in song.data[s:min(s + 16, z)]))
        o = z
    return "\n".join(lines) + "\n"


def assemble(text, counts, durations):
    """`ct-song/1` text -> song data; the result must walk to what was written."""
    return assemble_song(text, counts, durations)[0]


def assemble_song(text, counts, durations):
    """`ct-song/1` text -> (song data, the per-song tables the listing sets)."""
    origin = notrack = None
    tracks = [None] * 16
    items, tables, drums = [], {}, {}
    for no, raw in enumerate(text.split("\n"), 1):
        words = raw.split(";", 1)[0].split()
        if not words:
            continue
        head = words[0]

        def fail(msg):
            raise ValueError(f"line {no}: {msg}")

        def hexword(t):
            if not re.fullmatch(r"\$[0-9A-Fa-f]{4}", t):
                fail(f"{t} is not a $XXXX word")
            return int(t[1:], 16)

        if head in ("@origin", "@notrack"):
            if len(words) != 2:
                fail(f"expected {head} $XXXX")
            if head == "@origin":
                origin = hexword(words[1])
            else:
                notrack = hexword(words[1])
        elif head == "@samples":
            if "samples" in tables:
                fail("@samples given twice")
            if words[1:] == ["none"]:
                tables["samples"] = []
            elif not 1 < len(words) <= 17 or not all(w.isdigit() and 1 <= int(w) <= SAMPLE_NUMBER_MAX for w in words[1:]):
                fail(f"expected @samples none or 1-16 sample numbers 1-{SAMPLE_NUMBER_MAX}")
            else:
                tables["samples"] = [int(w) for w in words[1:]]
        elif head == "@echo":
            if "echo" in tables or len(words) != 3 or not all(re.fullmatch(r"\$[0-9A-Fa-f]{2}", w) for w in words[1:]):
                fail("expected one @echo $XX $XX")
            tables["echo"] = bytes(int(w[1:], 16) for w in words[1:])
        elif head == "@drums":
            if words[1:] != ["none"] or "drums" in tables or drums:
                fail("expected one @drums none (or 12 @drum lines)")
            tables["drums"] = bytes(36)
        elif head == "@drum":
            if (len(words) != 5 or not words[1].isdigit() or not 0 <= int(words[1]) <= 11
                    or not all(re.fullmatch(r"\$[0-9A-Fa-f]{2}", w) for w in words[2:])):
                fail("expected @drum 0-11 $SAMPLE $NOTE $PAN")
            if "drums" in tables or int(words[1]) in drums:
                fail(f"drum {words[1]} given twice")
            drums[int(words[1])] = bytes(int(w[1:], 16) for w in words[2:])
        elif head == "@track":
            if len(words) != 4 or words[1] not in ("A", "B") or words[2] not in "01234567" or len(words[2]) != 1:
                fail("expected @track A|B 0-7 LABEL|-")
            i = "AB".index(words[1]) * 8 + int(words[2])
            if tracks[i] is not None:
                fail("track given twice")
            tracks[i] = words[3]
        elif head == "@bytes":
            if len(words) < 2 or not all(re.fullmatch(r"[0-9A-Fa-f]{2}", w) for w in words[1:]):
                fail("expected @bytes XX ...")
            items.append(("bytes", bytes(int(w, 16) for w in words[1:])))
        elif head.endswith(":"):
            if len(words) != 1 or not re.fullmatch(r"[A-Za-z_]\w*", head[:-1]):
                fail("bad label")
            items.append(("label", head[:-1]))
        else:
            if head in ("note", "tie", "rest"):
                rest = words[1:]
                index = 0
                if head == "note":
                    if not rest or rest[0] not in NOTE_NAMES:
                        fail("expected note C|C#|...|B LENGTH")
                    index = NOTE_NAMES.index(rest[0])
                    rest = rest[1:]
                if len(rest) != 1 or not rest[0].isdigit() or int(rest[0]) not in durations:
                    fail(f"{head} length must be one of {sorted(set(durations))}")
                d = durations.index(int(rest[0]))
                base = {"note": index * 14, "tie": FIRST_TIE, "rest": FIRST_REST}[head]
                items.append(("op", base + d, []))
                continue
            if head not in BY_NAME:
                fail(f"unknown statement {head}")
            op, ops = BY_NAME[head], []
            for t in words[1:]:
                if t.startswith("->"):
                    if op not in JUMPS or len(ops) != JUMPS[op]:
                        fail(f"{head}: operand {len(ops) + 1} is not an address")
                    ops.append(("label", t[2:]))
                elif re.fullmatch(r"\$[0-9A-Fa-f]{2}", t):
                    ops.append(("byte", int(t[1:], 16)))
                else:
                    fail(f"{t} is not a $XX byte or ->LABEL")
            size = sum(2 if k == "label" else 1 for k, _ in ops)
            if size != counts[op - FIRST_CMD] or (op in JUMPS and not any(k == "label" for k, _ in ops)):
                fail(f"{head} takes {counts[op - FIRST_CMD]} operand bytes" +
                     (" with a ->LABEL address" if op in JUMPS else ""))
            items.append(("op", op, ops))
    if origin is None or notrack is None or None in tracks:
        raise ValueError("need @origin, @notrack and all 16 @track lines")
    if drums:
        if len(drums) != 12:
            raise ValueError("give all 12 @drum lines (0-11) or @drums none")
        tables["drums"] = b"".join(drums[k] for k in range(12))
    labels, offset, written = {}, HEADER, []
    for item in items:
        if item[0] == "label":
            if item[1] in labels:
                raise ValueError(f"label {item[1]} defined twice")
            labels[item[1]] = (origin + offset - HEADER) & 0xFFFF
        elif item[0] == "bytes":
            offset += len(item[1])
        else:
            written.append(offset)
            offset += 1 + sum(2 if k == "label" else 1 for k, _ in item[2])

    def resolve(name):
        if name not in labels:
            raise ValueError(f"undefined label {name}")
        return labels[name]

    out = bytearray(origin.to_bytes(2, "little") + notrack.to_bytes(2, "little"))
    for t in tracks:
        a = notrack if t == "-" else resolve(t)
        if t != "-" and a == notrack:
            raise ValueError(f"track label {t} equals the @notrack word")
        out += a.to_bytes(2, "little")
    for item in items:
        if item[0] == "bytes":
            out += item[1]
        elif item[0] == "op":
            out.append(item[1])
            for k, v in item[2]:
                out += resolve(v).to_bytes(2, "little") if k == "label" else bytes([v])
    if not fits(len(out)):
        raise ValueError(f"song is {len(out)} bytes; its transfer would reach ${BLOCK_4700:04X} (the most is {MAX_LENGTH})")
    song = Song(out, counts)
    stray = sorted(set(song.walk()) - set(written))
    if stray:
        raise ValueError(f"${song.address(stray[0]):04X} is reached but written as data; write it as statements")
    return bytes(out), tables


def songs(rom):
    """[(index, pointer, pc, data)] for every Audio_SongTable entry."""
    count = rom[SONG_COUNT_PC]
    out = []
    for i in range(count):
        p = int.from_bytes(rom[SONG_TABLE_PC + 3 * i:SONG_TABLE_PC + 3 * i + 3], "little")
        at = pc_of(p)
        n = word(rom, at)
        out.append((i, p, at, rom[at + 2:at + 2 + n]))
    return out


def derive(rom):
    counts, durations = driver_tables(rom)
    rows = []
    for i, p, at, data in songs(rom):
        song = Song(data, counts)
        seen = song.walk()
        tables = song_tables(rom, i)
        text = render(song, durations, tables=tables)
        if assemble_song(text, counts, durations) != (data, tables):
            raise SystemExit(f"song {i:02X}: the listing does not assemble to the ROM bytes and tables")
        if any(rom[pc + row * i:pc + row * i + row] != b for pc, row, b in table_rows(tables)):
            raise SystemExit(f"song {i:02X}: table rows do not re-encode")
        reached = sum(seen.values())
        rows.append({
            "song": i, "pointer": f"${p >> 16:02X}:{p & 0xFFFF:04X}", "pc": f"0x{at:06X}",
            "length": len(data), "origin": f"${song.origin:04X}",
            "tracks": [sum(a != song.notrack for a in song.tracks[:8]), sum(a != song.notrack for a in song.tracks[8:])],
            "same_sets": song.tracks[:8] == song.tracks[8:],
            "statements": len(seen), "unreached_bytes": len(data) - HEADER - reached,
            "samples": len(tables["samples"]), "drum_kit": any(tables["drums"]),
            "data_sha256": hashlib.sha256(data).hexdigest(),
            "listing_sha256": hashlib.sha256(text.encode()).hexdigest(),
        })
    return {
        "schema": "ct-spc-sequences/1",
        "source": "tools/ct_spc_seq.py derive (ROM tables checked against refs/ChronoRET driver.asm)",
        "song_table": "$C7:0D18", "song_count": len(rows),
        "tables": {"samples": "$C7:0E11", "echo": "$C7:241D", "drums": "$C7:1871"},
        "operand_counts": list(counts), "durations": list(durations),
        "song_room": SONG_ROOM, "max_length": MAX_LENGTH,
        "songs_over_song_room": [r["song"] for r in rows if r["length"] >= SONG_ROOM],
        "totals": {"bytes": sum(r["length"] for r in rows),
                   "unreached_bytes": sum(r["unreached_bytes"] for r in rows),
                   "statements": sum(r["statements"] for r in rows),
                   "byte_exact": len(rows)},
        "songs": rows,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("command", choices=["derive", "check", "listing"])
    ap.add_argument("song", nargs="?", type=lambda s: int(s, 0))
    ap.add_argument("--rom", default=str(WS / "ct_clean.sfc"))
    args = ap.parse_args()
    rom = Path(args.rom).read_bytes()
    if args.command == "listing":
        counts, durations = driver_tables(rom)
        i, p, at, data = songs(rom)[args.song]
        sys.stdout.write(render(Song(data, counts), durations, title=f"song {i:02X} (${p >> 16:02X}:{p & 0xFFFF:04X})",
                                tables=song_tables(rom, i)))
        return 0
    manifest = derive(rom)
    if args.command == "derive":
        MANIFEST.write_text(json.dumps(manifest, indent=1) + "\n")
        print(f"wrote {MANIFEST.relative_to(WS)}: {manifest['song_count']} songs, "
              f"{manifest['totals']['statements']} statements, byte-exact")
        return 0
    if json.loads(MANIFEST.read_text()) != manifest:
        print("spc_sequences.json differs from a fresh derive", file=sys.stderr)
        return 1
    print(f"{manifest['song_count']} songs byte-exact through ct-song/1 listings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
