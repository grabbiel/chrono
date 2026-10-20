#!/usr/bin/env python3
"""Phase 1 Step 1.1: ROM ingestion, header normalization, HiROM verification.

Reads the ROM from ./input/ (or a path argument), strips a 512-byte copier
header if present (file_size % 1024 == 512), verifies the internal HiROM
header fields, writes re_workspace/ct_clean.sfc and
re_workspace/manifests/rom_identity.json, and updates STATE.json.

Exit code 0 == all verifications passed.
"""
from __future__ import annotations

import hashlib
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))  # repo root (chrono/)
WS = os.path.join(ROOT, "re_workspace")

EXPECTED_TITLE = b"CHRONO TRIGGER       "
EXPECTED_MAP_MODE = 0x31   # FastROM + HiROM
EXPECTED_ROM_SIZE = 0x0C   # 4 MB / 32 Mbit
CLEAN_SIZE = 4 * 1024 * 1024


def state_update(patch: dict) -> None:
    path = os.path.join(WS, "STATE.json")
    state = {}
    if os.path.exists(path):
        with open(path) as f:
            state = json.load(f)
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(state.get(k), dict):
            state[k].update(v)
        else:
            state[k] = v
    with open(path, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)


def main() -> int:
    candidates = [sys.argv[1]] if len(sys.argv) > 1 else [
        os.path.join(ROOT, "input", "chrono_trigger.sfc"),
        os.path.join(ROOT, "original", "Chrono Trigger (USA).sfc"),
    ]
    src = next((c for c in candidates if os.path.exists(c)), None)
    if src is None:
        print("FATAL: no ROM found in ./input/ or ./original/", file=sys.stderr)
        return 2

    raw = open(src, "rb").read()
    size = len(raw)
    mod = size % 1024
    header_stripped = mod == 512
    data = raw[:-512] if header_stripped else raw

    checks: dict[str, dict] = {}

    def check(name: str, ok: bool, expected, got) -> None:
        checks[name] = {"ok": bool(ok), "expected": expected, "got": got}

    check("size_after_normalize", len(data) == CLEAN_SIZE, CLEAN_SIZE, len(data))

    # Internal SNES header (HiROM): at PC 0xFFB0..0xFFFF (bank $C0 alias $00).
    title = data[0xFFC0:0xFFD5]
    check("title_0FFC0", title == EXPECTED_TITLE, EXPECTED_TITLE.decode(), title.decode("latin-1"))
    map_mode = data[0xFFD5]
    check("map_mode_0FFD5", map_mode == EXPECTED_MAP_MODE, f"0x{EXPECTED_MAP_MODE:02X}", f"0x{map_mode:02X}")
    rom_size_byte = data[0xFFD7]
    check("rom_size_0FFD7", rom_size_byte == EXPECTED_ROM_SIZE, f"0x{EXPECTED_ROM_SIZE:02X}", f"0x{rom_size_byte:02X}")

    # Size byte 0x0C -> 2^0x0C KiB = 4 MB, consistent with file size.
    check("size_byte_matches", (1 << rom_size_byte) * 1024 == len(data), len(data), (1 << rom_size_byte) * 1024)

    # Complement checksum bytes at 0xFFDC/0xFFDE (little-endian; complement pairs sum to 0xFFFF).
    cmp_sum, cmp_comp = struct.unpack_from("<HH", data, 0xFFDC)
    check("complement_checksum", (cmp_sum + cmp_comp) & 0xFFFF == 0xFFFF, "x + ~x == 0xFFFF", f"0x{cmp_sum:04X} + 0x{cmp_comp:04X}")

    # Hardware vector area at $FF:FFE0-$FFFF is all zero in CT:
    # the CPU boots in emulation mode with PC=0 -> starts at $00:8000 (== $C0:8000).
    hw_vec = rom_area = struct.unpack_from("<16H", data, 0x3FFE0)
    check("hw_vectors_zero", all(v == 0 for v in hw_vec), "all $0000", f"{sum(hw_vec)} (sum of 16 words)")
    boot_op = data[0x8000]
    check("boot_entry_is_code", boot_op != 0xFF and boot_op != 0x00, "not FF/00 fill", f"op=0x{boot_op:02X} @ $C0:8000")
    # Game's own stub table at $C0:FFE0: emul-NMI $FFEA -> $FF10 = JML $000500.
    stub_table = struct.unpack_from("<16H", data, 0xFFE0)
    check("stub_nmi_jml", data[0xFF10:0xFF14] == bytes([0x5C, 0x00, 0x05, 0x00]),
          "JML $000500 @ $FF10", data[0xFF10:0xFF14].hex())

    ok = all(c["ok"] for c in checks.values())

    clean_path = os.path.join(WS, "ct_clean.sfc")
    if ok:
        with open(clean_path, "wb") as f:
            f.write(data)

    identity = {
        "source": os.path.relpath(src, ROOT),
        "source_size": size,
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "copier_header_stripped": header_stripped,
        "clean_size": len(data),
        "clean_sha256": hashlib.sha256(data).hexdigest() if ok else None,
        "map_mode": "HiROM FastROM (0x31)",
        "internal_title": title.decode("latin-1"),
        "checksum_bytes": {"sum": f"0x{cmp_sum:04X}", "complement": f"0x{cmp_comp:04X}"},
        "hardware_vectors_FF_FFE0": "all 16 words $0000 (boot PC -> $00:8000)",
        "boot_entry": "$C0:8000 (hardware vectors are zero; emulation boot PC=$0000)",
        "vector_stub_table_C0_FFE0": {
            f"$C0:{0xFFE0 + 2 * i:04X}": f"$C0:{v:04X}" for i, v in enumerate(stub_table)
        },
        "checks": checks,
        "all_passed": ok,
    }
    os.makedirs(os.path.join(WS, "manifests"), exist_ok=True)
    with open(os.path.join(WS, "manifests", "rom_identity.json"), "w") as f:
        json.dump(identity, f, indent=2)

    for name, c in checks.items():
        print(f"{'PASS' if c['ok'] else 'FAIL'}  {name}: expected {c['expected']} got {c['got']}")
    print(f"\nclean image: {clean_path if ok else 'NOT WRITTEN'}")
    state_update({
        "phases": {"phase1_step1_1_ingestion": "verified" if ok else "FAILED"},
        "rom": {
            "clean_path": "re_workspace/ct_clean.sfc",
            "clean_sha256": identity["clean_sha256"],
            "size": len(data),
            "map_mode": "HiROM FastROM",
            "boot_entry": "$C0:8000",
        },
    })
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
