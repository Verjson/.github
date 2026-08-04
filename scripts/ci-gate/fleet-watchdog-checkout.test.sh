#!/usr/bin/env bash
# Contract check for the privileged fleet-watchdog checkout boundary (#350).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/fleet-watchdog.yml"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

extract_step() {
  local name="$1"
  awk -v step="      - name: $name" '
    $0 == step { capture = 1 }
    capture && $0 != step && /^      - name:/ { exit }
    capture { print }
  ' "$workflow"
}

checkout_step="$(extract_step "Check out the watchdog")"
sweep_step="$(extract_step "Sweep the fleet for poll deadlocks")"
checkout_ref="$(awk '$1 == "ref:" { print $2 }' <<<"$checkout_step")"
input_expression='\$\{\{ (github\.event\.)?inputs\.'
token_binding="GH_TOKEN: \${{ secrets.ORG_ADMIN_TOKEN }}"

if [[ "$checkout_ref" =~ ^[0-9a-f]{40}$ ]]; then
  pass "privileged watchdog code is checked out at a full immutable commit SHA"
else
  fail "watchdog checkout ref is not a full immutable commit SHA: ${checkout_ref:-missing}"
fi

if [ "$(grep -c 'uses: actions/checkout@' "$workflow")" -eq 1 ]; then
  pass "the immutable checkout is the workflow's only source checkout"
else
  fail "the workflow must have exactly one source checkout"
fi

if grep -qF 'inputs.' <<<"$checkout_step"; then
  fail "a workflow_dispatch input can influence the privileged checkout"
else
  pass "workflow_dispatch inputs cannot influence the privileged checkout"
fi

unexpected_inputs="$(grep -nE "$input_expression" "$workflow" \
  | grep -vE '^[0-9]+: +WATCHDOG_(DRY_RUN|MIN_AGE_MINUTES):' || true)"
if [ -z "$unexpected_inputs" ]; then
  pass "manual inputs are confined to watchdog data environment variables"
else
  fail "manual inputs escape the data-only environment boundary: $unexpected_inputs"
fi

if grep -qE '^        run: bash scripts/fleet-watchdog\.sh$' <<<"$sweep_step"; then
  pass "the privileged command path is static"
else
  fail "the privileged command path can drift from the reviewed script"
fi

if [ "$(grep -c '^      - name:' "$workflow")" -eq 2 ]; then
  pass "no unreviewed execution step can enter the checkout-to-token boundary"
else
  fail "the watchdog job must contain only its checkout and privileged sweep steps"
fi

checkout_line="$(grep -nF 'name: Check out the watchdog' "$workflow" | cut -d: -f1)"
token_line="$(grep -nF "$token_binding" "$workflow" | cut -d: -f1)"
run_line="$(grep -nF 'run: bash scripts/fleet-watchdog.sh' "$workflow" | cut -d: -f1)"
if [ -n "$checkout_line" ] && [ -n "$token_line" ] && [ -n "$run_line" ] \
  && [ "$checkout_line" -lt "$token_line" ] && [ "$token_line" -lt "$run_line" ]; then
  pass "immutable checkout precedes the privileged token binding and execution"
else
  fail "the privileged token or execution is not ordered behind the immutable checkout"
fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
