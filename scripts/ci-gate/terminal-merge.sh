#!/usr/bin/env bash
set -euo pipefail

for name in TARGET_REPO PR_NUMBER EXPECTED_HEAD_SHA AUTHORIZED_BASE_SHA DEFAULT_BRANCH GH_TOKEN; do
  [ -n "${!name:-}" ] || { echo "::error::$name is required"; exit 1; }
done
[[ "$TARGET_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || exit 1
[[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$EXPECTED_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
[[ "$AUTHORIZED_BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
[[ "$DEFAULT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || exit 1

# This is the final trusted read before the head-CAS merge. The merge App token is
# repository-scoped, and no event, PR-head, or caller input selects these identities.
current="$(gh api "repos/$TARGET_REPO/pulls/$PR_NUMBER")"
jq -e --arg head "$EXPECTED_HEAD_SHA" --arg base "$AUTHORIZED_BASE_SHA" \
  --arg branch "$DEFAULT_BRANCH" '
    .state == "open" and .head.sha == $head and
    .base.ref == $branch and .base.sha == $base
  ' <<<"$current" >/dev/null || {
  echo "::error::terminal merge rejected a moved head, stale base, malformed ref, or closed pull request"
  exit 1
}

current_base_sha="$(gh api "repos/$TARGET_REPO/git/ref/heads/$DEFAULT_BRANCH" \
  --jq 'select(.object.type == "commit") | .object.sha // ""')"
[[ "$current_base_sha" =~ ^[0-9a-f]{40}$ ]] && [ "$current_base_sha" = "$AUTHORIZED_BASE_SHA" ] || {
  echo "::error::terminal merge rejected a moved or malformed default-branch ref"
  exit 1
}

gh pr merge "$PR_NUMBER" --repo "$TARGET_REPO" --admin --squash \
  --match-head-commit "$EXPECTED_HEAD_SHA"
