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


def test_description_zero_operands_and_bounded_termination():
    rom = bytearray(cc.DESC_BODY_END)
    at = cc.DESC_BODY_PC
    rom[cc.DESC_TABLE_PC:cc.DESC_TABLE_PC + 2] = (at & 0xFFFF).to_bytes(2, "little")
    # A, {tech}, B, two wide glyphs, {wait 00}, C, END: each control has one operand.
    text = bytes([0xA0, 0x12, 0, 0xA1, 1, 0, 2, 0, 3, 0, 0xA2])
    rom[at:at + len(text) + 1] = text + b"\0"
    assert cc.description_bytes(rom)[0] == text
    for tail in (b"\x12", b"\x12\x00", b"\xA0"):
        at = cc.DESC_BODY_END - len(tail)
        rom[cc.DESC_TABLE_PC:cc.DESC_TABLE_PC + 2] = (at & 0xFFFF).to_bytes(2, "little")
        rom[at:cc.DESC_BODY_END] = tail
        assert cc.description_bytes(rom)[0] is None


def test_checker_accepts_empty_names_but_rejects_internal_padding():
    clean = bytearray(0x400000)
    clean[ct.COMBOS_PC] = 0xFF  # Synthetic empty combination table.
    at = ct.TECH_NAMES_PC + ct.NAME_SIZE
    clean[at:at + ct.NAME_SIZE] = bytes([0xA0] + [cc.NAME_PAD] * 10)
    report = {"techs": {"combos": [], "userSets": ct.user_sets(clean)}}
    for icon in (None, 0x2F):
        base = bytearray(clean)
        if icon is not None:
            base[at:at + ct.NAME_SIZE] = bytes([icon, 0xA0] + [cc.NAME_PAD] * 9)
        built = bytearray(base)
        built[at:at + ct.NAME_SIZE] = bytes(([icon] if icon is not None else []) +
                                           [cc.NAME_PAD] * (ct.NAME_SIZE - (icon is not None)))
        assert cc.build_problems(base, built, report) == []
        built[at + 3] = 0xA1  # A glyph after padding remains invalid.
        assert any("name is not glyphs then $EF padding" in p for p in cc.build_problems(base, built, report))


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
