#!/usr/bin/env python3
"""Chrono Trigger's sample tables and song loads, read without the Swift code.

    ct_samples.py tables <rom.sfc>              the sample tables the code reads
    ct_samples.py load <rom.sfc> <song> [--json] the transfers the ROM's own sender makes

Tables: Audio_SampleTable (a long pointer per sample to a length word and its
BRR bytes), Audio_SampleLoop, Audio_SampleParamA (the tuning word) and
Audio_SampleParamB (ADSR1, ADSR2), back to back from $C7:0AEA with 62 entries
in the US 1.0 ROM. Where a ROM's code reads them is found, not assumed: the
LDA/ADC long,X instructions of bank $C7 whose operands fall in those tables in
the clean ROM (a byte search; twelve sites), whose operands are then read in
the ROM given. A built ROM that appends samples moves the four tables and
points those operands at them.

Loads: Audio_CmdLoadSong ($C7:01A1) run on the ROM's own code by ChronoRET's
65816 interpreter (refs/ChronoRET/tools/absint.py, MIT), from the state
Audio_Boot leaves (no sample in a slot, the first slot at $4700 + boot block
2's length, no $2F00 block to send, the song's echo delay current), with the
APU modelled as a receiver that echoes every port at once. Every byte written
to APUIO0-3 is recorded; a write to APUIO0 is one step. Steps are read back as
the driver's transfer protocol: the command, then per transfer a header (its
ARAM address in APUIO2/3, its mode in APUIO1) and steps of 2 or 3 bytes, then
the end ($E0, $E0). The run stops at Audio_CommandDone ($C7:0192).

Decode: the S-DSP's BRR recursion (fullsnes "BRR Samples"): a nibble scales to
(n << shift) >> 1, shifts 13-15 act as 12 with the nibble's sign only, the
filters use the 15-bit history, and each sample is clamped to 16 bits and kept
as 15 with wraparound.
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
REF = WS / "refs" / "ChronoRET"
ROM = WS / "ct_clean.sfc"

TABLE_START, TABLE_END = 0xC70AEA, 0xC70D18     # Audio_SampleTable ... the end of Audio_SampleParamB
ROM_COUNT = 62
LONG_X_OPCODES = (0xBF, 0x7F)                   # LDA long,X; ADC long,X
SAMPLES_PC = 0x070E11                           # AudioRom_SongSamples: 16 words per song
ECHO_PC = 0x07241D                              # AudioRom_SongEcho: a word per song
BLOCK_4700_LEN_PC = 0x0740B4                    # !AudioRom_Block4700's length word
ECHO_TOP = 0xF100                               # !Audio_EchoTopPage
SONG_COUNT_PC = 0x070AE9

LOAD_SONG, COMMAND_DONE = 0xC701A1, 0xC70192    # Audio_CmdLoadSong, Audio_CommandDone
DP_AUDIO = 0x7E1E00                             # !DP_Audio
CMD_ID, CMD_ARG0, SONG_LOADING = 0x7E1E00, 0x7E1E01, 0x7E1E05
SLOT_ARAM, ECHO_DELAY = 0x7E1E60, 0x7E1EF0
PORTS = range(0x2140, 0x2144)
SEQ_HEADER = 0xE0


def word(rom, pc):
    return rom[pc] | rom[pc + 1] << 8


def long(rom, pc):
    return rom[pc] | rom[pc + 1] << 8 | rom[pc + 2] << 16


def pc_of(address):
    return address & 0x3FFFFF


def sha(data):
    return hashlib.sha256(bytes(data)).hexdigest()


def find_sites(clean):
    """(operand file offset, table base it reads) of every LDA/ADC long,X in
    bank $C7 whose operand lies in the clean ROM's four tables."""
    sites = []
    for at in range(0x070000, 0x080000 - 3):
        if clean[at] in LONG_X_OPCODES:
            operand = long(clean, at + 1)
            if TABLE_START <= operand < TABLE_END:
                sites.append(at + 1)
    return sites


def tables(rom, sites, clean=None):
    """(pointers, loops, tuning, adsr, count) as the code at `sites` reads
    them. In the clean ROM each site's operand is its table + 0-2 (the
    pointer's byte); the same offsets apply in a built ROM."""
    clean = clean if clean is not None else rom
    base_of = {}
    for site in sites:
        original = long(clean, site)
        # Which table and byte: the clean layout's four tables of 62 entries.
        offset = original - TABLE_START
        if offset < 3 * ROM_COUNT:
            name, byte = "pointers", offset % 3
        elif offset < 5 * ROM_COUNT:
            name, byte = "loops", 0
        elif offset < 7 * ROM_COUNT:
            name, byte = "tuning", 0
        else:
            name, byte = "adsr", 0
        if name != "pointers" and (offset - {"loops": 3, "tuning": 5, "adsr": 7}[name] * ROM_COUNT) != 0:
            raise ValueError(f"site ${site - 1:06X} reads inside a word table")
        base = long(rom, site) - byte
        if base_of.setdefault(name, base) != base:
            raise ValueError(f"the code reads {name} from two places")
    pointers = base_of["pointers"]
    count = (base_of["loops"] - pointers) // 3
    layout = {"pointers": pointers, "loops": pointers + 3 * count, "tuning": pointers + 5 * count,
              "adsr": pointers + 7 * count, "count": count}
    if any(base_of[k] != layout[k] for k in ("loops", "tuning", "adsr")) or not 1 <= count <= 255:
        raise ValueError("the sample tables are not back to back")
    return layout


