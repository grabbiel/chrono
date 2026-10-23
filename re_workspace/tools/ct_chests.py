#!/usr/bin/env python3
"""Chrono Trigger chests: who reads a chest's flag, how many flags there are, and the locations the game never loads.

A chest is a TreasureRom record (tools/ct_maps.py). Its flag is a bit of
Treasure_Flags ($7F:0001, 64 bytes), numbered by the record's place in
TreasureRom: (record offset - TreasureRom_LocOfs[0]) / 4. ChronoRET's matched
source (MIT; refs/ChronoRET) and the ROM's own code bytes show the readers
and writers:

  Map_LoadTreasureTiles ($C0:A712)  Map_TreasureRec0 = TreasureRom_LocOfs[0];
                                    marks each record's tile, n = its place in
                                    the location's list (7 bits: $80 is none)
  Map_TreasureTaken ($C0:A7BC)      the flag of the record at Map_RecOfs:
                                    (Map_RecOfs - Map_TreasureRec0) / 4, byte
                                    n >> 3 & $3F, bit n & 7: reads it
  Field_CheckTileInFront ($C0:1DF4) the action button: the record on the tile
                                    in front, the same number, reads the flag
                                    and sets it, then gives the item (service
                                    1) or the gold (service 4)

Nothing else names a chest's number: no opcode of the 462 event packs
addresses $7F:0001-$7F:0040 (the event flags start at $7F:0050), and the only
other code that touches those bytes copies the whole page ($7F:0000-$01FF,
M7Scene_SaveWram7F / M7Scene_RestoreWram7F). So renumbering the chests (a
chest added or removed before others) needs no reference rewritten: the flags
follow the records. The byte mask $3F gives 512 flags; the ROM uses 249
(244 chests, five redirect records and location 0's dummy).

The locations the game never loads: no ExitRom record, no event warp operand
($DC-$E1; the one $E2 takes $7F:0166, which events set to 1, $0C or $75), no
world-map exit (C2SceneRom_ListPacks) and no world-map script operand names
them; their LocRom record is the placeholder (MapProps 0, Tileset12 18, no
Tileset3, palette 75, no exits, no treasure) and their Events entry does not
point at an event pack. The matched code that sets Loc_Id or Loc_DestId takes
the number from those tables or from a saved one.

No ROM bytes are kept here: everything is read from the user's ROM.

    ct_chests.py check [--rom PATH] [--run]    every claim (exit 1 on a failure); --run opens chests with the
                                               ROM's own Field_CheckTileInFront in ChronoRET's interpreter
    ct_chests.py flags [--rom PATH] [LOC ...]  each location's chests with their flag numbers
    ct_chests.py unused-locations [--rom PATH] the location numbers the game never loads, with the proof
    ct_chests.py open <loc> <k> [--rom PATH] [--taken]
                                               Map_LoadTreasureTiles then Field_CheckTileInFront facing chest k
"""

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_maps as cm  # noqa: E402
import ct_tilesets as ts  # noqa: E402
from ct_tilesets import REF, ROM_PATH, pc, u8, u16, u24, read_rom  # noqa: E402

TREASURE_FLAGS, FLAG_BYTES = 0x7F0001, 64          # !Treasure_Flags; !Treasure_FlagByteMask = $3F
FLAG_COUNT = FLAG_BYTES * 8
LIST_MAX = 0x80                                     # Map_TreasureIdx: bit 7 is "no treasure"
EVENT_FLAGS_FIRST = 0x7F0050                        # the lowest page-0 byte an event addresses (checked)
WORLD_LISTS, WORLD_SCRIPTS, WORLD_SLOTS = 0xC6FFC0, 0xC6FFE0, 10   # C2SceneRom_ListPacks / ScriptPacks
WORLD_FIRST = cm.DEST_WORLD                         # $1F0 and up: the world maps
PLACEHOLDER = {"tileset12": 18, "tileset3": cm.NONE, "palette": 75, "mapProps": 0}
WARP_OPS = (0xDC, 0xDD, 0xDE, 0xDF, 0xE0, 0xE1)     # location (word), column, row
SVC_ADD_ITEM, SVC_ADD_GOLD = 1, 4                   # BankC1_Entry8003 services
KIND_ITEM, KIND_GOLD, KIND_OPENED = 0, 1, 2         # Field_Unk2A (TreasureKind_*)
INVENTORY, GOLD = 0x7E2400, 0x7E2C53                # items $7E:2400 / counts $7E:2500; 24-bit gold

