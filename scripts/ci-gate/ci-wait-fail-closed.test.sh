#!/usr/bin/env bash
# Tests that the merge gate treats an ABSENT check as not-green (Verjson/.github#143).
# A workflow that dies with `startup_failure` produces no check run at all, so the
# PR's statusCheckRollup is EMPTY once the gate's own checks are filtered out —
# indistinguishable from "everything passed". The gate concluded green and
# auto-merged a PR that was never built, tested or linted.
#
# Same house method as gate-hold-disable.test.sh / gate-queue.test.sh: awk-extract the exact
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
  # Capture stops at the FIRST line that leaves the `run: |` body — the next
  # step's `- name:`, or any line indented less than the block body. Clearing
  # `cap` alone is not enough: `seen` stays set, so the next step's `run: |`
  # re-arms capture and every later step gets concatenated onto the script
  # (ci_wait once extracted as 529 lines). That silently turns the rc=0
  # positive controls into assertions about unrelated appended code.
  awk -v want="        id: $1" '
    $0 == want { seen = 1 }
    seen && $0 == "        run: |" { cap = 1; next }
    cap && $0 ~ /^      - name:/ { exit }
    cap {
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      if ($0 ~ /^[ \t]*$/) { print ""; next }
      exit
    }
  ' "$wf" >"$2"
}

wait_script="$tmp/ci-wait.sh"
extract ci_wait "$wait_script"
grep -q '/check-runs?per_page=100' "$wait_script" || { echo "FAIL - could not extract ci_wait run block from $wf"; exit 1; }

dispatch_exclusions=$(grep -c '\$n != "dispatch-merge"' "$wf")
privileged_exclusions=$(grep -c '\$n != "privileged_merge"' "$wf")
[ "$dispatch_exclusions" -eq 2 ] && [ "$privileged_exclusions" -eq 2 ] \
  && pass "CI wait and authoritative recheck exclude trusted continuation checks" \
  || fail "trusted continuation checks can circularly authorize or block the review gate"

# Fake `gh`: the rollup fixture is the POST-`--jq` filtered array (house
# convention); `gh api` serves the raw Actions-runs payload for the head SHA so
# the shipped jq filter itself is exercised. SUITES_RC forces an API failure.
# Fake `sleep` keeps the 30-second poll loop instant.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
# Counts a call in <file> and echoes the new total. Only used by the scenarios
# that need call ordering — the poll loop runs up to 80 times per case, so the
# default path stays fork-free.
bump() { n=0; [ -f "$1" ] && read -r n <"$1"; n=$((n + 1)); printf '%s\n' "$n" >"$1"; printf '%s' "$n"; }
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  [ "${GRAPHQL_ROLLUP_RC:-0}" = "0" ] || {
    echo "GraphQL: Resource not accessible by integration (repository.pullRequest.statusCheckRollup)" >&2
    exit "$GRAPHQL_ROLLUP_RC"
  }
  cat "$META_FILE"
  exit 0
fi
if [ "$1" = "api" ]; then
  case "$*" in
    */actions/runs/*/jobs\?per_page=100*)
      [ "${SELF_JOBS_RC:-0}" = "0" ] || exit "$SELF_JOBS_RC"
      printf '{"jobs":[{"name":"preflight"},{"name":"gate"}]}\n'
      exit 0 ;;
    */check-runs\?per_page=100*)
      [ "${CHECKS_RC:-0}" = "0" ] || exit "$CHECKS_RC"
      bump "$CHECKS_CALL_COUNT" >/dev/null
      if [ -n "${CHECKS_PAGES_FILE:-}" ]; then
        jq -c '.[]' "$CHECKS_PAGES_FILE"
        exit 0
      fi
      fixture="$ROLLUP_FILE"
      if [ -n "${ROLLUP_FILE2:-}" ] && [ "$(bump "$ROLLUPCOUNT")" -gt "${ROLLUP_SWITCH_AFTER:-0}" ]; then
        fixture="$ROLLUP_FILE2"
      fi
      jq -c '{total_count: ([.[] | select(has("status"))] | length), check_runs: [.[] | select(has("status"))]}' "$fixture"
      exit 0 ;;
    */status\?per_page=100*)
      [ "${STATUSES_RC:-0}" = "0" ] || exit "$STATUSES_RC"
      bump "$STATUSES_CALL_COUNT" >/dev/null
      if [ -n "${STATUSES_PAGES_FILE:-}" ]; then
        jq -c '.[]' "$STATUSES_PAGES_FILE"
        exit 0
      fi
      jq -c '{statuses: [.[] | select(has("state"))]}' "$ROLLUP_FILE"
      exit 0 ;;
  esac
  [ "${SUITES_RC:-0}" != "0" ] && { echo "gh: api error" >&2; exit "$SUITES_RC"; }
  # SUITES_FAIL_FIRST makes only the first N probes fail, so a test can show a
  # transient outage being recovered from rather than a permanent one.
  if [ "${SUITES_FAIL_FIRST:-0}" != "0" ] && [ "$(bump "$APICOUNT")" -le "$SUITES_FAIL_FIRST" ]; then
    echo "gh: api error" >&2
    exit 1
  fi
  cat "$SUITES_FILE"
  exit 0
