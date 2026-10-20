#!/bin/bash
# Check out only spc700/v1 of SingleStepTests/ProcessorTests at the pinned commit.
# The corpus and samples prepared from it are test inputs only: never commit,
# bundle or upload them (the pinned upstream commit has no license file).
set -euo pipefail
PIN=bb11756436da8fd16cce86aef63dc6725f48836f
DEST=${1:?usage: fetch_spc700_corpus.sh DEST}
if [ ! -d "$DEST/.git" ]; then
  git clone --quiet --filter=blob:none --no-checkout --sparse \
    https://github.com/SingleStepTests/ProcessorTests.git "$DEST"
fi
git -C "$DEST" sparse-checkout set spc700/v1
git -C "$DEST" -c advice.detachedHead=false checkout --quiet "$PIN"
test "$(git -C "$DEST" rev-parse HEAD)" = "$PIN"
test -z "$(git -C "$DEST" status --porcelain -- spc700/v1)"
echo "SPC700 corpus at $PIN: $(ls "$DEST/spc700/v1" | wc -l | tr -d ' ') opcode files"
