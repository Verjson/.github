#!/usr/bin/env bash
# Pins the merge gate's cross-org `workflow_call` distribution seams
# (Verjson/.github#128, ADR 0022). The gate is the org's required merge check AND
# a reusable other orgs pin via `uses: …@v1`; a refactor that silently drops the
# reusable trigger, un-parameterizes the runner, or breaks the org direct path
# reaches every consumer. These are structural (`on:`/`inputs:`/`runs-on:`)
# invariants, not `run:` shell, so this asserts the YAML shape directly rather
# than extracting a block. Plain bash + awk/grep; no YAML-library or
# test-framework dependency (runs on the bare self-hosted pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

# Extract only the top-level `on:` mapping (from `on:` up to the next
# zero-indented key) so trigger assertions can't be fooled by the same words
# appearing in a comment or a job body further down.
on_block="$(awk '
  $0 == "on:" { cap = 1; print; next }
  cap && /^[A-Za-z]/ { exit }   # next top-level key ends the on: block
  cap { print }
' "$wf")"

# (a) Org direct path preserved: the required-check `pull_request` trigger, with
# its event-type list, must stay — or every Verjson repo loses its merge gate.
# Assert the `types:` line too: keeping `pull_request:` but dropping the types
# would silently change which events fire the required check.
{ grep -qE '^  pull_request:' <<<"$on_block" && grep -qE '^    types:' <<<"$on_block"; } \
  && pass "pull_request trigger + types retained (org ruleset path intact)" \
  || fail "pull_request trigger or its types list missing — org required check would break"

# (b) Operator re-gate path preserved.
grep -qE '^  workflow_dispatch:' <<<"$on_block" \
  && pass "workflow_dispatch trigger retained (operator re-gate)" \
  || fail "workflow_dispatch trigger missing"

# (c) Cross-org distribution: the reusable `workflow_call` trigger must exist.
grep -qE '^  workflow_call:' <<<"$on_block" \
  && pass "workflow_call trigger present (cross-org consumers can pin it)" \
  || fail "workflow_call trigger missing — cross-org consumers would have to hand-copy"

# (d) `runner_labels` input is declared under workflow_call so a consumer with a
# different fleet can parameterize runs-on instead of forking the file.
wc_block="$(awk '
  $0 == "  workflow_call:" { cap = 1; next }
  cap && /^[A-Za-z]/ { exit }   # workflow_call is the last trigger — the next
  cap { print }                 # top-level key (concurrency:) ends the block
' "$wf")"
grep -qE '^      runner_labels:' <<<"$wc_block" \
  && pass "workflow_call declares a runner_labels input" \
  || fail "workflow_call is missing the runner_labels input (fleet not parameterizable)"

# (d2) runner_labels must be REQUIRED under workflow_call: an in-job fast-fail
# can't catch a missing fleet (the job queues forever on labels the consumer's
# org has no runner for, #130), so the only fast-fail is rejecting the call.
awk '
  $0 == "      runner_labels:" { cap = 1; next }
  cap && /^      [A-Za-z]/ { exit }   # next input key ends this input block
  cap { print }
' <<<"$wc_block" | grep -qE '^        required: true' \
  && pass "runner_labels is required under workflow_call (missing fleet fails the call, not the runner queue)" \
  || fail "runner_labels is optional — a consumer that omits it silently queues forever on Verjson's gate pool (#130)"

# (e) Every gate job's runs-on prefers inputs.runner_labels before the org
# fallback — so a consumer's fleet actually takes effect. Both jobs
# (preflight, gate) share the identical expression; require at least two.
runs_on_parameterized="$(grep -cE "runs-on: \\\$\{\{ inputs\.runner_labels && fromJSON\(inputs\.runner_labels\) \|\|" "$wf")"
[ "${runs_on_parameterized:-0}" -ge 2 ] \
  && pass "both gate jobs' runs-on prefer inputs.runner_labels then fall back to the org pool" \
  || fail "runs-on is not runner_labels-parameterized on both jobs (got ${runs_on_parameterized:-0}/2)"

# (f) The org fallback still self-gates Verjson/.github on `meta` (ADR 0016) —
# the reusable change must not collapse the deadlock-avoidance split.
grep -qE "github\.repository == 'Verjson/\.github' && fromJSON\('\[\"self-hosted\",\"meta\"\]'\)" "$wf" \
  && pass "self-gate meta/gate split preserved in the fallback (ADR 0016)" \
  || fail "self-gate meta split lost — Verjson/.github could deadlock on the gate pool"

# (g) The dispatch-target guard stays org-RELATIVE (github.repository_owner via
# env), never hardcoded to 'Verjson'. Under workflow_call GITHUB_REPOSITORY_OWNER
# is the CALLER's owner, so the guard automatically bounds each consumer to its
# OWN org (ADR 0020 §re-verify under workflow_call, ADR 0022). A hardcoded owner
# would either break cross-org callers or authorize a foreign target.
guard="$(awk '
  $0 == "        id: target_guard" { seen = 1 }
  seen && !cap && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf")"
if grep -q 'GITHUB_REPOSITORY_OWNER' <<<"$guard" \
  && ! grep -qE "(=|!=)[[:space:]]*[\"']?Verjson[\"']?" <<<"$guard"; then
  pass "target guard is org-relative (GITHUB_REPOSITORY_OWNER), safe under workflow_call"
else
  fail "target guard hardcodes an org or lost GITHUB_REPOSITORY_OWNER — cross-org callers break or a foreign target is authorized"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
