#!/usr/bin/env bash
# Pin the receipt-bound two-pass DeepSeek cascade and explicit later re-review.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/ai-review-merge.yml"
arm="$root/.github/workflows/gate-rearm.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

check_contract() {
  local candidate=$1 verdict
  [ "$(grep -c 'id: deepseek_primary' "$candidate")" -eq 1 ] || return 1
  [ "$(grep -c 'id: deepseek_fallback' "$candidate")" -eq 1 ] || return 1
  ! grep -Eq 'id: (deepseek_third|verdict_3)' "$candidate" || return 1
  grep -qF "steps.verdict_1.outputs.usable != 'true'" "$candidate" || return 1
  grep -qF 'MODEL: ${{ needs.preflight.outputs.fallback_model }}' "$candidate" || return 1
  grep -qF 'BUDGET_USD: ${{ needs.preflight.outputs.fallback_budget_usd }}' "$candidate" || return 1
  verdict=$(awk '/id: submit$/{found=1} found&&/VERDICT:/{print; exit}' "$candidate")
  printf '%s' "$verdict" | grep -q 'steps.verdict_1.outputs.verdict' || return 1
  printf '%s' "$verdict" | grep -q 'steps.verdict_2.outputs.verdict' || return 1
}

check_contract "$workflow" \
  && pass "DeepSeek cascade has exactly two separately budgeted passes and selects the first usable verdict" \
  || fail "DeepSeek cascade ordering or bounds drifted"

grep -q 'deepseek-v4-pro then deepseek-v4-flash' "$arm" \
  && grep -q 'review_pricing_version=deepseek-v4-2026-08-10' "$arm" \
  && pass "arm fixes the model order and pricing-table version before receipt creation" \
  || fail "DeepSeek model order or pricing version is not receipt-bound"

primary_guard=$(awk '/id: deepseek_primary$/{found=1} found&&/^ *if:/{print; exit}' "$workflow")
fallback_guard=$(awk '/id: deepseek_fallback$/{found=1} found&&/^ *if:/{print; exit}' "$workflow")
case "$primary_guard" in
  *"needs.preflight.outputs.lane == 'ai'"*"steps.rereview.outputs.skip_model != 'true'"*) pass "primary pass is opt-in lane scoped and honors deterministic skip evidence" ;;
  *) fail "primary DeepSeek guard is unsafe: $primary_guard" ;;
esac
case "$fallback_guard" in
  *"needs.preflight.outputs.provider == 'deepseek'"*"steps.verdict_1.outputs.usable != 'true'"*) pass "fallback runs only when the DeepSeek primary has no usable verdict" ;;
  *) fail "fallback DeepSeek guard is unsafe: $fallback_guard" ;;
esac

grep -q "event.label.name == 're-review'" "$workflow" \
  && grep -q -- '--remove-label re-review' "$arm" \
  && pass "a later same-head attempt still requires consumed maintainer re-review authorization" \
  || fail "explicit later re-review authorization is not wired"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$workflow" "$tmp/workflow.yml"
printf '\n      - id: deepseek_third\n        run: python3 "$RUNNER_TEMP/deepseek-review.py"\n' >>"$tmp/workflow.yml"
if check_contract "$tmp/workflow.yml"; then fail "mutation survived: an unbounded third model pass was admitted"; else pass "mutation rejected: the cascade cannot grow a third paid pass"; fi

sed "s/steps.verdict_1.outputs.usable != 'true'/steps.verdict_1.outputs.usable == 'true'/" "$workflow" >"$tmp/workflow.yml"
if check_contract "$tmp/workflow.yml"; then fail "mutation survived: fallback can run after a usable primary verdict"; else pass "mutation rejected: usable primary verdict terminates the cascade"; fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