ASM_CLAIMS = (
    ("bankC0/bankC0.asm", "Field_CheckTileInFront",
     ("JSR (Field_TileInFrontTable,X)", "AND.w #!Map_TreasureIdxMask", "ADC.w !Map_TreasureLocRecs",
      "LDA.l TreasureRom.Tile,X", "CMP.b !Field_FrontTile", "SBC.w !Map_TreasureRec0", "LSR A", "LSR A",
      "AND.w #!Treasure_FlagByteMask", "AND.b #!Treasure_FlagBitMask", "LDA.l !Treasure_Flags,X",
      "BNE .already_opened", "STA.l !Treasure_Flags,X", "LDA.l TreasureRom.Contents,X", "BMI .gold",
      "BIT.w #!Treasure_Empty", "AND.w #!Treasure_ItemMask", "LDA.b #!BankC1Svc_AddItem", "JSL BankC1_Entry8003",
      "LDA.b #!BankC1Svc_AddGold", "JSL BankC1_Entry8003", "LDA.b #!TreasureKind_Opened")),
    ("bankC0/bankC0.asm", "Map_LoadTreasureTiles",
     ("LDA.l !TreasureRom_LocOfs", "STA.b !Map_TreasureRec0-!DP_Map", "LDA.l !TreasureRom_LocOfs+2,X",
      "STA.b !Map_TreasureLocRecs-!DP_Map", "LDA.l TreasureRom.Contents,X", "LDA.b !Map_RecNum-!DP_Map",
      "STA.l !Map_TreasureIdx,X", "JSR Map_TreasureTaken")),
    ("bankC0/bankC0.asm", "Map_TreasureTaken",
     ("SBC.b !Map_TreasureRec0-!DP_Map", "LSR A", "LSR A", "AND.w #!Treasure_FlagByteMask",
      "AND.b #!Treasure_FlagBitMask", "LDA.l !Treasure_Flags,X")),
    ("bankC0/bankC0.asm", "Evt_OpE0_Warp", ("LDA.l !Evt_Data,X", "AND.w #!Loc_IdMask", "STA.b !Loc_DestId")),
    ("bankC0/bankC0.asm", "Evt_OpE1_WarpNow", ("LDA.l !Evt_Data,X", "AND.w #!Loc_IdMask", "STA.b !Loc_DestId")),
    ("bankC0/bankC0.asm", "Evt_OpDD_SetLoc", ("LDA.l !Evt_Data,X", "AND.w #!Loc_IdMask", "STA.b !Loc_Id")),
    ("bankC2/bankC2.asm", "C2Scene_LoadLists", ("LDA.l !C2SceneRom_ListPacks,X", "JSL Decomp_ToWramVec")),
)

CONSTANT_CLAIMS = (
    ("include/ram_engine.inc", "!Treasure_Flags = $7F0001"),
    ("include/ram_engine.inc", "!Map_TreasureRec0 = $1D06"),
    ("include/ram_engine.inc", "!Map_TreasureLocRecs = $1D08"),
    ("include/constants_engine.inc", "!Treasure_FlagByteMask = $003F"),
    ("include/constants_engine.inc", "!Treasure_FlagBitMask = $07"),
    ("include/constants_engine.inc", "!Map_TreasureIdxMask = $007F"),
    ("include/constants_engine.inc", "!Treasure_Empty = $4000"),
    ("include/constants_engine.inc", "!Treasure_ItemMask = $01FF"),
    ("include/constants_menu.inc", "!C2SceneRom_ListPacks = $C6FFC0"),
    ("include/constants_menu.inc", "!C2SceneRom_ScriptPacks = $C6FFE0"),
)


