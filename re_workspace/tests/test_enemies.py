"""Enemies: stat records, rewards, names and AI scripts (tools/ct_enemies.py).

ROM-free: the field table covers each stat byte once, the codecs round-trip
synthetic records, the AI script parser and assembler agree on synthetic
scripts and refuse malformed ones, and the Swift vectors file is current.

Local (ROM, ChronoRET): every code, data, table and source claim of
`check`, and the ROM's own loader BattleFD_UnkB438 and reward routine
BattleFD_AddEnemyRewards run in ChronoRET's 65816 interpreter for every id.
"""

import os
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_enemies as ce  # noqa: E402

LENGTHS = ce.SYNTHETIC_LENGTHS


def test_fields_cover_each_stat_byte_once():
    covered = []
    for offset, size, name, status, dest, evidence in ce.FIELDS:
        assert status in ("verified", "decoded", "partial", "undecoded"), name
        assert evidence and 0x2D <= dest + 0x2D <= 0x80 + 0x2D
        covered += range(offset, offset + size)
    assert covered == list(range(ce.STATS_SIZE))
    rewards = []
    for offset, size, *_ in ce.REWARD_FIELDS:
        rewards += range(offset, offset + size)
    assert rewards == list(range(ce.REWARDS_SIZE))


def test_stat_and_reward_codecs_round_trip():
    raw = bytes(range(3, 3 + ce.STATS_SIZE))
    v = ce.decode_stats(raw)
    assert v["hp"] == 3 | 4 << 8 and v["level"] == 5 and v["attack_id"] == raw[0x16]
    assert v["affinity"] == dict(zip(ce.ELEMENTS, raw[0x10:0x14]))
    assert ce.encode_stats(v) == raw
    reward = bytes([0x34, 0x12, 0x78, 0x56, 0x9A, 0xBC, 0xDE])
    r = ce.decode_reward(reward)
    assert r == {"exp": 0x1234, "gold": 0x5678, "drop": 0x9A, "charm": 0xBC, "tech_points": 0xDE}
    assert ce.encode_reward(r) == reward


def test_expected_block_places_the_record_as_the_loader():
    raw = bytes(range(1, 1 + ce.STATS_SIZE))
    block = ce.expected_block(raw, 7)
    assert block[0] == 7 and block[3:5] == block[5:7] == raw[0:2] and block[0x12] == raw[2]
    assert block[0x22:0x27] == raw[3:8] and (block[0x20], block[0x21]) == (raw[6], raw[7])
    assert block[0x37:0x43] == raw[8:0x14] and block[0x19:0x1C] == raw[0x14:0x17]
    assert block[0x1D] == block[0x1E] == block[0x1F] == 0 and len(block) == 0x80


def test_affinity_text():
    assert ce.affinity_text(4) == "x4/4"
    assert ce.affinity_text(0x84) == "absorb x4/4"
    assert ce.affinity_text(0x48) == "x4/6"
    assert ce.affinity_text(0) == "none (0 damage)"


def test_names_round_trip_with_blanks():
    glyphs = {0xA0: "A", 0xA1: "B", ce.NAME_BLANK: " ", 0xFF: "_"}
    raw = bytes([0xA0, ce.NAME_BLANK, 0xA1] + [ce.NAME_BLANK] * 8)
    assert ce.decode_name(raw, glyphs) == "A B"
    assert ce.encode_name("A B", glyphs) == raw
    with pytest.raises(ValueError):
        ce.encode_name("ABABABABABAB", glyphs)
    with pytest.raises(ValueError):
        ce.encode_name("C", glyphs)


def test_ai_vectors_round_trip_and_reject():
    v = ce.synthetic_cases()
    assert len(v["cases"]) == 40
    for case in v["cases"]:
        data = bytes.fromhex(case["bytes"])
        assert ce.ai_text(data, 0, LENGTHS) == case["text"]
        assert ce.ai_assemble(case["text"], LENGTHS) == data
    for text in v["rejected"]:
        with pytest.raises(ce.ScriptError):
            ce.ai_assemble(text, LENGTHS)


def test_parser_refuses_what_the_game_would_cut():
    # an action whose argument is $FE: the game's byte scan would end the block there
    with pytest.raises(ce.ScriptError):
        ce.parse_script(bytes([0, 0, 0, 0, 0xFE, 0x09, 0xFE, 0xFE, 0xFF, 0xFF]), 0, LENGTHS)
    # a test part of three bytes
    with pytest.raises(ce.ScriptError):
        ce.parse_script(bytes([0, 0, 0, 0xFE, 0xFE, 0xFF, 0xFF]), 0, LENGTHS)
    parts, end = ce.parse_script(bytes([0, 0, 0, 0, 0xFE, 0x04, 0x09, 0x00, 0xFE, 0xFF, 0xFF]), 0, LENGTHS)
    assert end == 11 and parts[0][0][1] == [bytes([4]), bytes([9, 0])] and parts[1] == []


def test_the_assembler_ignores_comments_and_checks_names():
    text = ("main\n  block\n    test $17 Chance percent=$32 b2=$00 b3=$00  ; half the time\n"
            "    act $09 Leave action=$05\nreaction\nend\n")
    assert ce.ai_assemble(text, LENGTHS) == bytes([0x17, 0x32, 0, 0, 0xFE, 0x09, 0x05, 0xFE, 0xFF, 0xFF])
    bare = "main\n block\n  test $17 $32 $00 $00\n  act $09 $05\nreaction\n"
    assert ce.ai_assemble(bare, LENGTHS) == bytes([0x17, 0x32, 0, 0, 0xFE, 0x09, 0x05, 0xFE, 0xFF, 0xFF])


def test_swift_vectors_file_is_current():
    path = ce.VECTORS
    assert path.exists(), "run ct_enemies.py vectors --out " + str(path)
    assert path.read_text() == ce.vectors_text()


# --- local: the ROM and ChronoRET ----------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return ce.read_rom(rom_path)


def _assert_all(claims):
    failed = [(name, detail) for name, ok, detail in claims if not ok]
    assert not failed, failed


def test_code_claims(rom):
    _assert_all(ce.code_claims(rom))


def test_data_claims(rom, chronoret):
    _assert_all(ce.data_claims(rom, ce._glyphs(chronoret)))


def test_dispatch_tables_and_headers(rom, chronoret):
    _assert_all(ce.table_claims(rom, chronoret))


def test_chronoret_source_claims(rom, chronoret):
    _assert_all(ce.asm_claims(chronoret))


def test_rom_loader_and_rewards_run_as_decoded(rom, chronoret):
    _assert_all(ce.run_claims(rom, chronoret))


def test_rom_loader_detects_a_changed_record(rom, chronoret):
    image = bytearray(rom)
    at = ce.STATS_PC + ce.STATS_SIZE * 5
    image[at + 0x0A] ^= 0x01                     # magic
    block = ce.RomEnemy(bytes(image), chronoret).load(5, 2)
    assert block == ce.expected_block(bytes(image[at:at + ce.STATS_SIZE]), 5)
    assert block != ce.expected_block(ce.stats_record(rom, 5), 5)


def test_every_enemy_decodes(rom, chronoret):
    out = ce.decode_all(rom, ce._glyphs(chronoret))
    assert len(out["enemies"]) == 256 and len(out["attacks"]) == 23 and len(out["techs"]) == 256
    named = [e for e in out["enemies"] if e["name"]]
    assert len(named) >= 200
    scripts = [e for e in out["enemies"] if "text" in e["ai"]]
    assert len(scripts) == 255
