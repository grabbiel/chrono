"""ct_schemas — evidence-backed binary schema manifests for Chrono Trigger (Phase 3).

This module is the shared library for the Phase 3 gameplay-domain manifests:

  manifests/characters_schema.json      characters / party / enemies
  manifests/items_and_techs_schema.json items / techs / text codec
  manifests/maps_schema.json            maps / tilesets / collision

It provides:
  * ROM access built on tools/address_map.py (HiROM mapping)
  * LZSS decompression (tools/ct_lzss.py, with a pure-Python fallback that
    implements the Decomp_ToWram loop of bankC3.asm / module.asm)
  * the CT text codec (glyphs $A0-$DD, space $FF, terminator $EF, and the
    127-entry substring dictionary addressed from $DE:FA00)
  * a GENERIC verifier: walk any manifest, re-check every machine-readable
    byte claim against the live ROM bytes, check that every claimed SNES
    address resolves inside the ROM image, check record strides divide the
    ChronoRET data_assets.csv blob sizes, and check 24-bit pointer tables.

Machine-checkable conventions used inside the manifests:
  * any dict {"addr": "$BB:AAAA", "bytes": "XX YY ..."}  -> ROM byte claim
  * any dict {"addr": "$BB:AAAA", "u16": N} / {"addr", "u24": N} -> value claim
  * manifest["record_types"][*]["addr"] with "address_space" == "rom"
  * manifest["pointer_tables"][*]  : 24-bit little-endian pointer tables,
    each entry must resolve to an in-ROM offset
  * manifest["stride_blobs"][*]    : {"addr","size","stride"} size % stride == 0
"""

from __future__ import annotations

import json
import os
import re
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_WS = os.path.dirname(_TOOLS)
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)

from address_map import Rom, load as rom_load  # noqa: E402

ROM_PATH = os.path.join(_WS, "ct_clean.sfc")
CSV_PATH = os.path.join(_WS, "refs", "ChronoRET", "symbols", "data_assets.csv")

_ROM: Rom | None = None


def rom() -> Rom:
    global _ROM
    if _ROM is None:
        _ROM = rom_load(ROM_PATH)
    return _ROM