def asm_claims(ref=REF):
    saved = ts.ASM_CLAIMS, ts.CONSTANT_CLAIMS
    ts.ASM_CLAIMS, ts.CONSTANT_CLAIMS = ASM_CLAIMS, CONSTANT_CLAIMS
    try:
        return ts.asm_claims(ref)
    finally:
        ts.ASM_CLAIMS, ts.CONSTANT_CLAIMS = saved


def code_claims(rom):
    """The readers' operands in the ROM's own code bytes."""
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    body = ts._body
    opener = body(rom, 0xC01DF4, 0xC01E91)
    claim("$C0:1DF4 masks the tile's index (AND #$007F), adds Map_TreasureLocRecs (ADC $1D08), reads TreasureRom "
          "(LDA.l $F50000,X / $F50002,X)",
          b"\x29\x7f\x00" in opener and b"\x6d\x08\x1d" in opener and b"\xbf\x00\x00\xf5" in opener
          and b"\xbf\x02\x00\xf5" in opener)
    claim("$C0:1DF4 numbers the record from Map_TreasureRec0 (SBC $1D06; LSR; LSR), byte AND #$003F, bit AND #$07",
          b"\xed\x06\x1d\x4a\x4a" in opener and b"\x29\x3f\x00" in opener and b"\x29\x07" in opener)
    claim("$C0:1DF4 reads and sets Treasure_Flags (LDA.l / STA.l $7F0001,X), then services 1 and 4 (JSL $C18003)",
          b"\xbf\x01\x00\x7f" in opener and b"\x9f\x01\x00\x7f" in opener
          and b"\xa9\x01\x22\x03\x80\xc1" in opener and b"\xa9\x04\x22\x03\x80\xc1" in opener)
    taken = body(rom, 0xC0A7BC, 0xC0A7E8)
    claim("$C0:A7BC numbers Map_RecOfs from Map_TreasureRec0 (SBC $06 with D = $1D00; LSR; LSR) and reads "
          "Treasure_Flags (LDA.l $7F0001,X)",
          b"\xe5\x06\x4a\x4a" in taken and b"\x29\x3f\x00" in taken and b"\xbf\x01\x00\x7f" in taken)
    loader = body(rom, 0xC0A712, 0xC0A7BB)
    claim("$C0:A712 sets Map_TreasureRec0 to TreasureRom_LocOfs[0] (LDA.l $F5F000; STA $06)",
          b"\xaf\x00\xf0\xf5\x85\x06" in loader)
    return out


# --- What addresses the flags ------------------------------------------------------------------

def _event_table():
    import ct_event_packs as packs
    doc = json.loads(packs.TABLE.read_text())
    return packs, doc["opcodes"] if isinstance(doc, dict) else doc


def mem_address(op, b):
    """The $7F address an event opcode's static operands name (bytes b = the instruction), or None."""
    if op == 0x16:
        return 0x7F0000 + b[1] + (0x100 if b[3] & 0x80 else 0)
    if op in (0x65, 0x66):
        return 0x7F0000 + b[2] + (0x100 if b[1] & 0x80 else 0)
    if op in (0x1C, 0x53, 0x54):
        return 0x7F0000 + (b[1] | b[2] << 8)
    if op in (0x56, 0x58, 0x59):
        return 0x7F0000 + (b[2] | b[3] << 8)
    if op in (0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D):
        return b[1] | b[2] << 8 | b[3] << 16
    return None


WORD_OPS = (0x1C, 0x49, 0x4B, 0x4D, 0x54, 0x59)       # these touch the byte after the address too


