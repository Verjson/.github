#!/usr/bin/env bash
# Verjson/.github#988 / ADR 0089 amendment: `ai-privileged-merge.yml` declared
# `privileged_lane` as a workflow_call input but never read, validated, or even
# referenced it anywhere else in the file — the private-Verjson `runs-on:`
# branch hardcoded `fromJSON('["self-hosted","general"]')` regardless of what
# the caller supplied. Practically benign today (the literal cannot be
# widened), but it left ADR 0089's promised fail-closed diagnostic missing: a
# caller with a missing, malformed, or shadowed `VERJSON_LANE_PRIVILEGED`
# produced zero signal.
#
# ADR 0117 moves validation into a credentialless fixed-lane admission job.
# GitHub's job-level `if` independently exact-matches the input before the
# secret-bearing job can schedule, so a compromised admission runner cannot
# authorize attacker-selected labels merely by returning success.
#
# This extracts that step's run script from the shipped workflow (single
# source of truth, per house convention) and exercises it directly against
# fixture PRIVILEGED_LANE/repo values — the same extraction pattern as
# scripts/ci-gate/privileged-merge-pin.test.sh.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-privileged-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FAIL - jq is required by this test"; exit 1; }
python3 -c 'import yaml' 2>/dev/null \
  || { echo "FAIL - PyYAML is required by this test but is not importable"; exit 1; }

step_name="Validate caller-supplied privileged lane routing"
extract_validation_script() {
  local source="$1" destination="$2"
  python3 - "$source" "$step_name" >"$destination" <<'EXTRACT_PY'
import sys

import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = workflow.get("jobs", {}).get("validate_privileged_lane", {}).get("steps", [])
matches = [step for step in steps if step.get("name") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one {sys.argv[2]!r} step, found {len(matches)}")
script = matches[0].get("run")
if not isinstance(script, str) or not script.strip():
    raise SystemExit(f"{sys.argv[2]!r} has no non-empty run script")
print(script, end="" if script.endswith("\n") else "\n")
EXTRACT_PY
}

script="$tmp/validate.sh"
if extract_validation_script "$wf" "$script" 2>"$tmp/extract.err"; then
  pass "the privileged-lane validation step is found and its script is extracted"
else
  # This IS the red state before the fix: no such step exists yet, so there is
  # nothing to extract and nothing to fail closed. Documented here rather than
  # asserted, since a fresh checkout of this file already carries the fix.
  fail "could not extract the validation step's script: $(cat "$tmp/extract.err")"
  echo "$fails test(s) failed."
  exit 1
fi

run_case() { PRIVILEGED_LANE="${PRIVILEGED_LANE-}" bash "$script" 2>&1; }

# --- the exact admitted lane passes -------------------------------------------
out="$(PRIVILEGED_LANE='["self-hosted","general"]' run_case)"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -qF '::error::' <<<"$out"; then
  pass "the exact admitted lane validates with no diagnostic"
else
  fail "the exact admitted lane was rejected: $out"
fi

# --- missing input: THE GAP THIS ISSUE FOUND ----------------------------------
# Before the fix, a missing privileged_lane produced no diagnostic at all and
# the job still scheduled on self-hosted — the silent-proceed gap #988 reports.
out="$(PRIVILEGED_LANE='' run_case)"
rc=$?
if [ "$rc" -ne 0 ] && grep -qF '::error::' <<<"$out" && grep -qF 'missing, malformed' <<<"$out"; then
  pass "a missing privileged_lane fails closed with a clear diagnostic"
else
  fail "a missing privileged_lane did not fail closed: $out"
fi

# --- malformed JSON -------------------------------------------------------
out="$(PRIVILEGED_LANE='not-json' run_case)"
rc=$?
if [ "$rc" -ne 0 ] && grep -qF '::error::' <<<"$out"; then
  pass "a malformed (non-JSON) privileged_lane fails closed"
else
  fail "a malformed privileged_lane did not fail closed: $out"
fi

# --- widened lane (extra element) ---------------------------------------------
out="$(PRIVILEGED_LANE='["self-hosted","general","extra"]' run_case)"
rc=$?
if [ "$rc" -ne 0 ] && grep -qF '::error::' <<<"$out"; then
  pass "a widened lane fails closed"
else
  fail "a widened lane was accepted: $out"
fi

# --- hosted value instead of self-hosted --------------------------------------
out="$(PRIVILEGED_LANE='["ubuntu-24.04"]' run_case)"
rc=$?
if [ "$rc" -ne 0 ] && grep -qF '::error::' <<<"$out"; then
  pass "a hosted lane value fails closed"
else
  fail "a hosted lane value was accepted: $out"
fi

# --- shadowed value: a differently-shaped but well-formed array ---------------
out="$(PRIVILEGED_LANE='["self-hosted","attacker-fleet"]' run_case)"
rc=$?
if [ "$rc" -ne 0 ] && grep -qF '::error::' <<<"$out"; then
  pass "a shadowed (repo-variable-overridden) lane value fails closed"
else
  fail "a shadowed lane value was accepted: $out"
fi

python3 - "$wf" <<'PY' && pass "admission is credentialless and merge eligibility independently exact-matches the lane" \
  || fail "admission or scheduling-time lane enforcement drifted"
import sys, yaml
w = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs = w["jobs"]
admission = jobs["validate_privileged_lane"]
merge = jobs["privileged_merge"]
assert admission["runs-on"] == ["self-hosted", "general"]
assert admission["permissions"] == {}
assert "secrets." not in str(admission)
assert merge["needs"] == "validate_privileged_lane"
assert "inputs.privileged_lane == '[\"self-hosted\",\"general\"]'" in merge["if"]
assert "needs.validate_privileged_lane.result == 'success'" in merge["if"]
assert "always()" in merge["if"]
PY

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
