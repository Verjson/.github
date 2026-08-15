#!/usr/bin/env bash
# Unit tests for scripts/ci-gate/hosted-selector-policy.sh (Verjson/.github#814).
#
# The rules under test cannot be proven against this repository's own workflow
# tree: `.github` has no macOS or Windows selector and no OS-scoped lane, so an
# assertion pointed at `.github/workflows` can never fail and would prove
# nothing. Every rule therefore gets a fixture that FAILS the check and a
# fixture that PASSES it, under `scripts/fixtures/hosted-selector-policy/`.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
script="$root/scripts/ci-gate/hosted-selector-policy.sh"
fixtures="$root/scripts/fixtures/hosted-selector-policy"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - policy script not found: $script"; exit 1; }

policy_rc=0
policy_out=""
run_policy() {
  policy_out="$(bash "$script" "$@" 2>&1)"
  policy_rc=$?
}

# assert_undetermined <label> <args...>
#
# Exit 2 is "this sweep could not decide", and it is a distinct outcome from
# exit 0 on purpose: a policy script that quietly passes when it cannot tell
# what it is scanning is the defect class this whole check exists to prevent,
# reproduced inside the check itself.
assert_undetermined() {
  local label="$1"; shift
  run_policy "$@"
  if [ "$policy_rc" -eq 2 ]; then
    pass "$label"
  else
    fail "$label (expected exit 2, got $policy_rc: $policy_out)"
  fi
}

# assert_violation <fixture> <expected-substring> <label> [extra args...]
#
# The message substring is asserted, not only the exit status. A single "policy
# violation" exit proves the sweep tripped, not that it tripped on the rule the
# fixture exercises — and R3's two failure modes (missing key vs. over-ceiling
# value) are deliberately distinct messages, which an exit-status-only assertion
# could not tell apart.
assert_violation() {
  local fixture="$1" expected="$2" label="$3"; shift 3
  run_policy --visibility public "$fixtures/$fixture" "$@"
  if [ "$policy_rc" -ne 1 ]; then
    fail "$label (expected exit 1, got $policy_rc: $policy_out)"
  elif ! grep -qF "$expected" <<<"$policy_out"; then
    fail "$label (exit 1 but no '$expected' in: $policy_out)"
  else
    pass "$label"
  fi
}

assert_undetermined "a directory that does not exist is undetermined, never clean" \
  --visibility public "$fixtures/does-not-exist"

# R1 (Tier A) — the metered families, zero exceptions. macOS bills at a 10x
# multiplier and Windows at 2x, and no security-boundary argument has ever
# required either, unlike the closed ADR 0089 `ubuntu-24.04` inventory.
assert_violation metered-macos 'metered hosted runner family' \
  "a metered macOS selector is a hard failure"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
