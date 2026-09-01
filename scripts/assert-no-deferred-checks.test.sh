#!/usr/bin/env bash
# ADR 0156: exercises scripts/assert-no-deferred-checks.sh against a stubbed
# `gh`, per house convention. Every negative case asserts the SPECIFIC
# terminal error so a harness regression cannot pass by failing elsewhere.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/assert-no-deferred-checks.sh"
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
  *"pr view "*"--json headRefOid,statusCheckRollup"*)
    [ "${FAIL_PR_VIEW:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$PR_JSON_FIXTURE" ;;
  *"check-runs?per_page"*)
    [ "${FAIL_CHECK_RUNS:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    printf '%s\n' "$CHECK_RUNS_FIXTURE" ;;
  *"/annotations?per_page"*)
    [ "${FAIL_ANNOTATIONS:-0}" -eq 0 ] || { echo "gh: some transient API error (HTTP 502)" >&2; exit 1; }
    id="$(grep -oE 'check-runs/[0-9]+' <<<"$args" | head -1 | cut -d/ -f2)"
    jq -c --arg id "$id" '.[$id] // []' <<<"$ANNOTATIONS_MAP"
    ;;
  *) echo "UNSTUBBED gh $args" >&2; exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_case() {
  PATH="$tmp/bin:$PATH" \
  PR_JSON_FIXTURE="$PR_JSON_FIXTURE" \
  CHECK_RUNS_FIXTURE="$CHECK_RUNS_FIXTURE" \
  ANNOTATIONS_MAP="$ANNOTATIONS_MAP" \
  DEFERRED_CHECK_ANNOTATION_PATTERN="${DEFERRED_CHECK_ANNOTATION_PATTERN:-}" \
  FAIL_PR_VIEW="${FAIL_PR_VIEW:-0}" FAIL_CHECK_RUNS="${FAIL_CHECK_RUNS:-0}" FAIL_ANNOTATIONS="${FAIL_ANNOTATIONS:-0}" \
    bash "$script" Verjson/example 7 2>&1
}

green_pr_json() {
  jq -n --arg sha "$HEAD_SHA" \
    '{headRefOid: $sha, statusCheckRollup: [{conclusion: "SUCCESS"}, {conclusion: "NEUTRAL"}]}'
}

# --- missing arguments fail closed on usage ----------------------------------
out="$(PATH="$tmp/bin:$PATH" bash "$script" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -qF 'usage:' <<<"$out" \
  && pass "missing arguments exit 2 with usage" \
  || fail "missing arguments did not fail closed on usage: rc=$rc out=$out"

# --- a non-passing rollup conclusion is rejected without checking annotations
PR_JSON_FIXTURE="$(jq -n --arg sha "$HEAD_SHA" \
  '{headRefOid: $sha, statusCheckRollup: [{conclusion: "FAILURE"}]}')"
CHECK_RUNS_FIXTURE='UNSTUBBED'
ANNOTATIONS_MAP='{}'
out="$(run_case)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'statusCheckRollup is empty, pending, or has a non-passing conclusion' <<<"$out" \
  && ! grep -qF 'UNSTUBBED' <<<"$out" \
  && pass "a non-passing rollup conclusion is rejected before any check-run lookup" \
  || fail "a non-passing rollup conclusion was not rejected first: rc=$rc out=$out"

# --- an empty rollup is rejected, not vacuously accepted ---------------------
PR_JSON_FIXTURE="$(jq -n --arg sha "$HEAD_SHA" '{headRefOid: $sha, statusCheckRollup: []}')"
out="$(run_case)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'statusCheckRollup is empty, pending, or has a non-passing conclusion' <<<"$out" \
  && pass "an empty rollup is rejected rather than vacuously accepted" \
  || fail "an empty rollup was accepted: rc=$rc out=$out"

# --- an unresolvable head SHA fails closed ------------------------------------
PR_JSON_FIXTURE='{"headRefOid": "", "statusCheckRollup": [{"conclusion": "SUCCESS"}]}'
out="$(run_case)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'could not resolve a head SHA' <<<"$out" \
  && pass "an unresolvable head SHA fails closed" \
  || fail "an unresolvable head SHA was not rejected: rc=$rc out=$out"

