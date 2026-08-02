#!/usr/bin/env bash
# Tests that the merge gate excludes ITS OWN jobs from the required checks it
# waits on, under every installation shape ADR 0039 supports (Verjson/.github#276).
#
# A reusable `workflow_call` publishes the callee's checks as
# "<caller job> / <callee job>", so a consumer that installs the gate with
# `uses: Verjson/.github/.github/workflows/ai-review-merge.yml` sees the gate's
# own jobs as "ci / preflight", "ci / gate", "ci / dispatch-merge". The filter
# matched bare names by exact equality, so the gate enumerated its own jobs as
# required checks and waited for itself until the poll window ran out —
# reported as "trusted gate/checks did not become green", which points nowhere
# near the cause.
#
# The fix derives the gate's own job names at RUNTIME from
# `repos/<repo>/actions/runs/<run id>/jobs`, which reports them exactly as
# GitHub published them, prefixed or not. Two properties are pinned here because
# both have a plausible-looking wrong implementation:
#
#   1. NOT name normalization. Stripping everything before "/" keys on the
#      CALLEE segment, so an unrelated consumer check named "security / review"
#      or "release / gate" silently drops out of the required set — a fail-open
#      in someone else's repository. The unrelated-consumer cases below fail
#      under any such implementation.
#   2. A UNION with the static list, not a replacement. Jobs are created as they
#      start, so at wait time the run cannot enumerate its own not-yet-created
#      downstream jobs (`dispatch-merge`, `ai-merge`). The static list stays as
#      the floor; dropping it turns those into required checks again.
#
# Same house method as ci-wait-fail-closed.test.sh: awk-extract the exact `run:`
# block from ai-review-merge.yml (single source of truth) and exercise it
# against a stubbed `gh`. Plain bash + awk + jq.
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
  # extract <step-id> <destination>. Capture stops at the first line that leaves
  # the `run: |` body, so a later step cannot be concatenated onto the script.
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
grep -q '/check-runs?per_page=100' "$wait_script" \
  || { echo "FAIL - could not extract ci_wait run block from $wf"; exit 1; }

merge_script="$tmp/merge.sh"
extract merge "$merge_script"
grep -q 'pr merge' "$merge_script" \
  || { echo "FAIL - could not extract merge run block from $wf"; exit 1; }

# Both snapshots must self-derive. The authoritative recheck is the step that
# actually squash-merges, so a fix applied only to the polling step would still
# deadlock the consumer at merge time.
jobs_endpoint_uses=$(grep -c 'actions/runs/\$GITHUB_RUN_ID/jobs' "$wf")
[ "$jobs_endpoint_uses" -ge 2 ] \
  && pass "both CI snapshots derive the gate's own job names from the runs/jobs API (#276)" \
  || fail "only $jobs_endpoint_uses of 2 CI snapshots self-derive their own job names (#276)"

head_sha='0123456789abcdef0123456789abcdef01234567'
gate_run_id=424242

mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"

# Fake `gh`. Every stubbed branch returns a well-formed payload and applies the
# `--jq` filter itself; anything unstubbed exits non-zero and says so, because
# falling through to a bare `exit 0` with empty stdout is exactly the fail-open
# shape these guards exist to prevent.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
ARGV=("$@")
emit() {
  local payload="$1" filter="" i
  for ((i = 0; i < ${#ARGV[@]}; i++)); do
    [ "${ARGV[$i]}" = "--jq" ] && filter="${ARGV[$((i + 1))]}"
  done
  if [ -n "$filter" ]; then
    jq -r "$filter" <<<"$payload"
  else
    printf '%s\n' "$payload"
  fi
}
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then cat "$META_FILE"; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then printf 'MERGE %s\n' "$*" >>"$ACTIONLOG"; exit 0; fi
if [ "$1" = "pr" ]; then exit 0; fi
if [ "$1" = "api" ]; then
  case "$*" in
    */actions/runs/*/jobs*)
      # `emit`'s status is the exit status: a body the `--jq` filter cannot be
      # applied to makes the real `gh` exit non-zero, and swallowing that here
      # would test a fallback path production never reaches.
      [ "${SELF_JOBS_RC:-0}" = "0" ] && { emit "$(cat "$SELF_JOBS_FILE")"; exit $?; }
      echo "gh: HTTP 403" >&2
      exit "$SELF_JOBS_RC" ;;
    */check-runs\?per_page=100*)
      emit "$(jq -c '{total_count: ([.[] | select(has("status"))] | length), check_runs: [.[] | select(has("status"))]}' "$ROLLUP_FILE")"
      exit 0 ;;
    */status\?per_page=100*)
      emit "$(jq -c '{statuses: [.[] | select(has("state"))]}' "$ROLLUP_FILE")"
      exit 0 ;;
    */actions/runs\?head_sha=*)
      emit "$(cat "$SUITES_FILE")"
      exit 0 ;;
  esac
