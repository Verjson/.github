#!/usr/bin/env bash
# A runner without `gh` must fail the gate IMMEDIATELY, not after 30 minutes
# (Verjson/.github#363).
#
# Every API call in ci_wait's poll loop exits 127 ("command not found") on such
# a runner. The loop read 127 as "the API is unavailable", spent all 60 attempts
# on it, and held the runner for the full window to reach a verdict that was
# knowable in the first millisecond.
#
# That is not merely slow. `gate` polls on the SAME pool as the CI it waits for,
# so each mis-provisioned runner removes a slot from the pool for 30 minutes per
# job — one bad runner starves the whole fleet. Four runners provisioned without
# `gh` on 2026-08-03 saturated a ten-runner pool and stalled every repository in
# the organization.
#
# House method: awk-extract the exact `run:` block from ai-review-merge.yml
# (single source of truth) and exercise it with the tool genuinely absent from
# PATH. Plain bash + awk; runs on the bare pool.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
pm="$repo_root/.github/workflows/ai-privileged-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

extract() { # extract <step-id> <destination>
  awk -v want="        id: $1" '
    $0 == want { seen = 1 }
    seen && $0 == "        run: |" { cap = 1; next }
    cap && $0 ~ /^      - name:/ { exit }
    cap {
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      if ($0 ~ /^[ \t]*$/) { print ""; next }
      exit
    }
  ' "$wf" >"$2"
}

wait_script="$tmp/ci-wait.sh"
extract ci_wait "$wait_script"
grep -q '/check-runs?per_page=100' "$wait_script" \
  || { echo "FAIL - could not extract ci_wait run block from $wf"; exit 1; }

# A PATH with the real coreutils but deliberately WITHOUT gh. `command -v gh`
# must genuinely miss, which a stub cannot model — the bug was that a missing
# binary looked like a failing API, so the absence has to be real.
mkdir -p "$tmp/bin"
for t in bash date printf echo sleep awk sed grep cat cut tr head jq timeout env; do
  src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$tmp/bin/$t" 2>/dev/null
done

run_without_gh() {
  timeout 60 env -i PATH="$tmp/bin" HOME="$tmp" \
    LANE=ai PR_NUMBER=1 TARGET_REPO=Verjson/toquorum \
    EXPECTED_HEAD_SHA=abc123 GH_TOKEN=x RUNNER_NAME=gha-general-7 \
    bash "$wait_script" 2>&1
}

start="$(date +%s)"
out="$(run_without_gh)"
rc=$?
elapsed=$(( $(date +%s) - start ))

[ "$rc" -ne 0 ] \
  && pass "a runner without gh fails the gate instead of concluding green" \
  || fail "the gate did NOT fail on a runner missing gh (rc=$rc)"

# The whole point: bounded, and fast. The old behaviour was 60 attempts of
# 30-second sleeps. Ten seconds is generous for what should be one `command -v`.
[ "$elapsed" -lt 10 ] \
  && pass "it fails within ${elapsed}s rather than polling out the window" \
  || fail "took ${elapsed}s — it is still burning the poll budget on a fixed fault"

grep -q 'result=toolchain-missing' <<<"$out" \
  && pass "the failure names the toolchain, not a phantom API outage" \
  || fail "the operator is told the API is unavailable when the runner is broken"

grep -q 'gha-general-7' <<<"$out" \
  && pass "the failure names WHICH runner must be fixed" \
  || fail "the message does not identify the runner, so the fleet must be searched by hand"

# 127 can also appear mid-run if PATH changes under the job, so the loop keeps
# its own terminal branch rather than trusting the up-front probe alone.
grep -q 'checks_rc" -eq 127' "$wf" \
  && pass "the poll loop treats 127 as terminal, not as a transient API error" \
  || fail "127 inside the loop still consumes the retry budget"

# The privileged merge polls the same pool with the same tools and the same
# ~40-minute window, so it carries the same guard or it reintroduces the fault.
grep -q 'result=toolchain-missing' "$pm" \
  && pass "the privileged merge asserts its toolchain before its own poll loop" \
  || fail "ai-privileged-merge.yml can still hold a runner for 40 minutes without gh"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