# --- a green rollup with no deferred annotations passes -----------------------
PR_JSON_FIXTURE="$(green_pr_json)"
CHECK_RUNS_FIXTURE='{"check_runs": [{"id": 1, "conclusion": "success"}, {"id": 2, "conclusion": "success"}]}'
ANNOTATIONS_MAP='{"1": [], "2": [{"title": "Some other notice"}]}'
out="$(run_case)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = true ] \
  && pass "a green rollup with no deferred annotations prints true" \
  || fail "a genuinely green head was rejected: rc=$rc out=$out"

# --- a deferred annotation on any completed check run is rejected ------------
PR_JSON_FIXTURE="$(green_pr_json)"
CHECK_RUNS_FIXTURE='{"check_runs": [{"id": 1, "conclusion": "success"}]}'
ANNOTATIONS_MAP='{"1": [{"title": "CI deferred", "message": "renovate/stability-days has not cleared"}]}'
out="$(run_case)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'carries deferred/unexercised checks: check-run 1: CI deferred' <<<"$out" \
  && pass "a check run annotated CI deferred is rejected even with a green rollup" \
  || fail "a deferred check run was accepted: rc=$rc out=$out"

# --- check runs with no conclusion yet (still queued) are not queried --------
PR_JSON_FIXTURE="$(green_pr_json)"
CHECK_RUNS_FIXTURE='{"check_runs": [{"id": 1, "conclusion": null}]}'
ANNOTATIONS_MAP='{}'
out="$(run_case)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = true ] \
  && pass "a check run with no conclusion yet is skipped rather than queried" \
  || fail "an in-flight check run's annotations were queried or the run was rejected: rc=$rc out=$out"

# --- the deferral pattern is overridable for a distinct future marker --------
PR_JSON_FIXTURE="$(green_pr_json)"
CHECK_RUNS_FIXTURE='{"check_runs": [{"id": 1, "conclusion": "success"}]}'
ANNOTATIONS_MAP='{"1": [{"title": "quarantined: flaky suite"}]}'
out="$(DEFERRED_CHECK_ANNOTATION_PATTERN='^quarantined:' run_case)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'quarantined: flaky suite' <<<"$out" \
  && pass "DEFERRED_CHECK_ANNOTATION_PATTERN overrides the default marker" \
  || fail "the overridden pattern was not honored: rc=$rc out=$out"

# --- an owner/repo with no slash fails closed on usage -----------------------
out="$(PATH="$tmp/bin:$PATH" bash "$script" not-a-repo 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -qF 'usage:' <<<"$out" \
  && pass "a repo argument without a slash fails closed on usage" \
  || fail "a malformed repo argument was not rejected: rc=$rc out=$out"

# --- a transient gh failure fetching PR metadata is reported, not raw stderr --
out="$(FAIL_PR_VIEW=1 run_case)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF '::error::failed to fetch PR metadata for Verjson/example#7' <<<"$out" \
  && pass "a gh failure fetching PR metadata is reported with ::error::, not raw stderr" \
  || fail "a gh failure fetching PR metadata was not reported closed: rc=$rc out=$out"

# --- a transient gh failure listing check runs is reported, not raw stderr ---
PR_JSON_FIXTURE="$(green_pr_json)"
out="$(FAIL_CHECK_RUNS=1 run_case)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "::error::failed to fetch check runs for Verjson/example@$HEAD_SHA" <<<"$out" \
  && pass "a gh failure listing check runs is reported with ::error::, not raw stderr" \
  || fail "a gh failure listing check runs was not reported closed: rc=$rc out=$out"

# --- a transient gh failure fetching annotations is reported, not raw stderr -
PR_JSON_FIXTURE="$(green_pr_json)"
CHECK_RUNS_FIXTURE='{"check_runs": [{"id": 1, "conclusion": "success"}]}'
out="$(FAIL_ANNOTATIONS=1 run_case)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF '::error::failed to fetch annotations for check-run 1 on Verjson/example' <<<"$out" \
  && pass "a gh failure fetching annotations is reported with ::error::, not raw stderr" \
  || fail "a gh failure fetching annotations was not reported closed: rc=$rc out=$out"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