fi
echo "gh: unstubbed call: $*" >&2
exit 64
GH
chmod +x "$tmp/bin/gh"

# The gate is itself a run on the reviewed head, so this query is never empty.
no_startup_failures="{\"total_count\":2,\"workflow_runs\":[
  {\"id\":$gate_run_id,\"name\":\"AI review + auto-merge\",\"conclusion\":null,\"head_sha\":\"$head_sha\"},
  {\"id\":11,\"name\":\"node-ci\",\"conclusion\":\"success\",\"head_sha\":\"$head_sha\"}
]}"

jobs_payload() {
  # jobs_payload <name>... -> the Actions runs/jobs response for this run
  local out=() n
  for n in "$@"; do out+=("$(jq -n --arg n "$n" '{id: 1, name: $n, status: "in_progress"}')"); done
  jq -n --argjson jobs "$(printf '%s\n' "${out[@]:-}" | jq -s -c '.')" \
    '{total_count: ($jobs | length), jobs: $jobs}'
}

# The reusable (`workflow_call`) shape: GitHub prefixes the callee's job names
# with the caller's job id.
prefixed_jobs="$(jobs_payload 'ci / preflight' 'ci / gate')"
# The org required-workflow shape (how Verjson installs it): un-prefixed.
bare_jobs="$(jobs_payload 'preflight' 'gate')"

setup_env() {
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/consumer" PR_NUMBER=7
  export GITHUB_REPOSITORY="Verjson/consumer" GITHUB_RUN_ID="$gate_run_id"
  export LANE=ai LANE_REASON="code change" EXPECTED_HEAD_SHA="$head_sha"
  export ALLOW_ABSENT_CHECKS=false
  export ROLLUP_FILE="$tmp/rollup.json" SUITES_FILE="$tmp/suites.json"
  export SELF_JOBS_FILE="$tmp/self-jobs.json" META_FILE="$tmp/meta.json"
  export ACTIONLOG="$tmp/actions.log"
  export SELF_JOBS_RC="${SELF_JOBS_RC:-0}"
  printf '%s' "$1" >"$ROLLUP_FILE"
  printf '%s' "$2" >"$SELF_JOBS_FILE"
  printf '%s' "$no_startup_failures" >"$SUITES_FILE"
  printf '{"labels":[],"title":"feat: x","isDraft":false,"state":"OPEN","headRefOid":"%s"}' \
    "$head_sha" >"$META_FILE"
  : >"$ACTIONLOG"
}

run_wait() {
  # run_wait <rollup-json> <self-jobs-json>
  setup_env "$1" "$2"
  bash "$wait_script" >"$tmp/wait-out.txt" 2>&1
  echo "rc=$?"
}
wait_out_has() { grep -q "$1" "$tmp/wait-out.txt"; }

# --- #276: the reusable shape must not wait on the gate's own prefixed jobs ---
# "ci / preflight" and "ci / gate" ARE this run's own jobs (the runs/jobs API
# says so); "unit" is the consumer's real CI and is green, so the gate is green.
reusable_rollup='[
  {"name":"ci / preflight","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"ci / gate","status":"IN_PROGRESS","conclusion":null},
  {"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"},
  {"context":"deployment","state":"SUCCESS"}
]'
rc="$(run_wait "$reusable_rollup" "$prefixed_jobs")"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "reusable-call install does not wait on its own prefixed jobs (#276)" \
  || fail "gate deadlocked on its own '<caller> / <job>' checks ($rc)"

# --- the org required-workflow shape (how Verjson installs it) still works ---
# Runtime derivation must not regress the un-prefixed install: the API reports
# bare names there, and the union with the static list is still the whole set.
bare_rollup='[
  {"name":"preflight","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"gate","status":"IN_PROGRESS","conclusion":null},
  {"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"},
  {"context":"deployment","state":"SUCCESS"}
]'
rc="$(run_wait "$bare_rollup" "$bare_jobs")"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "required-workflow install still ignores its own un-prefixed jobs" \
  || fail "self-derivation regressed the org required-workflow shape ($rc)"

# --- NOT name normalization: an unrelated consumer check stays required -------
# `security / review` and `release / gate` end in a segment the static list
# names, but they are NOT this run's jobs. Stripping everything before "/" would
# drop both out of the required set and merge on an unheld review — fail-open in
# the consumer's repository. Provenance says they are somebody else's checks.
foreign_pending='[
  {"name":"ci / preflight","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"ci / gate","status":"IN_PROGRESS","conclusion":null},
  {"name":"security / review","status":"IN_PROGRESS","conclusion":null},
  {"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}
]'
rc="$(run_wait "$foreign_pending" "$prefixed_jobs")"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has 'pending=security / review'; } \
  && pass "an unrelated consumer check ending in '/ review' stays required (#276)" \
  || fail "a foreign check was excluded by callee-segment matching — fail-open ($rc)"

