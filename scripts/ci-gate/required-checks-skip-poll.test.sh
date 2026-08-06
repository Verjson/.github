#!/usr/bin/env bash
# Tests ADR 0058 step 6, conditional per repository (Verjson/.github#341): the
# merge gate stops polling the commit rollup in a repository that has already
# declared required status checks, because GitHub is blocking the merge on those
# contexts itself. Where no such rule exists — 66 of 91 org repositories on
# 2026-08-06 — the gate MUST keep polling, or that repository's CI silently
# becomes advisory, which ADR 0058 calls a worse defect than the deadlock it
# removes.
#
# Same house method as ci-wait-fail-closed.test.sh: awk-extract the exact `run:`
# block of the `ci_wait` step from ai-review-merge.yml — single source of truth,
# so the test cannot drift from the shipped logic — and exercise it against a
# stubbed `gh`.
#
# Plain bash + awk + jq; no test-framework dependency (runs on the bare pool).
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

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

# --- extraction --------------------------------------------------------------
# Capture stops at the FIRST line that leaves the `run: |` body. Clearing `cap`
# alone is not enough: `seen` stays set, so the next step's `run: |` re-arms
# capture and every later step is concatenated onto the script under test.
script="$tmp/ci-wait.sh"
awk '
  $0 == "        id: ci_wait" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap && $0 ~ /^      - name:/ { exit }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$script"

# Bound the extraction by SIZE as well as by structure. A step that is reshaped
# — or a second `run:` block that leaks in — changes the line count long before
# it changes the marker strings, and an unbounded extraction is how a test ends
# up exercising something other than the step it names (ci_wait once extracted
# as 529 lines).
lines="$(wc -l <"$script")"
{ [ "$lines" -ge 330 ] && [ "$lines" -le 460 ]; } \
  && pass "extracted ci_wait step is $lines lines (bounded 330..460)" \
  || fail "extracted ci_wait step is $lines lines, outside the expected 330..460 band"

# The extracted text must be a runnable shell script, not a workflow fragment: a
# surviving `${{ }}` would be a bash parse error, and it would also mean a
# PR-controlled value reaches the shell instead of arriving through `env:`.
grep -q '\${{' "$script" \
  && fail "extracted step still contains a \${{ }} expression" \
  || pass "extracted step is pure shell; every input arrives through env:"

for marker in 'set -euo pipefail' '/check-runs?per_page=100'; do
  grep -qF "$marker" "$script" \
    || { echo "FAIL - could not extract the ci_wait run block from $wf (missing: $marker)"; exit 1; }
done

# --- stub gh -----------------------------------------------------------------
# Every call is logged, because the assertion this file exists to make is about
# which endpoints the gate touches, not only about its exit code. The stub NEVER
# exits 0 silently for an unrecognised call: a fall-through that looks like
# success is exactly how a fail-open ships (#143).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >>"$CALLLOG"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  [ "${BASE_VIEW_RC:-0}" = "0" ] || { echo "gh: could not resolve PR" >&2; exit "$BASE_VIEW_RC"; }
  printf '%s\n' "${BASE_VIEW_OUT-}"
  exit 0
fi
if [ "$1" = "api" ]; then
  for arg in "$@"; do
    case "$arg" in
      */rules/branches/*)
        [ "${RULES_RC:-0}" = "0" ] || { echo "gh: api error" >&2; exit "$RULES_RC"; }
        cat "$RULES_FILE"
        exit 0 ;;
      */actions/runs/*/jobs\?per_page=100*)
        printf '%s\n' "gate"
        exit 0 ;;
      */check-runs\?per_page=100*)
        jq -c '{total_count: ([.[] | select(has("status"))] | length), check_runs: [.[] | select(has("status"))]}' "$ROLLUP_FILE"
        exit 0 ;;
      */status\?per_page=100*)
        jq -c '{statuses: [.[] | select(has("state"))]}' "$ROLLUP_FILE"
        exit 0 ;;
      */actions/runs\?head_sha=*)
        cat "$SUITES_FILE"
        exit 0 ;;
    esac
  done
