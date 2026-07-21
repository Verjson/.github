#!/usr/bin/env bash
# Pins the two-runner-job merge-gate shape and exercises the immediate,
# authoritative merge recheck introduced for Verjson/.github#104. The shipped
# merge run block remains the single source of truth.
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

# The AI path may request only two runners: one preflight and one gate. Step
# consolidation is intentional; restoring any former job silently regresses
# queue exposure even if the shell behavior remains correct.
jobs="$(awk '
  /^jobs:$/ { in_jobs=1; next }
  in_jobs && /^  [A-Za-z0-9_-]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }
' "$wf")"
[ "$jobs" = $'preflight\ngate' ] \
  && pass "workflow has exactly preflight + gate runner jobs" \
  || fail "expected only preflight and gate jobs, got: $(tr '\n' ' ' <<<"$jobs")"

[ "$(grep -c '^    runs-on:' "$wf")" -eq 2 ] \
  && pass "AI path has at most two runner assignments" \
  || fail "expected exactly two runs-on assignments"

preflight_timeout="$(awk '/^  preflight:/{f=1} f&&/timeout-minutes:/{print; exit}' "$wf")"
gate_timeout="$(awk '/^  gate:/{f=1} f&&/timeout-minutes:/{print; exit}' "$wf")"
printf '%s' "$preflight_timeout" | grep -q 'timeout-minutes: 20' \
  && pass "preflight aggregates both former 10-minute phase ceilings" \
  || fail "preflight aggregate timeout is not 20 minutes"
case "$gate_timeout" in
  *"lane == 'ai'"*"80 || 45"*)
    pass "gate has bounded lane-aware aggregate timeouts" ;;
  *)
    fail "gate timeout must be 80 minutes for AI and 45 for fast (got: $gate_timeout)" ;;
esac

fresh_line="$(grep -n 'id: freshness$' "$wf" | cut -d: -f1)"
classify_line="$(grep -n 'id: classify$' "$wf" | cut -d: -f1)"
if [ -n "$fresh_line" ] && [ -n "$classify_line" ] && [ "$fresh_line" -lt "$classify_line" ] \
   && grep -A2 'id: classify$' "$wf" | grep -q "if: steps.freshness.outputs.proceed == 'true'"; then
  pass "preflight preserves freshness-before-classification gating"
else
  fail "preflight freshness/classification order or proceed guard regressed"
fi

# Only the pre-model CI step may poll. The merge recheck below must be a single
# snapshot so a successful review never starts the former second 40-minute wait.
[ "$(grep -c 'for i in \$(seq' "$wf")" -eq 1 ] \
  && pass "workflow contains one long CI polling loop" \
  || fail "workflow must contain exactly one long CI polling loop"

wait_script="$tmp/ci-wait.sh"
awk '
  $0 == "        id: ci_wait" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    cap = 0
  }
' "$wf" >"$wait_script"
grep -q 'IN("SUCCESS","NEUTRAL","SKIPPED")' "$wait_script" \
  && pass "initial CI wait allowlists accepted completed conclusions" \
  || fail "initial CI wait completed-conclusion allowlist missing"

merge_script="$tmp/merge.sh"
awk '
  $0 == "        id: merge" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    cap = 0
  }
' "$wf" >"$merge_script"
if grep -q 'for i in \$(seq\|sleep 30' "$merge_script"; then
  fail "merge recheck must not poll or sleep"
elif grep -q 'headRefOid' "$merge_script" && grep -q 'statusCheckRollup' "$merge_script"; then
  pass "merge recheck is immediate and verifies head + CI"
else
  fail "could not extract authoritative merge recheck"
fi
grep -qF -- '--match-head-commit "$EXPECTED_HEAD_SHA"' "$merge_script" \
  && pass "merge request atomically matches the reviewed head" \
  || fail "merge request is missing the expected-head atomic guard"
grep -q 'IN("SUCCESS","NEUTRAL","SKIPPED")' "$merge_script" \
  && pass "final CI snapshot allowlists accepted completed conclusions" \
  || fail "final CI snapshot completed-conclusion allowlist missing"

for marker in 'phase=preflight' 'phase=ci-wait' 'phase=model' 'phase=merge-recheck'; do
  grep -qF "$marker" "$wf" \
    && pass "timing diagnostic present ($marker)" \
    || fail "missing timing diagnostic ($marker)"
