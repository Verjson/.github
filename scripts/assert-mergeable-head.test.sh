#!/usr/bin/env bash
# Exercises scripts/assert-mergeable-head.sh against a stubbed `gh`, per house
# convention. Every negative case asserts the SPECIFIC gate and exit code, so a
# harness regression cannot pass by failing somewhere else — and so that a
# future change which collapses the three gates back into one bare boolean
# cannot land green.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/assert-mergeable-head.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
APP_ID=15368
OTHER_APP_ID=99999

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  *"pr view "*"--json headRefOid,baseRefName"*)
    [ "${FAIL_PR_VIEW:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$PR_JSON_FIXTURE" ;;
  *"/rules/branches/"*)
    [ "${FAIL_RULES:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$RULES_FIXTURE" ;;
  *"/check-runs?per_page"*)
    [ "${FAIL_CHECK_RUNS:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$CHECK_RUNS_FIXTURE" ;;
  *"/commits/"*"/status"*)
    [ "${FAIL_STATUS:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$STATUS_FIXTURE" ;;
  *"/annotations?per_page"*)
    [ "${FAIL_ANNOTATIONS:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$ANNOTATIONS_FIXTURE" ;;
  *)
    echo "gh: unstubbed call: $args" >&2; exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

rules_bound="[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"ci / build-test\",\"integration_id\":$APP_ID},{\"context\":\"changelog / validate\",\"integration_id\":$APP_ID}]}}]"
rules_unbound='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci / build-test"},{"context":"changelog / validate"}]}}]'
rules_none='[{"type":"pull_request","parameters":{}}]'

check_run() { # id name status conclusion app-id
  printf '{"id":%s,"name":"%s","status":"%s","conclusion":%s,"app":{"id":%s}}' \
    "$1" "$2" "$3" "$(if [ -z "$4" ]; then echo null; else echo "\"$4\""; fi)" "$5"
}
# Both fixture builders stamp `total_count`, because both real endpoints always
# do -- verified against a live commit, including the empty-status case, which
# returns `total_count: 0` rather than omitting the field. A fixture without it
# would model a response GitHub does not send and would quietly exempt itself
# from the page-walk reconciliation.
runs() { printf '{"total_count":%s,"check_runs":[%s]}' "$(entry_count "$1")" "$1"; }
stat_page() { printf '{"total_count":%s,"statuses":[%s]}' "$(entry_count "$1")" "$1"; }
entry_count() { jq 'length' <<<"[$1]"; }

green_runs="$(check_run 1 'ci / build-test' completed success "$APP_ID"),$(check_run 2 'changelog / validate' completed success "$APP_ID")"

run() {
  OUT="$("$script" "${REPO:-Verjson/verjson-ci}" "${PR:-185}" 2>&1)"
  RC=$?
}

expect() { # label expected-rc needle
  if [ "$RC" -eq "$2" ] && grep -qF -- "$3" <<<"$OUT"; then
    pass "$1"
  else
    fail "$1 (rc=$RC, output: $OUT)"
  fi
}

expect_true() { # label
  if [ "$RC" -eq 0 ] && [ "$OUT" = "true" ]; then pass "$1"
  else fail "$1 (rc=$RC, output: $OUT)"; fi
}

# A pass that degraded to display-name matching must SAY so. Asserting the
# warning keeps the degradation from becoming invisible again.
expect_true_unbound() { # label
  if [ "$RC" -eq 0 ] \
    && grep -q '^true$' <<<"$OUT" \
    && grep -q '::warning::Gate A matched these required contexts on display name alone' <<<"$OUT"
  then pass "$1"
  else fail "$1 (rc=$RC, output: $OUT)"; fi
}

reset_env() {
  unset FAIL_PR_VIEW FAIL_RULES FAIL_CHECK_RUNS FAIL_STATUS FAIL_ANNOTATIONS
  export RULES_FIXTURE="$rules_bound"
  export PR_JSON_FIXTURE
  PR_JSON_FIXTURE="$(printf '{"headRefOid":"%s","baseRefName":"main"}' "$HEAD_SHA")"
  export CHECK_RUNS_FIXTURE
  CHECK_RUNS_FIXTURE="$(runs "$green_runs")"
  export STATUS_FIXTURE="$(stat_page '')"
  export ANNOTATIONS_FIXTURE='[]'
}

# --- the only accepting case ------------------------------------------------
reset_env; run
expect_true "a head whose required contexts all passed, from the bound app, with no deferral, prints true"

# --- Gate A -----------------------------------------------------------------
reset_env
CHECK_RUNS_FIXTURE="$(runs "$(check_run 1 'ci / build-test' completed success "$APP_ID")")"
run
expect "an absent required context fails closed rather than being satisfied by its absence" 3 "absent: changelog / validate"

reset_env
CHECK_RUNS_FIXTURE="$(runs "$(check_run 1 'ci / build-test' in_progress '' "$APP_ID"),$(check_run 2 'changelog / validate' completed success "$APP_ID")")"
run
expect "a still-running required context is not mistaken for a passing one" 3 "pending: ci / build-test"

