#!/usr/bin/env bash
# Tests the ci-eligibility composite action (Verjson/.github#133) by extracting
# the exact `run:` block from .github/actions/ci-eligibility/action.yml — the
# single source of truth, so the test can't drift from the shipped logic — and
# exercising it with a stubbed `gh` and env. The action decides whether org CI
# runs or is deferred while a Renovate PR is held by `renovate/stability-days`;
# a regression that inverted it would either skip real CI (unsafe) or never defer
# (defeats the point). It must: defer only on an ACTIVE pending status, fail OPEN
# on any uncertainty, and never defer a workflow_dispatch. Plain bash + awk; no
# test-framework or YAML-library dependency (runs on the bare self-hosted pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
action="$repo_root/.github/actions/ci-eligibility/action.yml"
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
script="$tmp/eligibility.sh"
awk '
  !cap && $0 == "      run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 8) == "        ") { print substr($0, 9); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit  # dedent ends the block
  }
' "$action" >"$script"
if ! grep -q 'renovate/stability-days' "$script"; then
  echo "FAIL - could not extract the eligibility run block from $action"
  exit 1
fi

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

# ---- node-ci.yml wiring (structural) --------------------------------------
# The action only defers if node-ci consumes it correctly. Pin the two seams a
# refactor could silently break: fail-open job gating and the statuses read grant.
nodeci="$repo_root/.github/workflows/node-ci.yml"

# (e) build-test must fail OPEN at the job level: gate on `always() && … != 'false'`
# so an errored eligibility job runs CI instead of skipping it. A plain
# `== 'true'` would skip build-test whenever eligibility errors (fail-closed).
grep -qF "if: always() && needs.eligibility.outputs.should-run != 'false'" "$nodeci" \
  && pass "build-test gates fail-open (always() && != 'false')" \
  || fail "build-test is not fail-open — an errored eligibility job would skip CI"

# (f) The eligibility job must request `statuses: read` (contents:read cannot read
# a commit's combined status), or the gh api call 403s and never defers.
awk '
  $0 == "  eligibility:" { cap = 1; next }
  cap && /^  [a-z]/ { exit }   # next top-level job ends the block
  cap { print }
' "$nodeci" | grep -qE '^      statuses: read' \
  && pass "eligibility job requests statuses: read" \
  || fail "eligibility job lacks statuses: read — status lookup would 403 and never defer"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
