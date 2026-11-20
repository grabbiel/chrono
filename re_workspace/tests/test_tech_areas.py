"""Synthetic targeting boundaries and ROM/interpreter agreement for circle/row previews."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import ct_tech_areas as areas
import ct_techs as ct


def test_circle_byte_wrap_and_row_anchor_order():
    positions = [(0, 0), None, None, (240, 112), (0, 32), (0, 33)] + [None] * 5
    assert areas.model('circle', 0, 0x12, False, positions) == [3, 4, 5]
    assert areas.model('circle', 0, 0x11, False, positions) == [4, 5]
    assert areas.model('row', 0, 0, False, positions) == [0, 4]
    assert areas.model('row', 3, 0, True, positions) == [3]


def test_only_forwarded_circle_sizes_are_editable():
    assert ct.editable_radius([1, 1, 9])
    assert ct.editable_radius([2, 6, 25])
    for entry in ([0, 1, 2], [1, 2, 4], [1, 3, 4], [1, 0x81, 9]):
        assert not ct.editable_radius(entry)


def test_circle_row_grid_matches_rom(rom_path, chronoret):
    assert len(areas.vectors(ct.read_rom(rom_path), chronoret)) == 116


def test_mutated_square_table_is_detected(rom_path, chronoret):
    image = bytearray(ct.read_rom(rom_path))
    positions = [(0, 0), None, None, (16, 0)] + [None] * 7
    runner = areas.RomAreas(image, chronoret)
    want = areas.model('circle', 0, 1, False, positions)
    assert runner.hits('circle', 0, 1, False, positions) == want == [3]
    image[0x0CFB6F + 1] = 2   # The local ROM table's square(1) is now wrong.
    damaged = areas.RomAreas(image, chronoret)
    assert damaged.hits('circle', 0, 1, False, positions) != want
