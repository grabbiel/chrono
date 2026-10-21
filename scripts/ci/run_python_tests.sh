#!/bin/bash
# Run the research test suites (re_workspace/tests) in a fresh venv and check
# results against scripts/ci/expected_pytest_skips.tsv. Logs go to $CI_LOG_DIR.
# PYTHON_VENV reuses an existing environment instead (local runs).
set -euo pipefail
cd "$(dirname "$0")/../.."
LOGS=${CI_LOG_DIR:-$PWD/.ci-logs}
mkdir -p "$LOGS"
sh re_workspace/tools/libctcodec/build.sh
if [ -z "${PYTHON_VENV:-}" ]; then
  PYTHON_VENV=${RUNNER_TEMP:-$(mktemp -d)}/pytest-venv
  python3 -m venv "$PYTHON_VENV"
  "$PYTHON_VENV/bin/python" -m pip install --quiet --disable-pip-version-check \
    --only-binary :all: --require-hashes -r scripts/ci/requirements-pytest.txt
fi
set +e
"$PYTHON_VENV/bin/python" -m pytest re_workspace/tests -q -rs -p no:cacheprovider \
  --junitxml "$LOGS/pytest.xml" >"$LOGS/pytest.log" 2>&1
status=$?
set -e
tail -n 20 "$LOGS/pytest.log"
python3 scripts/ci/check_pytest_junit.py "$LOGS/pytest.xml" \
  --expected-skips scripts/ci/expected_pytest_skips.tsv ${GITHUB_STEP_SUMMARY:+--summary "$GITHUB_STEP_SUMMARY"}
exit $status
