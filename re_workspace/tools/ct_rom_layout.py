#!/usr/bin/env python3
"""ROM layout facts the .sfc builder relies on, each checked against the ROM.

`derive` writes manifests/rom_layout.json (addresses and sizes only) and its
Swift twin CTROMLayout.swift; `check` re-derives both and compares.

- Free space: the padding rows of ChronoRET's data survey
  (refs/ChronoRET/symbols/data_survey.csv, MIT) marked `confirmed` ("uniform
  fill; nothing points into it"). Rows marked `probable` are left out: their
  reader's extent is not settled. Every byte of a region must hold its fill
  value in the user's ROM; no region may cross a bank, overlap an event pack
  stream or a message table, or contain the target of an Evt_PackPtrs entry
  or a message-table pointer.
- Event packs: every Evt_PackPtrs entry, the packed stream it points to and
  its length (through the final end marker, by ChronoRET's transcription of
  Decomp_ToWram, tools/c3pack.py), and the entries that point at no pack.
- Header: the checksum and its complement at $C0:FFDE/$C0:FFDC; the sum of
  all bytes (with the two fields as $FFFF / $0000) must reproduce the ROM's.
"""

import argparse
import csv
import json
import sys
from pathlib import Path

WS = Path(__file__).resolve().parents[1]
REF = WS / "refs" / "ChronoRET"
sys.path.insert(0, str(WS / "tools"))
sys.path.insert(0, str(REF / "tools"))
import c3pack  # noqa: E402
import ct_event_packs as packs  # noqa: E402

MANIFEST = WS / "manifests" / "rom_layout.json"
SWIFT = WS.parent / "macos_studio" / "Sources" / "ChronoForgeCore" / "CTROMLayout.swift"
CHECKSUM_PC, COMPLEMENT_PC = 0xFFDE, 0xFFDC
LOCROM_PC, LOCROM_COUNT, LOCROM_STRIDE, LOCROM_EVENTS = 0x360000, 512, 14, 8   # $F6:0000, LocRom.Events
EVT_DATA_MAX = 0x1700                                                            # LocLoad_CheckEvtData


def pc(text):
    bank, low = text[1:].split(":")
    return (int(bank, 16) & 0x3F) << 16 | int(low, 16)


def snes(offset):
    return f"${0xC0 | offset >> 16:02X}:{offset & 0xFFFF:04X}"


def checksum(rom):
    data = bytearray(rom)
    data[COMPLEMENT_PC:COMPLEMENT_PC + 4] = b"\xff\xff\x00\x00"
    return sum(data) & 0xFFFF


def message_tables(rom):
    """(pc, stop pc, [string pcs]) of the 15 event-message tables."""
    import ct_text_profile
    codec = ct_text_profile.reference_codec()
    rows = {row["start"]: row for row in csv.DictReader(
        line for line in (REF / "symbols" / "data_survey.csv").open() if not line.startswith("#"))}
    out = []
    for address in codec.MESSAGE_TABLES:
        start, stop = pc(rows[address]["start"]), pc(rows[address]["end"]) + 1
        count = codec._table_count(rom, start, stop)
        strings = [(start & 0xFF0000) | rom[start + 2 * i] | rom[start + 2 * i + 1] << 8 for i in range(count)]
        out.append((start, stop, strings))
    return out