fi
[ "$1" = "pr" ] && [ "$2" = "merge" ] && { printf 'MERGE %s\n' "$*" >>"$ACTIONLOG"; exit 0; }
[ "$1" = "pr" ] && [ "$2" = "comment" ] && { echo COMMENT >>"$ACTIONLOG"; exit 0; }
exit 0
GH
chmod +x "$tmp/bin/gh"
real_jq="$(command -v jq)"
export REAL_JQ="$real_jq"
cat >"$tmp/bin/jq" <<'JQ'
#!/usr/bin/env bash
if [ "${JQ_FAIL_AGGREGATE:-false}" = true ]; then
  for arg in "$@"; do
    [ "$arg" = self_jobs ] && exit 127
  done
fi
exec "$REAL_JQ" "$@"
JQ
chmod +x "$tmp/bin/jq"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"

# A real 40-hex commit SHA: the gate validates the shape of EXPECTED_HEAD_SHA
# before interpolating it into an API URL, so a placeholder like "expected-head"
# would exercise the reject path instead of the happy path.
head_sha='0123456789abcdef0123456789abcdef01234567'

if grep -q -- '--slurp' "$wait_script"; then
  fail "CI status aggregation still requires gh api --slurp"
else
  pass "CI status aggregation uses runner-compatible streaming pagination (#248)"
fi

# The gate is itself a workflow run on the PR head, so `?head_sha=<head>` ALWAYS
# returns at least one run — its own. A fixture with `workflow_runs: []` is a
# payload production cannot produce, and testing against it would let the
# "nothing was ever triggered" shortcut pass while being dead in the real world.
gate_run_id=424242
export GITHUB_RUN_ID="$gate_run_id"
gate_own_run="{\"id\":$gate_run_id,\"name\":\"AI review + auto-merge\",\"conclusion\":null,\"head_sha\":\"$head_sha\"}"

no_startup_failures="{\"total_count\":2,\"workflow_runs\":[
  $gate_own_run,
  {\"id\":11,\"name\":\"node-ci\",\"conclusion\":\"success\",\"head_sha\":\"$head_sha\"}
]}"

