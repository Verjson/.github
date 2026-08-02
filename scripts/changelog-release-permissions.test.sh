#!/usr/bin/env bash
# Exercises the token authority of the reusable changelog release workflow
# (Verjson/.github#295).
#
# A called workflow's `permissions` block is the cap — a caller granting
# contents: write cannot raise it. When the release job inherited the
# workflow-level `contents: read` default, the push_token reached the final
# atomic push read-only and every consumer release died with HTTP 403 after
# generating the snapshot. The assertions below pin the shape that failure
# requires: write authority scoped to the job that pushes, read everywhere else.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
workflow="$root/.github/workflows/changelog-release.yml"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# The release job's header: everything from `  release:` up to its `steps:`.
# Scoping matters — a workflow-level `contents: write` would satisfy a bare
# file-wide grep while granting the permission far more broadly than the push
# needs.
job_header="$(awk '
  /^  release:/ { inside = 1; next }
  inside && /^    steps:/ { exit }
  inside && /^  [^ ]/ { exit }
  inside { print }
' "$workflow")"

grep -qE '^      contents: write$' <<<"$job_header" \
  && pass "the release job grants contents: write to its own token" \
  || fail "the release job does not grant contents: write, so its push cannot succeed"

grep -qE '^    permissions:$' <<<"$job_header" \
  && pass "the write grant is scoped to the release job" \
  || fail "the release job declares no permissions block of its own"

# Least privilege is the reason the job-level override exists at all: anything
# this workflow gains later must ask for it explicitly.
workflow_default="$(awk '
  /^permissions:/ { inside = 1; next }
  inside && /^[^ ]/ { exit }
  inside { print }
' "$workflow")"

[ "$(grep -c . <<<"$workflow_default")" -eq 1 ] && grep -qE '^  contents: read$' <<<"$workflow_default" \
  && pass "the workflow-level default stays contents: read" \
  || fail "the workflow-level default is no longer a bare contents: read"

# The permission only matters because of what the job does with it. If either of
# these changes, the grant above needs re-justifying rather than inheriting.
grep -qF 'token: ${{ secrets.push_token }}' "$workflow" \
  && pass "the checkout still persists push_token for the push" \
  || fail "the checkout no longer uses push_token, so the write grant may be misplaced"

grep -qF 'git push --atomic origin \' "$workflow" \
  && grep -qF '"$release_commit:refs/heads/$DEFAULT_BRANCH" \' "$workflow" \
  && grep -qF '"refs/tags/$VERSION"' "$workflow" \
  && pass "the release still publishes commit and exact tag atomically" \
  || fail "the atomic commit+tag push shape changed"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
