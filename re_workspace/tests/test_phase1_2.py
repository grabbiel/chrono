"""Phase 1 Step 1.2 tests: state-aware 65c816 recursive disassembler + manifests.

Run from the repo root:
    re_workspace/.venv/bin/pytest re_workspace/tests/test_phase1_2.py -q
"""

from __future__ import annotations

import json
import os
import struct
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # re_workspace/
TOOLS = os.path.join(ROOT, "tools")
REFS = os.path.join(ROOT, "refs")
sys.path.insert(0, TOOLS)

import c816_dis as D  # noqa: E402
import opc816  # noqa: E402
from address_map import Rom, load  # noqa: E402

ROM_PATH = os.path.join(ROOT, "ct_clean.sfc")
VECTORS_PATH = os.path.join(ROOT, "manifests", "engine_vectors.json")
COVERAGE_PATH = os.path.join(ROOT, "manifests", "disasm_coverage.json")
BANKC0_ASM = os.path.join(REFS, "ChronoRET", "asm", "bankC0", "bankC0.asm")


@pytest.fixture(scope="module")
def rom() -> Rom:
    return load(ROM_PATH)


@pytest.fixture(scope="module")
def dis(rom) -> D.Disassembler:
    """Full seeded traversal (module-scoped; ~15s once)."""
    return D.build(rom)


# ---------------------------------------------------------------------------
# (a) boot prologue at $C0:8000: correct instruction lengths, cross-checked
#     against the ChronoRET bankC0.asm listing (Sub_C07F9A covers $7F9A-$813C).
# ---------------------------------------------------------------------------

def parse_chronoret_block(path: str, label: str) -> list[str]:
    """Mnemonics (normalized, no operands) of the instructions in a ChronoRET
    function block, from its label until the next org/top-level line."""
    lines = open(path, encoding="utf-8").read().split("\n")
    start = next(i for i, l in enumerate(lines) if l.startswith(f"{label}:"))
    out = []
    for l in lines[start + 1:]:
        if l.startswith("org ") or (l and not l[0].isspace() and not l.startswith(";")):
            break
        s = l.split(";")[0].strip()
        if s:
            out.append(s)
    return out


def norm_mnemonics(instrs: list[str]) -> list[str]:
    return [i.split()[0].upper().split(".")[0] for i in instrs]


def test_boot_prologue_sizes_and_mnemonics(rom, dis):
    mini = D.Disassembler(rom, blocklist=D.Blocklist())
    prologue = mini.decode_linear(0xC0, 0x8000, m=False, x=False, nbytes=20)
    sizes = [i.size for i in prologue]
    mnemonics = [i.mnemonic for i in prologue]
    # 20-byte prologue: tya clc adc $7c sta $ad lda $6c sta $e1 lda $6e
    # sta $e3 ply lda $99 clc adc #$0020 (16-bit imm: M=0)
    assert sizes[:11] == [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 1]
    assert sum(sizes[:11]) == 18
    assert mnemonics[:11] == ["tya", "clc", "adc", "sta", "lda", "sta",
                              "lda", "sta", "ply", "lda", "clc"]
    # the 12th instruction is the 16-bit-immediate ADC at $C0:8012 (3 bytes)
    adc = prologue[11]
    assert (adc.addr, adc.mnemonic, adc.size, adc.operand) == (0x8012, "adc", 3, 0x0020)
    assert rom.data[0x8012:0x8015] == bytes([0x69, 0x20, 0x00])
    assert sum(sizes) >= 20
    # the full seeded traversal traces it identically
    assert dis.insts[0x8012].size == 3
    assert dis.insts[0x8012].mnemonic == "adc"