def event_scan(rom):
    """Every event opcode's static $7F address over the decoded packs: (packs, ops, {address: count},
    [hits on the flags], warps {location: [where]}, dynamic warps [(pack, offset, bytes)])."""
    packs, table = _event_table()
    unpacked, _ = packs.unpack_all(rom)
    addresses, hits, warps, dynamic, n_ops, n_packs = {}, [], {}, [], 0, 0
    for p in unpacked:
        d = p["data"]
        if not d:
            continue
        n_packs += 1
        ops, _, _ = packs.decode(table, d)
        for y, (op, length, _, _) in ops.items():
            n_ops += 1
            b = d[1 + y:1 + y + length]
            a = mem_address(op, b)
            if a is not None:
                addresses[a] = addresses.get(a, 0) + 1
                top = a + (1 if op in WORD_OPS else 0)
                if a <= TREASURE_FLAGS + FLAG_BYTES - 1 and top >= TREASURE_FLAGS:
                    hits.append((p["label"], y, b.hex()))
            if op in WARP_OPS:
                warps.setdefault((b[1] | b[2] << 8) & 0x1FF, []).append(f"{p['label']} ${y:04X} op ${op:02X}")
            if op == 0xE2:
                dynamic.append((p["label"], y, b.hex()))
    return n_packs, n_ops, addresses, hits, warps, dynamic


def routines(ref=REF):
    """[(bank, start, bytes, name)] from the matched source's routine headers."""
    rx = re.compile(r"^; \$([0-9A-F]{2}):([0-9A-F]{4}) — (\S+) \((\d+) bytes")
    out = []
    for f in sorted((ref / "asm").rglob("*.asm")):
        for line in f.read_text(errors="replace").splitlines():
            m = rx.match(line)
            if m:
                out.append((int(m[1], 16), int(m[2], 16), int(m[4]), m[3]))
    return out


SURVEY = REF / "symbols" / "data_survey.csv"


def survey_regions(csv=SURVEY):
    """[(start long, end long inclusive, kind, content)] of the data survey."""
    out = []
    for line in Path(csv).read_text().splitlines():
        cols = line.split(",")
        if line.startswith("#") or len(cols) < 6 or not cols[0].startswith("$"):
            continue
        a, b = (int(c[1:3], 16) << 16 | int(c[4:8], 16) for c in cols[:2])
        out.append((a, b, cols[4], cols[5]))
    return out


LONG_OPS = {0xAF: "LDA", 0xBF: "LDA,X", 0x8F: "STA", 0x9F: "STA,X", 0x0F: "ORA", 0x1F: "ORA,X", 0x2F: "AND",
            0x3F: "AND,X", 0x4F: "EOR", 0x5F: "EOR,X", 0x6F: "ADC", 0x7F: "ADC,X", 0xCF: "CMP", 0xDF: "CMP,X",
            0xEF: "SBC", 0xFF: "SBC,X"}


def code_scan(rom, ref=REF, csv=SURVEY):
    """Every long-address instruction pattern over $7F:0001-$7F:0040 (or $7F:0000,X) in the ROM,
    with the matched routine or survey region it lies in: [(long, mnemonic, operand, where)]."""
    named = routines(ref)
    regions = survey_regions(csv)
    out = []
    for i in range(len(rom) - 3):
        op = rom[i]
        if op not in LONG_OPS or rom[i + 3] != 0x7F or rom[i + 2] != 0 or rom[i + 1] > FLAG_BYTES:
            continue
        if rom[i + 1] == 0 and not LONG_OPS[op].endswith(",X"):
            continue
        long = 0xC00000 | i
        bank, low = long >> 16, long & 0xFFFF
        where = next((f"routine {r[3]}" for r in named if r[0] == bank and r[1] <= low < r[1] + r[2]), None)
        if where is None:
            where = next((f"{r[2]} region {r[3][:40]}" for r in regions if r[0] <= long <= r[1]), "unsurveyed")
        out.append((long, LONG_OPS[op], 0x7F0000 | rom[i + 1], where))
    return out