fi
echo "unexpected gh call: $*" >&2
exit 64
GH
chmod +x "$tmp/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"

# A real 40-hex commit SHA: the gate validates the shape of EXPECTED_HEAD_SHA
# before interpolating it into an API URL, so a placeholder would exercise the
# reject path instead of the path under test.
head_sha='0123456789abcdef0123456789abcdef01234567'
gate_run_id=424242
gate_own_run="{\"id\":$gate_run_id,\"name\":\"AI review + auto-merge\",\"conclusion\":null,\"head_sha\":\"$head_sha\"}"
no_startup_failures="{\"total_count\":2,\"workflow_runs\":[
  $gate_own_run,
  {\"id\":11,\"name\":\"node-ci\",\"conclusion\":\"success\",\"head_sha\":\"$head_sha\"}
]}"
# Green on the first tick, so a run that DOES poll still finishes fast. The
# distinguishing signal in every case below is whether the rollup was read at
# all, never the exit code alone.
green_rollup='[{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"}]'

# The live shape, verified against Verjson/verjson-email on 2026-08-06.
rules_with_required_checks='[
  {"type":"deletion","ruleset_id":18098028,"ruleset_source_type":"Organization","parameters":null},
  {"type":"required_status_checks","ruleset_id":20515817,"ruleset_source_type":"Organization",
   "parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":true,
     "required_status_checks":[{"context":"ci / build-test"},{"context":"ci / eligibility"}]}}
]'

run_wait() {
  # run_wait <rules-json>
  export PATH="$tmp/bin:$PATH"
  export TARGET_REPO="${TARGET_REPO:-Verjson/foo}" PR_NUMBER="${PR_NUMBER:-7}" LANE=ai
  export GITHUB_REPOSITORY="Verjson/foo" GITHUB_RUN_ID="$gate_run_id"
  export EXPECTED_HEAD_SHA="${EXPECTED_HEAD_SHA:-$head_sha}"
  export ALLOW_ABSENT_CHECKS=false RUNNER_NAME=gha-general-7
  export ROLLUP_FILE="$tmp/rollup.json" SUITES_FILE="$tmp/suites.json"
  export RULES_FILE="$tmp/rules.json" CALLLOG="$tmp/calls.log"
  export RULES_RC="${RULES_RC:-0}"
  export BASE_VIEW_RC="${BASE_VIEW_RC:-0}" BASE_VIEW_OUT="${BASE_VIEW_OUT-main}"
  printf '%s' "$green_rollup" >"$ROLLUP_FILE"
  printf '%s' "$no_startup_failures" >"$SUITES_FILE"
  printf '%s' "$1" >"$RULES_FILE"
  : >"$CALLLOG"
  bash "$script" >"$tmp/out.txt" 2>&1
  echo "rc=$?"
}
out_has() { grep -qF "$1" "$tmp/out.txt"; }
polled() { grep -q '/check-runs' "$tmp/calls.log"; }

# --- the behaviour the ticket asks for ---------------------------------------
# GitHub is already blocking the merge on `ci / build-test` and `ci / eligibility`
# for this base branch, so the gate has nothing to add by holding a runner for up
# to 30 minutes to observe the same thing (#341, ADR 0058 step 6).
BASE_BRANCH=main
export BASE_BRANCH
rc="$(run_wait "$rules_with_required_checks")"
{ [ "$rc" = "rc=0" ] && ! polled && out_has 'result=required-checks-declared'; } \
  && pass "a base branch with declared required checks skips the poll loop" \
  || fail "the gate still polled the rollup where GitHub already requires checks (rc=$rc)"

# The 66-repository majority: rules exist on the branch, but none of them
# require a status check. Nothing else is watching CI here, so the gate must.
rules_without_required_checks='[
  {"type":"deletion","ruleset_id":18098028,"ruleset_source_type":"Organization","parameters":null},
  {"type":"non_fast_forward","ruleset_id":18098028,"ruleset_source_type":"Organization","parameters":null}
]'
rc="$(run_wait "$rules_without_required_checks")"
{ [ "$rc" = "rc=0" ] && polled && out_has 'result=no-required-checks'; } \
  && pass "a base branch with no required-check rule keeps polling" \
  || fail "the gate skipped the poll where GitHub requires nothing — CI became advisory (rc=$rc)"

