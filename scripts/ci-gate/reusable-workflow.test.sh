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

# (f) Verjson gate jobs expose independent default/untrusted variables while
# both keep the compatible general fallback during the permissive exception.
# Non-Verjson consumers retain the hosted fallback and explicit fleet input.
grep -qE "github\.repository_owner != 'Verjson' && 'ubuntu-24\.04'" "$wf" \
  && [ "$(grep -cF 'VERJSON_RUNNER_DEFAULT' "$wf")" -ge 2 ] \
  && [ "$(grep -cF 'VERJSON_RUNNER_UNTRUSTED' "$wf")" -ge 2 ] \
  && [ "$(grep -cF '["self-hosted","general"]' "$wf")" -ge 2 ] \
  && pass "Verjson gate jobs use variable lanes while cross-org routing stays portable" \
  || fail "variable gate routing or cross-org portability drifted"

# (g) Reusable callers are repository-local. Cross-org portability is retained,
# but neither workflow_call nor dispatch may smuggle in a sibling target.
if ! grep -qE '^      repository:' <<<"$wc_block" \
   && grep -qF 'TARGET_REPO: ${{ github.repository }}' "$wf"; then
  pass "workflow_call is portable but repository-local"
else
  fail "workflow_call accepts a cross-repository target or TARGET_REPO drifted"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