# The matched routines with a $7F:0000,X operand, and what X holds there.
INDEXED_READERS = {
    "Evt_Op16_IfMemByte": "Evt_Mem7F + an event operand (event_scan)",
    "Evt_Op1C_SetUnk7F0A80Mem": "Evt_Mem7F + an event operand (event_scan)",
    "Evt_Op53_GetMemByte": "Evt_Mem7F + an event operand (event_scan)",
    "Evt_Op54_GetMemWord": "Evt_Mem7F + an event operand (event_scan)",
    "Evt_Op56_SetMemByte": "Evt_Mem7F + an event operand (event_scan)",
    "Evt_Op58_SetMemVarByte": "Evt_Mem7F + an event operand (event_scan)",
    "Evt_Op59_SetMemVarWord": "Evt_Mem7F + an event operand (event_scan)",
    "Evt_Op65_SetMemBit": "Evt_Mem7F + an event operand (event_scan)",
    "Evt_Op66_ClearMemBit": "Evt_Mem7F + an event operand (event_scan)",
    "WinFx_StepWipe": "a window line table at WinFx_C3ETablePtr",
    "WinFx_BuildQuad": "a window line table at WinFx_C3ETablePtr",
    "M7Scene_SaveWram7F": "0-$1FF: the whole page, copied out",
    "M7Scene_RestoreWram7F": "0-$1FF: the whole page, copied back",
}
FLAG_READERS = {"Field_CheckTileInFront", "Map_TreasureTaken"}


