"""The playable characters' records and level-up rule (tools/ct_characters.py).

ROM-free: the field table covers each record byte once, the codec round-trips
synthetic records, the rule's edge cases (8-bit sum, caps, the experience
cap, a row that does not reach the level) and the Swift vectors file.

Local (ROM, ChronoRET): every code, data and source claim of `check`, the
ROM's own AddExp + LevelUpStep run in ChronoRET's 65816 interpreter against
`level_up` (the 7 records to level 99; the synthetic vectors with their rows
patched into a copy), and the characters manifest update.
"""

import json
import os
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_characters as cc  # noqa: E402
import ct_schemas as cs  # noqa: E402


def synthetic_value(**over):
    value = {"char_id": 2, "hp": 100, "max_hp": 120, "mp": 9, "max_mp": 10, "level": 5, "exp": 300,
             "exp_to_next": 40, "tech_points": 7, "tech_points_to_next": 3,
             "stats": dict(zip(cc.STATS, (10, 11, 12, 13, 14, 15, 16))),
             "growth_base": dict(zip(cc.STATS, (5, 6, 0, 7, 8, 9, 4))),
             "equipment": {"helmet": 0x7C, "armor": 0x5B, "weapon": 0x01, "accessory": 0x95}}
    value.update(over)
    return value


def synthetic_growth(**over):
    growth = {"hp": [[10, 12], [40, 20], [99, 30], [0, 0]], "mp": [[20, 1], [99, 2], [0, 0], [0, 0]],
              "stats": dict(zip(cc.STATS, (150, 120, 0, 90, 60, 45, 30)))}
    growth.update(over)
    return growth


TABLE = [0] + [10 * level for level in range(1, 99)] + [0]


# --- ROM-free ---------------------------------------------------------------------------

def test_fields_cover_each_record_byte_once():
    owner = [None] * cc.RECORD_SIZE
    for offset, size, name, status, evidence in cc.FIELDS:
        assert status in cs.STATUSES and evidence
        for b in range(offset, offset + size):
            assert owner[b] is None, f"+${b:02X} in {owner[b]} and {name}"
            owner[b] = name
    assert None not in owner
    statuses = {name: status for _, _, name, status, _ in cc.FIELDS}
    for name in cc.WRITABLE:
        assert statuses[name] in ("verified", "partial"), name
    assert "char_id" not in cc.WRITABLE and "derived" not in cc.WRITABLE
    assert all(statuses[s] == "verified" for s in cc.STATS + ("level", "exp", "exp_to_next", "max_hp", "max_mp"))


def test_codec_round_trips_and_keeps_other_bytes():
    rng = cc.Lcg(7)
    base = bytes(rng.next(256) for _ in range(cc.RECORD_SIZE))
    value = synthetic_value()
    raw = cc.encode_record(base, value)
    decoded = cc.decode_record(raw)
    decoded["char_id"] = value["char_id"]
    assert decoded == value
    written = {b for name in cc.WRITABLE for o, s in [cc.field(name)] for b in range(o, o + s)}
    assert all(raw[b] == base[b] for b in range(cc.RECORD_SIZE) if b not in written)
    assert cc.encode_record(raw, cc.decode_record(raw)) == raw


def test_growth_order_maps_growth_bytes_to_record_stats():
    raw = bytearray(cc.RECORD_SIZE)
    raw[0x2F:0x36] = bytes(range(1, 8))
    base = cc.decode_record(bytes(raw))["growth_base"]
    # byte k belongs to stat GROWTH_ORDER[k]: power, stamina, speed, hit, evade, magic, magic defense
    assert base == {"power": 1, "stamina": 2, "speed": 3, "hit": 4, "evade": 5, "magic": 6, "magic_defense": 7}
    hp, mp, st = cc.encode_growth(synthetic_growth())
    assert list(st) == [150, 120, 0, 60, 45, 90, 30]
    assert len(hp) == len(mp) == cc.GROWTH_ROW


