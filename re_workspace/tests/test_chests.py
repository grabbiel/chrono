"""Chests and new locations (tools/ct_chests.py, tools/ct_rom_check.py).

ROM-free: the flag numbers are the records' places counted from word 0 on a
synthetic TreasureRom; ct_rom_check.py reads the lists the offset words split
and the renumbered count the report states; expect_open's rules.

Local (ROM, ChronoRET, the layout manifest): every claim of `ct_chests.py
check` holds (the readers and writers of Treasure_Flags, the 512 flags, no
event naming one); the locations the game never loads are 448, 452-455 and
461-463; Field_CheckTileInFront run on a chest sets its flag and gives its
item; the checker fails a ROM whose treasure list changed without a report.
"""

import hashlib
import json
import os
import subprocess
import sys

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_chests as cch  # noqa: E402
import ct_maps as cm  # noqa: E402
import ct_tilesets as ts  # noqa: E402


def synthetic_treasure(lists, start=0xF402):
    """A zero ROM image whose TreasureRom holds `lists` ({location: [(tile, contents)]}) from `start`."""
    image = bytearray(ts.ROM_SIZE)
    at, words, body = start, [], bytearray()
    for i in range(cm.LOC_COUNT):
        words.append(at)
        for tile, contents in lists.get(i, []):
            body += bytes([tile & 0xFF, tile >> 8, contents & 0xFF, contents >> 8])
            at += cm.TREASURE_BYTES
    words.append(at)
    w = ts.pc(cm.TREASURE_OFS)
    for k, v in enumerate(words):
        image[w + 2 * k:w + 2 * k + 2] = bytes([v & 0xFF, v >> 8])
    r = ts.pc(cm.TREASURE_BANK + start)
    image[r:r + len(body)] = body
    return bytes(image)


def test_flag_numbers_are_record_places_from_word_0():
    lists = {0: [(0x2F2F, 0)], 3: [(0x0201, 5), (0x0302, 0x8010)], 4: [(0, 3)], 7: [(0x0404, 0x4000)]}
    rom = synthetic_treasure(lists)
    n = cch.treasure_numbers(rom)
    assert n[0] == [0] and n[3] == [1, 2] and n[4] == [3] and n[7] == [4]
    assert all(not n[i] for i in range(cm.LOC_COUNT) if i not in lists)
    moved = synthetic_treasure(lists, start=0xD423)               # a block moved: numbers follow word 0
    assert cch.treasure_numbers(moved) == n


def test_checker_reads_the_lists_the_words_split():
    import ct_rom_check as rc
    lists = {0: [(0x2F2F, 0)], 3: [(0x0201, 5), (0x0302, 0x8010)]}
    got = rc.treasure_lists(synthetic_treasure(lists))
    assert got[0] == [(0x2F2F, 0)] and got[3] == [(0x0201, 5), (0x0302, 0x8010)]
    assert sum(len(x) for x in got) == 3


def test_expect_open_rules():
    item = {"contents": 0xCA, "flag": 6, "flagsSet": [6], "kind": cch.KIND_ITEM, "items": [(0xCA, 1)], "gold": 0}
    assert cch.expect_open(item)
    assert not cch.expect_open(dict(item, flagsSet=[7]))
    gold = {"contents": 0x8064, "flag": 2, "flagsSet": [2], "kind": cch.KIND_GOLD, "items": [], "gold": 200}
    assert cch.expect_open(gold)
    assert not cch.expect_open(dict(gold, gold=100))
    taken = {"contents": 0xCA, "flag": 6, "flagsSet": [], "kind": cch.KIND_OPENED, "items": [], "gold": 0}
    assert cch.expect_open(taken, taken=True)


# --- Local ROM, ChronoRET and the layout manifest ---------------------------------------

def test_flag_claims_hold(rom_path, chronoret, manifest_path):
    manifest_path("rom_layout.json")
    result = subprocess.run([sys.executable, os.path.join(TOOLS, "ct_chests.py"), "check", "--rom", str(rom_path)],
                            capture_output=True, text=True, timeout=600)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "FAIL" not in result.stdout


def test_the_locations_the_game_never_loads(rom_path, chronoret, manifest_path):
    manifest_path("rom_layout.json")
    unused, proof = cch.unused_locations(cm.read_rom(rom_path))
    assert unused == [448, 452, 453, 454, 455, 461, 462, 463]
    assert all(proof[i]["events"] is not None for i in unused)


def test_opening_a_chest_sets_its_flag(rom_path, chronoret):
    rom = cm.read_rom(rom_path)
    runner = cm.MapRunner(rom, chronoret)
    r = cch.open_chest(runner, rom, 26, 0)
    assert cch.expect_open(r) and r["flagsSet"] == [cch.treasure_numbers(rom)[26][0]]
    assert cch.expect_open(cch.open_chest(runner, rom, 26, 0, taken=True), taken=True)


def test_checker_fails_an_unreported_treasure_list(tmp_path, rom_path, chronoret, manifest_path):
    manifest_path("rom_layout.json")
    import ct_rom_layout as layout
    rom = cm.read_rom(rom_path)
    data = bytearray(rom)
    _, records = cm.treasure_list(rom, 26)
    at = ts.pc(cm.TREASURE_BANK + records[0][0])
    data[at] ^= 1                                                 # chest 0 of location 26 one column over
    total = layout.checksum(data)
    data[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
    sha = hashlib.sha256(bytes(data)).hexdigest()
    report = {"schema": "ct-rom-build/1", "baseSHA256": hashlib.sha256(rom).hexdigest(), "outputSHA256": sha,
              "checksum": total, "packs": [], "messageTables": [], "songs": [], "freeBytesLeft": 0, "maps": [],
              "tilesets": [], "writes": [{"pc": at, "length": 1, "what": "stray"}]}
    (tmp_path / "b.sfc").write_bytes(bytes(data))
    (tmp_path / "b.json").write_text(json.dumps(report))
    result = subprocess.run([sys.executable, os.path.join(TOOLS, "ct_rom_check.py"), str(tmp_path / "b.sfc"),
                             str(tmp_path / "b.json")], capture_output=True, text=True, timeout=600)
    assert result.returncode != 0 and "FAIL" in result.stdout + result.stderr
