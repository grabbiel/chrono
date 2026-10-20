#!/bin/bash
# Build the C codec and the Swift package, run every XCTest serially, and check
# results against scripts/ci/expected_skips.txt. Logs go to $CI_LOG_DIR.
set -euo pipefail
cd "$(dirname "$0")/../.."
LOGS=${CI_LOG_DIR:-$PWD/.ci-logs}
mkdir -p "$LOGS"
sh re_workspace/tools/libctcodec/build.sh
swift build --package-path macos_studio --build-tests 2>&1 | tee "$LOGS/swift-build.log"
swift test list --package-path macos_studio --skip-build >"$LOGS/swift-test-list.txt"
set +e
swift test --package-path macos_studio --skip-build >"$LOGS/swift-test.log" 2>&1
status=$?
set -e
tail -n 20 "$LOGS/swift-test.log"
python3 scripts/ci/check_test_log.py "$LOGS/swift-test.log" --list "$LOGS/swift-test-list.txt" \
  --expected-skips scripts/ci/expected_skips.txt ${GITHUB_STEP_SUMMARY:+--summary "$GITHUB_STEP_SUMMARY"}
exit $status
