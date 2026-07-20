#!/usr/bin/env bash
# Tests the merge gate's `freshness` step (Verjson/.github#41, ADR 0008) by
# extracting the exact `run:` block from ai-review-merge.yml — the single source
# of truth, so the test can't drift from the shipped logic — and exercising it
# against a stubbed `gh`. Guards the org-critical fail-open / fail-closed
# behavior: a regression that starts merging conflicting branches or wedges the
# gate must fail here before it reaches every repo. Plain bash + awk + jq; no
# test-framework or YAML-library dependency (runs on the bare self-hosted pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

# Extract the freshness step's run script verbatim (10-space-indented body after
# `run: |`, scoped to the step whose `id:` is freshness).
script="$tmp/freshness.sh"
awk '
  $0 == "        id: freshness" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    cap = 0
  }
' "$wf" >"$script"
if ! grep -q 'update-branch' "$script" || ! grep -q 'behind_by' "$script"; then
  echo "FAIL - could not extract the freshness run block from $wf"
  exit 1
fi

# Fake gh: dispatches on args, driven by env fixtures, logging side effects.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '%s ' "$@" | grep -q -- '--json comments' && { cat "$COMMENTS_FILE" 2>/dev/null; exit 0; }
  [ "${PRVIEW_FAIL:-0}" = "1" ] && exit 1
  # After update-branch runs, return the post-update mergeable so a CONFLICTING
  # branch whose conflict was mere base drift reads as cleared on the re-check.
  if [ -n "${POST_UPDATE_MERGEABLE:-}" ] && grep -q UPDATE "$ACTIONLOG" 2>/dev/null; then
    jq -c --arg m "$POST_UPDATE_MERGEABLE" '.mergeable=$m' "$FIXTURE"; exit 0
  fi
  cat "$FIXTURE"; exit 0
fi
[ "$1" = "pr" ] && [ "$2" = "comment" ] && { echo COMMENT >>"$ACTIONLOG"; exit 0; }
if [ "$1" = "api" ]; then
  case "$*" in
    *compare*) echo "${BEHIND_BY:-0}"; exit 0 ;;
    *update-branch*) echo UPDATE >>"$ACTIONLOG"; exit "${UPDATE_RC:-0}" ;;
  esac
fi
exit 0
GH
chmod +x "$tmp/bin/gh"

run_case() {
  # run_case <pr-json-fixture> [existing-comments]
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export FIXTURE="$tmp/fix.json" GITHUB_OUTPUT="$tmp/out.txt" ACTIONLOG="$tmp/act.log" COMMENTS_FILE="$tmp/c.txt"
  : >"$GITHUB_OUTPUT"
  : >"$ACTIONLOG"
  printf '%s' "${2:-}" >"$COMMENTS_FILE"
  printf '%s' "$1" >"$FIXTURE"
  bash "$script" >/dev/null 2>&1
  echo "rc=$?"
}
out_has() { grep -q "$1" "$tmp/out.txt"; }
act_has() { grep -q "$1" "$tmp/act.log"; }

H='{"author":{"login":"human"},"headRefName":"feat/x","headRefOid":"abc","baseRefName":"main","mergeable":"MERGEABLE"}'

BEHIND_BY=5 run_case '{"author":{"login":"renovate[bot]"},"headRefName":"renovate/x","headRefOid":"s","baseRefName":"main","mergeable":"MERGEABLE"}' >/dev/null
{ out_has 'proceed=true' && ! act_has UPDATE; } && pass "renovate author is skipped (no update)" || fail "renovate author not skipped"

BEHIND_BY=5 run_case '{"author":{"login":"someone"},"headRefName":"renovate/x","headRefOid":"s","baseRefName":"main","mergeable":"MERGEABLE"}' >/dev/null
{ out_has 'proceed=true' && ! act_has UPDATE; } && pass "renovate/ branch prefix is skipped" || fail "renovate branch prefix not skipped"

BEHIND_BY=3 run_case '{"author":{"login":"human"},"headRefName":"feat/renovate-cleanup","headRefOid":"s","baseRefName":"main","mergeable":"MERGEABLE"}' >/dev/null
{ act_has UPDATE && out_has 'proceed=false'; } && pass "human branch merely containing 'renovate' is NOT skipped" || fail "over-matched renovate on a human branch"

