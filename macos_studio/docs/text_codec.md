# Chrono Trigger text codec (TextWin, US 1.0)

`CTTextCodec` compiles and decompiles the byte format the US 1.0 TextWin engine
(bank `$C2`) reads for event dialogue. It replaces the older Studio placeholder
`TextCodec` for projects that have imported a ROM text profile. Rules were
adapted from the matched ChronoRET reference (`refs/ChronoRET/tools/text.py`, MIT;
see `third_party/ChronoRET-LICENSE`) and checked against the user's ROM.

## Profile

The substring dictionary is game data, so it is never bundled. It is extracted
from the user's ROM into `strings/ct-text-profile.json` (`ct-text-us/1`):

- Studio: Story → **Import ROM Text Dictionary…**
- CLI: `chronoforge text profile <rom.sfc|rom.smc> --out profile.json`

Only the US 1.0 ROM (SHA-256 `06d1c2b0…829a9`) is accepted; a 512-byte copier
header is stripped. The 128 entries come from the word-pointer table at
`$DE:FA00` (length-prefixed glyph strings); the profile is also checked against a
pinned hash of the verified dictionary, so a hand-edited profile is rejected.

## Byte format

| Bytes | Meaning | Notation |
|---|---|---|
| `00` | end of message | `{end}` |
| `01`/`02` + 1 | wide glyph | `{wide 01XX}` / `{wide 02XX}` |
| `03` + 1 | delay | `{wait XX}` |
| `04`–`0C` | step, line, page and wait/indent variants | `{step}` `{line}` `{line indent}` `{wait line}` … `{wait page indent}` |
| `0D`–`0F` | 8/16/24-bit number argument | `{num8}` `{num16}` `{num24}` |
| `10`, `11` | no-op, argument name | `{nop}` `{argname}` |
| `12` + 1 | extension: tech, enemy, dictionary entry ≥ 31 | `{tech}` `{enemy}` `{ext XX}` / `{ext [text]}` |
| `13`–`20` | character, member and item names | `{char0}`…`{char6}` `{name0}` `{member0}`… `{nadia}` `{item}` `{name7}` |
| `21`–`9F` | dictionary entry 0–126 | expanded text, `[text]`, `{dict XX}` |
| `A0`–`FF` | glyphs (`EF` space, `FF` second blank `_`) | text, `{gXX}` for unassigned |

A newline in source is `{line}` (`$05`). All 33 control dispatch pointers in the
ROM's TextWin code table were compared to the matched assembly
(`re_workspace/manifests/text_codec_verification.json`).

## Compression

Encoding packs each glyph run greedily: at each position, the longest dictionary
entry starting with that glyph wins, ties by lower index. Entries 116–118 are
never chosen, which reproduces the original compressor. Entry 127 is only
reachable through `{ext 68}`.

Decoding is lossless. A run that greedy packing would not reproduce is written
inside `«…»` exactly as stored (`{dict XX}` for entries, glyphs for literals), so
`encode(decode(bytes)) == bytes` for every valid stream.

## Messages

`compileMessage` is the authoring API used by Validate, the Story pane and
`chronoforge text message`/`build`. It appends `{end}` when missing, rejects text
after `{end}`, and allows `{ext XX}` only for `00`, `01` and `08`–`68`. Unsupported
characters are errors; nothing is silently replaced. The Story pane shows compiled
size, bytes saved by the dictionary and the canonical decoded form.

`chronoforge text build <project.ctproj> --out dialogue.json` emits
`ct-dialogue/1`: all messages concatenated in ID order with per-record offsets.
Those offsets are local to that file; pointer tables and ROM placement belong to
the not-yet-implemented `.sfc` builder.

## Verification

```sh
re_workspace/.venv/bin/python re_workspace/tools/ct_text_profile.py --check
chronoforge text verify-corpus re_workspace/assets/text/message_corpus.json --profile <profile.json>
swift test --filter CTTextCodecTests
```

The corpus is every pointer in the 15 event-message tables (4,579) plus two
unreferenced table spans: 4,581 cases. Both the reference text and Swift's own
decode re-encode to the original ROM bytes. The master gate runs all three.

## Limitations

- Static encoding only: the variable-width font, window layout, pacing and
  name substitution are not rendered or emulated yet.
- Menu, name, credits and battle-message tables use other layouts and are not in
  the corpus.
- Other ROM revisions and languages are rejected rather than guessed.
- Projects without a profile keep using the placeholder codec, which is not
  ROM text; its `\{name:…}` escapes need manual conversion to CT tags.
