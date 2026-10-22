"""Maps and tilesets written back by `chronoforge rom build` (tools/ct_rom_check.py, tools/ct_maps.py).

ROM-free: `ct_maps.py verify-import --content` compares a map's content and
leaves out the `rom` provenance a build moves, on the synthetic tables.

Local (ROM, ChronoRET, the layout manifest): ct_rom_check.py accepts the
clean ROM as a build that lists no maps and no tilesets (every location,
Tileset12, Tileset3 and palette set compared with the clean ROM), and
rejects a LocRom byte changed without a reported map.
"""

import hashlib
import json
import os
import subprocess
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_maps as cm  # noqa: E402
import ct_tilesets as ts  # noqa: E402


def map_json(d):
    """A project map with decode()'s content (the fields verify_import reads)."""
    h, p = d["header"], d["props"]
    layers = []
    for k, plane in sorted(d["planes"].items()):
        w, hh = d["sizes"][k]
        layer = {"bg": int(k), "metatiles": plane}
        if k != "1":
            layer.update(width=w, height=hh)
        layers.append(layer)
    w1, h1 = d["sizes"]["1"]
    lim = h["limits"]
    tileset = (f"t12_{h['tileset12']:02d}" if h["tileset12"] != cm.NONE
               else f"t3_{h['tileset3']:02d}" if h["tileset3"] != cm.NONE else "t12_none")
    return {"id": f"loc_{d['id']:03d}", "name": "x", "tileset": tileset, "width": w1, "height": h1, "layers": layers,
            "exits": [{"x": e["x"], "y": e["y"], "map": f"loc_{e['dest']:03d}", "toX": e["destX"], "toY": e["destY"],
                       "span": e["span"], "vertical": e["vertical"], "facing": e["facing"], "facingBit7": e["destFlag"]}
                      for e in d["exits"]],
            "triggers": [],
            "location": {"music": h["music"], "tileset12": h["tileset12"], "tileset3": h["tileset3"],
                         "palette": h["palette"], "events": h["events"], "unk06": h["unk06"],
                         "limits": [lim["left"], lim["top"], lim["right"], lim["bottom"]]},
            "settings": {k: p[k] for k in ("screens", "colorMath", "move2", "move3", "halfRate2", "ownStep2", "ownStep3")},
            "tileProps": {"width": w1, "height": h1, "hiBits": bytes(d["hiBits"]).hex(),
                          "attrA": bytes(d["attrA"]).hex(), "attrB": bytes(d["attrB"]).hex()},
            "treasure": [{"x": t["x"], "y": t["y"], "contents": t["contents"]} for t in d["treasure"]["records"]],
            "rom": {"location": d["id"], "mapProps": p["entry"], "packedAt": p["at"], "packedBytes": p["packedBytes"],
                    "unpackedBytes": p["length"], "staleTiles": p["staleTiles"], "treasureList": d["treasure"]["list"]}}


def test_verify_import_content_leaves_out_the_provenance(tmp_path):
    regions, _ = cm.synthetic_rom()
    image = bytearray(ts.ROM_SIZE)
    for long, data in regions.items():
        image[ts.pc(long):ts.pc(long) + len(data)] = data
    rom = bytes(image)
    (tmp_path / "maps").mkdir()
    for i in range(4):
        m = map_json(cm.decode(rom, i))
        if i == 2:
            m["rom"]["packedAt"] = "$C0:0000"               # where a build moved it
        (tmp_path / "maps" / f"loc_{i:03d}.map.json").write_text(json.dumps(m))
    full = cm.verify_import(rom, tmp_path, locations=range(4))
    content = cm.verify_import(rom, tmp_path, locations=range(4), content_only=True)
    assert [ok for _, ok, _ in full] == [True, True, False, True]
    assert "rom" in full[2][2]
    assert all(ok for _, ok, _ in content)
    m = json.loads((tmp_path / "maps" / "loc_001.map.json").read_text())
    m["layers"][0]["metatiles"][0] ^= 1
    (tmp_path / "maps" / "loc_001.map.json").write_text(json.dumps(m))
    assert not cm.verify_import(rom, tmp_path, locations=[1], content_only=True)[0][1]


# --- Local ROM, ChronoRET and the layout manifest ---------------------------------------

def no_op_report(rom, **extra):
    import ct_rom_layout as layout
    total = layout.checksum(rom)
    sha = hashlib.sha256(rom).hexdigest()
    return {"schema": "ct-rom-build/1", "baseSHA256": sha, "outputSHA256": sha, "checksum": total, "packs": [],
            "messageTables": [], "songs": [], "writes": [], "freeBytesLeft": 0, "maps": [], "tilesets": [], **extra}


def run_check(tmp_path, data, report):
    (tmp_path / "b.sfc").write_bytes(data)
    (tmp_path / "b.json").write_text(json.dumps(report))
    return subprocess.run([sys.executable, os.path.join(TOOLS, "ct_rom_check.py"), str(tmp_path / "b.sfc"),
                           str(tmp_path / "b.json")], capture_output=True, text=True, timeout=600)


def test_checker_compares_every_unreported_map_and_tileset(tmp_path, rom_path, chronoret, manifest_path):
    manifest_path("rom_layout.json")
    import ct_rom_layout as layout
    rom = cm.read_rom(rom_path)
    result = run_check(tmp_path, rom, no_op_report(rom))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 maps, 0 tilesets" in result.stdout
    # A LocRom byte changed (inside a reported write, with a consistent header) but no map reported.
    data = bytearray(rom)
    at = ts.pc(cm.LOC_ROM) + cm.LOC_BYTES * 5
    data[at] ^= 1
    total = layout.checksum(data)
    data[layout.COMPLEMENT_PC:layout.COMPLEMENT_PC + 4] = bytes([~total & 0xFF, ~total >> 8 & 0xFF, total & 0xFF, total >> 8])
    report = no_op_report(bytes(data), writes=[{"pc": at, "length": 1, "what": "stray"}])
    report["baseSHA256"] = hashlib.sha256(rom).hexdigest()
    result = run_check(tmp_path, bytes(data), report)
    assert result.returncode != 0 and "FAIL" in result.stdout + result.stderr
