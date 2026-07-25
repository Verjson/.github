#!/usr/bin/env bash
# Tests that the merge gate treats an ABSENT check as not-green (Verjson/.github#143).
# A workflow that dies with `startup_failure` produces no check run at all, so the
# PR's statusCheckRollup is EMPTY once the gate's own checks are filtered out —
# indistinguishable from "everything passed". The gate concluded green and
# auto-merged a PR that was never built, tested or linted.
#
# Same house method as hold.test.sh / gate-queue.test.sh: awk-extract the exact
# `run:` block from ai-review-merge.yml (single source of truth, so the test can't
# drift from the shipped logic) and exercise it against a stubbed `gh`.
# Plain bash + awk + jq; no test-framework dependency (runs on the bare pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

extract() {
  # extract <step-id> <destination>
  awk -v want="        id: $1" '
    $0 == want { seen = 1 }
    seen && $0 == "        run: |" { cap = 1; next }
    cap {
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      if ($0 ~ /^[ \t]*$/) { print ""; next }
      cap = 0
    }
  ' "$wf" >"$2"
}

wait_script="$tmp/ci-wait.sh"
extract ci_wait "$wait_script"
grep -q 'statusCheckRollup' "$wait_script" || { echo "FAIL - could not extract ci_wait run block from $wf"; exit 1; }

# Fake `gh`: the rollup fixture is the POST-`--jq` filtered array (house
# convention); `gh api` serves the raw Actions-runs payload for the head SHA so
# the shipped jq filter itself is exercised. SUITES_RC forces an API failure.
# Fake `sleep` keeps the 30-second poll loop instant.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *statusCheckRollup*) cat "$ROLLUP_FILE" ;;
    *) cat "$META_FILE" ;;
  esac
  exit 0
fi
if [ "$1" = "api" ]; then
  [ "${SUITES_RC:-0}" != "0" ] && { echo "gh: api error" >&2; exit "$SUITES_RC"; }
  cat "$SUITES_FILE"
  exit 0
fi
[ "$1" = "pr" ] && [ "$2" = "merge" ] && { printf 'MERGE %s\n' "$*" >>"$ACTIONLOG"; exit 0; }
[ "$1" = "pr" ] && [ "$2" = "comment" ] && { echo COMMENT >>"$ACTIONLOG"; exit 0; }
exit 0
GH
chmod +x "$tmp/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"

no_startup_failures='{"total_count":1,"workflow_runs":[
  {"name":"node-ci","conclusion":"success","head_sha":"expected-head"}
]}'

run_wait() {
  # run_wait <rollup-json> [runs-api-json] [suites-rc]
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7 LANE=ai
  export EXPECTED_HEAD_SHA=expected-head
  export ROLLUP_FILE="$tmp/rollup.json" SUITES_FILE="$tmp/suites.json"
  export META_FILE="$tmp/meta.json" ACTIONLOG="$tmp/actions.log"
  export SUITES_RC="${3:-0}"
  export EXPECTED_HEAD_SHA="${4-expected-head}"
  printf '%s' "$1" >"$ROLLUP_FILE"
  printf '%s' "${2:-$no_startup_failures}" >"$SUITES_FILE"
  : >"$ACTIONLOG"
  bash "$wait_script" >"$tmp/wait-out.txt" 2>&1
  echo "rc=$?"
}
wait_out_has() { grep -q "$1" "$tmp/wait-out.txt"; }

# --- #143: an empty post-filter rollup is ABSENCE of CI, never green ---------
rc="$(run_wait '[]')"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green'; } \
  && pass "empty rollup never concludes green (#143)" \
  || fail "empty rollup concluded CI green — gate fails OPEN on absent checks ($rc)"

# --- #143: a startup_failure run emits no check run — probe for it directly ---
green_rollup='[{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}]'
startup='{"total_count":2,"workflow_runs":[
  {"name":"unit","conclusion":"success","head_sha":"expected-head"},
  {"name":"node-ci","conclusion":"startup_failure","head_sha":"expected-head"}
]}'
rc="$(run_wait "$green_rollup" "$startup")"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=startup-failure' && wait_out_has 'node-ci'; } \
  && pass "startup_failure workflow fails closed and is named (#143)" \
  || fail "startup_failure workflow did not fail the gate closed ($rc)"

# An empty rollup must not hang silently: the poll window ends in an explicit,
# actionable diagnosis saying WHY the gate refused.
rc="$(run_wait '[]')"
{ [ "$rc" = "rc=1" ] && wait_out_has '::error::phase=ci-wait result=no-checks' \
    && wait_out_has 'no CI checks at all'; } \
  && pass "empty rollup times out with an explicit no-checks diagnosis" \
  || fail "empty rollup failed without saying why ($rc)"

