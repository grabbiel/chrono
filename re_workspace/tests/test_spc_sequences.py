"""SPC700 song sequences: every Audio_SongTable song decodes from the driver's
tables, renders to a ct-song/1 listing and assembles back byte for byte; the
committed metadata manifest equals a fresh derive; the assembler refuses
listings the driver could not play as written."""
import json
import sys
from pathlib import Path

import pytest

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
import ct_event_packs as packs  # noqa: E402
import ct_spc_seq as spc  # noqa: E402


def test_manifest_matches_rom():
    derived = spc.derive(packs.read_rom())
    assert derived == json.loads(spc.MANIFEST.read_text())
    assert derived["song_count"] == 83 and derived["totals"]["byte_exact"] == 83
    assert derived["totals"]["unreached_bytes"] == 2
    assert derived["songs_over_song_room"] == [0x3F]
    assert derived["max_length"] == 9983


def test_every_song_round_trips():
    rom = packs.read_rom()
    counts, durations = spc.driver_tables(rom)
    for i, _, _, data in spc.songs(rom):
        tables = spc.song_tables(rom, i)
        text = spc.render(spc.Song(data, counts), durations, tables=tables)
        assert spc.assemble_song(text, counts, durations) == (data, tables), i


def _listing(body, origin="$1000", notrack="$FFFF"):
    tracks = [f"@track {'AB'[i // 8]} {i % 8} {['L_a', 'L_b'][i] if i < 2 else '-'}" for i in range(16)]
    return "\n".join([f"@origin {origin}", f"@notrack {notrack}"] + tracks) + "\n" + body + "\n"


GOOD = "L_a:\n    tempo $40\nL_loop:\n    note C# 24\n    branch $01 ->L_a\n    jump ->L_loop\nL_b:\n    rest 192\n    end"


def test_assembler_bytes_and_refusals():
    counts, durations = spc.driver_tables(packs.read_rom())
    data = spc.assemble(_listing(GOOD), counts, durations)
    assert data[0x24:] == bytes([0xF0, 0x40, 0x15, 0xFA, 0x01, 0x00, 0x10, 0xF6, 0x02, 0x10, 0xB6, 0xEB])
    for body, message in [
        ("L_a:\n    bogus\nL_b:\n    end", "unknown statement"),
        ("L_a:\n    note C 50\nL_b:\n    end", "length must be one of"),
        ("L_a:\n    tempo\nL_b:\n    end", "takes 1 operand bytes"),
        ("L_a:\n    jump $00 $10\nL_b:\n    end", "->LABEL address"),
        ("L_a:\n    jump ->L_x\nL_b:\n    end", "undefined label"),
        ("L_a:\n    rest 48\n@bytes EB\nL_b:\n    end", "written as data"),
        ("L_a:\n    rest 48\nL_b:\n    tempo $01", "outside the song"),
    ]:
        with pytest.raises(ValueError, match=message):
            spc.assemble(_listing(body), counts, durations)
    for line, message in [("@samples 0", "sample numbers"), ("@samples 63", "sample numbers"),
                          ("@echo $04", "@echo"), ("@drum 0 $00 $00 $00", "all 12 @drum"),
                          ("@drums none\n@drum 0 $00 $00 $00", "given twice")]:
        text = _listing(GOOD).replace("@notrack $FFFF\n", f"@notrack $FFFF\n{line}\n")
        with pytest.raises(ValueError, match=message):
            spc.assemble_song(text, counts, durations)
    drums = "\n".join(f"@drum {k} $2{k % 10} $4C $40" for k in range(12))
    data, tables = spc.assemble_song(_listing(GOOD).replace("@notrack $FFFF\n", f"@notrack $FFFF\n@samples 5 62\n@echo $04 $C0\n{drums}\n"),
                                     counts, durations)
    assert tables["samples"] == [5, 62] and tables["echo"] == b"\x04\xc0" and tables["drums"][9:12] == b"\x23\x4c\x40"
    assert spc.table_rows(tables)[0] == (spc.SAMPLES_PC, 32, b"\x05\x00\x3e\x00" + bytes(28))
    with pytest.raises(ValueError, match="reach"):
        spc.assemble(_listing("L_a:\n" + "    rest 48\n" * 9984 + "L_b:\n    end"), counts, durations)
