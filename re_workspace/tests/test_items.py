"""The item tables and the menu's equipment-stat rule (tools/ct_items.py).

ROM-free: the rule's edge cases on synthetic records and tables (the stat
caps, a boost past 255, the accessory HP bonus and its cap, the stat-5
accessory, each attack formula and its $FF ceiling), the codec's writable
bytes on a synthetic image, the write zones and the Swift vectors file.

Local (ROM, ChronoRET): every code, data and source claim of `check`; the
ROM's own Menu_BuildItemTables and Menu_RefreshAllChars run in ChronoRET's
65816 interpreter against `item_tables` and `calc_stats` (the starting
records, other equipment, the synthetic vectors with their tables patched
in), BattleFD_ItemRecOffset and BattleSys_UnkCF69; and a rule with the stat
caps dropped caught by the ROM.
"""

import os
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_items as ci  # noqa: E402


def synthetic_record(**over):
    rec = bytearray(ci.RECORD_SIZE)
    rec[3:5], rec[5:7] = (300).to_bytes(2, "little"), (400).to_bytes(2, "little")
    rec[0x0B:0x12] = bytes([10, 20, 30, 40, 50, 60, 70])
    rec[0x27], rec[0x28], rec[0x29], rec[0x2A] = 0x7C, 0x5B, 0x01, 0x95
    for k, v in over.items():
        rec[int(k[1:], 16)] = v
    return rec


def synthetic_tables():
    sort = [0] * 0x100
    sort[0x01], sort[0x5B], sort[0x7C] = 40, 15, 7
    info4 = [0] * ci.ITEMS
    info4[0x95] = 1
    st = {"boosts": [0, 0x80 << 0 | 3 << 8] + [0] * (ci.BOOSTS - 2), "order": [0, 1, 2, 3, 4, 5, 6],
          "caps": [99] * 7, "char5": list(range(ci.CHAR5_ATTACK))}
    return {"sort": sort, "info4": info4}, st


# --- ROM-free ---------------------------------------------------------------------------

def test_defence_is_stamina_plus_armour_and_helmet():
    items, st = synthetic_tables()
    derived, word3 = ci.calc_stats(synthetic_record(), items, st)
    assert derived[8] == 20 + 15 + 7
    assert word3 == 300 and derived[9:] == [400 & 0xFF, 400 >> 8]


def test_boost_adds_to_the_stat_of_its_bit_in_stat_order():
    items, st = synthetic_tables()
    derived, _ = ci.calc_stats(synthetic_record(), items, st)
    assert derived[0] == 10 + 3                       # bit 7 = order[0] = power
    st["order"] = [6, 0, 1, 2, 3, 4, 5]
    derived, _ = ci.calc_stats(synthetic_record(), items, st)
    assert derived[6] == 70 + 3 and derived[0] == 10


def test_caps_and_byte_wrap():
    items, st = synthetic_tables()
    st["caps"] = [12] * 7
    derived, _ = ci.calc_stats(synthetic_record(), items, st)
    assert derived[:7] == [12] * 7
    st["caps"] = [99] * 7
    st["boosts"][1] = 0x80 | 250 << 8               # 10 + 250 wraps to 4 before the cap
    derived, _ = ci.calc_stats(synthetic_record(), items, st)
    assert derived[0] == 4


def test_accessory_hp_bonus_lowers_current_hp_and_caps_at_999():
    items, st = synthetic_tables()
    rec = synthetic_record(o2A=ci.BOOST_HALF)
    rec[3:5] = (900).to_bytes(2, "little")
    derived, word3 = ci.calc_stats(rec, items, st)
    assert derived[9] | derived[10] << 8 == 600 and word3 == 600
    rec = synthetic_record(o2A=ci.BOOST_QUARTER)
    rec[5:7] = (900).to_bytes(2, "little")
    derived, word3 = ci.calc_stats(rec, items, st)
    assert derived[9] | derived[10] << 8 == 999 and word3 == 300


def test_stat5_accessory_doubles_evade_after_the_cap():
    items, st = synthetic_tables()
    derived, _ = ci.calc_stats(synthetic_record(o2A=ci.DOUBLE_STAT5, o10=90), items, st)
    assert derived[5] == 180


