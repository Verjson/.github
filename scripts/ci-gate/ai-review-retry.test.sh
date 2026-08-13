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
  local candidate=$1 verdict reservation_token reserve_two
  [ "$(grep -c 'id: deepseek_primary' "$candidate")" -eq 1 ] || return 1
  [ "$(grep -c 'id: deepseek_fallback' "$candidate")" -eq 1 ] || return 1
  ! grep -Eq 'id: (deepseek_third|verdict_3)' "$candidate" || return 1
  [ "$(grep -c 'name: Reserve cumulative AI review pass' "$candidate")" -eq 2 ] || return 1
  [ "$(grep -c '\[ "$consumed" -ge 2 \]' "$candidate")" -eq 2 ] || return 1
  grep -qF '[ "${EXPLICIT_REREVIEW:-false}" != true ] && [ "$consumed" -ge 2 ]' "$candidate" || return 1
  grep -qF "steps.reserve_1.outputs.allowed == 'true'" "$candidate" || return 1
  grep -qF "steps.reserve_2.outputs.allowed == 'true'" "$candidate" || return 1
  reservation_token=$(awk '/id: reservation-app-token$/{found=1} found&&/^      - name:/{exit} found{print}' "$candidate")
  printf '%s' "$reservation_token" | grep -qF 'uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' || return 1
  printf '%s' "$reservation_token" | grep -qF 'permission-pull-requests: write' || return 1
  printf '%s' "$reservation_token" | grep -Eq 'permission-(contents|actions|checks|issues):' && return 1
  grep -qF 'GH_TOKEN: ${{ steps.reservation-app-token.outputs.token }}' "$candidate" || return 1
  grep -qF 'ai-review-pass:v2:${next}/2 pr:${PR_NUMBER} check:${AUTHORIZATION_CHECK_ID} head:${EXPECTED_HEAD_SHA}' "$candidate" || return 1
  grep -qF 'ai-review-explicit:v1 pr:${PR_NUMBER} check:${AUTHORIZATION_CHECK_ID} head:${EXPECTED_HEAD_SHA}' "$candidate" || return 1
  grep -qF '[ "$marker_check" = "$AUTHORIZATION_CHECK_ID" ]' "$candidate" || return 1
  grep -qF '[ "$explicit_receipt_consumed" = true ]' "$candidate" || return 1
  grep -qF '.app.id == $app_id and .app.slug == $slug' "$candidate" || return 1
  reserve_two=$(awk '/id: reserve_2$/{found=1} found{print} found&&/^      - name: DeepSeek review pass 2/{exit}' "$candidate")
  printf '%s' "$reserve_two" | grep -qF 'consumed="${{ steps.reserve_1.outputs.count }}"' || return 1
  ! printf '%s' "$reserve_two" | grep -qF 'pulls/$PR_NUMBER/reviews?per_page=100' || return 1
  grep -qF "steps.verdict_1.outputs.usable != 'true'" "$candidate" || return 1
  grep -qF 'MODEL: ${{ needs.preflight.outputs.fallback_model }}' "$candidate" || return 1
  grep -qF 'BUDGET_USD: ${{ needs.preflight.outputs.fallback_budget_usd }}' "$candidate" || return 1
  verdict=$(awk '/id: submit$/{found=1} found&&/VERDICT:/{print; exit}' "$candidate")
  printf '%s' "$verdict" | grep -q 'steps.verdict_1.outputs.verdict' || return 1
  printf '%s' "$verdict" | grep -q 'steps.verdict_2.outputs.verdict' || return 1
}

check_contract "$workflow" \
  && pass "two App-authenticated cumulative reservations bound the provider cascade without fallback read-after-write" \
  || fail "DeepSeek cascade ordering or bounds drifted"

grep -q 'deepseek-v4-pro then deepseek-v4-flash' "$arm" \
  && grep -q 'review_pricing_version=deepseek-v4-2026-08-10' "$arm" \
  && pass "arm fixes the model order and pricing-table version before receipt creation" \
  || fail "DeepSeek model order or pricing version is not receipt-bound"

primary_guard=$(awk '/id: deepseek_primary$/{found=1} found&&/^ *if:/{print; exit}' "$workflow")
fallback_guard=$(awk '/id: deepseek_fallback$/{found=1} found&&/^ *if:/{print; exit}' "$workflow")
case "$primary_guard" in
  *"needs.preflight.outputs.lane == 'ai'"*"steps.rereview.outputs.skip_model != 'true'"*"steps.reserve_1.outputs.allowed == 'true'"*) pass "primary pass requires the AI lane, deterministic non-reuse, and a reserved cumulative slot" ;;
  *) fail "primary DeepSeek guard is unsafe: $primary_guard" ;;
esac
case "$fallback_guard" in
  *"inputs.explicit_rereview != true"*"needs.preflight.outputs.provider == 'deepseek'"*"steps.verdict_1.outputs.usable != 'true'"*"steps.reserve_2.outputs.allowed == 'true'"*) pass "fallback runs only for an automatic DeepSeek primary with no usable verdict and pass 2 reserved" ;;
  *) fail "fallback DeepSeek guard is unsafe: $fallback_guard" ;;
esac

grep -q "event.label.name == 're-review'" "$workflow" \
  && grep -q -- '--remove-label re-review' "$arm" \
  && grep -qF 'explicit re-review requires a new authorized label event' "$arm" \
  && grep -qF 'explicit re-review dispatch cannot be rerun' "$workflow" \
  && grep -qF 'this explicit authorization check already reserved its one diagnostic pass' "$workflow" \
  && pass "a later same-head attempt still requires consumed maintainer re-review authorization" \
  || fail "explicit later re-review authorization is not wired"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$workflow" "$tmp/workflow.yml"
printf '\n      - id: deepseek_third\n        run: python3 "$RUNNER_TEMP/deepseek-review.py"\n' >>"$tmp/workflow.yml"
if check_contract "$tmp/workflow.yml"; then fail "mutation survived: an unbounded third model pass was admitted"; else pass "mutation rejected: the cascade cannot grow a third paid pass"; fi

sed "s/steps.verdict_1.outputs.usable != 'true'/steps.verdict_1.outputs.usable == 'true'/" "$workflow" >"$tmp/workflow.yml"
if check_contract "$tmp/workflow.yml"; then fail "mutation survived: fallback can run after a usable primary verdict"; else pass "mutation rejected: usable primary verdict terminates the cascade"; fi

sed 's/\[ "$consumed" -ge 2 \]/[ "$consumed" -ge 3 ]/g' "$workflow" >"$tmp/workflow.yml"
if check_contract "$tmp/workflow.yml"; then fail "mutation survived: a third cumulative PR pass was admitted"; else pass "mutation rejected: the PR-wide pass cap cannot exceed two"; fi

sed 's/\[ "$explicit_receipt_consumed" = true \]/[ "$explicit_receipt_consumed" = false ]/' "$workflow" >"$tmp/workflow.yml"
if check_contract "$tmp/workflow.yml"; then fail "mutation survived: a fresh dispatch replayed an explicit authorization check"; else pass "mutation rejected: each explicit authorization check reserves at most one diagnostic pass"; fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
