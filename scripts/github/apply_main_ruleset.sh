#!/bin/bash
# Apply the default-branch ruleset and merge settings in docs/github-workflow.md.
# Dry run by default: prints the current state and what would change.
# Pass --apply to change GitHub. Requires admin rights on the repository.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=${REPO:-grabbiel/chrono}
RULESET=scripts/github/main_ruleset.json
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

echo "== $REPO current settings"
gh api "repos/$REPO" --jq '{default_branch, visibility, allow_merge_commit, allow_squash_merge,
  allow_rebase_merge, allow_auto_merge, delete_branch_on_merge}'
existing=$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "main") | .id')
echo "== existing 'main' ruleset: ${existing:-none}"
# The required check must have reported at least once, or every PR blocks.
gh api "repos/$REPO/commits/HEAD/check-runs" --jq '[.check_runs[].name] | unique' || true

if ! $APPLY; then
  echo "== dry run: would set merge commits off, squash/rebase on, auto-merge allowed, delete merged branches, and"
  echo "   $( [ -n "$existing" ] && echo "update ruleset $existing" || echo "create ruleset") from $RULESET"
  exit 0
fi
gh api -X PATCH "repos/$REPO" -F allow_merge_commit=false -F allow_squash_merge=true \
  -F allow_rebase_merge=true -F allow_auto_merge=true -F delete_branch_on_merge=true --silent
if [ -n "$existing" ]; then
  gh api -X PUT "repos/$REPO/rulesets/$existing" --input "$RULESET" --jq '{id, name, enforcement}'
else
  gh api -X POST "repos/$REPO/rulesets" --input "$RULESET" --jq '{id, name, enforcement}'
fi
gh api "repos/$REPO/rules/branches/main" --jq '[.[].type]'
