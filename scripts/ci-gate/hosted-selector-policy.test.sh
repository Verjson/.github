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

# assert_violation <visibility> <fixture> <expected-substring> <label> [sanctioned...]
#
# The message substring is asserted, not only the exit status. A single "policy
# violation" exit proves the sweep tripped, not that it tripped on the rule the
# fixture exercises — and R3's two failure modes (missing key vs. over-ceiling
# value) are deliberately distinct messages, which an exit-status-only assertion
# could not tell apart.
#
# Visibility is a required positional here rather than a default, mirroring the
# script: a caller that does not say what it is scanning gets no verdict.
assert_violation() {
  local visibility="$1" fixture="$2" expected="$3" label="$4"; shift 4
  run_policy --visibility "$visibility" "$fixtures/$fixture" "$@"
  if [ "$policy_rc" -ne 1 ]; then
    fail "$label (expected exit 1, got $policy_rc: $policy_out)"
  elif ! grep -qF "$expected" <<<"$policy_out"; then
    fail "$label (exit 1 but no '$expected' in: $policy_out)"
  else
    pass "$label"
  fi
}

# assert_clean <visibility> <fixture> <label> [sanctioned...]
assert_clean() {
  local visibility="$1" fixture="$2" label="$3"; shift 3
  run_policy --visibility "$visibility" "$fixtures/$fixture" "$@"
  if [ "$policy_rc" -eq 0 ]; then
    pass "$label"
  else
    fail "$label (expected exit 0, got $policy_rc: $policy_out)"
  fi
}

assert_undetermined "a directory that does not exist is undetermined, never clean" \
  --visibility public "$fixtures/does-not-exist"

# R1 (Tier A) — the metered families, zero exceptions. macOS bills at a 10x
# multiplier and Windows at 2x, and no security-boundary argument has ever
# required either, unlike the closed ADR 0089 `ubuntu-24.04` inventory.
assert_violation public metered-macos 'metered hosted runner family' \
  "a metered macOS selector is a hard failure"

# R2 (Tier A) — a rolling image in a metered family keeps its own message even
# though R1 already refuses the selector. The two rules answer different
# questions — "may this org spend here" and "is this build environment
# reproducible" — and a reader who fixes only the family would otherwise think
# `macos-latest` -> `windows-latest` was progress.
assert_violation public metered-macos 'rolling -latest image' \
  "a rolling image in a metered family is reported as its own defect"

# Tier B — literal Linux hosted selectors, keyed on repository visibility.
# Hosted minutes are free for a PUBLIC repository (measured 2026-08-01, ADR
# 0047/0048), so `ubuntu-latest` there spends nothing; on a PRIVATE repository
# it rides the spending limit the org is about to raise. The remedy for a public
# repository is still the `VERJSON_RUNNER_FASTLANE` variable rather than a
# literal (#816), which is why the message names it — but that half is not
# enforced here, and the difference between the tiers is the whole reason this
# script takes a visibility rather than assuming one.
assert_violation private linux-hosted-literal 'literal Linux hosted selector' \
  "a private repository may not hardcode a Linux hosted selector"
assert_clean public linux-hosted-literal \
  "the same selector on a public repository spends nothing and is not Tier B"

# R3 — a job that resolves to an OS lane must be BOUNDED, not merely annotated.
# `desktop-release.yml` is passed as sanctioned here so the fixture exercises
# R3 rather than R5; R5 has its own fixtures below.
assert_violation public os-lane-no-timeout 'R3 OS-lane job declares no timeout-minutes' \
  "an OS-lane job with no timeout-minutes is refused" desktop-release.yml
assert_violation public os-lane-timeout-over 'R3 OS-lane timeout-minutes 360 exceeds the 60 ceiling' \
  "a present-but-unbounded timeout is refused, and says so distinctly" desktop-release.yml
assert_clean public os-lane-bounded \
  "both OS lanes bounded at 45 minutes, with no fallback tail, are accepted" desktop-release.yml

# R4 — the deliberate exception to "every lane selector falls through to
# VERJSON_LANE_FALLBACK" (runner-routing-policy.test.sh:~100-110). Degrading a
# macOS leg to Linux yields a non-installable artifact behind a green check, so
# the OS lanes must fail closed. The rule LEARNS the exception here rather than
# the OS lane evading the rule.
assert_violation public os-lane-with-fallback 'R4 OS lane carries a fallback tail' \
  "an OS lane that can degrade to Linux is refused" desktop-release.yml

# The other direction of the same rule, and the reason the exception has to be
# encoded rather than assumed: narrowing the fallback requirement so it stops
# matching `VERJSON_LANE_TRUSTED_MACOS` must not stop it matching
# `VERJSON_LANE_TRUSTED`. Without this assertion, deleting the ordinary half
# would leave the suite green.
assert_violation public lane-without-terminal-landing 'R4 lane selector with no terminal landing' \
  "an ordinary lane selector with no terminal landing is still refused"
assert_clean public lane-with-fallback \
  "both conforming Linux chains — the ADR 0040 tail and ADR 0086's — are accepted"

# R5 — no off-path reference to the OS lane variables. The sanctioned set is a
# reviewed argument, EMPTY by default, so a repository that names none refuses
# every reference. Both shapes are covered because a rule that only read
# `runs-on:` would be walked around by staging the value into `env:` first.
assert_violation public os-lane-unsanctioned 'R5 off-path reference to an OS lane variable' \
  "an OS lane reference outside the sanctioned path is refused"
assert_violation public os-lane-reference-off-runs-on 'R5 off-path reference to an OS lane variable' \
  "an OS lane reference outside runs-on is refused too"
assert_clean public os-lane-bounded \
  "the sanctioned desktop-release path may name the OS lane variables" desktop-release.yml

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
