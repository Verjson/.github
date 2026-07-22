#!/usr/bin/env bash
# Tests the merge gate's dispatch-target guard (Verjson/.github#119; Tequity
# ADR-0027, tequityapp/tequity-ui#16) by extracting the exact `run:` block from
# ai-review-merge.yml — the single source of truth, so the test can't drift from
# the shipped logic — and exercising it against stubbed env. The gate drives
# `gh pr view/merge` under ORG_ADMIN_TOKEN against TARGET_REPO, so a free-form
# `repository` dispatch input is a cross-repo admin-merge escalation surface:
# the guard must fail closed unless the target is owned by this org. A regression
# that lets it point at a foreign owner (or a malformed target) reaches every
# repo, so it must fail here first. Plain bash + awk; no test-framework or
# YAML-library dependency (runs on the bare self-hosted pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

# Extract the guard step's run script verbatim (10-space-indented body after
# `run: |`, scoped to the step whose `id:` is target_guard).
script="$tmp/guard.sh"
awk '
  $0 == "        id: target_guard" { seen = 1 }
  seen && !cap && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit  # end of this step: stop before the next step re-arms capture
  }
' "$wf" >"$script"
if ! grep -q 'GITHUB_REPOSITORY_OWNER' "$script" || ! grep -q 'TARGET_REPO' "$script"; then
  echo "FAIL - could not extract the target_guard run block from $wf"
  exit 1
fi

# run_case <target-repo> — owner is fixed to this org (Verjson) via env.
run_case() {
  export GITHUB_REPOSITORY_OWNER="Verjson" TARGET_REPO="$1"
  bash "$script" >/dev/null 2>&1
  echo "rc=$?"
}

# (a) Default path: `repository` unset → TARGET_REPO === github.repository, which
# is same-owner (Verjson/.github) → passes.
[ "$(run_case 'Verjson/.github')" = "rc=0" ] \
  && pass "default same-owner target (github.repository) passes" \
  || fail "default same-owner target rejected"

# (b) Operator re-gates a sibling Verjson repo → same owner → passes.
[ "$(run_case 'Verjson/other-repo')" = "rc=0" ] \
  && pass "same-owner sibling repo passes" \
  || fail "same-owner sibling repo rejected"

# (c) Foreign owner → cross-repo escalation → fail closed (exit 1).
[ "$(run_case 'Attacker/evil')" = "rc=1" ] \
  && pass "foreign-owner target fails closed" \
  || fail "foreign-owner target NOT rejected (escalation surface open)"

# (d) Malformed values must fail closed, not silently proceed.
[ "$(run_case 'x')" = "rc=1" ] \
  && pass "no-slash target fails closed" || fail "no-slash target not rejected"
[ "$(run_case 'a/b/c')" = "rc=1" ] \
  && pass "extra-segment target fails closed" || fail "extra-segment target not rejected"
[ "$(run_case 'Verjson/')" = "rc=1" ] \
  && pass "empty-after-slash target fails closed" || fail "empty repo name not rejected"
[ "$(run_case '')" = "rc=1" ] \
  && pass "empty target fails closed" || fail "empty target not rejected"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
