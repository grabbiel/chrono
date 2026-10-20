# Contributing

Thanks for helping with ChronoForge. Please read [docs/github-workflow.md](docs/github-workflow.md)
for branches, CI, releases and branch protection.

## Never commit game or private data

This repository contains source code only. Do not add ROMs or ROM fragments,
extracted graphics/audio/text, SPC snapshots, the S-SMP IPL image, third-party
reference checkouts or test corpora, build products, local paths or credentials.
CI blocks known cases (`scripts/ci/publication_audit.py`), but it cannot catch
everything. Run it before pushing:

```sh
python3 scripts/ci/publication_audit.py
```

Code ported from other projects needs its license in `macos_studio/ThirdParty/`.

## Build and test

Requirements: Apple silicon Mac, macOS 15 or later, Xcode with Swift 6.

```sh
sh re_workspace/tools/libctcodec/build.sh
swift build --package-path macos_studio
swift test --package-path macos_studio
```

Tests that need your ROM or reference data skip without it. The bundled SPC700
instruction sample is not committed; generate it from the pinned upstream corpus:

```sh
bash scripts/ci/fetch_spc700_corpus.sh /tmp/processor-tests
python3 macos_studio/tools/prepare_spc700_vectors.py /tmp/processor-tests/spc700/v1
```

With your own Chrono Trigger (USA) ROM placed at `re_workspace/ct_clean.sfc`
(SHA-256 `06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9`) and
the reference workspace described in `re_workspace/tools/verify_all.sh`, run the
full local gate before PRs that touch ROM-facing code.

## Pull requests

- Keep each PR focused; add tests for new behavior.
- A new test that needs local data must skip with a clear reason and be listed in
  `scripts/ci/expected_skips.txt`.
- Say what you verified and what you did not.