def test_boot_prologue_matches_chronoret_listing(rom):
    block = norm_mnemonics(parse_chronoret_block(BANKC0_ASM, "Sub_C07F9A"))
    # the $C0:8000 prologue appears verbatim inside the listing block
    expected = ["TYA", "CLC", "ADC", "STA", "LDA", "STA", "LDA", "STA",
                "PLY", "LDA", "CLC", "ADC", "AND", "JSR"]
    assert any(block[i:i + len(expected)] == expected
               for i in range(len(block) - len(expected)))
    # ChronoRET writes the ADC after PLY/LDA/CLC with a WIDE immediate
    # (ADC.w #!Bg_ScreenWidth) => 16-bit operand => 3-byte instruction,
    # exactly what the M=0 state decode produces at $C0:8012.
    raw = parse_chronoret_block(BANKC0_ASM, "Sub_C07F9A")
    nrm = norm_mnemonics(raw)
    idx = next(i for i in range(len(nrm) - 5)
               if nrm[i:i + 6] == ["PLY", "LDA", "CLC", "ADC", "AND", "JSR"])
    assert raw[idx + 3].upper().startswith("ADC.W"), raw[idx + 3]


# ---------------------------------------------------------------------------
# (b) Evt_OpcodeTable structure
# ---------------------------------------------------------------------------

def test_evt_opcode_table(rom, dis):
    tbl = [struct.unpack_from("<H", rom.data, 0x5D6E + 2 * i)[0] for i in range(256)]
    distinct = set(tbl)
    assert len(distinct) == 225
    assert tbl.count(0x5F6E) == 32  # 32 unused opcodes -> Evt_UnusedOpcode halt
    assert all(t != 0 for t in tbl)
    assert D.evt_opcode_targets(rom) == sorted(distinct)
    # the four opcode-$FC dispatch sites
    for off in (0x5910, 0x5977, 0x59A0, 0x5AB1):
        assert rom.data[off:off + 3] == bytes([0xFC, 0x6E, 0x5D])
        assert dis.insts[off].mnemonic == "jsr"
        assert dis.insts[off].mode == "indirectX"
    # every distinct target traced as code by the seeded traversal
    assert all(w in dis.insts for w in distinct)


# ---------------------------------------------------------------------------
# (c) JSL $C3:0002 decompressor call sites
# ---------------------------------------------------------------------------

def test_jsl_decomp_sites(rom):
    sites = D.jsl_decomp_sites(rom)
    assert len(sites) == 42
    assert len(set(sites)) == 42
    assert sites[0] == 0x0A0F  # first: $C0:0A0F
    for pc in sites:
        assert rom.data[pc:pc + 4] == bytes([0x22, 0x02, 0x00, 0xC3])
        assert 0 <= pc < len(rom.data)


# ---------------------------------------------------------------------------
# (d) SEP/REP state tracking on a hand-assembled synthetic sequence
# ---------------------------------------------------------------------------

def test_sep_rep_immediate_widths(rom):
    # at PC $C7:FF00 (in-memory patch only):
    #   SEP #$20 / LDA #$34 / SEP #$10 / CPX #$42 / REP #$30 / LDA #$5678 /
    #   CPX #$1234 / RTS
    # entered with M=0 (16-bit A), X=0 (16-bit X):
    # after SEP #$20 the LDA immediate is 1 byte (2-byte insn);
    # after SEP #$10 the CPX immediate is 1 byte;
    # after REP #$30 both immediates are 2 bytes (3-byte insns).
    code = bytes([0xE2, 0x20, 0xA9, 0x34, 0xE2, 0x10, 0xE0, 0x42,
                  0xC2, 0x30, 0xA9, 0x78, 0x56, 0xE0, 0x34, 0x12, 0x60])
    patched = bytearray(rom.data)
    patched[0x07FF00:0x07FF00 + len(code)] = code
    synth = Rom(bytes(patched))
    mini = D.Disassembler(synth, blocklist=D.Blocklist())
    mini.seed(0xC7, 0xFF00, False, False, "synthetic")
    mini.run()
    got = [mini.insts[0x07FF00 + off] for off in
           (0, 2, 4, 6, 8, 10, 13, 16)]
    assert [i.mnemonic for i in got] == ["sep", "lda", "sep", "cpx",
                                         "rep", "lda", "cpx", "rts"]
    assert [i.size for i in got] == [2, 2, 2, 2, 2, 3, 3, 1]
    assert [i.operand for i in got] == [0x20, 0x34, 0x10, 0x42, 0x30,
                                        0x5678, 0x1234, None]
    # explicit widths: LDA #imm is 2 bytes with M=1, 3 bytes with M=0
    assert got[1].size == 2 and got[5].size == 3
    # state at the RTS reflects SEP/REP propagation
    root = mini.functions[0x07FF00]
    assert (False, False) in root["exit_states"]
    # and the vendored table agrees with the traversal
    assert opc816.operand_size("immediateA", True, True) == 1
    assert opc816.operand_size("immediateA", False, False) == 2
    assert opc816.operand_size("immediateX", True, True) == 1
    assert opc816.operand_size("immediateX", False, False) == 2


