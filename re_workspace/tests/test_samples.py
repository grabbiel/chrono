"""ct_samples.py: the S-DSP's BRR decode, the checks a written sample must pass,
and (locally) the ROM's sample tables and its own song load.

ROM-free: synthetic BRR blocks. Local (ROM, ChronoRET): the twelve operands
that read the tables, every ROM sample's entry and budget, and
Audio_CmdLoadSong run in ChronoRET's 65816 interpreter.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import ct_samples as cs  # noqa: E402


def block(header, nibbles):
    """A 9-byte block from a header and 16 signed nibbles."""
    data = bytes(((nibbles[2 * i] & 15) << 4) | (nibbles[2 * i + 1] & 15) for i in range(8))
    return bytes([header]) + data


def test_decode_shifts_filters_and_wraps():
    # Shift 12, filter 0: a nibble n decodes to (n << 12) >> 1.
    out = cs.dsp_decode(block(0xC0, [1, -1, 7, -8] + [0] * 12))
    assert out[:4] == [2048, -2048, 14336, -16384]
    # Shifts 13-15 keep only the sign: -2048 for negative nibbles, else 0.
    assert cs.dsp_decode(block(0xD0, [3, -3] + [0] * 14))[:2] == [0, -2048]
    # Filter 1 adds y1 - y1/16 (15/16 of the last sample).
    out = cs.dsp_decode(block(0x04, [0] * 16), y1=1600)
    assert out[0] == 1600 + ((-1600) >> 4)
    # The 16-bit clamp, then the 15-bit wraparound.
    out = cs.dsp_decode(block(0xC8, [7] + [0] * 15), y1=16000, y2=0)
    assert -16384 <= out[0] <= 16383


def test_written_sample_checks():
    good = block(0xB0, [1] * 16) + block(0xB3, [1] * 16)
    assert cs.brr_problems(good, 9) == []
    assert cs.brr_problems(good[:-1], 0) == ["17 bytes is not whole 9-byte blocks"]
    assert "the last block has no end flag" in cs.brr_problems(block(0xB0, [0] * 16), 0)
    early = block(0xB1, [0] * 16) + block(0xB1, [0] * 16)
    assert "an end flag before the last block" in cs.brr_problems(early, 0)
    assert cs.brr_problems(early, 0, strict=False) == []
    assert "loop offset 4" in cs.brr_problems(good, 4)
    no_loop = block(0xB0, [0] * 16) + block(0xB1, [0] * 16)
    assert "loop offset 9" in cs.brr_problems(no_loop, 9)


# --- Local: the ROM and ChronoRET --------------------------------------------------------

def test_tables_and_budgets(rom_path):
    rom = rom_path.read_bytes()
    sites = cs.find_sites(rom)
    assert len(sites) == 12
    t = cs.tables(rom, sites)
    assert t["count"] == cs.ROM_COUNT and t["pointers"] == cs.TABLE_START
    assert t["adsr"] + 2 * t["count"] == cs.TABLE_END
    lax = 0
    for n in range(1, t["count"] + 1):
        e = cs.entry(rom, t, n)
        assert len(e["brr"]) == e["length"] and e["length"] % 9 == 0 and e["adsr"] & 0x80
        assert cs.brr_problems(e["brr"], e["loopOffset"], strict=False) == []
        lax += bool(cs.brr_problems(e["brr"], e["loopOffset"]))
        assert len(cs.dsp_decode(e["brr"])) == e["length"] // 9 * 16
    assert lax == 2            # two loop words without a loop flag; written back asIs
    free = []
    for song in range(rom[cs.SONG_COUNT_PC]):
        start, end, echo, _ = cs.budget(rom, song, t)
        assert end <= echo
        free.append(echo - end)
    assert min(free) == 16 and free.index(16) == 0x27


def test_rom_song_load(rom_path, chronoret):
    rom = rom_path.read_bytes()
    t = cs.tables(rom, cs.find_sites(rom))
    command, transfers, end = cs.load_transfers(rom, 2)
    assert command[:2] == (0x10, 2) and end[:2] == (0xE0, 0xE0)
    at = {dest: data for dest, _, data in transfers}
    base = (0x4700 + cs.word(rom, cs.BLOCK_4700_LEN_PC)) & 0xFFFF
    for slot, n in enumerate(cs.song_list(rom, 2)):
        e = cs.entry(rom, t, n)
        directory = at[0x1E80]
        start = cs.word(directory, 4 * slot)
        assert at[start][:e["length"]] == e["brr"]
        assert cs.word(directory, 4 * slot + 2) == (start + e["loopOffset"]) & 0xFFFF
        assert (cs.word(at[0x1F40], 2 * slot), cs.word(at[0x1FC0], 2 * slot)) == (e["tuning"], e["adsr"])
        if slot == 0:
            assert start == base