def test_attack_formulas_by_record_byte_0():
    items, st = synthetic_tables()
    derived, _ = ci.calc_stats(synthetic_record(o00=0), items, st)
    assert derived[7] == (5 * 40 + 12 * 13) // 9
    derived, _ = ci.calc_stats(synthetic_record(o00=1), items, st)
    assert derived[7] == 2 * (50 + 40) // 3
    derived, _ = ci.calc_stats(synthetic_record(o00=5, o12=0x83), items, st)
    assert derived[7] == (16 * 13 + 3) // 9           # the doubled index is 8-bit: $83 reads entry 3
    st["char5"][4] = 0xFFFF
    derived, _ = ci.calc_stats(synthetic_record(o00=5, o12=4), items, st)
    assert derived[7] == (16 * 13 + 0xFFFF & 0xFFFF) // 9
    st["char5"][4] = 9000
    derived, _ = ci.calc_stats(synthetic_record(o00=5, o12=4), items, st)
    assert derived[7] == 0xFF


def test_boost_past_the_table_is_an_error():
    items, st = synthetic_tables()
    items["info4"][0x95] = ci.BOOSTS
    with pytest.raises(ValueError):
        ci.calc_stats(synthetic_record(), items, st)


def synthetic_image():
    """A blank image with the layout tables the codec reads (no ROM data)."""
    image = bytearray(ci.ROM_SIZE)
    a = [0x06A4, 0x08C0, 0x0986, 0x0A1C, 0x0ABC]
    b = [0x0262, 0x047E, 0x04E1, 0x052C, 0x05CC]
    for c in range(5):
        image[ci.TABLES_A_PC + 2 * c:ci.TABLES_A_PC + 2 * c + 2] = a[c].to_bytes(2, "little")
        image[ci.TABLES_B_PC + 2 * c:ci.TABLES_B_PC + 2 * c + 2] = b[c].to_bytes(2, "little")
    image[ci.SIZES_A_PC:ci.SIZES_A_PC + 5] = bytes(ci.SIZES_A)
    image[ci.SIZES_B_PC:ci.SIZES_B_PC + 5] = bytes(ci.SIZES_B)
    return image


@pytest.mark.parametrize("item", [0x01, 0x5B, 0x7C, 0x95, 0xBD])
def test_encode_writes_what_decode_reads(item):
    image = synthetic_image()
    v = ci.decode_item(image, item, {})
    for k in v:
        if k not in ("id", "category", "icon", "name"):
            v[k] = (item * 7 + len(k)) & 0xFF if k != "price" else 0x1234
    for at, byte in ci.encode_item(image, v).items():
        image[at] = byte
    got = ci.decode_item(image, item, {})
    assert {k: got[k] for k in v if k not in ("icon", "name")} == {k: v[k] for k in v if k not in ("icon", "name")}


def test_write_zones_cover_every_encoded_byte():
    image = synthetic_image()
    zones = ci.write_zones(image)
    for item in range(ci.ITEMS):
        for at in ci.encode_item(image, ci.decode_item(image, item, {})):
            assert any(at in z for z in zones), hex(at)


def test_vectors_file_matches_the_generator():
    path = ci.VECTORS
    if not path.exists():
        pytest.skip("vectors file not generated")
    assert path.read_text() == ci.vectors_text()


# --- Local: ROM and ChronoRET ---------------------------------------------------------------

@pytest.fixture(scope="module")
def rom(rom_path):
    return ci.read_rom(rom_path)


def test_code_and_data_claims(rom):
    bad = [r for r in ci.code_claims(rom) + ci.data_claims(rom) if not r[1]]
    assert not bad


def test_asm_claims(chronoret):
    bad = [r for r in ci.asm_claims(chronoret) if not r[1]]
    assert not bad


def test_rom_routines_agree_with_the_model(rom, chronoret):
    bad = [r for r in ci.run_claims(rom, chronoret) if not r[1]]
    assert not bad


def test_rom_routine_agrees_with_the_synthetic_vectors(rom, chronoret):
    bad = [r for r in ci.synthetic_run_claims(rom, chronoret) if not r[1]]
    assert not bad


def test_a_rule_without_the_caps_is_caught_by_the_rom(rom, chronoret):
    runner = ci.RomItems(rom, chronoret)
    records = [ci.record(rom, c) for c in range(ci.CHARACTERS)]
    rec = bytearray(records[0])
    rec[0x0B] = 0xF0                                  # power far above every cap
    tables, after, _ = runner.build([bytes(rec)] + records[1:])
    assert ci.derived_of(after[0]) == ci.calc_stats(rec, tables, ci.stat_tables(rom))
    uncapped = dict(ci.stat_tables(rom), caps=[255] * 7)
    assert ci.derived_of(after[0]) != ci.calc_stats(rec, tables, uncapped)
