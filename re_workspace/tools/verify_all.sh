#!/bin/bash
# verify_all.sh — Chrono-Forge master verification gate.
# Independently re-runs every phase gate. Exit 0 only if ALL gates pass.
set -u
cd "$(dirname "$0")/../.."   # repo root (chrono/)
PY=re_workspace/.venv/bin/python
# Local S-SMP IPL image for the real-firmware lane; never bundled or published.
if [ -z "${CHRONOFORGE_IPL_ROM:-}" ] && [ -f re_workspace/refs/ipl/snes9x-ipl.rom ]; then
  export CHRONOFORGE_IPL_ROM="$PWD/re_workspace/refs/ipl/snes9x-ipl.rom"
fi
FAILED=0
note() { printf '%-46s %s\n' "$1" "$2"; [ "$2" = FAIL ] && FAILED=1; }

# Phase 1.1 — ingestion
$PY re_workspace/tools/normalize.py >/dev/null 2>&1; note "P1.1 normalize.py exit0" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"

# Phase 1-3 pytest suites (whatever exists)
$PY -m pytest re_workspace/tests -q >/tmp/verify_pytest.log 2>&1
RC=$?; N=$(grep -oE '[0-9]+ passed' /tmp/verify_pytest.log | tail -1)
note "pytest re_workspace/tests ($N)" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"

# LZSS: the packer rebuilds every packed block and event stream byte for byte
$PY re_workspace/tools/verify_lzss_corpus.py >/tmp/verify_lzss.log 2>&1
note "LZSS packer byte-exact (1053 + 463 streams)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
# ROM layout facts for the .sfc builder (free space, packs, checksum) vs the ROM
$PY re_workspace/tools/ct_rom_layout.py check >/tmp/verify_rom_layout.log 2>&1
note "ROM layout manifest + Swift twin" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
# SPC700 songs: driver tables vs ChronoRET, every song through a ct-song/1 listing
$PY re_workspace/tools/ct_spc_seq.py check >/tmp/verify_spc_seq.log 2>&1
RC=$?
note "SPC song sequences ($(grep -oE '^[0-9]+ songs' /tmp/verify_spc_seq.log) byte-exact)" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"

# Manifest integrity: every manifest parses; every claimed pc in-ROM
$PY - <<'EOF' || exit 1
import json, glob, re, sys
rom_size = 4*1024*1024
bad = []
for f in glob.glob('re_workspace/manifests/*.json'):
    try:
        d = json.load(open(f))
    except Exception as e:
        bad.append((f, f'PARSE: {e}')); continue
    txt = json.dumps(d)
    for m in re.finditer(r'0x([0-9A-Fa-f]{4,6})\b', txt):
        v = int(m.group(1), 16)
        if 'sha256' in txt[max(0,m.start()-40):m.start()]:
            continue
        if v > rom_size:
            bad.append((f, f'pc out of ROM: 0x{v:X}'))
print('manifests checked:', len(glob.glob('re_workspace/manifests/*.json')))
if bad:
    [print('BAD', *b) for b in bad[:10]]; sys.exit(1)
EOF
note "manifests parse + pc sanity" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"