# --- preserved behaviour: real CI still decides the outcome ------------------
rc="$(run_wait '[
  {"name":"success","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"neutral","status":"COMPLETED","conclusion":"NEUTRAL"},
  {"name":"skipped","status":"COMPLETED","conclusion":"SKIPPED"}
]')"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "a genuinely green rollup still concludes green" \
  || fail "green rollup regressed ($rc)"

rc="$(run_wait '[{"name":"unit","status":"COMPLETED","conclusion":"FAILURE"}]')"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=failed'; } \
  && pass "a red rollup still fails the gate" \
  || fail "red rollup regressed ($rc)"

# renovate/stability-days is a commit StatusContext (context/state, no status);
# it keeps polling to the lane ceiling and must not be mistaken for absent CI.
rc="$(run_wait '[{"context":"renovate/stability-days","state":"PENDING"}]')"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=timeout' && ! wait_out_has 'result=no-checks'; } \
  && pass "pending StatusContext still times out as pending, not as no-checks" \
  || fail "renovate/stability-days StatusContext handling regressed ($rc)"

# --- failure modes of the probe itself ---------------------------------------
# An unreadable probe cannot prove absence of a startup failure, so it must never
# conclude green — and when it never recovers the terminal error must name the
# probe, not blame a phantom pending check.
rc="$(run_wait '[{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}]' "$no_startup_failures" 22)"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has '::error::phase=ci-wait result=probe-unavailable'; } \
  && pass "an unreadable startup-failure probe fails closed and names itself" \
  || fail "unreadable probe concluded green or gave no diagnosis ($rc)"

# A missing head SHA would query the runs API without a head filter, matching
# every recent run in the repo — a startup failure on an unrelated commit must
# never be attributed to this PR (nor may an unverifiable head go green).
other_sha_startup='{"total_count":1,"workflow_runs":[
  {"name":"unrelated-ci","conclusion":"startup_failure","head_sha":"some-other-sha"}
]}'
rc="$(run_wait '[{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}]' "$other_sha_startup" 0 "")"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && ! wait_out_has 'result=startup-failure' && ! wait_out_has 'unrelated-ci'; } \
  && pass "an unknown head SHA fails closed without misattributing another commit's failure" \
  || fail "empty head SHA went green or blamed an unrelated run ($rc)"

# --- the authoritative merge recheck must fail closed the same way -----------
# It is the step that actually squash-merges, and it re-reads the rollup itself;
# leaving it fail-open would still merge an unbuilt PR if the ci-wait snapshot
# and the merge snapshot disagree (a workflow re-dispatched onto the same head
# can start failing after ci-wait passed).
merge_script="$tmp/merge.sh"
extract merge "$merge_script"
grep -q 'pr merge' "$merge_script" || { echo "FAIL - could not extract merge run block from $wf"; exit 1; }

run_merge() {
  # run_merge <rollup-json> [runs-api-json] [suites-rc]
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export LANE=ai LANE_REASON="code change" EXPECTED_HEAD_SHA=expected-head
  export ROLLUP_FILE="$tmp/rollup.json" SUITES_FILE="$tmp/suites.json"
  export META_FILE="$tmp/meta.json" ACTIONLOG="$tmp/actions.log"
  export SUITES_RC="${3:-0}"
  printf '{"labels":[],"title":"feat: x","isDraft":false,"state":"OPEN","headRefOid":"expected-head"}' >"$META_FILE"
  printf '%s' "$1" >"$ROLLUP_FILE"
  printf '%s' "${2:-$no_startup_failures}" >"$SUITES_FILE"
  : >"$ACTIONLOG"
  bash "$merge_script" >"$tmp/merge-out.txt" 2>&1
  echo "rc=$?"
}
merged() { grep -q '^MERGE ' "$tmp/actions.log"; }
merge_out_has() { grep -q "$1" "$tmp/merge-out.txt"; }

rc="$(run_merge '[]')"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=no-checks'; } \
  && pass "merge recheck refuses to merge a PR with no checks at all (#143)" \
  || fail "merge recheck merged a PR whose rollup was empty ($rc)"

rc="$(run_merge "$green_rollup" "$startup")"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=startup-failure' && merge_out_has 'node-ci'; } \
  && pass "merge recheck refuses to merge past a startup_failure run (#143)" \
  || fail "merge recheck merged despite a startup_failure run ($rc)"

rc="$(run_merge "$green_rollup" "$no_startup_failures" 22)"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=probe-unavailable'; } \
  && pass "merge recheck refuses to merge on an unverifiable probe" \
  || fail "merge recheck merged without verifying the absence probe ($rc)"

rc="$(run_merge "$green_rollup")"
{ [ "$rc" = "rc=0" ] && merged; } \
  && pass "a genuinely green PR still merges" \
  || fail "green PR no longer merges ($rc)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
