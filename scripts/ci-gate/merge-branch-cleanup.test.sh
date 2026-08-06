#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
merge_wf="$repo_root/.github/workflows/ai-privileged-merge.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# --------------------------------------------------------------------------
# The property under test is an exit code, not a shape: the step's status must
# answer "did the PR merge?" and nothing else. `gh pr merge --delete-branch`
# broke that by folding an idempotent cleanup into the merge call, so on a
# repository with auto-delete-branch-on-merge the ref was already gone, gh
# 404ed, and a merged PR reported a red privileged_merge (#458).
#
# Extract the real block from the workflow (single source of truth) and run it
# under the same `set -euo pipefail` the step uses, against a `gh` stub whose
# merge and delete outcomes are driven independently.
# --------------------------------------------------------------------------
awk '/^          if ! gh pr merge/{p=1}
     p{print}
     p&&/already absent or is not deletable/{seen=1}
     seen&&/^          fi$/{exit}' "$merge_wf" | sed 's/^          //' >"$sandbox/merge.sh"

if [ ! -s "$sandbox/merge.sh" ] || ! grep -q 'git/refs/heads' "$sandbox/merge.sh"; then
  fail "could not extract the merge/cleanup block from $merge_wf"
  echo "$fails test(s) failed."
  exit 1
fi

mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 ${2:-}" in
  "pr merge") exit "${MERGE_EXIT:-0}" ;;
  "pr view") printf '%s' "$SETTLED_JSON"; exit "${VIEW_EXIT:-0}" ;;
  "api") exit "${DELETE_EXIT:-0}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$sandbox/bin/gh"
export PATH="$sandbox/bin:$PATH"
export GH_LOG="$sandbox/gh.log"
export PR_NUMBER=99 TARGET_REPO=Verjson/example
export EXPECTED_HEAD_SHA=1111111111111111111111111111111111111111

# `final` is the projection the step already fetched; the block reads the head
# ref back out of it rather than paying for another API call.
export final
final="$(jq -nc --arg r feat/deep/branch '{headRefName: $r}')"

# Assignments are exported explicitly rather than prefixed onto the call: the
# stub is a grandchild process, and prefix assignments on a *function* are not
# reliably exported to it.
run_block() {
  export MERGE_EXIT="$1" DELETE_EXIT="$2" SETTLED_JSON="$3"
  : >"$GH_LOG"
  ( set -euo pipefail; . "$sandbox/merge.sh" ) >/dev/null 2>&1
}

# 1. The regression itself: merge succeeds, the ref is already gone.
run_block 0 1 ''
[ "$?" -eq 0 ] \
  && pass "a merged PR whose head ref is already deleted exits 0" \
  || fail "a 404 on branch cleanup still fails the step (#458)"

# 2. The coupling must be gone from the call that produces the verdict, not
#    merely tolerated afterwards — asserted on the argv the block really used.
grep -q -- '--delete-branch' "$GH_LOG" \
  && fail "gh pr merge still couples branch deletion to the merge verdict" \
  || pass "gh pr merge no longer passes --delete-branch"

# 3. Cleanup still happens, against the head ref of the target repo. Branch
#    names contain slashes; the ref path must carry them literally.
run_block 0 0 ''
grep -q -- '-X DELETE repos/Verjson/example/git/refs/heads/feat/deep/branch' "$GH_LOG" \
  && pass "the head ref is deleted explicitly after the merge" \
  || fail "branch cleanup no longer runs, or targets the wrong ref"

# 4. Fail-closed is preserved: a merge that did not happen is still red.
run_block 1 0 "$(jq -nc '{state: "OPEN", headRefOid: "1111111111111111111111111111111111111111"}')"
[ "$?" -eq 1 ] \
  && pass "a failed merge on an open PR still exits 1" \
  || fail "the step now reports success for a PR that did not merge"

# 5. ...and a merge at a head we never attested is red, not "close enough".
run_block 1 0 "$(jq -nc '{state: "MERGED", headRefOid: "2222222222222222222222222222222222222222"}')"
[ "$?" -eq 1 ] \
  && pass "a merge at an unattested head still exits 1" \
  || fail "the step tolerates a merge at a head it never validated"

# 6. The one tolerated cause: a concurrent trusted run merged the attested head.
run_block 1 0 "$(jq -nc '{state: "MERGED", headRefOid: "1111111111111111111111111111111111111111"}')"
[ "$?" -eq 0 ] \
  && pass "a concurrent merge at the attested head exits 0" \
  || fail "the concurrent-merge recovery path regressed"

# 7. A projection without a head ref must not issue a delete against
#    `refs/heads/` — under `set -u` it must not kill the step either.
final='{}'
run_block 0 0 ''
status=$?
grep -q -- '-X DELETE' "$GH_LOG" \
  && fail "an absent head ref still issues a delete call"
[ "$status" -eq 0 ] \
  && pass "an absent head ref is skipped without failing the step" \
  || fail "an absent head ref fails the step"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