# Phase 5 gates (only if the package exists)
if [ -f macos_studio/Package.swift ]; then
  (cd macos_studio && swift build >/tmp/verify_swiftbuild.log 2>&1); note "swift build" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  SPC_VECTORS="${CHRONOFORGE_SPC700_VECTORS:-$PWD/re_workspace/refs/processor-tests/spc700/spc700/v1}"
  if [ -d "$SPC_VECTORS" ]; then
    $PY macos_studio/tools/prepare_spc700_vectors.py "$SPC_VECTORS" --check >/tmp/verify_spc700_fixture.log 2>&1
    note "SPC700 pinned corpus + bundled sample" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
    CHRONOFORGE_SPC700_VECTORS="$SPC_VECTORS" swift test --package-path macos_studio >/tmp/verify_swifttest.log 2>&1
    note "swift test (full SPC700 corpus included)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  else
    swift test --package-path macos_studio >/tmp/verify_swifttest.log 2>&1
    note "swift test (bundled SPC700 sample)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
    echo "SPC700 full corpus not installed; extended test skipped"
  fi
  $PY macos_studio/tools/verify_scene_cli.py >/tmp/verify_scene_cli.log 2>&1
  note "scene CLI integration" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  # CT text: Swift CLI extracts its own profile from the ROM, then re-encodes every corpus case.
  TXT=$(mktemp -d)
  macos_studio/.build/debug/chronoforge text profile re_workspace/ct_clean.sfc --out "$TXT/profile.json" >/tmp/verify_text_cli.log 2>&1 &&
    macos_studio/.build/debug/chronoforge text verify-corpus re_workspace/assets/text/message_corpus.json \
      --profile "$TXT/profile.json" >>/tmp/verify_text_cli.log 2>&1
  RC=$?; rm -rf "$TXT"
  note "text CLI ROM corpus ($(grep -oE '^[0-9]+ ROM text cases' /tmp/verify_text_cli.log | cut -d' ' -f1))" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  # CT events: Swift decodes every ROM pack to the handler-traced records and
  # reassembles it; lowered scenes are executed through the ROM's handlers.
  macos_studio/.build/debug/chronoforge event verify-rom re_workspace/ct_clean.sfc \
    --manifest re_workspace/manifests/event_pack_verification.json >/tmp/verify_event_cli.log 2>&1
  RC=$?
  note "event CLI ROM packs ($(grep -oE '^[0-9]+ event packs' /tmp/verify_event_cli.log | cut -d' ' -f1))" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  $PY macos_studio/tools/verify_event_lowering.py >/tmp/verify_event_lowering.log 2>&1
  note "event lowering vs ROM handlers" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  # Songs: the Swift CLI's listings equal the Python twin's for every ROM song.
  $PY macos_studio/tools/verify_music.py >/tmp/verify_music.log 2>&1
  RC=$?
  note "music CLI ROM songs ($(grep -oE '^[0-9]+ songs' /tmp/verify_music.log | cut -d' ' -f1))" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  $PY macos_studio/tools/verify_ssmp_driver.py --lane direct >/tmp/verify_ssmp_driver.log 2>&1
  note "S-SMP bus + CT driver execution CLI" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  if [ -n "${CHRONOFORGE_IPL_ROM:-}" ]; then
    $PY macos_studio/tools/verify_ssmp_driver.py --lane ipl >/tmp/verify_ssmp_ipl.log 2>&1
    note "S-SMP IPL upload + CT driver (local IPL)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  else
    note "S-SMP IPL upload + CT driver (local IPL)" "UNVERIFIED"
  fi
  # Song + samples through the driver's own command protocol, checked against
  # an independent Python transcription of the bank C7 sender; the lane adds an
  # IPL-boot comparison when CHRONOFORGE_IPL_ROM is set.
  $PY macos_studio/tools/verify_ssmp_driver.py --lane transfer >/tmp/verify_ssmp_transfer.log 2>&1
  RC=$?
  note "S-SMP song/sample transfer CLI$([ -n "${CHRONOFORGE_IPL_ROM:-}" ] && echo ' (direct + local IPL)')" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  # S-DSP PCM after the song load: WAV/report/snapshot checks and CLI refusals.
  $PY macos_studio/tools/verify_ssmp_driver.py --lane render >/tmp/verify_ssmp_render.log 2>&1
  note "S-DSP music render CLI" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  # S-DSP against libgme (external, never bundled): Gaussian table, bit-exact
  # probes, key-on/timer sweeps, CT songs. UNVERIFIED without libgme or the ROM.
  $PY macos_studio/tools/compare_libgme.py >/tmp/verify_libgme.log 2>&1
  case $? in 0) R=PASS;; 3) R=UNVERIFIED;; *) R=FAIL;; esac
  note "S-DSP PCM vs libgme (probes, sweeps, songs)" "$R"
  # .sfc builder: CLI build of a lowered scene, an edited listing and songs, checked
  # by re_workspace/tools/ct_rom_check.py (ROM's own TextWin_Init, ChronoRET unpack/text).
  $PY macos_studio/tools/verify_rom_build.py >/tmp/verify_rom_build.log 2>&1
  RC=$?
  note "ROM build ($(grep -oE '[0-9]+ checks passed' /tmp/verify_rom_build.log))" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  # Playable characters: CLI import = ct_characters.py decode, CLI curves = its rule,
  # identical rebuild, edits checked by ct_rom_check.py, damaged copies rejected.
  $PY macos_studio/tools/verify_character_build.py >/tmp/verify_character_build.log 2>&1
  note "Character records (import, curves, build)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  # The game's own level-up routine run in ChronoRET's interpreter against the rule.
  $PY re_workspace/tools/ct_characters.py check --run >/tmp/verify_character_claims.log 2>&1
  RC=$?
  note "Character evidence ($(grep -oE '[0-9]+ of [0-9]+' /tmp/verify_character_claims.log | tail -1) claims)" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  # PC sprites: source, code and data claims, the ROM's own frame decoder run on
  # every frame; then a CLI import into a fixture copy checked by ct_sprites.py.
  $PY re_workspace/tools/ct_sprites.py check --run >/tmp/verify_sprite_claims.log 2>&1
  RC=$?
  note "Sprite evidence ($(grep -oE '[0-9]+ of [0-9]+' /tmp/verify_sprite_claims.log | tail -1) claims)" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  SPRITE_DIR=$(mktemp -d)
  cp -R macos_studio/Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj "$SPRITE_DIR/p.ctproj" \
    && macos_studio/.build/debug/chronoforge sprites import re_workspace/ct_clean.sfc --project "$SPRITE_DIR/p.ctproj" >/tmp/verify_sprite_import.log 2>&1 \
    && $PY re_workspace/tools/ct_sprites.py verify-import "$SPRITE_DIR/p.ctproj" >>/tmp/verify_sprite_import.log 2>&1
  note "Sprite import (CLI = ct_sprites.py decode)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  rm -rf "$SPRITE_DIR"
  # Techs: CLI import = ct_techs.py decode, CLI tech-point runs = its rule, identical
  # rebuild, edits checked by ct_rom_check.py and learned by the ROM's AwardTechPoints.
  $PY macos_studio/tools/verify_tech_build.py >/tmp/verify_tech_build.log 2>&1
  note "Tech system (import, TP runs, build)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  $PY re_workspace/tools/ct_techs.py check --run >/tmp/verify_tech_claims.log 2>&1
  RC=$?
  note "Tech evidence ($(grep -oE '[0-9]+ of [0-9]+' /tmp/verify_tech_claims.log | tail -1) claims)" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  # Location tilesets: source, code and data claims, the ROM's decompressor, both
  # animation-list loaders and PalAnim_TickAll run; then a CLI import into a fixture
  # copy, checked by `tilesets verify` and by ct_tilesets.py.
  $PY re_workspace/tools/ct_tilesets.py check --run >/tmp/verify_tileset_claims.log 2>&1
  RC=$?
  note "Tileset evidence ($(grep -oE '[0-9]+ of [0-9]+' /tmp/verify_tileset_claims.log | tail -1) claims)" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  TILESET_DIR=$(mktemp -d)
  cp -R macos_studio/Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj "$TILESET_DIR/p.ctproj" \
    && macos_studio/.build/debug/chronoforge tilesets import re_workspace/ct_clean.sfc --project "$TILESET_DIR/p.ctproj" >/tmp/verify_tileset_import.log 2>&1 \
    && macos_studio/.build/debug/chronoforge tilesets verify re_workspace/ct_clean.sfc --project "$TILESET_DIR/p.ctproj" >>/tmp/verify_tileset_import.log 2>&1 \
    && $PY re_workspace/tools/ct_tilesets.py verify-import "$TILESET_DIR/p.ctproj" >>/tmp/verify_tileset_import.log 2>&1
  note "Tileset import (CLI = ct_tilesets.py decode)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  rm -rf "$TILESET_DIR"
  # Items: CLI import = ct_items.py decode, identical rebuild, edits checked by
  # ct_rom_check.py and by the ROM's own Menu_BuildItemTables / Menu_RefreshAllChars.
  $PY macos_studio/tools/verify_item_build.py >/tmp/verify_item_build.log 2>&1
  note "Item tables (import, build)" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  $PY re_workspace/tools/ct_items.py check --run >/tmp/verify_item_claims.log 2>&1
  RC=$?
  note "Item evidence ($(grep -oE '[0-9]+ of [0-9]+' /tmp/verify_item_claims.log | tail -1) claims)" "$([ $RC -eq 0 ] && echo PASS || echo FAIL)"
  if [ -f macos_studio/tools/bundle_app.sh ]; then
    bash macos_studio/tools/bundle_app.sh >/tmp/verify_bundle.log 2>&1; note "bundle_app.sh" "$([ $? -eq 0 ] && echo PASS || echo FAIL)"
  fi
else
  note "swift package present" "FAIL"
fi

echo "----------------------------------------"
if [ $FAILED -eq 0 ]; then echo "ALL GATES PASS"; else echo "GATES FAILED"; fi
exit $FAILED
