"""The tech system's tables and tech-point rule (tools/ct_techs.py).

ROM-free: the rule's edge cases on synthetic tables (the double payment, the
total's cap, the unlock, a full character, the combination masks), the
codec's writable bytes, the Swift vectors file, the manifest proposal on a
hand-written manifest and the ROM checker's tech zones.

Local (ROM, ChronoRET): every code, data and source claim of `check`, the
ROM's own AwardTechPoints run in ChronoRET's 65816 interpreter against
`award_tech_points` (the ROM's starting state in several parties; the
synthetic vectors with their tables patched into a copy), a rule without the
quirk caught by the ROM, and the manifest proposal.
"""

import json
import os
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_schemas as cs  # noqa: E402
import ct_techs as ct  # noqa: E402


def synthetic_tables(**over):
    tp = [100] * (ct.CHARACTERS * 8) + [ct.SYNTHETIC_TP_AFTER]
    tp[0], tp[1] = 5, 90
    t = {"char_techs": [tuple(x) for x in ct.SYNTHETIC_CHAR_TECHS], "tp": tp,
         "needs_unlock": [False] * ct.TECHS,
         "combos": [{"mask": 0xC0, "first": 0x39, "requirements": [[1, 1, 255], [2, 1, 255], [3, 3, 255]]},
                    {"mask": 0xE0, "first": 0x66, "requirements": [[1, 1, 1]]}]}
    t.update(over)
    return t


def synthetic_state(**over):
    s = {"counts": [0, 1, 0, 0, 0, 0, 0], "bits1": [0, 0x80, 0, 0, 0, 0, 0], "combo_bits": [0] * ct.COMBO_BYTES,
         "unlock": 0, "slots": [{"char": 0, "flags": 0x80, "tp": 0, "to_next": 5},
                                {"char": 1, "flags": 0, "tp": 0, "to_next": 1000}, None]}
    s.update(over)
    return s


# --- ROM-free ---------------------------------------------------------------------------

def test_award_pays_the_award_again_after_a_cost_above_the_leftover():
    s = ct.award_tech_points(synthetic_tables(), synthetic_state(), 7)
    crono = s["slots"][0]
    # 5 paid, 2 left; the next need is 90 - 2, and the loop then pays the award (7) again.
    assert s["counts"][0] == 1 and s["bits1"][0] == 0x80
    assert crono["to_next"] == 90 - 2 - 7 and crono["tp"] == 7
    assert s["slots"][1]["to_next"] == 1000 - 7
    assert s["combo_bits"][0] == 0x80                  # both have 1 single: the first double


def test_award_with_a_leftover_above_the_next_cost_pays_on():
    t = synthetic_tables(tp=[5, 3, 2] + [400] * 53 + [ct.SYNTHETIC_TP_AFTER])
    s = ct.award_tech_points(t, synthetic_state(), 20)
    # 20 pays 5 (15 left), 3 (12 left), 2 (10 left): each cost below the leftover stores the
    # leftover as the amount; then 400 - 10 = 390, less that stored amount (12) again.
    assert s["counts"][0] == 3 and s["bits1"][0] == 0xE0
    assert s["slots"][0]["to_next"] == 400 - 10 - 12


def test_cap_unlock_and_full_characters():
    t = synthetic_tables()
    capped = synthetic_state()
    capped["slots"][0]["tp"] = 0x989600
    assert ct.award_tech_points(t, capped, 0x100)["slots"][0]["tp"] == 0x98967F
    # Quirk as coded: a high byte past $98 with a low word below $967F is not capped.
    over = synthetic_state()
    over["slots"][0]["tp"] = 0x98967F
    assert ct.award_tech_points(t, over, 0x6981)["slots"][0]["tp"] == 0x990000
    full = synthetic_state()
    full["slots"][0]["flags"] |= ct.ALL_TECHS
    assert ct.award_tech_points(t, full, 50)["slots"][0] == full["slots"][0]
    locked = synthetic_tables(needs_unlock=[t == 2 for t in range(ct.TECHS)])
    s = synthetic_state(counts=[1, 1, 0, 0, 0, 0, 0], bits1=[0x80, 0x80, 0, 0, 0, 0, 0])
    s["slots"][0]["to_next"] = 0
    assert ct.award_tech_points(locked, s, 500)["counts"][0] == 1
    s["unlock"] = 1
    assert ct.award_tech_points(locked, s, 500)["counts"][0] > 1


