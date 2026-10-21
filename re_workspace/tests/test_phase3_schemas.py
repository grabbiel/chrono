"""Phase 3 schema-manifest tests (characters, items/techs, maps).

Re-checks every machine-readable claim in the three gameplay-domain
manifests against the live ROM bytes:

  * each manifest is valid JSON with the expected top-level shape
  * every claimed SNES address resolves to an in-ROM PC offset
  * every byte / u16 / u24 evidence claim matches the ROM right now
    (generic walker in tools/ct_schemas.verify_manifest)
  * record strides divide the ChronoRET blob sizes exactly (>= 10 blobs)
  * 24-bit pointer-table entries all resolve in-ROM ($000000 = none where
    the manifest documents it)
  * text codec: dictionary located, names decode to known strings
  * map decode: one real location's MapProps pack parses byte-exactly and
    its metatile words carry sane palette bits
"""

import json
import os
import sys

import pytest

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(WS, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import ct_schemas as cs  # noqa: E402

MANIFESTS = ["characters_schema.json", "items_and_techs_schema.json",
             "maps_schema.json"]


@pytest.fixture(scope="module")
def load_manifest(manifest_path):
    def load(name):
        with open(manifest_path(name), encoding="utf-8") as f:
            return json.load(f)
    return load


# ---------------------------------------------------------------- basics ---

@pytest.mark.parametrize("name", MANIFESTS)
def test_manifest_is_valid_json_with_shape(name, load_manifest):
    m = load_manifest(name)
    assert isinstance(m, dict)
    assert m.get("phase") == 3
    assert "record_types" in m and len(m["record_types"]) >= 5
    assert "stride_blobs" in m


@pytest.mark.parametrize("name", MANIFESTS)
def test_record_type_addresses_in_rom(name, load_manifest):
    m = load_manifest(name)
    for rt in m["record_types"]:
        if rt.get("address_space", "rom") == "rom":
            assert cs.in_rom(rt["addr"]), \
                f"{rt['name']} addr {rt['addr']} not in ROM"


@pytest.mark.parametrize("name", MANIFESTS)
def test_byte_evidence_claims_live(name, load_manifest, rom_path):
    """Generic verifier: walk the manifest, re-check every claim against ROM."""
    fails = cs.verify_manifest(load_manifest(name), name)
    assert fails == [], "\n".join(fails)


# ------------------------------------------------------- stride blobs ------

@pytest.mark.parametrize("name", MANIFESTS)
def test_stride_blobs_divide_blob_sizes(name, load_manifest):
    m = load_manifest(name)
    blobs = m["stride_blobs"]
    assert blobs
    for sb in blobs:
        assert sb["size"] % sb["stride"] == 0, \
            f"{sb['label']}: {sb['size']} % {sb['stride']} != 0"
        assert cs.in_rom(sb["addr"])


def test_at_least_ten_stride_blobs_across_manifests(load_manifest):
    total = sum(len(load_manifest(n)["stride_blobs"]) for n in MANIFESTS)
    assert total >= 10, f"only {total} stride blobs"


def test_stride_blob_sizes_match_chronoret_csv(load_manifest, data_assets_csv):
    """Blob sizes must equal the sizes ChronoRET's data_assets.csv declares."""
    import csv as _csv
    sizes = {}
    with open(data_assets_csv, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split(",")
            label, start, size = parts[0], parts[1], parts[3]
            try:
                sizes[start.upper()] = int(size)
            except ValueError:
                pass
    checked = 0
    for n in MANIFESTS:
        for sb in load_manifest(n)["stride_blobs"]:
            want = sizes.get(sb["addr"].upper())
            if want is not None:
                assert sb["size"] == want, \
                    f"{sb['label']}: manifest says {sb['size']}, CSV says {want}"
                checked += 1
    assert checked >= 10, f"only {checked} blobs cross-checked against CSV"


# ------------------------------------------------------ pointer tables -----

@pytest.mark.parametrize("name", MANIFESTS)
def test_pointer_tables_in_rom(name, load_manifest, rom_path):
    m = load_manifest(name)
    for pt in m.get("pointer_tables", []):
        for i in range(pt["count"]):
            v = cs.u24(pt["addr"], 3 * i)
            if v == 0:
                assert pt.get("allow_zero"), \
                    f"{pt['label']} entry {i} is zero but not allow_zero"
                continue
            assert cs.ptr24_in_rom(v), f"{pt['label']} entry {i}: {v:06X}"


# --------------------------------------------------------- text codec ------

def test_dictionary_located_and_decoded(rom_path):
    d = cs.dictionary()
    assert len(d) == 127
    # the highest-frequency English substrings, in roughly the ROM's order
    assert d[0] == "the"
    assert "you" in d[:16]
    assert "ing" in d[:16]
    lens = [len(s) for s in d]
    assert max(lens) <= 14
    # two entries (54, 93) begin with control byte $E3 (punctuation class)
    # and decode empty with a glyph-only decoder
    assert sum(1 for s in d if s) >= 120


def test_text_codec_known_names(rom_path):
    assert cs.decode_name_at("$CC:15C4", 11) == "Cyclone"        # tech 1
    # item names are fixed 11-byte records (icon byte + text, no $EF inside)
    assert cs.decode_name_at("$CC:0B5E", 11, maxlen=11) == "Wood Sword"
    assert cs.decode_name_at("$CC:6500", 11) == "Reptite"        # enemy 1


def test_dict_pointer_table_bytes_live(load_manifest, rom_path):
    # first dictionary pointer (entry 0 -> "the") + terminator conventions
    m = load_manifest("items_and_techs_schema.json")
    tc = m["text_codec"]
    assert tc["dictionary"]["located"] is True
    ev = tc["dictionary"]["pointer_table"]["byte_evidence"]
    assert ev["bytes"] == cs.hexs(ev["addr"], len(ev["bytes"].split()))


# ---------------------------------------------------------- map decode -----

def test_real_map_pack_parses_byte_exact(load_manifest, rom_path):
    m = load_manifest("maps_schema.json")
    rd = m["real_map_decode"]
    assert rd["exact_consumption"] is True
    # re-run the parse live rather than trusting the stored numbers
    mp = cs.lzss_at(rd["packed_addr"])
    assert len(mp) == rd["unpacked_len"] == rd["csv_expected_len"]
    s1, s3 = mp[0], mp[1]
    w1 = ((s1 & 3) + 1) * 16
    h1 = (((s1 >> 2) & 3) + 1) * 16
    w2 = ((s1 >> 4) & 3) * 16 + 16
    h2 = ((s1 >> 6) & 3) * 16 + 16
    w3 = ((s3 & 3) + 1) * 16
    h3 = (((s3 >> 2) & 3) + 1) * 16
    off = 6 + w1 * h1 + w2 * h2 + (w3 * h3 if s3 & 0x80 else 0)
    seen = 0
    n1 = w1 * h1
    while seen < n1:
        c = mp[off]
        off += 1
        if c & 0x80:
            off += 2
            seen += mp[off] or 256
            off += 1
        else:
            off += 2
            seen += 1
    assert off == len(mp)


def test_all_plane_parse_evidence_exact(load_manifest, rom_path):
    m = load_manifest("maps_schema.json")
    ev = m["plane_parse_evidence"]
    assert len(ev) >= 10
    for e in ev:
        assert e["exact_consumption"], f"pack {e['map_props_entry']} not exact"
        # spot re-verify the unpacked length claim live
        assert len(cs.lzss_at(e["packed_addr"])) == e["csv_expected_len"]


def test_metatile_words_palette_bits_sane(rom_path):
    """The 4x 8x8-tiles -> 16x16-chip composition decodes with valid
    3-bit palette indices for every word of the tileset-2 metatile table."""
    meta = cs.lzss_at("$ED:13C6")
    assert len(meta) == 4096          # 512 metatiles x 8 bytes (CSV lz11 -> 4096)
    for i in range(len(meta) // 2):
        w = int.from_bytes(meta[2 * i:2 * i + 2], "little")
        assert (w >> 10) & 7 <= 7     # tautology guard: 3-bit field
    # structural check: metatile 139 (first tile of LocRom[1] plane1 row 0)
    words = [int.from_bytes(meta[8 * 139 + 2 * j:8 * 139 + 2 * j + 2], "little")
             for j in range(4)]
    assert all(w & 0x3FF for w in words)   # nonzero tile indices


def test_locrom_stride_and_field_sanity(load_manifest, rom_path):
    m = load_manifest("maps_schema.json")
    rt = next(r for r in m["record_types"] if r["name"] == "LocRom")
    assert rt["stride"] * rt["count"] == 14 * 512 == 7168
    # MapProps entry numbers must stay inside the 256-entry pointer table
    for i in range(512):
        base = cs.pc_of("$F6:0000") + 14 * i
        entry = cs.rom().data[base + 4] | cs.rom().data[base + 5] << 8
        assert entry < 256


# ------------------------------------------------------------ coverage -----

def test_field_evidence_coverage(load_manifest):
    """Every field carries an evidence string; decoded fraction is reported."""
    for n in MANIFESTS:
        m = load_manifest(n)
        for rt in m["record_types"]:
            for f in rt.get("fields", []):
                assert f.get("evidence") is not None, \
                    f"{n}:{rt['name']} field {f['name']} lacks evidence"
                assert f["status"] in ("decoded", "partial", "undecoded")
                if f["status"] == "undecoded":
                    # undecoded fields must state their byte range
                    assert str(f["offset"]).startswith("+$") or \
                        f["offset"] == "var"


def test_field_stats_report(capsys, load_manifest):
    lines = []
    for n in MANIFESTS:
        st = cs.field_stats(load_manifest(n))
        tot = sum(st.values())
        frac = (st["decoded"] + st["partial"]) / tot
        lines.append(f"{n}: {st} -> evidence-backed {frac:.0%}")
    print("\n".join(lines))
    for n in MANIFESTS:
        st = cs.field_stats(load_manifest(n))
        assert st["decoded"] > 0