def treasure_numbers(rom):
    """[[flag number of each record of location i's own list]] (a redirect list has its one record)."""
    word0 = u16(rom, cm.TREASURE_OFS)
    out = []
    for i in range(cm.LOC_COUNT):
        first, end = u16(rom, cm.TREASURE_OFS + 2 * i), u16(rom, cm.TREASURE_OFS + 2 * i + 2)
        out.append([(o - word0) // cm.TREASURE_BYTES for o in range(first, end, cm.TREASURE_BYTES)])
    return out


def flag_claims(rom, ref=REF, csv=SURVEY):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    n_packs, n_ops, addresses, hits, warps, dynamic = event_scan(rom)
    page0 = sorted(a for a in addresses if 0x7F0000 < a < 0x7F0100)
    claim(f"no opcode of the {n_packs} non-empty event packs ({n_ops} instructions) addresses Treasure_Flags "
          f"($7F:0001-$7F:0040)", not hits, f"{len(hits)} hits" if hits else f"lowest page-0 address above $7F:0000: "
          f"${page0[0]:06X}" if page0 else "")
    claim(f"the event flags start at ${EVENT_FLAGS_FIRST:06X}: nothing between Treasure_Flags and them is addressed",
          page0 and page0[0] == EVENT_FLAGS_FIRST)
    scan = code_scan(rom, ref, csv)
    direct = sorted({w.split()[1] for _, _, a, w in scan if a != 0x7F0000 and w.startswith("routine")})
    claim("the matched routines with a $7F:0001-$7F:0040 operand are Field_CheckTileInFront and Map_TreasureTaken",
          set(direct) == FLAG_READERS, ", ".join(direct))
    indexed = sorted({w.split()[1] for _, _, a, w in scan if a == 0x7F0000 and w.startswith("routine")})
    claim("every matched routine with a $7F:0000,X operand indexes an event operand, a window table or the whole page",
          set(indexed) <= set(INDEXED_READERS), ", ".join(sorted(set(indexed) - set(INDEXED_READERS))))
    other = [(f"${long:06X}", w) for long, _, _, w in scan if not w.startswith("routine")]
    claim("every other long $7F:0000-$7F:0040 pattern lies in a surveyed data region (packed or table data, not code)",
          all("region" in w and not w.startswith("code") for _, w in other),
          f"{len(other)} patterns; " + ", ".join(sorted({w.split(' region')[0] for _, w in other})))
    numbers = treasure_numbers(rom)
    total = (u16(rom, cm.TREASURE_OFS + 2 * cm.LOC_COUNT) - u16(rom, cm.TREASURE_OFS)) // cm.TREASURE_BYTES
    claim(f"TreasureRom holds {total} records numbered 0-{total - 1} in location order, of the {FLAG_COUNT} flags "
          f"Treasure_Flags holds", [n for lst in numbers for n in lst] == list(range(total)) and total <= FLAG_COUNT)
    longest = max(len(lst) for lst in numbers)
    claim(f"no list has more than {LIST_MAX} records (Map_TreasureIdx keeps 7 bits)", longest <= LIST_MAX, f"longest {longest}")
    return out


# --- The locations the game never loads ---------------------------------------------------------

def _unpack(rom, long):
    import ct_lzss
    last = None
    for mode in ("lz12", "lz11"):
        try:
            return ct_lzss.decompress(rom[pc(long):pc(long) + 0x10000], mode)
        except Exception as e:  # noqa: BLE001
            last = e
    raise last


def world_lists(rom):
    """{location: [where]} of the world maps' exit lists (C2Scene_ListA entries, .Loc bits 0-8)."""
    out = {}
    for k in range(WORLD_SLOTS):
        long = u24(rom, WORLD_LISTS + 3 * k)
        if not long:
            continue
        data = _unpack(rom, long)
        for j in range(data[0]):
            e = data[1 + 7 * j:8 + 7 * j]
            loc = (e[3] | e[4] << 8) & 0x1FF
            if loc != 0x1FF:                                   # C2Scene_ListANoLoc
                out.setdefault(loc, []).append(f"world list {k} entry {j}")
    return out


def world_script_words(rom):
    """{location: count} of every $05 byte followed by a word naming it in the world-map scripts
    (C2Script_GoToLocation's operand; read as raw bytes, so a superset of the real operands)."""
    out = {}
    for k in range(WORLD_SLOTS):
        long = u24(rom, WORLD_SCRIPTS + 3 * k)
        if not long:
            continue
        data = _unpack(rom, long)
        for j in range(len(data) - 2):
            if data[j] == 0x05:
                w = (data[j + 1] | data[j + 2] << 8) & 0x1FF
                out[w] = out.get(w, 0) + 1
    return out


def unused_locations(rom, scan=None):
    """(the location numbers the game never loads, {location: proof}) below the world maps."""
    import ct_rom_layout as layout
    named = {}
    for i in range(cm.LOC_COUNT):
        for _, raw in cm.exit_records(rom, i):
            named.setdefault(cm.decode_exit(raw)["dest"], []).append(f"exit of location {i}")
    _, _, addresses, _, warps, dynamic = scan or event_scan(rom)
    for loc, where in warps.items():
        named.setdefault(loc, []).extend(where)
    for loc, where in world_lists(rom).items():
        named.setdefault(loc, []).extend(where)
    for loc, n in world_script_words(rom).items():
        named.setdefault(loc, []).append(f"{n} world-script words")
    # The one dynamic warp ($E2) reads its destination from $7F:0166 (GetMemByte): the values events store there.
    stored = dynamic_warp_values(rom)
    for v in stored:
        for hi in range(2):
            named.setdefault(v | hi << 8, []).append("a value events store for the $E2 warp")
    not_packs = {d["entry"] for d in json.loads(layout.MANIFEST.read_text())["eventPacks"]["notPacks"]}
    unused, proof = [], {}
    for i in range(WORLD_FIRST):
        if named.get(i):
            continue
        h = cm.header(rom, i)
        placeholder = all(h[k] == v for k, v in PLACEHOLDER.items())
        empty = not cm.exit_records(rom, i) and not cm.treasure_list(rom, i)[1]
        if placeholder and empty and h["events"] in not_packs:
            unused.append(i)
            proof[i] = {"events": h["events"], "music": h["music"]}
    return unused, proof


def dynamic_warp_values(rom):
    """The byte values events store at the address the $E2 warps' word is read from."""
    packs, table = _event_table()
    unpacked, _ = packs.unpack_all(rom)
    sources, values = set(), set()
    for p in unpacked:
        d = p["data"]
        if not d:
            continue
        ops, _, _ = packs.decode(table, d)
        e2 = [d[1 + y + 1] for y, o in ops.items() if o[0] == 0xE2]
        for y, (op, length, _, _) in ops.items():
            b = d[1 + y:1 + y + length]
            if op == 0x53 and b[3] in e2:                     # event word a's low byte = the byte at $7F:m
                sources.add(0x7F0000 + (b[1] | b[2] << 8))
    for p in unpacked:
        d = p["data"]
        if not d:
            continue
        ops, _, _ = packs.decode(table, d)
        for y, (op, length, _, _) in ops.items():
            b = d[1 + y:1 + y + length]
            if op == 0x56 and 0x7F0000 + (b[2] | b[3] << 8) in sources:
                values.add(b[1])
    return sorted(values)


def unused_claims(rom):
    out = []

    def claim(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    scan = event_scan(rom)
    dynamic = scan[5]
    values = dynamic_warp_values(rom)
    claim(f"{len(dynamic)} event warp takes its destination from event words ($E2); it reads $7F:0166, "
          f"which events set to {', '.join(f'${v:02X}' for v in values)}", len(dynamic) == 1 and values,
          "; ".join(f"{p} ${y:04X}" for p, y, _ in dynamic))
    unused, proof = unused_locations(rom, scan)
    claim(f"{len(unused)} locations below ${WORLD_FIRST:03X} are named by no exit, warp, world list or world script, "
          "have the placeholder record and an Events entry that is not an event pack",
          unused, ", ".join(map(str, unused)))
    return out, unused


# --- Opening a chest in the interpreter --------------------------------------------------------------

def open_chest(runner, rom, loc, k, taken=False, face=0):
    """Map_LoadTreasureTiles for `loc` (every flag clear, or set with `taken`), then the leader one tile
    below chest k, facing up, presses the button: Field_CheckTileInFront ($C0:1DF4). The result."""
    _, records = cm.treasure_list(rom, loc)
    tile, contents = records[k][1], records[k][2]
    x, y = tile & 0xFF, tile >> 8
    mem = runner.load_map(loc, treasure=1 if taken else 0)
    known = dict(mem)
    known.update({0x7E0129: 0, 0x7E0197: 0, 0x7E0198: 0, 0x7E1600: face, 0x7E1801: x, 0x7E1881: (y + 1) & 0xFF})
    for j in range(0x200):
        known.setdefault(INVENTORY + j, 0)
    for j in range(3):
        known.setdefault(GOLD + j, 0)
    out = runner.run_concrete(0xC01DF4, known, d=0x0100)
    before = [known.get(TREASURE_FLAGS + j, 0) for j in range(FLAG_BYTES)]
    after = [out.get(TREASURE_FLAGS + j, 0) for j in range(FLAG_BYTES)]
    set_now = [8 * j + b for j in range(FLAG_BYTES) for b in range(8) if (after[j] & ~before[j]) >> b & 1]
    items = [(out.get(INVENTORY + j, 0), out.get(INVENTORY + 0x100 + j, 0)) for j in range(0x100) if out.get(INVENTORY + j, 0)]
    gold = out.get(GOLD, 0) | out.get(GOLD + 1, 0) << 8 | out.get(GOLD + 2, 0) << 16
    word0 = u16(rom, cm.TREASURE_OFS)
    return {"location": loc, "chest": k, "tile": [x, y], "contents": contents,
            "flag": (records[k][0] - word0) // cm.TREASURE_BYTES, "flagsSet": set_now, "kind": out.get(0x7E012A),
            "tileIndex": mem.get(0x7E70C0 + (y << 8 | x)),
            "items": items, "gold": gold}


def expect_open(r, taken=False):
    """Whether an open_chest result is what the record says the game does."""
    c = r["contents"]
    if taken:
        return r["kind"] == KIND_OPENED and not r["flagsSet"] and not r["items"] and not r["gold"]
    if r["flagsSet"] != [r["flag"]]:
        return False
    if c & 0x8000:
        return r["kind"] == KIND_GOLD and r["gold"] == (c & 0x7FFF) * 2 and not r["items"]
    if c & 0x4000:
        return not r["items"] and not r["gold"]
    return r["kind"] == KIND_ITEM and r["items"] == [(c & 0x1FF, 1)] and not r["gold"]


def run_claims(rom, ref=REF, picks=None):
    """Field_CheckTileInFront on the given (location, chest) pairs, or one item, one gold and one empty chest."""
    runner = cm.MapRunner(rom, ref)
    if picks is None:
        picks, kinds = [], set()
        for i in range(1, cm.LOC_COUNT):
            tloc, records = cm.treasure_list(rom, i)
            if tloc != i:
                continue
            for k, (_, tile, c) in enumerate(records):
                kind = "gold" if c & 0x8000 else "empty" if c & 0x4000 else "item"
                if kind not in kinds and (tile >> 8) + 1 < 64:
                    kinds.add(kind)
                    picks.append((i, k))
    out = []
    for loc, k in picks:
        r = open_chest(runner, rom, loc, k)
        out.append((f"Field_CheckTileInFront at location {loc} chest {k}: flag {r['flag']} set, "
                    f"contents ${r['contents']:04X} given", expect_open(r), json.dumps({x: r[x] for x in ("flagsSet", "kind", "items", "gold")})))
        again = open_chest(runner, rom, loc, k, taken=True)
        out.append((f"Field_CheckTileInFront at location {loc} chest {k} with its flag set: already opened",
                    expect_open(again, taken=True), json.dumps({x: again[x] for x in ("flagsSet", "kind")})))
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    k = sub.add_parser("check")
    k.add_argument("--rom", default=str(ROM_PATH))
    k.add_argument("--run", action="store_true")
    f = sub.add_parser("flags")
    f.add_argument("locations", nargs="*", type=int)
    f.add_argument("--rom", default=str(ROM_PATH))
    u = sub.add_parser("unused-locations")
    u.add_argument("--rom", default=str(ROM_PATH))
    o = sub.add_parser("open")
    o.add_argument("location", type=int)
    o.add_argument("chest", type=int)
    o.add_argument("--rom", default=str(ROM_PATH))
    o.add_argument("--taken", action="store_true")
    args = parser.parse_args()
    if args.command == "open":
        rom = Path(args.rom).read_bytes()
        print(json.dumps(open_chest(cm.MapRunner(rom), rom, args.location, args.chest, args.taken)))
        return 0
    rom = read_rom(args.rom)
    if args.command == "flags":
        numbers = treasure_numbers(rom)
        for i in args.locations or range(cm.LOC_COUNT):
            tloc, records = cm.treasure_list(rom, i)
            if numbers[i]:
                print(f"location {i}: " + ("redirect to " + str(tloc) if tloc != i else
                      ", ".join(f"({t & 0xFF},{t >> 8}) ${c:04X} flag {n}" for n, (_, t, c) in zip(numbers[i], records))))
        return 0
    if args.command == "unused-locations":
        unused, proof = unused_locations(rom)
        for i in unused:
            print(f"location {i}: events entry {proof[i]['events']} (not an event pack), music ${proof[i]['music']:02X}")
        print(f"{len(unused)} locations the game never loads")
        return 0
    claims = asm_claims() + code_claims(rom) + flag_claims(rom)
    more, _ = unused_claims(rom)
    claims += more
    if args.run:
        claims += run_claims(rom)
    return ts.report(claims)


if __name__ == "__main__":
    sys.exit(main())