def derive(rom):
    """Event packs are the surveyed `events` pieces (each reached only through
    Evt_PackPtrs); an entry pointing anywhere else (a graphics pack, an empty
    or undecodable stream) is not a pack the builder may replace."""
    entries = packs.pointer_entries(rom)
    pieces = {start: (label, stop + 1, size) for label, start, stop, _, size in packs.event_pieces()}
    streams, not_packs = {}, []
    for index, address in enumerate(entries):
        start = packs.to_pc(address)
        if start not in pieces:
            not_packs.append({"entry": index, "address": snes(start), "reason": "not an event piece in the survey"})
            continue
        label, stop, size = pieces[start]
        if start not in streams:
            data, end, mode = c3pack.unpack(rom, start)
            if end != stop or len(data) != size:
                raise SystemExit(f"{label}: stream ends at {snes(end)} / {len(data)} bytes, surveyed {snes(stop)}")
            if end - 1 >> 16 != start >> 16:
                raise SystemExit(f"{label}: pack crosses a bank")
            streams[start] = {"length": end - start, "unpacked": len(data), "mode": mode}
        if streams[start]["unpacked"] == 0:
            not_packs.append({"entry": index, "address": snes(start), "reason": f"{label} unpacks to 0 bytes"})
    spans = sorted((start, start + s["length"]) for start, s in streams.items())
    for (a, b), (c, d) in zip(spans, spans[1:]):
        if c < b:
            raise SystemExit(f"pack streams overlap at {snes(c)}")
    pointers = [packs.to_pc(a) for a in entries]
    other_readers = [r for r in csv.DictReader(line for line in (REF / "symbols" / "data_survey.csv").open()
                                               if not line.startswith("#"))
                     if pc(r["start"]) in streams and r["readers"] != "LocLoad_Unk56D4"]
    if other_readers:
        raise SystemExit(f"event pieces with other readers: {[r['start'] for r in other_readers]}")

    tables = message_tables(rom)
    pointers += [p for _, _, strings in tables for p in strings]

    regions = []
    survey = csv.DictReader(line for line in (REF / "symbols" / "data_survey.csv").open() if not line.startswith("#"))
    for row in survey:
        if row["kind"] != "padding" or row["confidence"] != "confirmed":
            continue
        start, stop = pc(row["start"]), pc(row["end"]) + 1
        fill = int(row["format"].split(" x $")[1], 16)
        if start >> 16 != stop - 1 >> 16:
            raise SystemExit(f"{row['start']}: padding crosses a bank")
        if any(b != fill for b in rom[start:stop]):
            raise SystemExit(f"{row['start']}: not {stop - start} x ${fill:02X} in this ROM")
        if any(start <= p < stop for p in pointers):
            raise SystemExit(f"{row['start']}: a pack or message pointer points into the padding")
        if any(a < stop and start < b for a, b in spans) or any(a < stop and start < b for a, b, _ in tables):
            raise SystemExit(f"{row['start']}: padding overlaps a pack or message table")
        regions.append({"start": row["start"], "pc": start, "size": stop - start, "fill": fill})
    regions.sort(key=lambda r: r["pc"])

    stored = rom[CHECKSUM_PC] | rom[CHECKSUM_PC + 1] << 8
    complement = rom[COMPLEMENT_PC] | rom[COMPLEMENT_PC + 1] << 8
    if checksum(rom) != stored or stored ^ complement != 0xFFFF:
        raise SystemExit("checksum formula does not reproduce the ROM's header")

    return {
        "schema": "ct-rom-layout/1",
        "generated_by": "tools/ct_rom_layout.py",
        "rom_sha256": packs.ROM_SHA256,
        "header": {"checksumPC": CHECKSUM_PC, "complementPC": COMPLEMENT_PC, "checksum": stored,
                   "rule": "sum of all bytes mod $10000 with complement $FFFF and checksum $0000"},
        "eventPacks": {"pointerTablePC": packs.PTRS_PC, "entries": len(entries),
                       "streams": len(streams), "packEntries": len(entries) - len(not_packs),
                       "streamBytes": sum(s["length"] for s in streams.values()),
                       "dataMax": EVT_DATA_MAX, "notPacks": not_packs,
                       "sharedStreams": sum(1 for s in streams if pointers.count(s) > 1),
                       "readers": "every stream's only reader in the survey is LocLoad_Unk56D4 (through Evt_PackPtrs)"},
        "locations": {"pc": LOCROM_PC, "count": LOCROM_COUNT, "stride": LOCROM_STRIDE, "eventsOffset": LOCROM_EVENTS},
        "messageTables": [{"start": snes(a), "pc": a, "stop": b, "strings": len(s)} for a, b, s in tables],
        "freeRegions": regions,
        "freeBytes": sum(r["size"] for r in regions),
        "evidence": ["free regions: ChronoRET data_survey.csv padding rows with confidence 'confirmed', "
                     "byte-verified here; 'probable' rows are excluded",
                     "pack lengths: ChronoRET tools/c3pack.py unpack (a transcription of Decomp_ToWram)",
                     "Evt_DataMax $1700 and the ($0D, $0A) refusal: LocLoad_CheckEvtData ($C0:5CC7)",
                     "a pack is read with DB = its bank and 16-bit X (Decomp_ToWram), so it must not cross a bank",
                     "a message table's entries are 16-bit addresses in the table's own bank (TextWin_Init, $C2:57DF)"],
    }


def swift_source(layout):
    rows = ",\n".join(f"        .init(pc: 0x{r['pc']:06X}, size: {r['size']}, fill: 0x{r['fill']:02X})"
                      for r in layout["freeRegions"])
    return f"""// Generated by re_workspace/tools/ct_rom_layout.py from manifests/rom_layout.json.
// Do not edit. Free regions: ChronoRET data-survey padding rows marked confirmed,
// byte-verified against the ROM (see the manifest for the evidence).
public enum CTROMLayout {{
    public struct Region: Equatable, Sendable {{
        public let pc: Int
        public let size: Int
        public let fill: UInt8
        public var end: Int {{ pc + size }}
    }}
    public static let checksumPC = 0x{CHECKSUM_PC:04X}
    public static let complementPC = 0x{COMPLEMENT_PC:04X}
    public static let locationPC = 0x{LOCROM_PC:06X}
    public static let locationCount = {LOCROM_COUNT}
    public static let locationStride = {LOCROM_STRIDE}
    public static let locationEventsOffset = {LOCROM_EVENTS}
    public static let eventDataMax = 0x{EVT_DATA_MAX:04X}
    /// Evt_PackPtrs entries that do not point at an event pack (a graphics
    /// pack, the empty stream, or bytes that do not decode).
    public static let notEventPackEntries: Set<Int> = [{", ".join(str(d["entry"]) for d in layout["eventPacks"]["notPacks"])}]
    public static let freeRegions: [Region] = [
{rows}
    ]
}}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["derive", "check"])
    args = parser.parse_args()
    layout = derive(packs.read_rom())
    text = json.dumps(layout, indent=1) + "\n"
    source = swift_source(layout)
    if args.command == "derive":
        MANIFEST.write_text(text)
        SWIFT.write_text(source)
    elif MANIFEST.read_text() != text or SWIFT.read_text() != source:
        raise SystemExit("rom_layout.json or CTROMLayout.swift differs from the ROM; run derive")
    print(f"ROM layout: {len(layout['freeRegions'])} free regions, {layout['freeBytes']:,} bytes; "
          f"{layout['eventPacks']['packEntries']} pack entries, {layout['eventPacks']['streams']} streams; "
          f"{len(layout['messageTables'])} message tables; checksum ${layout['header']['checksum']:04X}")


if __name__ == "__main__":
    main()