run_wait() {
  # run_wait <rollup-json> [runs-api-json] [suites-rc]
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7 LANE=ai
  export REAL_JQ="$real_jq"
  export GITHUB_EVENT_NAME="${TEST_EVENT_NAME:-pull_request}"
  export ROLLUP_FILE="$tmp/rollup.json" SUITES_FILE="$tmp/suites.json"
  export META_FILE="$tmp/meta.json" ACTIONLOG="$tmp/actions.log"
  export SUITES_RC="${3:-0}"
  export CHECKS_RC="${CHECKS_RC:-0}" STATUSES_RC="${STATUSES_RC:-0}"
  export SELF_JOBS_RC="${SELF_JOBS_RC:-0}"
  export GRAPHQL_ROLLUP_RC="${GRAPHQL_ROLLUP_RC:-0}"
  export CHECKS_PAGES_FILE="${CHECKS_PAGES_FILE:-}"
  export STATUSES_PAGES_FILE="${STATUSES_PAGES_FILE:-}"
  export EXPECTED_HEAD_SHA="${4-$head_sha}"
  # `<unset>` removes the variable instead of setting it: every other case sets
  # it explicitly, so nothing would otherwise pin the `:-false` default and a
  # flip to `:-true` would leave the suite green. Safe inside `$( )`.
  if [ "${5:-false}" = "<unset>" ]; then unset ALLOW_ABSENT_CHECKS; else export ALLOW_ABSENT_CHECKS="${5:-false}"; fi
  export ROLLUPCOUNT="$tmp/rollup.count" APICOUNT="$tmp/api.count"
  export CHECKS_CALL_COUNT="$tmp/checks-call.count" STATUSES_CALL_COUNT="$tmp/statuses-call.count"
  export SUITES_FAIL_FIRST="${SUITES_FAIL_FIRST:-0}"
  export ROLLUP_FILE2="${ROLLUP_FILE2:-}" ROLLUP_SWITCH_AFTER="${ROLLUP_SWITCH_AFTER:-0}"
  rm -f "$ROLLUPCOUNT" "$APICOUNT" "$CHECKS_CALL_COUNT" "$STATUSES_CALL_COUNT"
  printf '%s' "$1" >"$ROLLUP_FILE"
  # `${2-...}`, not `${2:-...}`: an explicitly EMPTY body is a distinct case
  # under test (a 2xx with no payload), not "caller omitted the argument".
  printf '%s' "${2-$no_startup_failures}" >"$SUITES_FILE"
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

SELF_JOBS_RC=127
GITHUB_REPOSITORY=Verjson/foo
RUNNER_NAME=gha-general-7
export SELF_JOBS_RC GITHUB_REPOSITORY RUNNER_NAME
rc="$(run_wait "$green_rollup")"
unset SELF_JOBS_RC GITHUB_REPOSITORY RUNNER_NAME
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=toolchain-missing' && wait_out_has 'gha-general-7'; } \
  && pass "self-job enumeration fails fast when gh disappears" \
  || fail "self-job enumeration swallowed exit 127 and entered the poll loop ($rc)"

JQ_FAIL_AGGREGATE=true
export JQ_FAIL_AGGREGATE
rc="$(run_wait "$green_rollup")"
unset JQ_FAIL_AGGREGATE
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=toolchain-missing' && wait_out_has 'aggregate_shape_rc=127'; } \
  && pass "aggregation-time jq loss is terminal instead of consuming the poll budget" \
  || fail "aggregation-time jq loss still retries as an API outage ($rc)"

startup='{"total_count":2,"workflow_runs":[
  {"name":"unit","conclusion":"success","head_sha":"0123456789abcdef0123456789abcdef01234567"},
  {"name":"node-ci","conclusion":"startup_failure","head_sha":"0123456789abcdef0123456789abcdef01234567"}
]}'
rc="$(run_wait "$green_rollup" "$startup")"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=startup-failure' && wait_out_has 'node-ci'; } \
  && pass "startup_failure workflow fails closed and is named (#143)" \
  || fail "startup_failure workflow did not fail the gate closed ($rc)"

# `name` is nullable in the Actions runs schema, and a run that died parsing its
# own YAML — the literal #143 scenario — is the likeliest place for GitHub to
# have no workflow name to report. Deciding on the joined NAME string is
# therefore fail-open: `[null] | join(", ")` is "", which reads as "nothing
# failed startup". The decision must key on a COUNT; the names are log text only.
unnamed_startup='{"total_count":1,"workflow_runs":[
  {"name":null,"conclusion":"startup_failure","head_sha":"0123456789abcdef0123456789abcdef01234567"}
]}'
blank_startup='{"total_count":1,"workflow_runs":[
  {"name":"","conclusion":"startup_failure","head_sha":"0123456789abcdef0123456789abcdef01234567"}
]}'
for body in "$unnamed_startup" "$blank_startup"; do
  rc="$(run_wait "$green_rollup" "$body")"
  { [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
      && wait_out_has 'result=startup-failure'; } \
    && pass "a startup_failure run with no usable name still fails closed (#143)" \
    || fail "an unnamed startup_failure run concluded CI green — fails OPEN ($rc)"
done

# An empty rollup must not hang silently: the poll window ends in an explicit,
# actionable diagnosis saying WHY the gate refused.
rc="$(run_wait '[]')"
{ [ "$rc" = "rc=1" ] && wait_out_has '::error::phase=ci-wait result=no-checks' \
    && wait_out_has 'no CI checks at all'; } \
  && pass "empty rollup times out with an explicit no-checks diagnosis" \
  || fail "empty rollup failed without saying why ($rc)"

# --- preserved behaviour: real CI still decides the outcome ------------------
GRAPHQL_ROLLUP_RC=1 rc="$(GRAPHQL_ROLLUP_RC=1 run_wait "$green_rollup")"
unset GRAPHQL_ROLLUP_RC
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "repository REST checks remain readable when GraphQL rollup access is denied (#248)" \
  || fail "integration GraphQL denial still blocks a green REST snapshot ($rc)"

rc="$(run_wait '[
  {"name":"unit","status":"completed","conclusion":"success"},
  {"context":"deployment","state":"success"}
]')"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "lowercase REST check-run and commit-status values normalize to green (#248)" \
  || fail "REST casing made a green snapshot fail closed incorrectly ($rc)"

rc="$(run_wait '[
  {"name":"success","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"neutral","status":"COMPLETED","conclusion":"NEUTRAL"},
  {"name":"skipped","status":"COMPLETED","conclusion":"SKIPPED"}
]')"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "a genuinely green rollup still concludes green" \
  || fail "green rollup regressed ($rc)"