# --- the base branch is the PR's own, never the literal "main" ---------------
# Several repositories in the org do not use `main`. Reading rules for the wrong
# branch would answer "nothing required" on a repository that requires plenty.
BASE_BRANCH=develop
export BASE_BRANCH
rc="$(run_wait "$rules_with_required_checks")"
{ [ "$rc" = "rc=0" ] && grep -qF 'rules/branches/develop' "$tmp/calls.log"; } \
  && pass "the rules probe reads the PR's own base branch, not 'main'" \
  || fail "the rules probe did not read the PR's base branch (rc=$rc): $(cat "$tmp/calls.log")"

# A base branch containing a slash is a real ref shape and must survive intact.
BASE_BRANCH='release/1.x'
export BASE_BRANCH
rc="$(run_wait "$rules_with_required_checks")"
{ [ "$rc" = "rc=0" ] && ! polled && grep -qF 'rules/branches/release/1.x' "$tmp/calls.log"; } \
  && pass "a slash-bearing base branch is probed intact" \
  || fail "a slash-bearing base branch was mangled or ignored (rc=$rc)"

# --- workflow_dispatch and workflow_call carry no base ref in the event ------
BASE_BRANCH=''
export BASE_BRANCH
BASE_VIEW_OUT='trunk'
export BASE_VIEW_OUT
rc="$(run_wait "$rules_with_required_checks")"
unset BASE_VIEW_OUT
{ [ "$rc" = "rc=0" ] && ! polled && grep -qF 'rules/branches/trunk' "$tmp/calls.log"; } \
  && pass "an event without a base ref resolves it from the API and still skips" \
  || fail "a dispatch-shaped run could not resolve its base branch (rc=$rc)"

# --- every failure mode falls back to POLLING, never to skipping -------------
# This repository has shipped a fail-open guard three times running; the cases
# below are the ones that look like success to a careless implementation.
poll_case() {
  # poll_case <label> <rules-json>
  local label="$1" rules="$2" rc
  rc="$(run_wait "$rules")"
  { [ "$rc" = "rc=0" ] && polled && ! out_has 'result=required-checks-declared'; } \
    && pass "$label falls back to polling" \
    || fail "$label did NOT poll — the gate fails OPEN (rc=$rc)"
}

BASE_BRANCH=main
export BASE_BRANCH

# The literal body one org repository returns today: a 403 JSON OBJECT, not an
# array. `.[]` over an object iterates its values instead of failing, so a
# type-blind filter reads a denial as "no rules" — or worse, as rules.
poll_case "a 403 'Upgrade to GitHub Pro' object body" \
  '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'
# The case the type guard is actually for. `.[]` over an OBJECT iterates its
# values, so a wrapper-shaped body — a paginated envelope, or any future reshape
# of this endpoint — presents rule objects to the filter without ever being a
# list of rules. Without the guard this reads as "GitHub requires ci / build-test"
# and the gate stops waiting on a repository that declared nothing.
poll_case "an object body whose values are rule objects" \
  '{"rules":{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci / build-test"}]}}}'
poll_case "a body that is not JSON at all" 'not json <html>502 Bad Gateway</html>'
poll_case "an empty 2xx body" ''
poll_case "a JSON null body" 'null'
poll_case "a rule whose parameters are null" \
  '[{"type":"required_status_checks","parameters":null}]'
poll_case "a required-checks rule declaring no contexts" \
  '[{"type":"required_status_checks","parameters":{"required_status_checks":[]}}]'
poll_case "a required-checks rule whose contexts are unnamed" \
  '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"integration_id":42}]}}]'
poll_case "an array of scalars where rule objects belong" '["required_status_checks"]'
poll_case "an empty rule array" '[]'