def entry(rom, t, n):
    """Sample n (1-count): its pointer, file offset, BRR bytes and words."""
    if not 1 <= n <= t["count"]:
        raise ValueError(f"sample {n} is not 1-{t['count']}")
    pointer = long(rom, pc_of(t["pointers"]) + 3 * (n - 1))
    if not 0xC0 <= pointer >> 16 <= 0xFF:
        raise ValueError(f"sample {n} points at ${pointer:06X}")
    pc = pc_of(pointer)
    length = word(rom, pc)
    return {"number": n, "pointer": pointer, "pc": pc, "length": length, "brr": bytes(rom[pc + 2:pc + 2 + length]),
            "loopOffset": word(rom, pc_of(t["loops"]) + 2 * (n - 1)),
            "tuning": word(rom, pc_of(t["tuning"]) + 2 * (n - 1)),
            "adsr": word(rom, pc_of(t["adsr"]) + 2 * (n - 1))}


def brr_problems(brr, loop_offset, strict=True):
    """Why the S-DSP would not play `brr` as one sample, or []."""
    out = []
    if not brr or len(brr) % 9:
        return [f"{len(brr)} bytes is not whole 9-byte blocks"]
    blocks = len(brr) // 9
    if not brr[9 * (blocks - 1)] & 1:
        out.append("the last block has no end flag")
    if strict:
        if any(brr[9 * b] & 1 for b in range(blocks - 1)):
            out.append("an end flag before the last block")
        loops = brr[9 * (blocks - 1)] & 2
        if loop_offset % 9 or not 0 <= loop_offset < len(brr) or (not loops and loop_offset):
            out.append(f"loop offset {loop_offset}")
    return out