# ---------------------------------------------------------------------------
# (e) engine_vectors.json validity + byte evidence
# ---------------------------------------------------------------------------

def test_engine_vectors(rom):
    assert os.path.exists(VECTORS_PATH), "run tools/c816_dis.py to generate manifests"
    vectors = json.load(open(VECTORS_PATH))
    subs = vectors["subsystems"]
    for name in ("main_loop_and_state_dispatcher", "dma_hdma_transfer_queues",
                 "global_decompression", "location_event_bytecode_interpreter",
                 "spc700_communication_driver"):
        assert name in subs and subs[name]
    assert vectors["discrepancies"]  # cross-check notes present
    n_entries = 0
    for entries in subs.values():
        for e in entries:
            n_entries += 1
            for key in ("label", "snes", "pc", "evidence"):
                assert key in e, e
            pc = e["pc"]
            assert isinstance(pc, int) and 0 <= pc < len(rom.data)
            bank, addr = D.parse_snes(e["snes"])
            assert Rom.snes_to_pc(bank, addr) == pc  # snes/pc consistent, in-ROM
            if e.get("bytes"):
                claimed = bytes.fromhex(e["bytes"])
                assert rom.data[pc:pc + len(claimed)] == claimed, e["label"]
    assert n_entries > 80
    decomp = subs["global_decompression"]
    jsl_entries = [e for e in decomp if e["label"].startswith("JSL_")]
    assert len(jsl_entries) == 42
    assert {e["pc"] for e in jsl_entries} == set(D.jsl_decomp_sites(rom))
    evt = subs["location_event_bytecode_interpreter"]
    assert sum(1 for e in evt if "Dispatch@" in e["label"]) == 4
    dma = subs["dma_hdma_transfer_queues"]
    assert any(e["snes"] == "$C0:0B5D" for e in dma)  # first BDMAEN write
    assert any(e["snes"] == "$C0:0B60" for e in dma)  # first HDMAEN write
    assert any(e["snes"] == "$C2:001C" for e in dma)
    assert any(e["label"] == "VramQ_Flush" for e in dma)
    assert any(e["label"] == "NmiHandler" for e in dma)
    spc = subs["spc700_communication_driver"]
    assert any(e["snes"] == "$C7:0038" and e["label"] == "Audio_Boot" for e in spc)
    assert any(e["snes"] == "$C7:0000" for e in spc)


def test_coverage_manifest(rom, dis):
    cov = json.load(open(COVERAGE_PATH))
    assert cov["self_check"]["all_pass"] is True
    assert all(c["pass"] for c in cov["self_check"]["checks"])
    assert sum(b["code_bytes"] for b in cov["per_bank"].values()) == cov["total_code_bytes"]
    assert cov["total_instructions"] > 50000  # thousands of instructions, banks C0-C7+FD
    assert cov["per_bank"]["C0"]["instructions"] > 20000
    assert cov["functions"] > 1000
    assert cov["entry_state_distribution"]
    # the Evt_OpcodeTable dispatch table was discovered by jump-table following
    tables = {t["snes"]: t for t in cov["jump_tables"]}
    assert "$C0:5D6E" in tables
    assert tables["$C0:5D6E"]["seeded"] == 256
