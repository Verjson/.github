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
token_binding="GH_TOKEN: \${{ secrets.ORG_ADMIN_TOKEN }}"
event_sha_ref="ref: \${{ github.sha }}"

if grep -qF 'workflow_dispatch' "$workflow"; then
  fail "the privileged watchdog still exposes workflow_dispatch"
else
  pass "the privileged watchdog has no branch-selectable workflow_dispatch trigger"
fi

trigger_names="$(awk '
  /^on:$/ { capture = 1; next }
  capture && /^permissions:$/ { exit }
  capture && /^  [a-zA-Z_]+:/ { name = $1; sub(/:$/, "", name); print name }
' "$workflow")"
if [ "$trigger_names" = "schedule" ]; then
  pass "schedule is the watchdog's only trigger"
else
  fail "the watchdog has a non-schedule trigger: ${trigger_names:-missing}"
fi

if grep -qF "$event_sha_ref" <<<"$checkout_step" \
  && [ "$(grep -c '^          ref:' <<<"$checkout_step")" -eq 1 ]; then
  pass "privileged code checkout is bound to the scheduled event SHA"
else
  fail "watchdog checkout is not bound exactly once to github.sha"
fi

if [ "$(grep -cE '^        uses: actions/checkout@[0-9a-f]{40}( # .*)?$' "$workflow")" -eq 1 ]; then
  pass "the event-SHA checkout is the sole immutable checkout action"
else
  fail "the workflow must have exactly one full-SHA-pinned checkout action"
fi

if grep -qE '^        run: bash scripts/fleet-watchdog\.sh$' <<<"$sweep_step"; then
  pass "the privileged command path is static"
else
  fail "the privileged command path can drift from the reviewed script"
fi

mapfile -t step_entries < <(grep '^      - ' "$workflow")
if [ "${#step_entries[@]}" -eq 2 ] \
  && [ "${step_entries[0]}" = "      - name: Check out the watchdog" ] \
  && [ "${step_entries[1]}" = "      - name: Sweep the fleet for poll deadlocks" ]; then
  pass "the job has exactly two named steps and no unnamed bypass"
else
  fail "the watchdog job contains an unexpected or unnamed step"
fi

checkout_keys="$(awk '/^        [a-zA-Z_-]+:/ { key = $1; sub(/:$/, "", key); print key }' <<<"$checkout_step")"
sweep_keys="$(awk '/^        [a-zA-Z_-]+:/ { key = $1; sub(/:$/, "", key); print key }' <<<"$sweep_step")"
if [ "$checkout_keys" = $'uses\nwith' ] && [ "$sweep_keys" = $'env\nrun' ]; then
  pass "step execution surfaces are limited to checkout and the static sweep"
else
  fail "an unexpected executable step key can bypass the checkout boundary"
fi

checkout_inputs="$(awk '/^          [a-zA-Z_-]+:/ { key = $1; sub(/:$/, "", key); print key }' <<<"$checkout_step")"
sweep_env="$(awk '/^          [a-zA-Z_-]+:/ { key = $1; sub(/:$/, "", key); print key }' <<<"$sweep_step")"
if [ "$checkout_inputs" = $'ref\npersist-credentials' ] \
  && [ "$sweep_env" = $'GH_TOKEN\nWATCHDOG_ORG\nWATCHDOG_DRY_RUN\nWATCHDOG_MIN_AGE_MINUTES' ]; then
  pass "checkout inputs and privileged environment expose no alternate execution hook"
else
  fail "checkout inputs or privileged environment contain an unexpected execution hook"
fi

workflow_keys="$(awk '/^[a-zA-Z_-]+:/ { key = $1; sub(/:$/, "", key); print key }' "$workflow")"
job_keys="$(awk '
  /^  watchdog:$/ { capture = 1; next }
  capture && /^  [a-zA-Z_-]+:/ { exit }
  capture && /^    [a-zA-Z_-]+:/ { key = $1; sub(/:$/, "", key); print key }
' "$workflow")"
if [ "$workflow_keys" = $'name\non\npermissions\nconcurrency\njobs' ] \
  && [ "$job_keys" = $'runs-on\ntimeout-minutes\nsteps' ]; then
  pass "workflow and job scopes expose no defaults, container, or service bypass"
else
  fail "workflow or job scope contains an unexpected execution surface"
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