reset_env
CHECK_RUNS_FIXTURE="$(runs "$(check_run 1 'ci / build-test' completed failure "$APP_ID"),$(check_run 2 'changelog / validate' completed success "$APP_ID")")"
run
expect "a failing required context is refused by name" 3 "not passing: ci / build-test"

# The impostor case: a DIFFERENT app publishes a check with the required
# context's exact display name while the genuine one is absent. Matching on the
# name alone would report this head as fully verified.
reset_env
CHECK_RUNS_FIXTURE="$(runs "$(check_run 1 'ci / build-test' completed success "$OTHER_APP_ID"),$(check_run 2 'changelog / validate' completed success "$APP_ID")")"
run
expect "a required context published by an app the ruleset does not bind is refused" 3 "wrong producer: ci / build-test"

# A legacy commit status carries no app id, so it cannot satisfy a bound context.
reset_env
CHECK_RUNS_FIXTURE="$(runs "$(check_run 2 'changelog / validate' completed success "$APP_ID")")"
STATUS_FIXTURE="$(stat_page '{"context":"ci / build-test","state":"success"}')"
run
expect "an app-bound required context cannot be satisfied by a provenance-less commit status" 3 "wrong producer: ci / build-test"

reset_env
RULES_FIXTURE="$rules_unbound"
CHECK_RUNS_FIXTURE="$(runs '')"
STATUS_FIXTURE="$(stat_page '{"context":"ci / build-test","state":"success"},{"context":"changelog / validate","state":"success"}')"
run
expect_true_unbound "an unbound required context is satisfied by a legacy commit status, and says it matched on name alone"

reset_env
RULES_FIXTURE="$rules_unbound"
CHECK_RUNS_FIXTURE="$(runs '')"
STATUS_FIXTURE="$(stat_page '{"context":"ci / build-test","state":"error"},{"context":"changelog / validate","state":"success"}')"
run
expect "a commit status in the error state is not passing" 3 "not passing: ci / build-test"

reset_env
RULES_FIXTURE="$rules_none"
run
expect "a base ref governed by no required checks cannot be gated by a green rollup" 3 "declares no required status checks"

reset_env
RULES_FIXTURE='[]'
run
expect "an empty rules response is refused rather than treated as fully satisfied" 3 "declares no required status checks"

reset_env
RULES_FIXTURE='"not-an-array"'
run
expect "a malformed rules response cannot silently yield an empty required set that passes" 3 "declares no required status checks"

# --- Gate B -----------------------------------------------------------------
for name in 'build-test / deferred-ci' 'deferred-ci' 'deferred-ci (push)' 'ci / deferred-ci (ubuntu-latest)' 'Deferred-CI'; do
  reset_env
  CHECK_RUNS_FIXTURE="$(runs "$green_runs,$(check_run 9 "$name" completed failure "$APP_ID")")"
  run
  expect "a deferral named '$name' is caught by the execution-evidence gate" 4 "was DEFERRED, not verified"
done

reset_env
CHECK_RUNS_FIXTURE="$(runs "$green_runs,$(check_run 9 'build-test / deferred-ci' completed success "$APP_ID")")"
run
expect "a deferred-ci that somehow concluded SUCCESS still proves the head was deferred" 4 "was DEFERRED, not verified"

reset_env
CHECK_RUNS_FIXTURE="$(runs "$green_runs,$(check_run 9 'build-test / deferred-ci' completed skipped "$APP_ID")")"
run
expect_true "a skipped deferred-ci is the normal exercised path and does not block"

reset_env
CHECK_RUNS_FIXTURE="$(runs "$green_runs,$(check_run 9 'x / deferred-cindy' completed success "$APP_ID")")"
run
expect_true "a longer name sharing the prefix after a separator does not falsely trip the gate"

# Gate B must not be relaxable from the environment: an earlier draft exposed
# these as tunable patterns, which made disabling it a one-variable edit.
reset_env
CHECK_RUNS_FIXTURE="$(runs "$green_runs,$(check_run 9 'build-test / deferred-ci' completed failure "$APP_ID")")"
# These are the script's OWN constant names. An earlier version of this test
# used the sibling script's names, which the gate never reads, so it would have
# passed against a build where the gate really was overridable.
OUT="$(DEFERRED_JOB_PATTERN='$x^' DEFERRED_ANNOTATION_PATTERN='$x^' "$script" Verjson/verjson-ci 185 2>&1)"; RC=$?
expect "the deferral gate cannot be switched off from the environment" 4 "was DEFERRED, not verified"

