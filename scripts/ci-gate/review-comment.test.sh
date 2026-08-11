#!/usr/bin/env bash
# Execute the exact advisory-publication block from the trusted workflow.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

awk '
  $0 == "      - name: Submit deterministic PR review" { seen = 1 }
  seen && $0 == "        run: |" { capture = 1; next }
  capture {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$workflow" >"$tmp/submit.sh"
grep -q 'AI review advisory' "$tmp/submit.sh" || { echo "FAIL - submit block extraction failed"; exit 1; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
args=("$@"); body=""
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" = --body ] && body="${args[$((i + 1))]}"
done
case "$1 $2" in
  "pr comment") printf '%s' "$body" >"$COMMENT_FILE"; echo COMMENT >>"$ACTION_LOG" ;;
  "pr edit") echo EDIT >>"$ACTION_LOG" ;;
  "pr review") echo REVIEW >>"$ACTION_LOG"; exit 90 ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_submit() {
  export PATH="$tmp/bin:$PATH" TARGET_REPO=Verjson/example PR_NUMBER=7 HEAD_SHA=deadbeef MODEL=deepseek-v4-pro
  export PATCH_ID=patch123 GITHUB_RUN_ID=12345 GITHUB_OUTPUT="$tmp/output" COMMENT_FILE="$tmp/comment" ACTION_LOG="$tmp/actions"
  export VERDICT="$1" SELECTED_PASS_TERMINAL_ERROR="${2:-false}" BUDGET_EXHAUSTED="${3:-false}"
  export CHANGED_LINES=42 BUDGET_USD=5.00 PERMISSION_DENIALS=0
  : >"$GITHUB_OUTPUT"; : >"$COMMENT_FILE"; : >"$ACTION_LOG"
  bash -eo pipefail "$tmp/submit.sh" >"$tmp/log" 2>&1
  printf 'rc=%s' "$?"
}
has_comment() { grep -qF "$1" "$tmp/comment"; }
has_output() { grep -qF "$1" "$tmp/output"; }
has_action() { grep -qF "$1" "$tmp/actions"; }

approved='{"blocking":false,"summary":"looks good","review_first":[{"location":"auth.ts:42","why":"gates admin"}],"findings":[],"followups":[]}'
rc="$(run_submit "$approved")"
{ [ "$rc" = rc=0 ] && has_comment 'AI review advisory: non-blocking verdict' && has_comment 'Review these first' && has_output outcome=approved && ! has_action REVIEW; } \
  && pass "non-blocking verdict comments and records approval eligibility without submitting a review" \
  || fail "non-blocking advisory path drifted ($rc)"
has_comment '<!-- ai-review-head:deadbeef patchid:patch123 model:deepseek-v4-pro -->' \
  && pass "advisory marker binds head, patch, and selected model" \
  || fail "advisory marker lost immutable review identity"

blocking='{"blocking":true,"summary":"bug","review_first":[],"findings":[{"location":"app.py:7","reason":"broken","failure_scenario":"request fails"}],"followups":[]}'
rc="$(run_submit "$blocking")"
{ [ "$rc" = rc=0 ] && has_comment 'AI review advisory: blocking verdict' && has_comment 'app.py:7' && has_output outcome=blocking && ! has_action REVIEW; } \
  && pass "blocking AI verdict remains advisory and leaves human approval available" \
  || fail "blocking advisory path became a merge veto ($rc)"

rc="$(run_submit not-json)"
{ [ "$rc" = rc=0 ] && has_action EDIT && has_comment 'review could not complete' && has_output outcome=inconclusive; } \
  && pass "inconclusive provider result cannot block human approval" \
  || fail "inconclusive provider result blocked the required workflow ($rc)"

rc="$(run_submit "$approved" true)"
{ [ "$rc" = rc=0 ] && has_output outcome=inconclusive && ! has_output outcome=approved; } \
  && pass "terminal provider evidence cannot authorize AI approval" \
  || fail "terminal provider error escaped into AI approval ($rc)"

rc="$(run_submit "$approved" true true)"
{ [ "$rc" = rc=0 ] && has_comment 'budget exceeded' && has_comment 'Human approval remains available'; } \
  && pass "budget exhaustion is advisory and actionable" \
  || fail "budget exhaustion lost the human fallback ($rc)"

grep -q -- '--request-changes' "$tmp/submit.sh" \
  && fail "AI advisory still submits a blocking review" \
  || pass "AI advisory never submits CHANGES_REQUESTED"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
