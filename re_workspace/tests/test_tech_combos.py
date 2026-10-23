"""ct_tech_combos.py: combinations end to end. ROM-free: the helpers and the
fixed id layout. Local: every code, data and source claim, and the routines
run in ChronoRET's interpreter over every ROM combination (battle menu, the
learn path, the field menu, the rock path)."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import ct_tech_combos as cc  # noqa: E402
import ct_techs as ct  # noqa: E402


def test_helpers_and_id_layout():
    assert cc.mask_of([0, 6]) == 0x82
    assert cc.single_of_bit(1) == (0, 0) and cc.single_of_bit(56) == (6, 7)
    assert [cc.cut(5, a) for a in (0, 0xA2, 0xA3)] == [5, 3, 2]
    assert len(cc.FIRST_IDS) == cc.MENU_BYTES
    assert cc.FIRST_IDS[7] == ct.FIRST_DOUBLE and cc.FIRST_IDS[22] == ct.FIRST_TRIPLE
    assert cc.FIRST_IDS[-1] == ct.TECHS - 1
    # 15 pair bytes x 3 + 15 triple bytes = every combination id: no free slot.
    assert 3 * cc.PAIR_RECORDS + 15 == ct.TECHS - ct.FIRST_DOUBLE
    assert cc.FIRST_ROCK + cc.ROCKS == ct.TECHS


@pytest.fixture(scope="module")
def rom(rom_path):
    return ct.read_rom(rom_path)


def failures(claims):
    return [f"{name}: {detail}" for name, ok, detail in claims if not ok]


def test_code_claims(rom):
    claims = cc.code_claims(rom)
    assert len(claims) >= 10 and failures(claims) == []


def test_data_claims(rom, chronoret):
    claims = cc.data_claims(rom)
    assert len(claims) >= 12 and failures(claims) == []


def test_chronoret_source_claims(rom, chronoret):
    assert failures(cc.asm_claims(chronoret)) == []


def test_battle_menu_runs(rom, chronoret):
    assert failures(cc.battle_menu_runs(rom)) == []


def test_learn_runs(rom, chronoret):
    assert failures(cc.learn_runs(rom)) == []


def test_field_menu_and_rock_runs(rom, chronoret):
    runner = cc.Rom65816(rom)
    assert failures(cc.field_menu_runs(rom, runner) + cc.rock_runs(rom, runner)) == []
