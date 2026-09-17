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

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  *"pr view "*"--json headRefOid,baseRefName,statusCheckRollup"*)
    [ "${FAIL_PR_VIEW:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$PR_JSON_FIXTURE" ;;
  *"/rules/branches/"*)
    [ "${FAIL_RULES:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$RULES_FIXTURE" ;;
  *"check-runs?per_page"*)
    [ "${FAIL_CHECK_RUNS:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "${CHECK_RUNS_FIXTURE:-'{"check_runs":[]}'}" ;;
  *"/annotations?per_page"*)
    [ "${FAIL_ANNOTATIONS:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "${ANNOTATIONS_FIXTURE:-[]}" ;;
  *)
    echo "gh: unstubbed call: $args" >&2; exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

rules_with_required='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci / build-test"},{"context":"changelog / validate"}]}}]'
rules_without_required='[{"type":"pull_request","parameters":{}}]'

rollup_entry() { # name workflow status conclusion
  printf '{"name":"%s","workflowName":"%s","status":"%s","conclusion":"%s"}' "$1" "$2" "$3" "$4"
}

pr_json() { # base-ref  rollup-entries-json
  printf '{"headRefOid":"%s","baseRefName":"%s","statusCheckRollup":[%s]}' "$HEAD_SHA" "main" "$1"
}

green_rollup="$(rollup_entry build-test ci COMPLETED SUCCESS),$(rollup_entry validate changelog COMPLETED SUCCESS)"

run() { # -> sets OUT / RC
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

reset_env() {
  unset FAIL_PR_VIEW FAIL_RULES FAIL_CHECK_RUNS FAIL_ANNOTATIONS
  unset CHECK_RUNS_FIXTURE ANNOTATIONS_FIXTURE
  export RULES_FIXTURE="$rules_with_required"
  export PR_JSON_FIXTURE
  PR_JSON_FIXTURE="$(pr_json "$green_rollup")"
  export CHECK_RUNS_FIXTURE='{"check_runs":[{"id":1,"conclusion":"success"}]}'
  export ANNOTATIONS_FIXTURE='[]'
}

# --- the only accepting case ------------------------------------------------
reset_env
run
if [ "$RC" -eq 0 ] && [ "$OUT" = "true" ]; then
  pass "a head whose required contexts all passed, with no deferral, prints true"
else
  fail "a head whose required contexts all passed, with no deferral, prints true (rc=$RC, output: $OUT)"
fi

# --- Gate A -----------------------------------------------------------------
reset_env
PR_JSON_FIXTURE="$(pr_json "$(rollup_entry build-test ci COMPLETED SUCCESS)")"
run
expect "an absent required context fails closed rather than being satisfied by its absence" 3 "absent: changelog / validate"

reset_env
PR_JSON_FIXTURE="$(pr_json "$(rollup_entry build-test ci IN_PROGRESS ''),$(rollup_entry validate changelog COMPLETED SUCCESS)")"
run
expect "a still-running required context is not mistaken for a passing one" 3 "pending: ci / build-test"

reset_env
PR_JSON_FIXTURE="$(pr_json "$(rollup_entry build-test ci COMPLETED FAILURE),$(rollup_entry validate changelog COMPLETED SUCCESS)")"
run
expect "a failing required context is refused by name" 3 "not passing: ci / build-test"

reset_env
RULES_FIXTURE="$rules_without_required"
run
expect "a base ref governed by no required checks cannot be gated by a green rollup" 3 "declares no required status checks"

reset_env
PR_JSON_FIXTURE="$(pr_json "$(printf '{"context":"ci / build-test","state":"success"},{"context":"changelog / validate","state":"success"}')")"
run
if [ "$RC" -eq 0 ]; then
  pass "a legacy commit-status context satisfies its required binding"
else
  fail "a legacy commit-status context satisfies its required binding (rc=$RC, output: $OUT)"
fi

# --- Gate B -----------------------------------------------------------------
reset_env
PR_JSON_FIXTURE="$(pr_json "$green_rollup,$(rollup_entry 'build-test / deferred-ci' ci COMPLETED FAILURE)")"
run
expect "a head whose deferred-ci ran is refused as unverified, not as merely red" 4 "was DEFERRED, not verified"

reset_env
PR_JSON_FIXTURE="$(pr_json "$green_rollup,$(rollup_entry 'build-test / deferred-ci' ci COMPLETED SUCCESS)")"
run
expect "a deferred-ci that somehow concluded SUCCESS still proves the head was deferred" 4 "was DEFERRED, not verified"

reset_env
PR_JSON_FIXTURE="$(pr_json "$green_rollup,$(rollup_entry 'build-test / deferred-ci' ci COMPLETED SKIPPED)")"
run
if [ "$RC" -eq 0 ]; then
  pass "a skipped deferred-ci is the normal exercised path and does not block"
else
  fail "a skipped deferred-ci is the normal exercised path and does not block (rc=$RC, output: $OUT)"
fi

reset_env
ANNOTATIONS_FIXTURE='[{"title":"CI deferred","message":"nothing ran"}]'
run
expect "an ADR 0156 deferral annotation still blocks the composite-action path" 4 "carries a deferral annotation"

# --- Gate C -----------------------------------------------------------------
reset_env
PR_JSON_FIXTURE="$(pr_json "$green_rollup,$(rollup_entry mirror-contract ci COMPLETED FAILURE)")"
run
expect "a failing advisory check blocks under its own gate, distinct from a deferral" 5 "Gate C"

# --- unevaluable states fail closed, never green ----------------------------
reset_env
FAIL_PR_VIEW=1 run
expect "a pull-request metadata failure is a fault, not a pass" 1 "failed to fetch pull request metadata"

reset_env
FAIL_RULES=1 run
expect "an unreadable ruleset is a fault: the required set must never be inferred from the head" 1 "cannot establish the required-check set"

reset_env
FAIL_CHECK_RUNS=1 run
expect "a check-runs failure is a fault, not a pass" 1 "failed to fetch check runs"

reset_env
FAIL_ANNOTATIONS=1 run
expect "an annotations failure is a fault, not a pass" 1 "failed to fetch annotations"

reset_env
PR_JSON_FIXTURE='{"headRefOid":"","baseRefName":"main","statusCheckRollup":[]}'
run
expect "a missing head SHA is a fault rather than an empty comparison" 1 "could not resolve a head SHA"

reset_env
PR_JSON_FIXTURE="$(printf '{"headRefOid":"%s","baseRefName":"","statusCheckRollup":[]}' "$HEAD_SHA")"
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