def test_eighth_single_sets_the_flag_and_reads_the_word_after_the_rows():
    t = synthetic_tables(tp=[0] * 56 + [ct.SYNTHETIC_TP_AFTER])
    s = synthetic_state(counts=[0, 0, 0, 0, 0, 0, 7], bits1=[0, 0, 0, 0, 0, 0, 0xFE])
    s["slots"] = [{"char": 6, "flags": 0, "tp": 0, "to_next": 0}, None, None]
    out = ct.award_tech_points(t, s, 1)
    assert out["counts"][6] == 8 and out["bits1"][6] == 0xFF and out["slots"][0]["flags"] & ct.ALL_TECHS
    # the cost after the 8th is the word after the rows (CharTechs[0]); TryNextTech then pays once more
    assert out["slots"][0]["to_next"] == ct.SYNTHETIC_TP_AFTER - 1 - 1


def test_combo_masks_and_triples():
    assert ct.combo_masks([0, None, 2]) == [0x20, 0x80, 0xA0, 0xA0]
    assert ct.combo_masks([2, 1, 0]) == [0x60, 0xA0, 0xC0, 0xE0]
    t = synthetic_tables()
    s = synthetic_state(counts=[1, 1, 1, 0, 0, 0, 0], bits1=[0x80, 0x80, 0x80, 0, 0, 0, 0])
    s["slots"] = [{"char": c, "flags": 0, "tp": 0, "to_next": 999} for c in (2, 0, 1)]
    out = ct.award_tech_points(t, s, 1)
    assert out["combo_bits"][0] == 0x80 and out["combo_bits"][1] == 0x80
    t["needs_unlock"][0x66] = True
    assert ct.award_tech_points(t, s, 1)["combo_bits"][1] == 0


def test_codec_writes_only_the_writable_bytes():
    rng = ct.Lcg(5)
    rom = bytearray(rng.next(256) for _ in range(ct.pc(0xCD, 0x5000)))
    for t in (0, 9, 0x74):
        value = ct.decode_tech(rom, t)
        writes = ct.encode_tech(rom, t, value)
        assert all(rom[at] == b for at, b in writes.items())
        rec = ct.TECH_REC_PC + ct.TECH_REC_SIZE * t
        assert set(writes) >= {rec, rec + 3} and rec + 1 not in writes and rec + 4 not in writes


def test_swift_vectors_file_is_current():
    path = ct.VECTORS
    assert path.exists(), "regenerate with ct_techs.py vectors --out"
    assert path.read_text() == ct.vectors_text()
    vectors = json.loads(path.read_text())
    assert vectors["schema"] == "ct-tech-point-vectors/1" and len(vectors["cases"]) == 12
    learned = sum(sum(c["steps"][-1]["state"]["counts"]) - sum(c["state"]["counts"]) for c in vectors["cases"])
    assert learned > 50


def test_manifest_update_on_a_hand_written_manifest():
    manifest = {"record_types": [{"name": "ItemNames", "addr": "$CC:0B5E", "fields": []},
                                 {"name": "TechRec", "addr": "$CC:1BEB", "fields": []},
                                 {"name": "Other", "addr": "$C0:0000", "fields": []}]}
    m = cs.techs_manifest_update(manifest)
    names = [rt["name"] for rt in m["record_types"]]
    assert names[0] == "ItemNames" and names[-1] == "Other" and "TechTpCost" in names and "TechState" in names
    rec = next(rt for rt in m["record_types"] if rt["name"] == "TechRec")
    assert sum(f["size"] for f in rec["fields"]) == ct.TECH_REC_SIZE
    state = next(rt for rt in m["record_types"] if rt["name"] == "TechState")
    assert sum(f["size"] for f in state["fields"]) == ct.TECH_STATE_SIZE
    assert all(f["status"] in cs.STATUSES for rt in m["record_types"] for f in rt["fields"])
    assert cs.techs_manifest_update(m) == m


