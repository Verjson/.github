#!/usr/bin/env bash
# Pins the one-automatic-paid-pass invariant (Verjson/.github#637, ADR 0080).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

check_contract() {
  local candidate=$1
  local action_count verdict budget_args
  action_count=$(grep -c 'uses: anthropics/claude-code-action@' "$candidate" || true)
  [ "$action_count" -eq 1 ] || return 1
  grep -qF 'id: claude' "$candidate" || return 1
  ! grep -Eq 'id: (claude_retry|claude_retry2|verdict_2|verdict_3)' "$candidate" || return 1
  verdict=$(awk '/id: submit$/{f=1} f&&/VERDICT:/{print; exit}' "$candidate")
  printf '%s' "$verdict" | grep -q 'steps.verdict_1.outputs.verdict' || return 1
  ! printf '%s' "$verdict" | grep -Eq 'verdict_[23]|claude_retry' || return 1
  budget_args=$(grep -E -- '--max-budget-usd ' "$candidate" || true)
  [ "$(printf '%s\n' "$budget_args" | sed '/^$/d' | wc -l)" -eq 1 ] || return 1
  printf '%s' "$budget_args" | grep -qF '${{ needs.preflight.outputs.budget_usd }}' || return 1
}

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

check_contract "$wf" \
  && pass 'one automatic paid action uses only the selected first-pass budget' \
  || fail 'workflow can automatically invoke more than one paid pass or exceed the selected budget'

guard=$(awk '/id: claude$/{f=1} f&&/^ *if:/{print; exit}' "$wf")
case "$guard" in
  *"needs.preflight.outputs.lane == 'ai'"*"steps.rereview.outputs.skip_model != 'true'"*)
    pass 'paid pass remains lane-scoped and honors deterministic model-skip evidence' ;;
  *) fail "paid pass guard is unsafe: $guard" ;;
esac

grep -q 'event.label.name == '\''re-review'\''' "$wf" \
  && grep -q -- '--remove-label re-review' "$wf" \
  && pass 'a same-head paid retry requires and consumes explicit re-review authorization' \
  || fail 'explicit re-review authorization is not wired as a consumed trigger'

grep -q 'no automatic retry' "$wf" \
  && grep -q 'apply.*re-review' "$wf" \
  && pass 'terminal and unusable outcomes explain the fail-closed maintainer remedy' \
  || fail 'single-pass failure evidence does not direct maintainers to explicit re-review'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$wf" "$tmp/workflow.yml"
printf '\n      - id: claude_retry\n        uses: anthropics/claude-code-action@v1\n        with:\n          claude_args: --max-budget-usd 1.00\n' >>"$tmp/workflow.yml"
if check_contract "$tmp/workflow.yml"; then
  fail 'mutation survived: an automatic escalation action was not rejected'
else
  pass 'mutation rejected: an injected automatic escalation cannot satisfy the contract'
fi

cp "$wf" "$tmp/workflow.yml"
sed 's/steps\.verdict_1\.outputs\.verdict/steps.verdict_2.outputs.verdict/' "$wf" >"$tmp/workflow.yml"
if check_contract "$tmp/workflow.yml"; then
  fail 'mutation survived: submit can select a nonexistent later paid verdict'
else
  pass 'mutation rejected: submit cannot select escalation verdicts'
fi

if [ "$fails" -eq 0 ]; then echo 'All tests passed.'; exit 0; fi
echo "$fails test(s) failed."
exit 1
