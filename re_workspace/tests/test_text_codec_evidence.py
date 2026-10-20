"""Live-ROM checks for the TextWin profile and cross-language integration corpus."""

import sys
from pathlib import Path

import pytest

WS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WS / "tools"))
import ct_text_profile as profile  # noqa: E402


@pytest.fixture(scope="module")
def built():
    return profile.build(profile.read_rom())


@pytest.mark.parametrize("index,path", [
    (0, profile.ASSETS / "text_profile.json"),
    (1, profile.ASSETS / "message_corpus.json"),
    (2, profile.MANIFEST),
])
def test_generated_outputs_match_current_rom_and_sources(built, index, path):
    assert path.is_file(), "Run re_workspace/tools/ct_text_profile.py to generate local assets"
    assert path.read_text() == profile.serialize(built[index])


def test_profile_schema_and_dictionary_pointer_extent(built):
    data, _, evidence = built
    assert set(data) == {"schema", "romSHA256", "dictionary"}
    assert data["schema"] == "ct-text-us/1"
    assert data["romSHA256"] == profile.ROM_SHA256
    assert len(data["dictionary"]) == 128
    assert evidence["dictionary"]["extendedEntry127Bytes"] == [0x12, 0x68]
    assert evidence["dictionary"]["greedySkippedIndices"] == [116, 117, 118]
    assert all(0x1EFB00 <= item["entryPC"] < 0x1EFD01
               for item in evidence["dictionary"]["entries"])


def test_all_33_dispatch_pointers_are_verified(built):
    table = built[2]["controlTable"]
    assert table["pc"] == 0x25903
    assert table["matchedPointers"] == len(table["entries"]) == 33
    assert [row["code"] for row in table["entries"] if row["operandBytes"]] == [1, 2, 3, 0x12]
    assert table["entries"][0]["handler"] == "TextWin_CodeSetStatus"


def test_rom_dispatch_mutation_fails_verification():
    rom = bytearray(profile.read_rom())
    rom[0x25903] ^= 1
    with pytest.raises(ValueError, match="Control 00"):
        profile.control_evidence(rom, profile.reference_codec())


def test_wrong_rom_fails_before_extraction():
    with pytest.raises(ValueError, match="identity"):
        profile.build(bytes(32))


def test_pointer_and_unreferenced_coverage_is_explicit(built):
    _, corpus, evidence = built
    assert len(evidence["messageTables"]) == 15
    assert sum(t["pointerCount"] for t in evidence["messageTables"]) == 4579
    assert evidence["pointerCases"] == 4579
    assert len(corpus["cases"]) == evidence["corpusCases"] == 4581
    assert len({case["label"] for case in corpus["cases"]}) == 4581
    spans = [span for table in evidence["messageTables"] for span in table["unreferencedSpans"]]
    assert [(span["pc"], span["byteCount"]) for span in spans] == [(0x1EE8EC, 9), (0x3CD9AC, 1)]
    assert evidence["malformedOrOmittedCases"] == 0


def test_corpus_has_byte_exact_reference_text_without_formatting_newlines(built):
    codec = profile.reference_codec()
    dictionary = codec.Dictionary([bytes(entry) for entry in built[0]["dictionary"]])
    for case in built[1]["cases"]:
        assert "\n" not in case["text"], case["label"]
        assert codec.decode_msg(bytes(case["bytes"]), dictionary).replace("\n", "") == case["text"]
        assert codec.encode_msg(case["text"], dictionary, case["label"]) == bytes(case["bytes"])


@pytest.mark.parametrize("data", [
    bytes([0xEF, 0xFF, 0x00]),  # Two different blanks and the real terminator.
    bytes([0x12, 0x68, 0x00]),  # Dictionary entry 127 through extended control.
    bytes([0x01, 0x00, 0x02, 0xEF, 0x03, 0x00, 0x00]),  # Operand 00 is not END.
    bytes([0x95, 0x96, 0x97, 0x00]),  # Entries excluded from greedy compression.
    bytes([0xCD, 0xC1, 0xBE, 0x00]),  # Literal spelling of dictionary entry 0.
])
def test_boundary_and_noncanonical_runs_remain_lossless(built, data):
    codec = profile.reference_codec()
    dictionary = codec.Dictionary([bytes(entry) for entry in built[0]["dictionary"]])
    decoded = codec.decode_msg(data, dictionary).replace("\n", "")
    assert codec.encode_msg(decoded, dictionary, "boundary") == data
    if data[0] == 0xEF:
        assert decoded == " _{end}"
    if data[0] in (0x95, 0xCD):
        assert "«" in decoded


def test_manifest_contains_metadata_only(built):
    evidence = built[2]
    assert all(set(source) == {"path", "sha256"} for source in evidence["sources"])
    assert "cases" not in evidence
    assert all("text" not in entry and "bytes" not in entry
               for entry in evidence["dictionary"]["entries"])