done

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
[ "$1" = "pr" ] && [ "$2" = "merge" ] && { printf 'MERGE %s\n' "$*" >>"$ACTIONLOG"; exit 0; }
[ "$1" = "pr" ] && [ "$2" = "comment" ] && { echo COMMENT >>"$ACTIONLOG"; exit 0; }
exit 0
GH
chmod +x "$tmp/bin/gh"

run_wait() {
  # run_wait <rollup-json>
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7 LANE=ai
  export ROLLUP_FILE="$tmp/rollup.json" ACTIONLOG="$tmp/actions.log"
  printf '%s' "$1" >"$ROLLUP_FILE"
  : >"$ACTIONLOG"
  bash "$wait_script" >"$tmp/wait-output.txt" 2>&1
  echo "rc=$?"
}
wait_out_has() { grep -q "$1" "$tmp/wait-output.txt"; }

accepted='[
  {"name":"success","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"neutral","status":"COMPLETED","conclusion":"NEUTRAL"},
  {"name":"skipped","status":"COMPLETED","conclusion":"SKIPPED"}
]'
rc="$(run_wait "$accepted")"
{ [ "$rc" = "rc=0" ] && wait_out_has 'result=green'; } \
  && pass "initial wait accepts SUCCESS, NEUTRAL, and SKIPPED" \
  || fail "initial wait rejected an accepted conclusion ($rc)"

for conclusion in STALE STARTUP_FAILURE; do
  rc="$(run_wait "[{\"name\":\"bad\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\"}]")"
  { [ "$rc" = "rc=1" ] && wait_out_has 'result=failed'; } \
    && pass "initial wait fails closed on $conclusion" \
    || fail "initial wait accepted $conclusion ($rc)"
done

run_case() {
  # run_case <current-head> <rollup-json>
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export LANE=ai LANE_REASON="code change" EXPECTED_HEAD_SHA=expected-head
  export META_FILE="$tmp/meta.json" ROLLUP_FILE="$tmp/rollup.json" ACTIONLOG="$tmp/actions.log"
  printf '{"labels":[],"title":"feat: x","isDraft":false,"state":"OPEN","headRefOid":"%s"}' "$1" >"$META_FILE"
  printf '%s' "$2" >"$ROLLUP_FILE"
  : >"$ACTIONLOG"
  bash "$merge_script" >"$tmp/output.txt" 2>&1
  echo "rc=$?"
}
merged() { grep -q '^MERGE ' "$tmp/actions.log"; }
out_has() { grep -q "$1" "$tmp/output.txt"; }

rc="$(run_case moved-head '[]')"
{ [ "$rc" = "rc=1" ] && ! merged && out_has 'result=head-changed'; } \
  && pass "changed head fails closed before merge" \
  || fail "changed head did not fail closed ($rc)"

rc="$(run_case expected-head '[{"name":"unit","status":"IN_PROGRESS","conclusion":null}]')"
{ [ "$rc" = "rc=1" ] && ! merged && out_has 'result=pending'; } \
  && pass "pending check fails closed without a second wait" \
  || fail "pending check did not fail closed ($rc)"

rc="$(run_case expected-head '[{"name":"unit","status":"COMPLETED","conclusion":"FAILURE"}]')"
{ [ "$rc" = "rc=1" ] && ! merged && out_has 'result=failed'; } \
  && pass "red check fails closed" \
  || fail "red check did not fail closed ($rc)"

for conclusion in STALE STARTUP_FAILURE; do
  rc="$(run_case expected-head "[{\"name\":\"bad\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\"}]")"
  { [ "$rc" = "rc=1" ] && ! merged && out_has 'result=failed'; } \
    && pass "final snapshot fails closed on $conclusion" \
    || fail "final snapshot accepted $conclusion ($rc)"
done

rc="$(run_case expected-head "$accepted")"
{ [ "$rc" = "rc=0" ] && merged \
   && grep -qF -- '--match-head-commit expected-head' "$tmp/actions.log"; } \
  && pass "accepted conclusions merge only with atomic expected-head guard" \
  || fail "accepted conclusions or atomic merge guard regressed ($rc)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
