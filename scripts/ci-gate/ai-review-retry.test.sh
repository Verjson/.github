#!/usr/bin/env bash
# Pins the ai-review retry chain in ai-review-merge.yml (Verjson/.github#64, ADR
# 0015). The gate makes up to THREE bounded attempts to obtain a structured
# verdict — cheap first pass, escalation, and a second escalation added for #64
# because error_max_structured_output_retries is a transient flake that struck
# both prior passes in the same run. This asserts the wiring from the workflow
# itself (single source of truth) so a regression that drops the extra attempt or
# breaks the verdict fallback order is caught. The retry logic is GitHub-expression
# wiring (not a shell block), so — like pulumi-comment.test.sh — we assert against
# the extracted YAML rather than executing it. Pure bash + awk.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

# 1. All three review passes are present, in order.
for id in "id: claude" "id: claude_retry" "id: claude_retry2"; do
  grep -qF "        $id" "$wf" && pass "review pass step present ($id)" || fail "missing review pass step ($id)"
done

# 2. The second escalation only fires when BOTH prior passes produced no verdict
#    (else a clean first/second pass would waste a third model call — or worse,
#    a skipped claude_retry's empty output would trigger it spuriously).
guard="$(awk '/id: claude_retry2$/{f=1} f&&/^ *if:/{print; exit}' "$wf")"
case "$guard" in
  *"steps.claude.outputs.structured_output == ''"*"steps.claude_retry.outputs.structured_output == ''"*)
    pass "claude_retry2 guarded on BOTH prior passes being empty" ;;
  *)
    fail "claude_retry2 if-guard must require claude AND claude_retry empty (got: $guard)" ;;
esac

# 3. The submitted VERDICT prefers the newest non-empty pass: retry2 → retry → claude.
verdict="$(awk '/id: submit$/{f=1} f&&/VERDICT:/{print; exit}' "$wf")"
p2=$(printf '%s' "$verdict" | grep -bo "claude_retry2.outputs.structured_output" | head -1 | cut -d: -f1)
p1=$(printf '%s' "$verdict" | grep -bo "claude_retry.outputs.structured_output"  | head -1 | cut -d: -f1)
p0=$(printf '%s' "$verdict" | grep -bo "claude.outputs.structured_output"        | head -1 | cut -d: -f1)
if [ -n "$p2" ] && [ -n "$p1" ] && [ -n "$p0" ] && [ "$p2" -lt "$p1" ] && [ "$p1" -lt "$p0" ]; then
  pass "submit VERDICT falls back retry2 -> retry -> claude"
else
  fail "submit VERDICT fallback order wrong (retry2=$p2 retry=$p1 claude=$p0)"
fi

# 4. The extra attempt must not weaken fail-closed: it stays continue-on-error, so
#    an empty third pass falls through to the submit instead of failing the job.
awk '/id: claude_retry2$/{f=1} f&&/continue-on-error: true/{print "y"; exit}' "$wf" | grep -q y \
  && pass "claude_retry2 is continue-on-error (never fails the job itself)" \
  || fail "claude_retry2 must be continue-on-error so an empty pass falls through to the fail-closed submit"

# 5. The deterministic submit must stay UNCONDITIONAL (no `if:`): that is what
#    guarantees it runs — and fails closed — when every review pass came back
#    empty. A narrowing guard here would silently let an unreviewed PR slip.
submit_if="$(awk '/id: submit$/{f=1} f&&/^ *run: \|/{exit} f&&/^ *if:/{print "HASIF"}' "$wf")"
[ -z "$submit_if" ] \
  && pass "submit step is unconditional (fail-closed always runs)" \
  || fail "submit step must not carry an if: guard — it must always run to fail closed"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