rc="$(run_wait '[{"name":"unit","status":"COMPLETED","conclusion":"FAILURE"}]')"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=failed' \
    && wait_out_has 'CI failed checks:' \
    && wait_out_has '"name":"unit"' \
    && wait_out_has '"conclusion":"FAILURE"'; } \
  && pass "a red rollup fails with an attributable compact snapshot (#240)" \
  || fail "red rollup was not attributable ($rc)"

CHECKS_RC=1 rc="$(CHECKS_RC=1 run_wait "$green_rollup")"
unset CHECKS_RC
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has '^::error::phase=ci-wait result=checks-unavailable' \
    && wait_out_has 'checks_endpoint_rc=1 statuses_endpoint_rc=0 aggregate_shape_rc=1' \
    && wait_out_has 'attempt=60/60' \
    && ! wait_out_has 'result=no-checks-allowed'; } \
  && pass "an unreadable repository checks endpoint fails closed (#248)" \
  || fail "unreadable repository checks were accepted ($rc)"

STATUSES_RC=1 rc="$(STATUSES_RC=1 run_wait "$green_rollup")"
unset STATUSES_RC
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has '^::error::phase=ci-wait result=checks-unavailable' \
    && wait_out_has 'attempt=60/60' \
    && ! wait_out_has 'result=no-checks-allowed'; } \
  && pass "an unreadable repository statuses endpoint fails closed (#248)" \
  || fail "unreadable repository statuses were accepted ($rc)"

printf '%s' '[{"message":"integration proxy error"}]' >"$tmp/bad-pages.json"
export CHECKS_PAGES_FILE="$tmp/bad-pages.json"
rc="$(run_wait '[]' "$no_startup_failures" 0 "$head_sha" true)"
unset CHECKS_PAGES_FILE
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has '^::error::phase=ci-wait result=checks-unavailable' \
    && wait_out_has 'attempt=60/60' \
    && ! wait_out_has 'result=no-checks-allowed'; } \
  && pass "wrong-shape check-run pages remain unreadable despite the absent-check opt-out (#248)" \
  || fail "wrong-shape check-run pages became an allowed empty snapshot ($rc)"

export STATUSES_PAGES_FILE="$tmp/bad-pages.json"
rc="$(run_wait '[]' "$no_startup_failures" 0 "$head_sha" true)"
unset STATUSES_PAGES_FILE
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has '^::error::phase=ci-wait result=checks-unavailable' \
    && wait_out_has 'attempt=60/60' \
    && ! wait_out_has 'result=no-checks-allowed'; } \
  && pass "wrong-shape status pages remain unreadable despite the absent-check opt-out (#248)" \
  || fail "wrong-shape status pages became an allowed empty snapshot ($rc)"

: >"$tmp/empty-pages.json"
export CHECKS_PAGES_FILE="$tmp/empty-pages.json"
rc="$(run_wait '[]' "$no_startup_failures" 0 "$head_sha" true)"
unset CHECKS_PAGES_FILE
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has '^::error::phase=ci-wait result=checks-unavailable' \
    && wait_out_has 'checks_endpoint_rc=0 statuses_endpoint_rc=0 aggregate_shape_rc='; } \
  && pass "an empty successful check-run response fails closed with shape diagnostics (#248)" \
  || fail "an empty check-run response became an allowed empty snapshot ($rc)"

printf '%s' '[{"total_count":2,"check_runs":[
  {"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}
]},{"total_count":2,"check_runs":[
  {"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}
]}]' >"$tmp/check-pages.json"
export CHECKS_PAGES_FILE="$tmp/check-pages.json"
rc="$(run_wait '[]')"
unset CHECKS_PAGES_FILE
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green' \
    && wait_out_has 'checks=2'; } \
  && pass "all paginated check-run pages participate in classification (#248)" \
  || fail "paginated check runs were dropped or misclassified ($rc)"

printf '%s' '[{"statuses":[
  {"context":"deploy","state":"SUCCESS"}
]},{"statuses":[
  {"context":"deploy","state":"FAILURE"}
]}]' >"$tmp/status-pages.json"
export STATUSES_PAGES_FILE="$tmp/status-pages.json"
rc="$(run_wait '[]')"
unset STATUSES_PAGES_FILE
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "newest commit status wins across REST pages (#248)" \
  || fail "an older duplicate commit status overrode the newest state ($rc)"

