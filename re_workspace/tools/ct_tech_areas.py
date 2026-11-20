#!/usr/bin/env python3
"""Circle/row target evidence, executed against the user's ROM (never bundled).

BattleTgt_AreaCircle $C1:2701, AreaRow $C1:2332 and the common list helpers
run in ChronoRET's interpreter with M=1, X=0, DB=$7E, DP=0, B=0.
The deterministic grid covers cell edges, clamping, both sides, anchor order
and the circle's byte overflow. The result is consumed by Swift tests too.
Line/triangle geometry, area parameter routing, KO/status filtering and the
caller establishing B=0 are outside this claim.
"""
import argparse
import json
import sys
from pathlib import Path

import ct_techs as ct
from ct_tech_combos import Rom65816


class RomAreas(Rom65816):
    def hits(self, kind, centre, size, party, positions):
        memory = {0x7E9604: int(party), 0x7E9605: centre, 0x7E9607: size}
        for slot, point in enumerate(positions):
            memory[0x7E96F5 + slot] = int(point is not None)
            if point is not None:
                memory[0x7E1D0C + slot], memory[0x7E1D23 + slot] = point
        out = self.call(0xC12701 if kind == 'circle' else 0xC12332, memory)
        return [out[0x7E99C0 + i] for i in range(11) if out[0x7E99C0 + i] != 0xFF]


def model(kind, centre, size, party, positions):
    side = range(3) if party else range(3, 11)
    x, y = positions[centre]
    found = []
    for slot in side:
        p = positions[slot]
        if slot == centre or p is None:
            continue
        if kind == 'circle':
            dx, dy = (p[0] >> 4) - (x >> 4), (p[1] >> 4) - (y >> 4)
            hit = (dx * dx + dy * dy) & 0xFF <= size
        else:
            hit = max(0, y - 32) <= p[1] <= min(255, y + 32)
        if hit:
            found.append(slot)
    return ([centre] if kind == 'row' or centre in side else []) + found


def cases():
    grid = [(x, y) for x in (0, 31, 32, 112, 128, 224, 255) for y in (0, 31, 32, 112, 128, 224, 255)]
    for kind, size in [('circle', 0), ('circle', 9), ('circle', 25), ('circle', 127), ('row', 0)]:
        for centre, origin in [(0, (0, 0)), (3, (128, 128)), (3, (255, 255))]:
            side = [s for s in range(3, 11) if s != centre]
            for start in range(0, len(grid), len(side)):
                positions = [None] * 11
                positions[centre] = origin
                for slot, point in zip(side, grid[start:start + len(side)]):
                    positions[slot] = point
                yield dict(kind=kind, centre=centre, size=size, party=False, positions=positions)
        # PC scan with an on-side and an off-side anchor, at inclusive band/cell edges.
        for centre in (0, 3):
            positions = [(0, 0), (32, 32), (33, 33), (0, 0)] + [None] * 7
            yield dict(kind=kind, centre=centre, size=size, party=True, positions=positions)
    # Explicit byte-overflow regression: 15²+7²=$112 -> $12.
    positions = [(0, 0), None, None, (240, 112)] + [None] * 7
    yield dict(kind='circle', centre=0, size=0x12, party=False, positions=positions)


def vectors(image, ref=ct.REF):
    runner = RomAreas(image, ref)
    result = []
    for case in cases():
        actual = runner.hits(**case)
        expected = model(**case)
        if actual != expected:
            raise RuntimeError(f'ROM/model disagreement: {case}: {actual} != {expected}')
        result.append({**case, 'hits': actual})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom', type=Path, default=ct.ROM_PATH)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    result = vectors(ct.read_rom(args.rom))
    if args.json:
        print(json.dumps(result))
    else:
        print(f'Circle/row model = ROM in {len(result)} target queries (eligible battlers; B=0).')


if __name__ == '__main__':
    main()