foreign_failed='[
  {"name":"ci / preflight","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"ci / gate","status":"IN_PROGRESS","conclusion":null},
  {"name":"release / gate","status":"COMPLETED","conclusion":"FAILURE"},
  {"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}
]'
rc="$(run_wait "$foreign_failed" "$prefixed_jobs")"
{ [ "$rc" = "rc=1" ] && wait_out_has 'result=failed' && wait_out_has 'release / gate'; } \
  && pass "a red consumer check ending in '/ gate' still fails the gate (#276)" \
  || fail "a red foreign check was filtered out of the required set ($rc)"

# --- UNION, not replacement: the static list is the floor --------------------
# `dispatch-merge` and `ai-merge` have not started yet, so this run's jobs API
# cannot name them. Replacing the static list with the derived one would make
# the gate's own downstream jobs required and reintroduce the deadlock.
not_yet_created='[
  {"name":"ci / preflight","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"ci / gate","status":"IN_PROGRESS","conclusion":null},
  {"name":"dispatch-merge","status":"IN_PROGRESS","conclusion":null},
  {"name":"ai-merge","status":"IN_PROGRESS","conclusion":null},
  {"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}
]'
rc="$(run_wait "$not_yet_created" "$prefixed_jobs")"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "not-yet-created downstream jobs stay excluded by the static floor (#276)" \
  || fail "the derived set replaced the static list and re-deadlocked ($rc)"

# The trusted continuation runs in a separate workflow, so it is never in this
# run's jobs at all — only the literal covers it, prefixed or not.
continuation='[
  {"name":"ci / preflight","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"privileged_merge","status":"IN_PROGRESS","conclusion":null},
  {"name":"trusted / privileged_merge","status":"IN_PROGRESS","conclusion":null},
  {"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}
]'
rc="$(run_wait "$continuation" "$prefixed_jobs")"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "the trusted continuation check is still excluded by its literal" \
  || fail "the continuation check became a required check ($rc)"

# --- failure modes: an unreadable jobs API is never a licence to exclude more -
SELF_JOBS_RC=1 rc="$(SELF_JOBS_RC=1 run_wait "$foreign_pending" "$prefixed_jobs")"
unset SELF_JOBS_RC
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has 'result=self-jobs-unavailable' \
    && wait_out_has 'result=timeout.*security / review'; } \
  && pass "an unreadable jobs API falls back to the static floor and says so" \
  || fail "a failed self-derivation changed which checks are required ($rc)"

# A 2xx carrying a body the filter cannot be applied to (a proxy's HTML error
# page, a truncated payload) must be treated exactly like an outage, not like
# "this run has no jobs and no names to trust".
rc="$(run_wait "$foreign_pending" '<html>502 Bad Gateway</html>')"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' \
    && wait_out_has 'result=self-jobs-unavailable'; } \
  && pass "an unparseable jobs payload is an outage, not an empty job list" \
  || fail "a malformed jobs payload was accepted as a derived name set ($rc)"

# `name` is nullable in the jobs schema. Rendered naively it becomes the literal
# string "null", which would exclude a consumer check that happens to be called
# `null` — a real check silently dropped from the required set.
null_named_jobs='{"total_count":2,"jobs":[
  {"id":1,"name":null,"status":"in_progress"},
  {"id":2,"name":"","status":"in_progress"}
]}'
null_rollup='[
  {"name":"null","status":"IN_PROGRESS","conclusion":null},
  {"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}
]'
rc="$(run_wait "$null_rollup" "$null_named_jobs")"
{ [ "$rc" = "rc=1" ] && ! wait_out_has 'result=green' && wait_out_has 'pending=null'; } \
  && pass "a null job name does not excuse a consumer check literally named null" \
  || fail "a nullable job name rendered into the exclusion set and dropped a check ($rc)"

run_merge() {
  # run_merge <rollup-json> <self-jobs-json>
  setup_env "$1" "$2"
  bash "$merge_script" >"$tmp/merge-out.txt" 2>&1
  echo "rc=$?"
}
merged() { grep -q '^MERGE ' "$tmp/actions.log"; }

# The authoritative recheck is the step that actually squash-merges, and it
# re-reads the rollup itself — a fix applied only to the polling step would move
# the deadlock rather than remove it.
rc="$(run_merge "$reusable_rollup" "$prefixed_jobs")"
{ [ "$rc" = "rc=0" ] && merged; } \
  && pass "merge recheck does not block on its own prefixed jobs (#276)" \
  || fail "merge recheck refused to merge because of the gate's own checks ($rc)"

printf '\n'
[ "$fails" -eq 0 ] && { echo "all self-job exclusion assertions passed"; exit 0; }
echo "$fails assertion(s) failed"
exit 1
