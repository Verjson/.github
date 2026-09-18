#!/usr/bin/env bash
# The hub publishes the changelog contract but sits in the `core-checks-actions`
# ruleset cohort, not `changelog-contract-required`, so `changelog / validate`
# never runs on its own pull requests (Verjson/.github#1425). A fragment missing
# `impact:` merged green on #1418 for exactly that reason, and the snapshot it
# would have been consumed into is immutable.
#
# The remedy is that the producer exercises its own contract at the source
# rather than adopting its own consumer packaging: this wrapper runs
# `scripts/changelog.py validate --base <base> --head HEAD` from the hub's own
# `platform` CI group. These assertions are what keep that wrapper honest.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
gate="$here/hub-changelog-validate.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# A fixture repository with a `main` holding one complete fragment, so every
# case below differs from its base only in what the branch adds. The contract
# engine under test is the hub's own `scripts/changelog.py`, which the wrapper
# resolves from its own location — the fixture never carries a copy.
write_fragment() {
  local dir="$1" file="$2" identity="$3" title="$4" impact="${5:-}"
  mkdir -p "$dir/NEXT"
  {
    echo "---"
    echo "date: 2026-09-18"
    echo "issue: $identity"
    [ -z "$impact" ] || echo "impact: $impact"
    echo "title: $title"
    echo "---"
    echo
    echo "$title release note."
  } >"$dir/NEXT/$file"
}

new_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name test
  git -C "$dir" config user.email test@example.com
  write_fragment "$dir" 2026-09-18-issue-1000-base.md 1000 "Base entry" patch
  git -C "$dir" add -A
  git -C "$dir" commit -qm base
  # The wrapper resolves `origin/main` by default; a bare remote gives the
  # fixture a real one rather than a local alias that would not exercise it.
  git -C "$dir" remote add origin "$dir"
  git -C "$dir" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$dir" switch -q -c feature
}

commit_branch() {
  git -C "$1" add -A
  git -C "$1" commit -qm branch
}

# (a) The failure that #1418 shipped: a fragment the branch adds with no
# `impact:` at all. `check-pr` exits 0 on this, which is why the hub saw green.
missing="$tmp/missing-impact"
new_fixture "$missing"
write_fragment "$missing" 2026-09-18-issue-1001-no-impact.md 1001 "No impact"
commit_branch "$missing"

status=0
output="$(cd "$missing" && bash "$gate" . 2>&1)" || status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep 'impact is required' >/dev/null; then
  pass "a branch-added fragment without impact reddens the hub gate"
else
  fail "the gate exited $status for a fragment missing impact; output: $output"
fi

# (b) The shape actions-ci actually runs in. `actions-ci.yml` checks out with
# `fetch-depth: 1`, so the PR ref is the only history present and
# `refs/remotes/origin/main` does not exist at all. A gate that resolved its base
# only from a local ref would be unable to run in the one place it must, which is
# how this whole class of gap is introduced. The base is named by
# `GITHUB_BASE_REF`, exactly as the generated consumer caller names it from the
# pull-request event, and the gate fetches it.
shallow_origin="$tmp/shallow-origin"
new_fixture "$shallow_origin"
write_fragment "$shallow_origin" 2026-09-18-issue-1002-no-impact.md 1002 "Shallow no impact"
commit_branch "$shallow_origin"
branch_sha="$(git -C "$shallow_origin" rev-parse HEAD)"

shallow="$tmp/shallow"
mkdir -p "$shallow"
git -C "$shallow" init -q -b main
git -C "$shallow" config user.name test
git -C "$shallow" config user.email test@example.com
git -C "$shallow" remote add origin "$shallow_origin"
git -C "$shallow" fetch -q --depth 1 origin "$branch_sha"
git -C "$shallow" checkout -q --detach "$branch_sha"

if git -C "$shallow" rev-parse --verify -q origin/main >/dev/null; then
  fail "the shallow fixture already resolves origin/main; it no longer reproduces actions-ci"
else
  pass "the shallow fixture reproduces the fetch-depth 1 checkout actions-ci performs"
fi

status=0
output="$(cd "$shallow" && GITHUB_BASE_REF=main bash "$gate" . 2>&1)" || status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep 'impact is required' >/dev/null; then
  pass "the gate resolves its base under a fetch-depth 1 checkout and still reddens"
else
  fail "the gate exited $status in the shallow checkout; output: $output"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d test(s) failed.\n' "$fails" >&2
  exit 1
fi