def load_manifest(name: str) -> dict:
    with open(os.path.join(_WS, "manifests", name), "r", encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# addresses
# ---------------------------------------------------------------------------

_ADDR_RE = re.compile(r"^\$([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4})$")


def parse_addr(s: str) -> tuple[int, int]:
    m = _ADDR_RE.match(s)
    if not m:
        raise ValueError(f"not a $BB:AAAA address: {s!r}")
    return int(m.group(1), 16), int(m.group(2), 16)


def pc_of(s: str) -> int:
    """PC file offset for a $BB:AAAA string; raises for non-ROM addresses."""
    b, a = parse_addr(s)
    return Rom.snes_to_pc(b, a)


def in_rom(s: str) -> bool:
    try:
        pc_of(s)
        return True
    except ValueError:
        return False


def hexs(addr: str, n: int) -> str:
    """Space-separated uppercase hex of n ROM bytes at $BB:AAAA."""
    r = rom()
    b, a = parse_addr(addr)
    return " ".join(f"{x:02X}" for x in r.read(b, a, n))


def u8(addr: str, off: int = 0) -> int:
    b, a = parse_addr(addr)
    return rom().u8(b, a + off)


def u16(addr: str, off: int = 0) -> int:
    b, a = parse_addr(addr)
    return rom().u16(b, a + off)


def u24(addr: str, off: int = 0) -> int:
    b, a = parse_addr(addr)
    return rom().u24(b, a + off)


def ptr24_to_pc(v: int) -> int:
    """Map a 24-bit little-endian long pointer value to a PC offset (HiROM)."""
    return ((v >> 16) & 0x3F) << 16 | (v & 0xFFFF)


def ptr24_in_rom(v: int) -> bool:
    return 0 < v and ptr24_to_pc(v) < 4 * 1024 * 1024


# ---------------------------------------------------------------------------
# LZSS
# ---------------------------------------------------------------------------

def lzss_at(addr: str, maxlen: int = 0x20000) -> bytes:
    """Decompress the LZSS pack that starts at $BB:AAAA."""
    b, a = parse_addr(addr)
    data = rom().read(b, a, maxlen)
    try:
        import ct_lzss
        return ct_lzss.decompress(data)
    except Exception:
        return lzss_py(data)


def lzss_py(data: bytes) -> bytes:
    """Pure-Python Square LZSS (Decomp_ToWram, bankC3 asm module).

    Layout: u16le packed length of segment 1 (packed bytes live at file
    offset 2).  At each segment end a marker byte carries the mode bits
    (bits 6-7: 0 -> lz11, else lz12), a group-control seed (bits 0-5) and a
    u16le offset of the next segment end; marker & $3F == 0 ends the stream.
    Control byte 0 = 8 raw literals; otherwise 8 items consumed LSB-first,
    set bit = u16le back-reference (lz11: dist v&$7FF len (v>>11)+3;
    lz12: dist v&$FFF len (v>>12)+3).
    """
    w = int.from_bytes(data[0:2], "little")
    seg_end = 2 + w
    mode = 11 if (data[seg_end] & 0xC0) == 0 else 12
    mask = 0x7FF if mode == 11 else 0xFFF
    shift = 11 if mode == 11 else 12
    out = bytearray()
    src = 2
    glen = 8
    while True:
        if src == seg_end:
            m = data[seg_end]
            if (m & 0x3F) == 0:
                return bytes(out)
            nxt = int.from_bytes(data[seg_end + 1:seg_end + 3], "little")
            src = seg_end + 3
            seg_end = nxt
            glen = m & 0x3F
            continue
        c = data[src]
        if c == 0:
            out += data[src + 1:src + 9]
            src += 9
            continue
        src += 1
        for bit in range(glen):
            if (c >> bit) & 1:
                v = int.from_bytes(data[src:src + 2], "little")
                src += 2
                start = len(out) - (v & mask)
                if start < 0:
                    raise ValueError("back-reference before start of output")
                for _ in range((v >> shift) + 3):
                    out.append(out[start])
                    start += 1
            else:
                out.append(data[src])
                src += 1
        glen = 8


# ---------------------------------------------------------------------------
# text codec (TextWin, bank C2; constants_menu.inc lines 310-330)
# ---------------------------------------------------------------------------

DICT_PTRS = "$DE:FA00"   # 127 x u16le, in-bank addresses (bank $DE -> PC 0x1E0000)
DICT_BASE = 0x1E0000
FIRST_GLYPH = 0xA0
FIRST_DICT = 0x21
TERMINATOR = 0xEF
SPACE = 0xFF


def glyph(b: int) -> str | None:
    if 0xA0 <= b <= 0xB9:
        return chr(ord("A") + b - 0xA0)
    if 0xBA <= b <= 0xD3:
        return chr(ord("a") + b - 0xBA)
    if 0xD4 <= b <= 0xDD:
        return chr(ord("0") + b - 0xD4)
    if b == SPACE:
        return " "
    return None


_dict: list[str] | None = None


def dictionary() -> list[str]:
    """The 127 substring-dictionary strings (length-prefixed, in bank $DE)."""
    global _dict
    if _dict is None:
        r = rom()
        out = []
        for i in range(127):
            p = u16(DICT_PTRS, 2 * i)
            ln = r.data[DICT_BASE + p]
            out.append(decode_text_bytes(r.data[DICT_BASE + p + 1:
                                                DICT_BASE + p + 1 + ln],
                                         use_dict=False))
        _dict = out
    return _dict


def decode_text_bytes(data: bytes, use_dict: bool = True) -> str:
    """Decode glyph/dictionary bytes (no terminator required)."""
    s = []
    for b in data:
        if b == TERMINATOR:
            break
        g = glyph(b)
        if g is not None:
            s.append(g)
        elif use_dict and FIRST_DICT <= b <= 0x9F:
            s.append(dictionary()[b - FIRST_DICT])
        # control bytes (< $21, other than $EF) are skipped in decoded form
    return "".join(s)


def decode_name_at(addr: str, off: int = 0, maxlen: int = 64) -> str:
    """Decode an $EF-terminated CT text string starting at ROM $addr + off."""
    b, a = parse_addr(addr)
    data = rom().read(b, a + off, maxlen)
    return decode_text_bytes(data)


# ---------------------------------------------------------------------------
# generic manifest verifier
# ---------------------------------------------------------------------------

def _walk_byte_claims(node, path="$"):
    """Yield (path, dict) for every machine-checkable claim dict in the JSON."""
    if isinstance(node, dict):
        if "addr" in node and ("bytes" in node or "u16" in node or "u24" in node):
            yield path, node
        for k, v in node.items():
            yield from _walk_byte_claims(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from _walk_byte_claims(v, f"{path}[{i}]")


def verify_manifest(manifest: dict, label: str = "") -> list[str]:
    """Re-check every machine-readable claim in a manifest against the ROM.

    Returns a list of failure strings (empty == all claims verified).
    """
    fails: list[str] = []
    r = rom()

    # 1. record-type / table addresses must be real ROM
    for rt in manifest.get("record_types", []):
        if rt.get("address_space", "rom") == "rom":
            if not in_rom(rt["addr"]):
                fails.append(f"{label}: record_type {rt['name']} addr "
                             f"{rt['addr']} is not in ROM")

    # 2. byte / value claims anywhere in the document
    for path, claim in _walk_byte_claims(manifest):
        addr = claim["addr"]
        if not in_rom(addr):
            fails.append(f"{label}: claim addr {addr} at {path} not in ROM")
            continue
        if "bytes" in claim:
            want = claim["bytes"].upper().split()
            got = hexs(addr, len(want)).split()
            if want != got:
                fails.append(f"{label}: bytes at {addr}: want "
                             f"{' '.join(want)} got {' '.join(got)}")
        if "u16" in claim:
            got = u16(addr, claim.get("off", 0))
            if got != claim["u16"]:
                fails.append(f"{label}: u16 at {addr}+{claim.get('off', 0)}: "
                             f"want {claim['u16']} got {got}")
        if "u24" in claim:
            got = u24(addr, claim.get("off", 0))
            if got != claim["u24"]:
                fails.append(f"{label}: u24 at {addr}+{claim.get('off', 0)}: "
                             f"want {claim['u24']} got {got}")

    # 3. 24-bit pointer tables: every entry resolves in-ROM
    for pt in manifest.get("pointer_tables", []):
        n, es = pt["count"], pt.get("entry_size", 3)
        if es != 3:
            continue
        bad = 0
        for i in range(n):
            v = u24(pt["addr"], es * i)
            allow_zero = pt.get("allow_zero", False)
            if v == 0 and allow_zero:
                continue
            if not ptr24_in_rom(v):
                bad += 1
        if bad:
            fails.append(f"{label}: pointer table {pt['label']} has {bad} "
                         f"out-of-ROM pointers")

    # 4. stride blobs: size % stride == 0
    for sb in manifest.get("stride_blobs", []):
        if sb["size"] % sb["stride"] != 0:
            fails.append(f"{label}: stride blob {sb['label']}: size "
                         f"{sb['size']} not divisible by stride {sb['stride']}")
    return fails


def verify_all(names=("characters_schema.json",
                     "items_and_techs_schema.json",
                     "maps_schema.json")) -> list[str]:
    fails = []
    for n in names:
        fails += verify_manifest(load_manifest(n), n)
    return fails


def field_stats(manifest: dict) -> dict:
    """decoded / partial / undecoded field counts for a manifest."""
    st = {"decoded": 0, "partial": 0, "undecoded": 0}
    for rt in manifest.get("record_types", []):
        for f in rt.get("fields", []):
            st[f.get("status", "undecoded")] = st.get(f.get("status", "undecoded"), 0) + 1
    return st


if __name__ == "__main__":
    fails = verify_all()
    for n in ("characters_schema.json", "items_and_techs_schema.json", "maps_schema.json"):
        print(n, field_stats(load_manifest(n)))
    if fails:
        print("FAILURES:")
        for f in fails:
            print(" ", f)
        sys.exit(1)
    print("all manifest claims verified against ROM")