def test_write_zones_cover_every_builder_write_once():
    """The checker's zones (ct_rom_check) are the spans CTTechROM.writes names (docs/techs.md)."""
    rom = bytearray(ct.ROM_SIZE)
    req = 0x27FA
    for i in range(25):
        at = ct.COMBOS_PC + ct.COMBO_SIZE * i
        count = 3 if i < 15 else 1
        rom[at:at + 5] = bytes([0xC0, 0x39 + i, count, req & 0xFF, req >> 8])
        req += 3 * count
    rom[ct.COMBOS_PC + 125] = ct.NONE
    zones = ct.write_zones(bytes(rom))
    size = sum(len(z) for z in zones)
    assert size == ct.TECHS * (2 + 1 + 1 + 6 + 2) + ct.PARTS * 13 + 112 + 3 * (15 * 3 + 10) + ct.TECH_STATE_SIZE + 7
    covered = set().union(*zones)
    assert len(covered) == size                         # no overlap


# --- Local ROM and ChronoRET ----------------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return ct.read_rom(rom_path)


def failures(claims):
    return [f"{name}: {detail}" for name, ok, detail in claims if not ok]


def test_code_claims(rom):
    claims = ct.code_claims(rom)
    assert len(claims) >= 10 and failures(claims) == []


def test_data_claims(rom, chronoret):
    claims = ct.data_claims(rom)
    assert len(claims) >= 40 and failures(claims) == []


def test_chronoret_source_claims(rom, chronoret):
    claims = ct.asm_claims(chronoret)
    assert len(claims) == len(ct.ASM_CLAIMS) and failures(claims) == []


def test_tables_decode_and_reencode(rom):
    decoded = ct.decode_all(rom)
    assert len(decoded["techs"]) == ct.TECHS and len(decoded["combos"]) == 25
    for t in range(ct.TECHS):
        assert all(rom[at] == b for at, b in ct.encode_tech(rom, t, decoded["techs"][t]).items())
    # every single belongs to its character, every combination tech to its record's members
    for c in range(ct.CHARACTERS):
        assert {decoded["techs"][1 + 8 * c + k]["user_set"] for k in range(8)} == {c}


def test_rom_routine_runs_as_the_rule(rom, chronoret):
    claims = ct.run_claims(rom, ref=chronoret)
    assert len(claims) == 2 * len(ct.RUN_PARTIES) and failures(claims) == []


def test_rom_routine_with_synthetic_tables_matches_the_vectors(rom, chronoret):
    claims = ct.synthetic_run_claims(rom, ref=chronoret)
    assert len(claims) == 12 and failures(claims) == []


def test_rom_routine_detects_a_rule_without_the_quirk(rom, chronoret):
    """Paying the leftover only once disagrees with the ROM."""
    t = ct.tables(rom)
    s = ct.starting_state(rom, (0, 1, 2))
    got = ct.RomTechPoints(rom, chronoret).award(s, 7)
    assert got == ct.award_tech_points(t, s, 7)
    first = t["tp"][1]
    leftover = 7 - s["slots"][0]["to_next"]
    assert got["slots"][0]["to_next"] == first - leftover - 7 != first - leftover


def test_techs_manifest_update_verifies(manifest_path, rom_path):
    with open(manifest_path("items_and_techs_schema.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    updated = cs.techs_manifest_update(manifest)
    assert cs.verify_manifest(updated, "items and techs (updated)") == []
    before, after = cs.field_stats(manifest), cs.field_stats(updated)
    assert after["verified"] >= 10 and after["verified"] > before["verified"]