RULES_RC=1
export RULES_RC
rc="$(run_wait "$rules_with_required_checks")"
unset RULES_RC
{ [ "$rc" = "rc=0" ] && polled && out_has 'result=branch-rules-unavailable'; } \
  && pass "an errored rules API falls back to polling" \
  || fail "an errored rules API skipped the poll — the gate fails OPEN (rc=$rc)"

# A CLI that disappears mid-step must end the job in the first millisecond, not
# read 127 as "the API is unavailable" and hold a self-hosted runner for the
# whole poll window — the starvation #363 was filed for.
RULES_RC=127
export RULES_RC
rc="$(run_wait "$rules_with_required_checks")"
unset RULES_RC
{ [ "$rc" = "rc=1" ] && ! polled && out_has 'result=toolchain-missing' && out_has 'gha-general-7'; } \
  && pass "a CLI lost while reading branch rules fails fast instead of polling" \
  || fail "exit 127 from the rules probe was swallowed into the poll loop (rc=$rc)"

BASE_VIEW_RC=1
BASE_BRANCH=''
export BASE_VIEW_RC BASE_BRANCH
rc="$(run_wait "$rules_with_required_checks")"
unset BASE_VIEW_RC
{ [ "$rc" = "rc=0" ] && polled && out_has 'result=base-branch-unresolved'; } \
  && pass "an unreadable PR falls back to polling" \
  || fail "an unreadable PR skipped the poll — the gate fails OPEN (rc=$rc)"

# `gh pr view --jq` renders JSON null as the literal string "null", which is
# non-empty and would otherwise be interpolated into the API URL.
# `main/../..` passes a naive character allowlist — every character in it is
# legal in a ref — and then walks out of the branch-rules endpoint when the
# server normalises the path. Git itself forbids `..` in a ref name, so a base
# branch that contains one is never real.
for bad in 'null' '' 'main; rm -rf /' 'main branch' '../../etc/passwd' '-main' '../other' \
           'main/../../../orgs/Verjson/rulesets' 'feature/ünïcode'; do
  BASE_BRANCH=''
  BASE_VIEW_OUT="$bad"
  export BASE_BRANCH BASE_VIEW_OUT
  rc="$(run_wait "$rules_with_required_checks")"
  unset BASE_VIEW_OUT
  { [ "$rc" = "rc=0" ] && polled && ! grep -q 'rules/branches' "$tmp/calls.log"; } \
    && pass "base branch '$bad' is rejected before any rules call" \
    || fail "base branch '$bad' reached the rules API or skipped the poll (rc=$rc)"
done

# --- the skip must not swallow the harder failures it sits next to -----------
BASE_BRANCH=main
EXPECTED_HEAD_SHA=not-a-sha
export BASE_BRANCH EXPECTED_HEAD_SHA
rc="$(run_wait "$rules_with_required_checks")"
unset EXPECTED_HEAD_SHA
{ [ "$rc" = "rc=1" ] && out_has 'result=unknown-head'; } \
  && pass "an unusable head SHA still fails the gate, required checks or not" \
  || fail "declared required checks let an unattributable head through (rc=$rc)"

# --- workflow-level wiring (evaluated by GitHub, so not executable here) -----
step_env="$(awk '
  $0 == "      - name: Wait once for the rest of CI to be green" { seen = 1 }
  seen && $0 == "        env:" { cap = 1; next }
  cap && $0 ~ /^        [a-z]/ { exit }
  cap && $0 ~ /^          [A-Z_]+:/ { print substr($0, 11) }
' "$wf")"
printf '%s' "$step_env" | grep -qF 'BASE_BRANCH: ${{ github.event.pull_request.base.ref }}' \
  && pass "the step reads the base ref from the event, not a hardcoded branch" \
  || fail "the ci_wait step no longer receives the PR's base ref: $step_env"

grep -qF 'repos/$TARGET_REPO/rules/branches/$base_branch' "$script" \
  && pass "the probe asks the TARGET repository for its branch rules" \
  || fail "the branch-rules probe is missing or reads the wrong repository"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