rc="$(run_wait '[{"name":"unit\n::error::injected","status":"COMPLETED","conclusion":"FAILURE"}]')"
{ [ "$rc" = "rc=1" ] \
    && grep -qF '\n::error::injected' "$tmp/wait-out.txt" \
    && ! grep -q '^::error::injected' "$tmp/wait-out.txt" \
    && [ "$(grep -c 'CI failed checks:' "$tmp/wait-out.txt")" -eq 1 ]; } \
  && pass "failed check names stay JSON-escaped on one log line (#240)" \
  || fail "failed check attribution allowed workflow-command line injection ($rc)"

# GitHub may expose a completed CheckRun before its conclusion field catches up.
# It is neither green nor terminal-red until the conclusion is populated.
ROLLUP_FILE2="$tmp/rollup2.json" ROLLUP_SWITCH_AFTER=1
export ROLLUP_FILE2 ROLLUP_SWITCH_AFTER
printf '%s' "$green_rollup" >"$ROLLUP_FILE2"
rc="$(run_wait '[{"name":"unit","status":"COMPLETED","conclusion":null}]')"
unset ROLLUP_FILE2 ROLLUP_SWITCH_AFTER
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green' \
    && ! wait_out_has 'result=failed'; } \
  && pass "a completed CheckRun waits for its conclusion before deciding (#240)" \
  || fail "a missing CheckRun conclusion was treated as terminal ($rc)"

# renovate/stability-days is a scheduler hold, not work this runner can advance.
# If it appears after preflight classification, fail immediately rather than
# occupying a runner for the full lane ceiling.
rc="$(run_wait '[{"context":"renovate/stability-days","state":"PENDING"}]')"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=stability-days-pending' && ! wait_out_has 'result=timeout' \
    && [ "$(cat "$tmp/checks-call.count")" = "1" ] \
    && [ "$(cat "$tmp/statuses-call.count")" = "1" ]; } \
  && pass "late stability-days status stops the gate without polling" \
  || fail "renovate/stability-days still consumed the polling window ($rc)"

for red_stability in \
  '[{"context":"renovate/stability-days","state":"ERROR"}]' \
  '[{"name":"renovate/stability-days","status":"COMPLETED","conclusion":"FAILURE"}]'; do
  rc="$(TEST_EVENT_NAME=workflow_dispatch run_wait "$red_stability")"
  { [ "$rc" = "rc=1" ] && wait_out_has 'result=failed'; } \
    && pass "failed stability-named check remains terminal under workflow_dispatch" \
    || fail "workflow_dispatch ignored a failed stability-named check ($rc)"
done

# --- failure modes of the probe itself ---------------------------------------
# An unreadable probe cannot prove absence of a startup failure, so it must never
# conclude green — and when it never recovers the terminal error must name the
# probe, not blame a phantom pending check.
rc="$(run_wait '[{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}]' "$no_startup_failures" 22)"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has '::error::phase=ci-wait result=probe-unavailable'; } \
  && pass "an unreadable startup-failure probe fails closed and names itself" \
  || fail "unreadable probe concluded green or gave no diagnosis ($rc)"

# A NON-ZERO exit is only one way the probe can fail. A proxy or edge cache can
# answer 2xx with an HTML error page, and a truncated response parses as
# nothing — in both cases `gh api` exits 0 and the body is not the payload we
# asked for. Swallowing jq's parse error yields an empty startup-failure list,
# which is byte-identical to "no startup failures" and re-opens the exact hole
# this gate exists to close.
rc="$(run_wait "$green_rollup" '<html>502 bad gateway</html>')"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has 'result=probe-unavailable'; } \
  && pass "an unparseable 2xx probe body is inconclusive, never green" \
  || fail "unparseable probe body concluded CI green — fails OPEN ($rc)"

rc="$(run_wait "$green_rollup" '')"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has 'result=probe-unavailable'; } \
  && pass "an empty 2xx probe body is inconclusive, never green" \
  || fail "empty probe body concluded CI green — fails OPEN ($rc)"

