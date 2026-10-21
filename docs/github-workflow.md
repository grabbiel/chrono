# GitHub workflow

ChronoForge is published as **source only**. The Chrono Trigger ROM, anything
extracted from it, the S-SMP IPL image, third-party reference checkouts, test
corpora without a clear license, build products and agent/machine state stay in
the maintainer's local workspace and are never committed, uploaded as CI
artifacts or attached to releases.

## Branches and pull requests

- `main` is the only long-lived branch. All changes land through pull requests
  from short-lived topic branches (`feature/…`, `fix/…`, `ci/…`).
- Merges are squash or rebase only, so history stays linear; merged branches are
  deleted automatically.
- Each PR fills in the template: what changed, what was verified (public CI and,
  when relevant, the local full gate), and what was not verified.
- Review conversations must be resolved before merging. While the project has a
  single maintainer, no approving review is required (GitHub does not let an
  author approve their own PR); `CODEOWNERS` still routes review requests.

## Continuous integration (`.github/workflows/ci.yml`)

Runs on every PR, on pushes to `main`, in merge queues and on demand. Superseded
PR runs are cancelled. The workflow token is read-only and checkout does not
persist credentials. Every action is pinned to a full commit SHA and every test
wheel to a version and hash; Dependabot proposes updates for both monthly after a
14-day cooldown.

| Job | Runner | Checks |
| --- | --- | --- |
| Publication audit | `ubuntu-24.04` | `scripts/ci/publication_audit.py`: no ROM/IPL/vector images (by hash), no valid SNES ROM header, no ROM/binary/archive file types, no file over 512 KiB, no private workspace paths, no credentials, key files or local machine paths. Run on the checkout **and on every blob the PR's (or push's) commits introduce**, because a file deleted later stays public in history and PR refs. Python sources compile |
| Build and test | `macos-26` arm64, Xcode 26.6 | Fixture generator reproduces committed fixtures byte for byte; pinned SingleStepTests SPC700 corpus fetched fresh each run (never cached or uploaded) and sampled (provenance must match); C codec + Swift package build; all XCTests run serially; research suites (`re_workspace/tests`) run with pytest in a fresh venv from hash-pinned wheels (`scripts/ci/requirements-pytest.txt`) |
| `ci-gate` | `ubuntu-24.04` | Succeeds only if every job above succeeded. **This is the one required status check.** |

`scripts/ci/check_test_log.py` compares the XCTest log with `swift test list`:
a failure, a listed test without a result, a test ID it cannot parse (only XCTest
results are checked, so Swift Testing tests would fail loudly), a skip that is not in
`scripts/ci/expected_skips.txt`, a `skip` entry that unexpectedly ran (private
data present), or a stale entry all fail the build. Metal tests are `may-skip`
because hosted-runner GPU support can vary.

`scripts/ci/check_pytest_junit.py` does the same for the research suites from
pytest's JUnit XML: every test must pass or skip with exactly the reason listed in
`scripts/ci/expected_pytest_skips.tsv` (tab-separated node ID and reason). A failure,
an unlisted skip, a different reason, a listed test that ran or a stale entry fails
the build. `bash scripts/ci/run_python_tests.sh` reproduces this step locally;
`PYTHON_VENV=re_workspace/.venv` reuses an existing environment.

### What public CI does not verify

Everything that needs the ROM or reference data: LZSS corpus round trips, text,
event and song round trips, ROM builds, the CT sound driver diagnostic and the
real-IPL upload lane, song/sample transfer, and the research tests that read the
ROM, the ChronoRET checkout, manifests or extracted assets (they skip in CI; 23 of
113 run there). Run the local gate for these:

```sh
bash re_workspace/tools/verify_all.sh
```

It uses `CHRONOFORGE_IPL_ROM` (or `re_workspace/refs/ipl/snes9x-ipl.rom`) for the
real-IPL lane and reports that lane as `UNVERIFIED` when no image is available.

## Releases (`.github/workflows/release.yml`)

Pushing a `vX.Y.Z` tag (or running the workflow for an existing tag) builds the
app on `macos-26`, verifies its ad-hoc signature, audits the staged bundle in
release mode (no ROM/IPL/vector content or SNES headers), zips it with a SHA-256
file and creates a **draft** release. A maintainer reviews and publishes it.
Builds are ad-hoc signed, not Developer ID signed or notarized.

## Branch protection (repository ruleset)

`scripts/github/main_ruleset.json` targets the default branch:

- no deletion, no force pushes, linear history;
- pull request required, 0 approvals, stale reviews dismissed, conversations resolved,
  squash/rebase merges only;
- `ci-gate` from GitHub Actions required and the branch must be up to date;
- no bypass actors.

Repository settings that go with it: merge commits off, squash and rebase on,
auto-merge allowed, delete branches after merge.

Auto-merge is how changes land: a PR opened with `gh pr merge --auto --squash`
merges by itself once `ci-gate` passes, and never before. Because the ruleset
requires an up-to-date branch, a PR that falls behind `main` waits until it is
updated (`gh pr update-branch`), which re-runs CI on the combined state.

Apply only after `ci-gate` has reported at least once on a PR, otherwise every PR
blocks on a check that never ran:

```sh
bash scripts/github/apply_main_ruleset.sh            # dry run: current state
bash scripts/github/apply_main_ruleset.sh --apply    # requires repository admin
```

There is deliberately no bypass actor, so a broken CI (Actions outage, retired
runner image) also blocks merges. The repository admin can still recover: set
the ruleset's enforcement to `disabled` in Settings → Rules (or `gh api -X PUT`
with `"enforcement": "disabled"`), merge the CI fix through a PR, and re-apply.
If that is too much friction, add the repository-admin role as a bypass actor
with `"bypass_mode": "pull_request"` (merges via PR only, never direct pushes).

When a second maintainer joins, raise `required_approving_review_count` to 1 and
turn on `require_code_owner_review`.