def dsp_decode(brr, y1=0, y2=0):
    """The S-DSP's 15-bit samples for whole blocks, from history y1, y2."""
    out = []
    for b in range(0, len(brr) - 8, 9):
        header = brr[b]
        shift, filt = header >> 4, header >> 2 & 3
        for i in range(16):
            byte = brr[b + 1 + i // 2]
            n = (byte >> 4) if i % 2 == 0 else byte & 15
            n = n - 16 if n >= 8 else n
            x = (n << shift) >> 1 if shift <= 12 else (-2048 if n < 0 else 0)
            if filt == 1:
                x += y1 + ((-y1) >> 4)
            elif filt == 2:
                x += 2 * y1 + ((-3 * y1) >> 5) - y2 + (y2 >> 4)
            elif filt == 3:
                x += 2 * y1 + ((-13 * y1) >> 6) - y2 + ((3 * y2) >> 4)
            x = max(-0x8000, min(0x7FFF, x))
            x = ((x << 1) & 0xFFFF)
            x = (x - 0x10000 if x & 0x8000 else x) >> 1
            out.append(x)
            y2, y1 = y1, x
    return out


def song_list(rom, song):
    words = [word(rom, SAMPLES_PC + 32 * song + 2 * k) for k in range(16)]
    return words[:words.index(0)] if 0 in words else words


def budget(rom, song, t=None, sites=None, clean=None):
    """(sample start, sample end, echo start, EDL) as the game loads `song`."""
    t = t or tables(rom, sites or find_sites(clean or rom), clean)
    start = (0x4700 + word(rom, BLOCK_4700_LEN_PC)) & 0xFFFF
    end = start + sum(entry(rom, t, n)["length"] for n in song_list(rom, song))
    edl = rom[ECHO_PC + 2 * song] & 0x0F
    return start, end, ECHO_TOP - 0x800 * edl, edl


# ── The ROM's sender in ChronoRET's interpreter ──

def load_transfers(rom, song):
    """Audio_CmdLoadSong for `song`, as the ROM's code sends it: (command
    step, [(destination, mode, bytes)], end step)."""
    if str(REF / "tools") not in sys.path:
        sys.path.insert(0, str(REF / "tools"))
    import absint

    class Apu(absint.Machine):
        """Ports that echo at once: APUIO0 reads back the step just written,
        APUIO1 the mode or argument just written."""

        def __init__(self, image):
            super().__init__(bytes(image), bytearray(b"\x01") * len(image), max_steps=10 ** 8, callee_steps=10 ** 8)
            self.widen_after = 10 ** 9
            self.out, self.steps = [0, 0, 0, 0], []

        @staticmethod
        def port(addr):
            bank = addr >> 16
            if (bank < 0x40 or 0x80 <= bank < 0xC0) and (addr & 0xFFFF) in PORTS:
                return (addr & 0xFFFF) - 0x2140
            return None

        def read8(self, s, addr):
            if addr is not None and self.port(addr) is not None:
                return self.out[self.port(addr)]
            return super().read8(s, addr)

        def write8(self, s, addr, v):
            p = None if addr is None else self.port(addr)
            if p is None:
                return super().write8(s, addr, v)
            if v is None:
                raise RuntimeError("an unknown byte was sent to the APU")
            self.out[p] = v
            if p == 0:
                self.steps.append(tuple(self.out))

        def step(self, s, base):
            if s.pc == COMMAND_DONE:
                return ("done", None)
            return super().step(s, base)

    machine = Apu(rom)
    s = absint.State()
    s.pc, s.a, s.b, s.x, s.y = LOAD_SONG, 0, 0, 0, 0
    s.d, s.db, s.m, s.xf, s.c = DP_AUDIO & 0xFFFF, 0, True, False, False
    s.z = s.n = s.v = False
    s.sp, s.spt, s.mem, s.memt, s.frames = [], [], {}, {}, []
    s.at = s.xt = s.yt = s.ft = absint.E
    s.depth = 0
    base = (0x4700 + word(rom, BLOCK_4700_LEN_PC)) & 0xFFFF
    known = {DP_AUDIO + i: 0 for i in range(0x200)}       # Audio_Boot clears the page; the buffers start empty
    known[CMD_ID], known[CMD_ARG0], known[SONG_LOADING] = 0x10, song, 0xE0
    known[SLOT_ARAM], known[SLOT_ARAM + 1] = base & 0xFF, base >> 8
    known[ECHO_DELAY] = rom[ECHO_PC + 2 * song] & 0x0F   # the song's echo delay is current: no $FC command
    ends = machine.run(s, known)
    if [how for _, how in ends] != ["done"] or machine.opaque:
        raise RuntimeError(f"Audio_CmdLoadSong did not end once at Audio_CommandDone: {[h for _, h in ends]} {machine.opaque}")
    steps = machine.steps
    command, transfers, k = steps[0], [], 1
    while k < len(steps):
        header = steps[k]
        if header[1] == SEQ_HEADER and header[0] == SEQ_HEADER:
            return command, transfers, header
        mode, dest = header[1], header[2] | header[3] << 8
        if mode not in (2, 3):
            raise RuntimeError(f"step {k}: header mode {mode}")
        data, k = [], k + 1
        while k < len(steps) and steps[k][0] != SEQ_HEADER:
            data += steps[k][1:1 + mode]
            k += 1
        transfers.append((dest, mode, bytes(data)))
    raise RuntimeError("the load did not end with $E0, $E0")


# ── ct_rom_check.py: what a report's samples may write, and the checks ──

def zones(clean, report):
    """Ranges `rom.samples` may write: replaced samples' old spans that no
    other entry uses, their table rows (or the operands, when the tables
    moved), and the sample-list rows of the songs it names."""
    out = []
    samples = report.get("samples") or []
    if not samples:
        return out
    sites = find_sites(clean)
    t = tables(clean, sites)
    replaced = {s["number"] for s in samples if s["replaced"]}
    entries = [entry(clean, t, n) for n in range(1, t["count"] + 1)]
    kept = {e["pc"] for e in entries if e["number"] not in replaced}
    for e in entries:
        if e["number"] in replaced:
            if e["pc"] not in kept:
                out.append(range(e["pc"], e["pc"] + 2 + e["length"]))
            n = e["number"] - 1
            out += [range(pc_of(t["pointers"]) + 3 * n, pc_of(t["pointers"]) + 3 * n + 3)]
            out += [range(pc_of(t[k]) + 2 * n, pc_of(t[k]) + 2 * n + 2) for k in ("loops", "tuning", "adsr")]
    if report.get("sampleTables"):
        out += [range(site, site + 3) for site in sites]
    for row in report.get("sampleLists") or []:
        out.append(range(SAMPLES_PC + 32 * row["song"], SAMPLES_PC + 32 * (row["song"] + 1)))
    return out


def check_samples(clean, built, report, check, inside, free):
    """The sample tables, every entry, the sample lists and the budgets of a
    built ROM against the report. `free` holds the confirmed free regions.
    Returns the new spans (for the overlap check) and the table count."""
    sites = find_sites(clean)
    check(len(sites) == 12, f"{len(sites)} long operands read the sample tables in the clean ROM")
    t0, t1 = tables(clean, sites), tables(built, sites, clean)
    samples = report.get("samples") or []
    moved = report.get("sampleTables")
    appended = sorted(s["number"] for s in samples if not s["replaced"])
    spans = {}
    if moved:
        check(t1["pointers"] == 0xC00000 | moved["pc"] and t1["count"] == moved["count"] == ROM_COUNT + len(appended),
              "the moved sample tables are not where the report says")
        block = range(moved["pc"], moved["pc"] + 9 * t1["count"])
        check(any(block.start >= z.start and block.stop <= z.stop for z in free), "the moved sample tables are outside free space")
        spans[block.start] = block
    else:
        check(t1 == t0, "the sample tables moved, and the report does not say so")
    check(appended == list(range(ROM_COUNT + 1, ROM_COUNT + 1 + len(appended))), "appended samples are not numbered from 63")
    by_number = {s["number"]: s for s in samples}
    check(len(by_number) == len(samples), "a sample number is reported twice")
    for n in range(1, t1["count"] + 1):
        e = entry(built, t1, n)
        s = by_number.get(n)
        if s is None:
            c = entry(clean, t0, n)
            check(all(e[k] == c[k] for k in ("pointer", "length", "brr", "loopOffset", "tuning", "adsr")), f"sample {n} changed")
            continue
        check(s["replaced"] == (n <= ROM_COUNT), f"sample {n}: replaced or appended")
        check(e["pc"] == s["pc"] and e["length"] == s["length"] and sha(e["brr"]) == s["brrSHA256"], f"sample {n}: BRR bytes")
        check((e["loopOffset"], e["tuning"], e["adsr"]) == (s["loopOffset"], s["tuning"], s["adsr"]), f"sample {n}: table words")
        problems = brr_problems(e["brr"], e["loopOffset"], strict=not s["asIs"])
        check(not problems, f"sample {n}: {problems}")
        check(e["adsr"] & 0x80 and len(e["brr"]) % 3 == 0, f"sample {n}: ADSR word or length")
        dsp_decode(e["brr"])
        span = range(e["pc"], e["pc"] + 2 + e["length"])
        check(inside(span), f"sample {n}: outside free space")
        spans[span.start] = span

    # Sample lists: only reported songs change, each as reported, in range.
    songs = clean[SONG_COUNT_PC]
    listed = {row["song"]: row["samples"] for row in report.get("sampleLists") or []}
    rebuilt = {s["song"]: s.get("samples") for s in report.get("songs", [])}
    for song in range(songs):
        before, after = song_list(clean, song), song_list(built, song)
        if song in listed:
            check(after == listed[song], f"song {song}: sample list")
        elif rebuilt.get(song) is not None:
            check(after == rebuilt[song], f"song {song}: sample list")
        else:
            check(after == before, f"song {song}: its sample list changed")
        check(len(after) <= 16 and all(1 <= x <= t1["count"] for x in after), f"song {song}: sample list range")
    for s in samples:
        for song in s["songs"]:
            check(s["number"] in song_list(built, song), f"sample {s['id']}: song {song} does not load it")

    # Budgets: each written song's samples end below its echo buffer.
    budgeted = set(listed) | set(rebuilt)
    reported = {b["song"]: b for b in report.get("budgets") or []}
    check(set(reported) == budgeted, "the report's budgets are not the written songs'")
    for song in sorted(budgeted):
        start, end, echo, edl = budget(built, song, t1)
        b = reported[song]
        check(end <= echo, f"song {song}: samples end at ${end:04X}, past the echo buffer at ${echo:04X}")
        check((b["sampleStart"], b["sampleEnd"], b["echoStart"], b["edl"]) == (start, end, echo, edl), f"song {song}: budget")
    return spans, t1["count"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("tables")
    a.add_argument("rom")
    b = sub.add_parser("load")
    b.add_argument("rom")
    b.add_argument("song", type=lambda v: int(v, 0))
    b.add_argument("--json", action="store_true")
    args = parser.parse_args()
    clean = ROM.read_bytes()
    rom = Path(args.rom).read_bytes()
    if args.cmd == "tables":
        t = tables(rom, find_sites(clean), clean)
        print(json.dumps({k: (f"${v:06X}" if k != "count" else v) for k, v in t.items()}))
        return
    command, transfers, end = load_transfers(rom, args.song)
    doc = {"command": list(command), "end": list(end),
           "transfers": [{"destination": d, "mode": m, "bytes": len(b), "sha256": sha(b)} for d, m, b in transfers]}
    print(json.dumps(doc, indent=1) if args.json else
          "\n".join(f"${d:04X} mode {m}: {len(b)} bytes {sha(b)[:16]}" for d, m, b in transfers))


if __name__ == "__main__":
    main()
