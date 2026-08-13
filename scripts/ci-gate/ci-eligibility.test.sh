#!/usr/bin/env bash
# Tests the ci-eligibility behavior (Verjson/.github#133, #164) by extracting
# both executable `run:` blocks: the composite action used by hand-rolled CI and
# node-ci's inline copy. Byte-for-byte parity prevents either consumer path from
# drifting, while inlining keeps an exact-pinned reusable from calling back into
# this repository through a separately-maintained self-pin. The script must:
# defer only on an ACTIVE pending status, fail OPEN on any uncertainty, and never
# defer a non-PR event. Plain bash + awk; no test-framework or YAML-library
# dependency (runs on the bare self-hosted pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
action="$repo_root/.github/actions/ci-eligibility/action.yml"
nodeci="$repo_root/.github/workflows/node-ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

# Extract the check step's run script verbatim (8-space-indented body after the
# lone `run: |` in the composite action).
action_script="$tmp/action-eligibility.sh"
awk '
  !cap && $0 == "      run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 8) == "        ") { print substr($0, 9); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit  # dedent ends the block
  }
' "$action" >"$action_script"
if ! grep -q 'renovate/stability-days' "$action_script"; then
  echo "FAIL - could not extract the eligibility run block from $action"
  exit 1
fi

nodeci_script="$tmp/node-ci-eligibility.sh"
awk '
  !step && $0 == "      - id: check" { step = 1; next }
  step && !cap && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    exit  # dedent ends the block
  }
' "$nodeci" >"$nodeci_script"
if ! grep -q 'renovate/stability-days' "$nodeci_script"; then
  echo "FAIL - could not extract the inline eligibility run block from $nodeci"
  exit 1
fi

if cmp -s "$action_script" "$nodeci_script"; then
  pass "composite action and node-ci inline eligibility scripts have exact parity"
else
  fail "composite action and node-ci inline eligibility scripts have drifted"
  diff -u "$action_script" "$nodeci_script" || true
fi

# Exercise the reusable workflow's inline copy. Exact parity above makes the
# same behavior proof apply to direct composite-action consumers.
script="$nodeci_script"

# Stubbed `gh`: prints the value of $STUB_GH_COUNT, or exits non-zero when
# $STUB_GH_FAIL is set (to exercise the fail-open path). Also records whether it
# was called at all.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
: >"$STUB_GH_CALLED"
if [ -n "${STUB_GH_FAIL:-}" ]; then exit 1; fi
echo "${STUB_GH_COUNT:-0}"
STUB
chmod +x "$stub_bin/gh"

# run_case <event-name> <gh-count> <gh-fail> — returns "should-run=<v> called=<0|1>".
run_case() {
  local out called
  out="$tmp/out"; called="$tmp/called"
  : >"$out"; rm -f "$called"
  PATH="$stub_bin:$PATH" \
  GITHUB_OUTPUT="$out" GITHUB_EVENT_NAME="$1" \
  GITHUB_REPOSITORY="Verjson/example" HEAD_SHA="deadbeef" GH_TOKEN="x" \
  STUB_GH_COUNT="$2" STUB_GH_FAIL="$3" STUB_GH_CALLED="$called" \
    bash -eo pipefail "$script" >/dev/null 2>&1
  local v; v="$(grep -oE 'should-run=(true|false)' "$out" | tail -1)"
  [ -f "$called" ] && echo "$v called=1" || echo "$v called=0"
}

# (a) Active pending stability-days status → defer (should-run=false).
[ "$(run_case pull_request 1 '')" = "should-run=false called=1" ] \
  && pass "pending renovate/stability-days → should-run=false (defer)" \
  || fail "pending status did not defer CI"

# (b) No pending status → run CI.
[ "$(run_case pull_request 0 '')" = "should-run=true called=1" ] \
  && pass "no pending status → should-run=true (run)" \
  || fail "clean head did not run CI"

# (c) API error / uncertainty → fail OPEN (run CI), never silently skip.
[ "$(run_case pull_request 0 fail)" = "should-run=true called=1" ] \
  && pass "gh api failure fails OPEN → should-run=true" \
  || fail "gh api failure did not fail open (a real PR could be silently skipped)"

# (d) workflow_dispatch is an explicit human override → run, without even
# consulting the status API.
[ "$(run_case workflow_dispatch 1 '')" = "should-run=true called=0" ] \
  && pass "workflow_dispatch forces should-run=true and skips the status check" \
  || fail "workflow_dispatch did not force a run / still called the API"

