#!/usr/bin/env bash
# Pin the review model's PR-head versus base-branch evidence boundary (#377).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
workflow="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

prompt="$tmp/review-prompt.txt"
awk '
  $0 == "            cat <<EOF" { capture = 1; next }
  capture && $0 == "          EOF" { exit }
  capture { print }
' "$workflow" >"$prompt"

grep -qF 'You are the autonomous merge gate' "$prompt" || {
  echo "FAIL - could not extract the active review prompt from $workflow"
  exit 1
}

grep -qF 'The checked-out workspace and git HEAD are the PR head, not the base or default branch.' "$prompt" \
  && pass "the prompt identifies HEAD as the untrusted PR head" \
  || fail "the prompt does not distinguish PR HEAD from the base branch"

grep -qF 'Never use HEAD, the current checkout, or matching blob hashes as evidence that content is already on the base branch.' "$prompt" \
  && pass "the prompt forbids the false duplicate evidence from PR #376" \
  || fail "the prompt permits PR-head evidence for base-branch claims"

grep -qF 'Do not block because you infer this PR submission is stale, duplicate, closed, or already merged; the deterministic API recheck owns PR lifecycle state.' "$prompt" \
  && pass "deterministic code, not the model, owns PR lifecycle state" \
  || fail "the model can still block on unverifiable PR lifecycle state"

grep -qF 'Still review duplicate-processing and idempotency defects in the proposed behavior normally.' "$prompt" \
  && pass "the lifecycle boundary preserves duplicate-behavior review" \
  || fail "the prompt can suppress duplicate-processing defects"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