def test_level_up_rule():
    v = cc.level_up(synthetic_value(), synthetic_growth(), TABLE)
    assert (v["level"], v["exp"], v["exp_to_next"]) == (6, 340, 60)
    assert (v["max_hp"], v["max_mp"]) == (132, 11)            # first pairs with top >= 6
    # stat = base + growth x (level - 1) / 100; speed is kept
    assert v["stats"] == {"power": 5 + 7, "stamina": 6 + 6, "speed": 12, "magic": 7 + 4, "hit": 8 + 3,
                          "evade": 9 + 2, "magic_defense": 4 + 1}
    assert v["hp"] == 100 and v["equipment"] == synthetic_value()["equipment"]


def test_level_up_caps_and_wraps():
    growth = synthetic_growth(stats=dict(zip(cc.STATS, (255, 0, 0, 0, 0, 0, 0))), hp=[[99, 255]] * 4,
                              mp=[[99, 50]] * 4)
    start = synthetic_value(level=70, growth_base=dict(zip(cc.STATS, (99, 0, 0, 0, 0, 0, 0))),
                            stats=dict(zip(cc.STATS, (1, 1, 77, 1, 1, 1, 1))), max_hp=990, max_mp=90)
    v = cc.level_up(start, growth, TABLE)
    assert v["stats"]["power"] == (99 + 255 * 70 // 100) & 0xFF    # the 8-bit sum wraps to 21
    assert v["stats"]["speed"] == 50                               # speed is capped at 50, not recomputed
    assert (v["max_hp"], v["max_mp"]) == (999, 99)
    capped = cc.level_up(synthetic_value(level=98, exp=0x98967F - 5, exp_to_next=100), synthetic_growth(), TABLE)
    assert (capped["level"], capped["exp"], capped["exp_to_next"]) == (99, 0x98967F, 0)
    assert cc.add_exp(0x97FFFF, 1) == 0x980000
    # Quirk as coded: the low word wraps on the carry and is then below $9680,
    # so a large amount at the cap leaves 9,999,998.
    assert cc.add_exp(0x98967F, 0xFFFF) == 0x98967E


def test_rows_must_reach_the_level():
    with pytest.raises(ValueError):
        cc.level_up(synthetic_value(level=50), synthetic_growth(hp=[[10, 1], [20, 1], [30, 1], [40, 1]]), TABLE)
    with pytest.raises(AssertionError):
        cc.level_up(synthetic_value(level=99), synthetic_growth(), TABLE)
    curve = cc.level_curve(synthetic_value(level=97), synthetic_growth(), TABLE)
    assert [v["level"] for v in curve] == [97, 98, 99] and curve[-1]["exp_to_next"] == 0


def test_swift_vectors_file_is_current():
    path = cc.VECTORS
    assert path.exists(), "regenerate with ct_characters.py vectors --out"
    assert path.read_text() == cc.vectors_text()
    vectors = json.loads(path.read_text())
    assert len(vectors["cases"]) == 24 and vectors["columns"] == list(cc.CURVE_COLUMNS)
    for case in vectors["cases"]:
        assert case["curve"][-1][0] == cc.LEVEL_MAX


def test_manifest_update_on_a_hand_written_manifest():
    manifest = {"record_types": [
        {"name": "CharRec", "addr": "$CC:0000", "fields": []},
        {"name": "StatGrowth", "addr": "$CC:25FA", "fields": []},
        {"name": "ExpToLevel", "addr": "$CC:2632", "fields": []}]}
    m = cs.characters_manifest_update(manifest)
    names = [rt["name"] for rt in m["record_types"]]
    assert names == ["CharRec", "HpGrowth", "MpGrowth", "StatGrowth", "ExpToLevel"]
    char = m["record_types"][0]
    assert sum(f["size"] for f in char["fields"]) == cc.RECORD_SIZE
    assert all(f["offset"].startswith("+$") for f in char["fields"])
    stats = cs.field_stats(m)
    assert stats["verified"] > 0 and stats["undecoded"] == 2
    assert cs.characters_manifest_update(m) == m


# --- Local ROM and ChronoRET ----------------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return cc.read_rom(rom_path)


def failures(claims):
    return [f"{name}: {detail}" for name, ok, detail in claims if not ok]


def test_code_claims(rom):
    claims = cc.code_claims(rom)
    assert len(claims) >= 20 and failures(claims) == []


def test_data_claims(rom):
    claims = cc.data_claims(rom)
    assert len(claims) >= 7 * 10 and failures(claims) == []


def test_records_decode_as_documented(rom):
    decoded = cc.decode_all(rom)
    assert [c["char_id"] for c in decoded["characters"]] == list(range(cc.CHARACTERS))
    for c, value in enumerate(decoded["characters"]):
        assert cc.encode_record(cc.record(rom, c), value) == cc.record(rom, c)
        hp, mp, st = cc.encode_growth(value["growth"])
        at = cc.STAT_GROWTH_PC + cc.STAT_GROWTH_ROW * c
        assert st == rom[at:at + cc.STAT_GROWTH_ROW]
    # the first level-up puts these back on the curve (kept as found)
    assert {c: sorted(cc.off_curve(v, v["growth"])) for c, v in enumerate(decoded["characters"])} == {
        0: [], 1: ["evade"], 2: ["evade", "magic", "magic_defense"], 3: ["evade", "hit"], 4: [], 5: [], 6: ["hit"]}


def test_chronoret_source_claims(rom, chronoret):
    claims = cc.asm_claims(chronoret)
    assert len(claims) == len(cc.ASM_CLAIMS) and failures(claims) == []


def test_rom_routine_runs_as_the_rule_to_level_99(rom, chronoret):
    claims = cc.run_claims(rom, ref=chronoret)
    assert len(claims) == cc.CHARACTERS and failures(claims) == []


def test_rom_routine_with_synthetic_rows_matches_the_vectors(rom, chronoret):
    claims = cc.synthetic_run_claims(rom, ref=chronoret)
    assert len(claims) == 24 and failures(claims) == []


def test_rom_routine_detects_a_changed_rule(rom, chronoret):
    """A rule without the 8-bit sum disagrees with the ROM on the wrap case."""
    vectors = cc.synthetic_cases()
    case = vectors["cases"][1]
    raw = bytearray.fromhex(case["record"])
    raw[0] = 1
    runner = cc.RomLevelUp(cc.patched_image(rom, 1, case["growth"], vectors["expToLevel"]), chronoret)
    row = next(r for r in case["curve"] if r[0] == 80)
    value = cc.with_row(cc.decode_record(bytes(raw)), row)
    stepped = cc.decode_record(runner.step(cc.encode_record(raw, value)))
    no_wrap = min(value["growth_base"]["power"] + case["growth"]["stats"]["power"] * 80 // 100, cc.STAT_CAP)
    assert stepped["stats"]["power"] != no_wrap
    assert stepped["stats"] == cc.level_up(value, case["growth"], vectors["expToLevel"])["stats"]


def test_rom_routine_has_the_exp_cap_quirk(rom, chronoret):
    """AddExp tests only the low word against $9680 after a carry."""
    value = synthetic_value(level=50, exp=0x98967F, exp_to_next=0xFFFF)
    raw = cc.encode_record(cc.record(rom, 0), value)
    stepped = cc.decode_record(cc.RomLevelUp(rom, chronoret).step(raw))
    assert stepped["exp"] == 0x98967E == cc.level_up(value, cc.decode_growth(rom, 0), cc.exp_to_level(rom))["exp"]


def test_characters_manifest_update_verifies(manifest_path, rom_path):
    with open(manifest_path("characters_schema.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    updated = cs.characters_manifest_update(manifest)
    assert cs.verify_manifest(updated, "characters (updated)") == []
    char = next(rt for rt in updated["record_types"] if rt["name"] == "CharRec")
    assert [f["name"] for f in char["fields"]][:4] == ["char_id", "unk01", "flags02", "hp"]
    before, after = cs.field_stats(manifest), cs.field_stats(updated)
    # <=: once the update is applied to the manifest, it changes nothing.
    assert after["verified"] >= 30 and after["undecoded"] <= before["undecoded"]
    assert cs.characters_manifest_update(updated) == updated