# (e) A push is already the trusted post-merge/direct-ref target. A stale PR
# release-age status on that commit cannot suppress validation.
[ "$(run_case push 1 '')" = "should-run=true called=0" ] \
  && pass "push bypasses the PR-only stability status check" \
  || fail "push validation was deferred by a stale stability-days status"

# ---- node-ci.yml wiring (structural) --------------------------------------
# Eligibility only defers if node-ci wires the inline step correctly. Pin the
# seams a refactor could silently break: output/env wiring, fail-open job gating,
# and the statuses read grant.
adr="$repo_root/docs/decisions/0023-skip-ci-while-stability-days-pending/README.md"

# (f) node-ci must keep the composite action's input/output contract while
# avoiding a remote ci-eligibility self-dependency.
eligibility_job="$tmp/eligibility-job.yml"
awk '
  $0 == "  eligibility:" { cap = 1 }
  cap && $0 != "  eligibility:" && /^  [a-z]/ { exit }
  cap { print }
' "$nodeci" >"$eligibility_job"
{ grep -qF 'should-run: ${{ steps.check.outputs.should-run }}' "$eligibility_job" \
  && grep -qF 'shell: bash' "$eligibility_job" \
  && grep -qF 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$eligibility_job" \
  && grep -qF 'HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}' "$eligibility_job" \
  && ! grep -qF 'uses: Verjson/.github/.github/actions/ci-eligibility@' "$eligibility_job"; } \
  && pass "node-ci preserves eligibility output/env wiring without a remote self-dependency" \
  || fail "node-ci eligibility output/env wiring or no-self-dependency invariant regressed"

# (g) build-test itself must always report the required context (#191). Only its
# execution steps may skip on an active defer; an eligibility error still fails
# open by running the suite.
python3 - "$nodeci" <<'PY' \
  && pass "build-test always reports while every executable step honors eligibility" \
  || fail "build-test can still disappear or execute held Renovate code"
import sys
from pathlib import Path

import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
job = workflow["jobs"]["build-test"]
assert job["if"] == "always()"
steps = job["steps"]
deferred = [step for step in steps if step.get("name") == "Report deferred CI"]
assert len(deferred) == 1
assert deferred[0]["if"] == "needs.eligibility.outputs.should-run == 'false'"
for step in steps:
    if step is deferred[0]:
        continue
    condition = step.get("if", "")
    assert "needs.eligibility.outputs.should-run != 'false'" in condition
PY

# (h) The eligibility job must request `statuses: read` (contents:read cannot read
# a commit's combined status). Because a called workflow cannot elevate the
# caller token, callers must grant the same permission or the call fails at startup.
awk '
  $0 == "  eligibility:" { cap = 1; next }
  cap && /^  [a-z]/ { exit }   # next top-level job ends the block
  cap { print }
' "$nodeci" | grep -qE '^      statuses: read' \
  && pass "eligibility job requests statuses: read" \
  || fail "eligibility job lacks statuses: read — status lookup would 403 and never defer"

# (i) The caller contract must describe `statuses: read` as required and preserve
# the startup-failure boundary. The action itself still fails open on runtime API
# errors, but an ungranted permission prevents GitHub from starting the workflow.
grep -qF '#         statuses: read          # REQUIRED:' "$nodeci" \
  && grep -qF '#                                 # makes the workflow fail at STARTUP before the' "$nodeci" \
  && grep -qF 'caller that does not grant it makes the reusable call invalid at workflow' "$adr" \
  && grep -qF 'startup. The action' "$adr" \
  && pass "caller contract marks statuses: read required before startup" \
  || fail "caller contract no longer documents statuses: read as startup-required"

# (j) Prevent the original false contract from returning in node-ci or its
# controlling ADR: omission must never be described as a fail-open path.
false_contract_re='(omit(ted|s|ting)|absent|withheld)[^.;]{0,160}(check[[:space:]]+)?fails?[[:space:]]+open'
if cat "$nodeci" "$adr" | tr '\n' ' ' | grep -qiE "$false_contract_re"; then
  fail "node-ci documentation again claims an omitted caller permission fails open"
else
  pass "node-ci documentation does not claim omitted caller permissions fail open"
fi

old_contract='Where it is absent the read is denied, the check fails open.'
if printf '%s\n' "$old_contract" | grep -qiE "$false_contract_re"; then
  pass "regression guard rejects the exact removed ADR fail-open sentence"
else
  fail "regression guard misses the exact removed ADR fail-open sentence"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