# A commit-status context uses `prefix/deferred-ci` with no space, and a check
# run may carry a trailing matrix separator. Both are deferrals.
reset_env
CHECK_RUNS_FIXTURE="$(runs "$green_runs")"
STATUS_FIXTURE="$(stat_page '{"context":"ci / build-test","state":"success"},{"context":"changelog / validate","state":"success"},{"context":"continuous-integration/deferred-ci","state":"success"}')"
run
expect "a slash-separated commit-status deferral blocks" 4 "was DEFERRED, not verified"

reset_env
CHECK_RUNS_FIXTURE="$(runs "$green_runs,$(check_run 9 'deferred-ci / verify' completed success "$APP_ID")")"
run
expect "a deferral naming a sub-step still blocks" 4 "was DEFERRED, not verified"

reset_env
ANNOTATIONS_FIXTURE='[{"title":"CI deferred","message":"nothing ran"}]'
run
expect "an ADR 0156 deferral annotation still blocks the composite-action path" 4 "carries a deferral annotation"

# --- Gate C -----------------------------------------------------------------
reset_env
CHECK_RUNS_FIXTURE="$(runs "$green_runs,$(check_run 3 'mirror-contract' completed failure "$APP_ID")")"
run
expect "a failing advisory check blocks under its own gate, naming the check" 5 "mirror-contract=FAILURE"

reset_env
CHECK_RUNS_FIXTURE="$(runs "$green_runs,$(check_run 3 'mirror-contract' queued '' "$APP_ID")")"
run
expect "a queued advisory check blocks rather than being read as absent" 5 "mirror-contract=QUEUED"

# --- unevaluable states fail closed, never green ----------------------------
reset_env; FAIL_PR_VIEW=1 run
expect "a pull-request metadata failure is a fault, not a pass" 1 "failed to fetch pull request metadata"

reset_env; FAIL_RULES=1 run
expect "an unreadable ruleset is a fault: the required set must never be inferred from the head" 1 "cannot establish the required-check set"

# A page walk that returns fewer runs than the endpoint claims exist leaves the
# gate reasoning over a short inventory -- the same shape as a `failure` the
# gate never sees. Reconciliation is only real if a short page is a fault.
reset_env
CHECK_RUNS_FIXTURE="$(jq -c --argjson runs "$(runs "$green_runs")" \
  '$runs + {total_count: 7}' <<<'{}')"
run
expect "a truncated check-run page walk is a fault, not a short green inventory" \
  1 "check-run inventory for"

# Commit statuses are the other half of the same inventory, and the endpoint
# Gate C reads a `failure` from. A short walk there hides exactly what Gate C
# exists to see, so it is a fault on the same terms.
reset_env
STATUS_FIXTURE="$(jq -c '. + {total_count: 9}' \
  <<<"$(stat_page '{"context":"ci / build-test","state":"success"}')")"
run
expect "a truncated commit-status page walk is a fault, not a short green inventory" \
  1 "commit-status inventory for"

# Defaulting the claim to the observation would make the reconciliation vacuous
# precisely where it matters: a body that states no count reconciles nothing,
# and an empty body reconciles zero against zero while the gate goes on to
# reason over an inventory in which no check can be seen at all.
reset_env
CHECK_RUNS_FIXTURE='{"check_runs":[]}'
run
expect "a check-run response that states no total_count is unattested, not empty" \
  1 "check-run inventory for"

reset_env
CHECK_RUNS_FIXTURE=''
run
expect "an empty check-run body is unattested, not a zero-length inventory" \
  1 "check-run inventory for"

reset_env
STATUS_FIXTURE='{"statuses":[]}'
run
expect "a commit-status response that states no total_count is unattested, not empty" \
  1 "commit-status inventory for"

reset_env; FAIL_CHECK_RUNS=1 run
expect "a check-runs failure is a fault, not a pass" 1 "failed to fetch check runs"

reset_env; FAIL_STATUS=1 run
expect "a commit-status failure is a fault, not a pass" 1 "failed to fetch commit statuses"

reset_env; FAIL_ANNOTATIONS=1 run
expect "an annotations failure is a fault, not a pass" 1 "failed to fetch annotations"

reset_env
PR_JSON_FIXTURE='{"headRefOid":"","baseRefName":"main"}'
run
expect "a missing head SHA is a fault rather than an empty comparison" 1 "could not resolve a head SHA"

reset_env
PR_JSON_FIXTURE="$(printf '{"headRefOid":"%s","baseRefName":""}' "$HEAD_SHA")"
run
expect "a missing base ref is a fault, since it names the governing ruleset" 1 "could not resolve a base ref"

# --- usage ------------------------------------------------------------------
OUT="$("$script" 2>&1)"; RC=$?
expect "no arguments is a usage error" 2 "usage:"
OUT="$("$script" not-a-repo 185 2>&1)"; RC=$?
expect "a malformed repository is a usage error" 2 "usage:"
OUT="$("$script" Verjson/verjson-ci not-a-number 2>&1)"; RC=$?
expect "a non-numeric pull-request number is a usage error" 2 "usage:"

if [ "$fails" -ne 0 ]; then
  printf '\n%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nall assertions passed\n'