rc=$(BEHIND_BY=0 run_case '{"author":{"login":"human"},"headRefName":"feat/x","headRefOid":"s","baseRefName":"main","mergeable":"CONFLICTING"}')
{ [ "$rc" = "rc=1" ] && act_has COMMENT; } && pass "conflict holds (exit 1) and comments" || fail "conflict path wrong ($rc)"

rc=$(BEHIND_BY=0 run_case '{"author":{"login":"human"},"headRefName":"feat/x","headRefOid":"s","baseRefName":"main","mergeable":"CONFLICTING"}' '{"comments":[{"body":"<!-- gate:branch-conflict --> old"}]}')
{ [ "$rc" = "rc=1" ] && ! act_has COMMENT; } && pass "conflict comment is deduped" || fail "conflict comment not deduped"

# (a) CONFLICTING from mere base drift → update-branch clears it → step aside
# like the BEHIND success path (proceed=false), no conflict comment.
rc=$(POST_UPDATE_MERGEABLE=MERGEABLE BEHIND_BY=0 run_case '{"author":{"login":"human"},"headRefName":"feat/x","headRefOid":"s","baseRefName":"main","mergeable":"CONFLICTING"}')
{ [ "$rc" = "rc=0" ] && act_has UPDATE && out_has 'proceed=false' && ! act_has COMMENT; } \
  && pass "conflict cleared by update-branch → proceed=false, no comment" || fail "conflict-then-update path wrong ($rc)"

# (b) CONFLICTING + update-branch API fails → hold (exit 1) + conflict comment.
rc=$(UPDATE_RC=1 BEHIND_BY=0 run_case '{"author":{"login":"human"},"headRefName":"feat/x","headRefOid":"s","baseRefName":"main","mergeable":"CONFLICTING"}')
{ [ "$rc" = "rc=1" ] && act_has COMMENT; } && pass "conflict + failed update-branch holds + comments" || fail "failed-update conflict path wrong ($rc)"

# (c) CONFLICTING + update-branch "succeeds" but branch is STILL CONFLICTING
# (genuine content conflict) → hold (exit 1) + conflict comment.
rc=$(POST_UPDATE_MERGEABLE=CONFLICTING BEHIND_BY=0 run_case '{"author":{"login":"human"},"headRefName":"feat/x","headRefOid":"s","baseRefName":"main","mergeable":"CONFLICTING"}')
{ [ "$rc" = "rc=1" ] && act_has UPDATE && act_has COMMENT; } && pass "genuine conflict survives update-branch → holds + comments" || fail "genuine-conflict path wrong ($rc)"

# (d) Renovate CONFLICTING branch → still exempt: no update attempt, no comment.
POST_UPDATE_MERGEABLE=MERGEABLE BEHIND_BY=0 run_case '{"author":{"login":"renovate[bot]"},"headRefName":"renovate/x","headRefOid":"s","baseRefName":"main","mergeable":"CONFLICTING"}' >/dev/null
{ out_has 'proceed=true' && ! act_has UPDATE && ! act_has COMMENT; } && pass "renovate conflict left to Renovate (no update, no comment)" || fail "renovate conflict not exempt"

BEHIND_BY=4 run_case "$H" >/dev/null
{ act_has UPDATE && out_has 'proceed=false'; } && pass "behind (clean) updates branch, proceed=false" || fail "behind path wrong"

BEHIND_BY=0 run_case "$H" >/dev/null
{ out_has 'proceed=true' && ! act_has UPDATE; } && pass "up-to-date proceeds, no update" || fail "up-to-date path wrong"

export PRVIEW_FAIL=1
rc=$(run_case "$H")
unset PRVIEW_FAIL
{ [ "$rc" = "rc=0" ] && out_has 'proceed=true'; } && pass "read failure fails open (proceed=true)" || fail "read failure did not fail open ($rc)"

BEHIND_BY=null run_case "$H" >/dev/null
{ out_has 'proceed=true' && ! act_has UPDATE; } && pass "non-numeric behind_by treated as 0" || fail "non-numeric behind_by mishandled"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