# Valid JSON of the WRONG SHAPE is the subtler variant: `.workflow_runs[]?` on an
# object without that key yields nothing, so a well-formed decoy (an error
# object, a paginated envelope we did not expect) reads as "clean".
# The key PRESENT but not an array is the case that separates a real shape
# assertion from a vacuous one: `has("workflow_runs")` alone waves it through,
# and `.workflow_runs[]?` on an object yields nothing — i.e. reads as "clean".
for bad_body in '{"message":"Not Found","status":"404"}' '{"workflow_runs":{}}' '{"workflow_runs":null}' '{"workflow_runs":"notanarray"}'; do
  rc="$(run_wait "$green_rollup" "$bad_body")"
  { [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
      && wait_out_has 'result=probe-unavailable'; } \
    && pass "a well-formed probe body of the wrong shape is inconclusive [$bad_body]" \
    || fail "wrong-shape probe body [$bad_body] concluded CI green — fails OPEN ($rc)"
done

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

# The REALISTIC bad head SHA is not "" but the literal string "null": `jq -r`
# prints that for a missing key, it is non-empty (so an `-z` test waves it
# through), and `?head_sha=null` returns zero runs — a probe that "proves"
# cleanliness about a commit it never looked at.
for bad_sha in null NULL 'deadbeef' '../../etc' '0123456789ABCDEF0123456789ABCDEF01234567'; do
  rc="$(run_wait '[{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}]' "$no_startup_failures" 0 "$bad_sha")"
  { [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' && wait_out_has 'result=unknown-head'; } \
    && pass "a malformed head SHA [$bad_sha] fails closed as unknown-head" \
    || fail "malformed head SHA [$bad_sha] was accepted as a commit ($rc)"
done

# --- #143 / path-filtered CI: absence must be decided FAST, and be escapable ---
# A workflow whose `paths:` filter does not match never runs and emits no check
# run, so the rollup can never fill. Polling that for the full 30-40 minute
# window burns a self-hosted runner to reach a conclusion available in seconds.
# "No workflow runs" means no runs OTHER than the gate's own — see gate_own_run.
no_runs="{\"total_count\":1,\"workflow_runs\":[$gate_own_run]}"
rc="$(run_wait '[]' "$no_runs")"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=no-checks' && wait_out_has 'attempts=10'; } \
  && pass "no checks AND no workflow runs fails closed after a short grace, not the full window" \
  || fail "an untriggerable PR burned the whole poll window ($rc)"

# Fail-closed is the DEFAULT, not the only option: a genuinely check-free PR
# (docs-only under a paths filter) needs a path forward, and the default error
# must name it. Reads the output of the run immediately above.
wait_out_has 'allow_absent_checks=true' \
  && pass "the no-checks failure names its explicit opt-out" \
  || fail "no-checks failed with no path forward for a legitimately check-free PR"

# The other side of that shortcut: the grace must be wide enough that a check
# which is merely SLOW to register still wins. Registration is not instant, and
# the runs API can lag the check API, so a too-tight grace turns a slow-starting
# green PR into a hard `no-checks` failure.
ROLLUP_FILE2="$tmp/rollup2.json" ROLLUP_SWITCH_AFTER=6
export ROLLUP_FILE2 ROLLUP_SWITCH_AFTER
printf '%s' "$green_rollup" >"$tmp/rollup2.json"
rc="$(run_wait '[]' "$no_runs")"
unset ROLLUP_FILE2 ROLLUP_SWITCH_AFTER
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green' && ! wait_out_has 'result=no-checks'; } \
  && pass "a check that only registers on a later poll still beats the no-checks shortcut" \
  || fail "the grace window cut off a slow-to-register check ($rc)"

rc="$(run_wait '[]' "$no_runs" 0 "$head_sha" true)"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=no-checks-allowed' \
    && wait_out_has '::warning::'; } \
  && pass "allow_absent_checks=true proceeds, and says so as a warning" \
  || fail "explicit allow_absent_checks opt-out did not let a check-free PR through ($rc)"

# The opt-out is opt-IN: with the variable absent entirely (a caller that never
# passes the input), the fallback must be strict. Every other case sets the
# variable, so without this the `:-false` default is unpinned.
rc="$(run_wait '[]' "$no_runs" 0 "$head_sha" '<unset>')"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=no-checks' \
    && ! wait_out_has 'result=no-checks-allowed'; } \
  && pass "an unset ALLOW_ABSENT_CHECKS falls back to strict, not to the opt-out" \
  || fail "the absent-checks opt-out defaults ON when the variable is unset ($rc)"

# The opt-out is bounded: it excuses ABSENT checks, never BROKEN ones.
rc="$(run_wait '[]' "$startup" 0 "$head_sha" true)"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=startup-failure'; } \
  && pass "allow_absent_checks does not excuse a startup_failure run" \
  || fail "the opt-out waved through a workflow that died at startup ($rc)"

# --- S5: a stale probe failure must not mislabel a genuine pending timeout ----
# Probe fails on the first attempts while the rollup is still empty; then a real
# check registers and hangs. The terminal diagnosis must be the hung check, not
# "re-run once the API is reachable".
SUITES_FAIL_FIRST=2 ROLLUP_FILE2="$tmp/rollup2.json" ROLLUP_SWITCH_AFTER=2
export SUITES_FAIL_FIRST ROLLUP_FILE2 ROLLUP_SWITCH_AFTER
printf '%s' '[{"name":"unit","status":"IN_PROGRESS"}]' >"$tmp/rollup2.json"
rc="$(run_wait '[]')"
unset SUITES_FAIL_FIRST ROLLUP_FILE2 ROLLUP_SWITCH_AFTER
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=timeout' \
    && ! wait_out_has '::error::phase=ci-wait result=probe-unavailable'; } \
  && pass "an early transient probe failure does not mislabel a later hung check" \
  || fail "a hung check was reported as probe-unavailable ($rc)"

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
  export GITHUB_EVENT_NAME="${TEST_EVENT_NAME:-pull_request}"
  export LANE=ai LANE_REASON="code change" EXPECTED_HEAD_SHA="$head_sha"
  export ROLLUP_FILE="$tmp/rollup.json" SUITES_FILE="$tmp/suites.json"
  export META_FILE="$tmp/meta.json" ACTIONLOG="$tmp/actions.log"
  export SUITES_RC="${3:-0}"
  if [ "${4:-false}" = "<unset>" ]; then unset ALLOW_ABSENT_CHECKS; else export ALLOW_ABSENT_CHECKS="${4:-false}"; fi
  export ROLLUPCOUNT="$tmp/rollup.count" APICOUNT="$tmp/api.count"
  export SUITES_FAIL_FIRST="${SUITES_FAIL_FIRST:-0}" ROLLUP_FILE2="" ROLLUP_SWITCH_AFTER=0
  rm -f "$ROLLUPCOUNT" "$APICOUNT"
  printf '{"labels":[],"title":"feat: x","isDraft":false,"state":"OPEN","headRefOid":"%s"}' "$head_sha" >"$META_FILE"
  printf '%s' "$1" >"$ROLLUP_FILE"
  printf '%s' "${2-$no_startup_failures}" >"$SUITES_FILE"
  : >"$ACTIONLOG"
  bash "$merge_script" >"$tmp/merge-out.txt" 2>&1
  echo "rc=$?"
}
merged() { grep -q '^MERGE ' "$tmp/actions.log"; }
merge_out_has() { grep -q "$1" "$tmp/merge-out.txt"; }

SELF_JOBS_RC=127
GITHUB_REPOSITORY=Verjson/foo
RUNNER_NAME=gha-general-7
export SELF_JOBS_RC GITHUB_REPOSITORY RUNNER_NAME
rc="$(run_merge "$green_rollup")"
unset SELF_JOBS_RC GITHUB_REPOSITORY RUNNER_NAME
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=toolchain-missing'; } \
  && pass "merge recheck self-job enumeration fails fast when gh disappears" \
  || fail "merge recheck swallowed exit 127 while enumerating its own jobs ($rc)"

JQ_FAIL_AGGREGATE=true
export JQ_FAIL_AGGREGATE
rc="$(run_merge "$green_rollup")"
unset JQ_FAIL_AGGREGATE
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=toolchain-missing' && merge_out_has 'aggregate_shape_rc=127'; } \
  && pass "merge recheck aggregation-time jq loss is terminal" \
  || fail "merge recheck misclassified aggregation-time jq loss ($rc)"

rc="$(run_merge '[]')"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=no-checks'; } \
  && pass "merge recheck refuses to merge a PR with no checks at all (#143)" \
  || fail "merge recheck merged a PR whose rollup was empty ($rc)"

rc="$(run_merge "$green_rollup" "$startup")"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=startup-failure' && merge_out_has 'node-ci'; } \
  && pass "merge recheck refuses to merge past a startup_failure run (#143)" \
  || fail "merge recheck merged despite a startup_failure run ($rc)"

rc="$(run_merge '[{"name":"unit","status":"COMPLETED","conclusion":null}]')"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=pending'; } \
  && pass "merge recheck refuses a completed CheckRun without a conclusion (#240)" \
  || fail "merge recheck misclassified a missing CheckRun conclusion ($rc)"

# The merge step is where a name-keyed verdict actually costs something: an
# unnamed startup_failure would be squash-merged. Both copies must key on the
# count — divergence between the wait rule and the merge rule is the original
# bug class (#143).
for body in "$unnamed_startup" "$blank_startup"; do
  rc="$(run_merge "$green_rollup" "$body")"
  { [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=startup-failure'; } \
    && pass "merge recheck refuses a startup_failure run with no usable name (#143)" \
    || fail "merge recheck MERGED past an unnamed startup_failure run ($rc)"
done

rc="$(run_merge "$green_rollup" "$no_startup_failures" 22)"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=probe-unavailable'; } \
  && pass "merge recheck refuses to merge on an unverifiable probe" \
  || fail "merge recheck merged without verifying the absence probe ($rc)"

export CHECKS_PAGES_FILE="$tmp/bad-pages.json"
rc="$(run_merge '[]' "$no_runs" 0 true)"
unset CHECKS_PAGES_FILE
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=checks-unavailable'; } \
  && pass "merge recheck rejects wrong-shape check-run pages before the absent-check opt-out (#248)" \
  || fail "merge recheck treated malformed check-run pages as allowed absence ($rc)"

export STATUSES_PAGES_FILE="$tmp/bad-pages.json"
rc="$(run_merge '[]' "$no_runs" 0 true)"
unset STATUSES_PAGES_FILE
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=checks-unavailable'; } \
  && pass "merge recheck rejects wrong-shape status pages before the absent-check opt-out (#248)" \
  || fail "merge recheck treated malformed status pages as allowed absence ($rc)"

# Same 2xx-with-a-bad-body class as ci-wait, but here the consequence is an
# irreversible squash-merge rather than a wasted poll window.
for bad_body in '<html>502 bad gateway</html>' '' '{"message":"Not Found","status":"404"}' '{"workflow_runs":{}}'; do
  rc="$(run_merge "$green_rollup" "$bad_body")"
  { [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=probe-unavailable'; } \
    && pass "merge recheck treats an unusable probe body as inconclusive [${bad_body:-<empty>}]" \
    || fail "merge recheck MERGED on an unusable probe body [${bad_body:-<empty>}] ($rc)"
done

# The merge step must honour the SAME opt-out as ci-wait: otherwise ci-wait lets
# a legitimately check-free PR through and the merge step blocks it anyway,
# after the model review has been paid for.
rc="$(run_merge '[]' "$no_runs" 0 true)"
{ [ "$rc" = "rc=0" ] && merged && merge_out_has 'result=no-checks-allowed'; } \
  && pass "merge recheck honours the explicit allow_absent_checks opt-out" \
  || fail "the opt-out did not reach the merge step ($rc)"

rc="$(run_merge '[]' "$startup" 0 true)"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=startup-failure'; } \
  && pass "merge recheck's opt-out still refuses a startup_failure run" \
  || fail "the opt-out let the merge step merge past a startup_failure ($rc)"

rc="$(run_merge '[]' "$no_runs" 0 '<unset>')"
{ [ "$rc" = "rc=1" ] && ! merged && merge_out_has 'result=no-checks'; } \
  && pass "merge recheck with ALLOW_ABSENT_CHECKS unset falls back to strict" \
  || fail "the merge step's opt-out defaults ON when the variable is unset ($rc)"

# A transient probe blip at merge time must not discard an already-paid-for AI
# review and demand a manual re-dispatch: retry a bounded few times first.
SUITES_FAIL_FIRST=2 rc="$(SUITES_FAIL_FIRST=2 run_merge "$green_rollup")"
unset SUITES_FAIL_FIRST
{ [ "$rc" = "rc=0" ] && merged && merge_out_has 'result=probe-retry'; } \
  && pass "merge recheck retries a transient probe failure instead of discarding the review" \
  || fail "a single transient probe blip aborted the merge ($rc)"

rc="$(run_merge "$green_rollup")"
{ [ "$rc" = "rc=0" ] && merged; } \
  && pass "a genuinely green PR still merges" \
  || fail "green PR no longer merges ($rc)"

# --- wiring: the opt-out must exist on BOTH public surfaces, defaulting strict --
# The behavioural tests above inject ALLOW_ABSENT_CHECKS directly, so they cannot
# see whether the input is actually declared and mapped. Without this pin the
# escape hatch could be unreachable (or, worse, default-on) while every test
# still passed.
for surface in workflow_dispatch workflow_call; do
  decl="$(awk -v want="  $surface:" '
    $0 == want { seen = 1; next }
    seen && /^  [a-z_]+:/ { exit }
    seen && /^      allow_absent_checks:/ { cap = 1; next }
    cap && substr($0, 1, 8) != "        " { exit }
    cap { print }
  ' "$wf")"
  { [ -n "$decl" ] && grep -q 'default: false' <<<"$decl"; } \
    && pass "$surface exposes allow_absent_checks, defaulting to strict" \
    || fail "allow_absent_checks is missing or not default-false on $surface"
done

[ "$(grep -c 'ALLOW_ABSENT_CHECKS: ${{ inputs.allow_absent_checks || false }}' "$wf")" -eq 2 ] \
  && pass "both ci_wait and the merge recheck receive the opt-out" \
  || fail "the opt-out input is not mapped into both steps' env"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
