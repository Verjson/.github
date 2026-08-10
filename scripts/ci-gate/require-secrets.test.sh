#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
review_workflow="$repo_root/.github/workflows/ai-review-merge.yml"
privileged_workflow="$repo_root/.github/workflows/ai-privileged-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }

job() {
  local workflow="$1" name="$2"
  awk -v wanted="$name" '
    /^jobs:$/ { in_jobs=1; next }
    in_jobs && $0 ~ "^  " wanted ":$" { found=1; print; next }
    found && /^  [A-Za-z0-9_-]+:$/ { exit }
    found { print }
  ' "$workflow"
}

step() {
  local workflow="$1" job_name="$2" step_name="$3"
  job "$workflow" "$job_name" | awk -v wanted="$step_name" '
    $0 == "      - name: " wanted { found=1; print; next }
    found && /^      - name:/ { exit }
    found { print }
  '
}

contract_errors() {
  local review="$1" privileged="$2" route terminal checkout
  route="$(job "$privileged" resolve_privileged_route)"
  terminal="$(job "$privileged" privileged_merge)"
  checkout="$(step "$privileged" privileged_merge 'Check out immutable arm verifier')"

  ! grep -qF '${{ secrets.ORG_ADMIN_TOKEN }}' "$review" \
    || printf '%s\n' 'review workflow receives ORG_ADMIN_TOKEN'
  [ "$(grep -cF '${{ secrets.ORG_ADMIN_TOKEN }}' "$privileged")" -eq 1 ] \
    || printf '%s\n' 'privileged workflow must consume ORG_ADMIN_TOKEN exactly once'
  ! grep -qF 'ORG_ADMIN_TOKEN' <<<"$route" \
    || printf '%s\n' 'routing job receives ORG_ADMIN_TOKEN'
  grep -qF 'GH_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}' <<<"$terminal" \
    || printf '%s\n' 'terminal merge job does not own the merge token'

  grep -qF 'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' <<<"$checkout" \
    || printf '%s\n' 'immutable verifier checkout is not pinned'
  grep -qF 'repository: Verjson/.github' <<<"$checkout" \
    || printf '%s\n' 'verifier checkout is not restricted to the canonical repository'
  grep -qF 'ref: ${{ steps.trusted-revision.outputs.sha }}' <<<"$checkout" \
    || printf '%s\n' 'verifier checkout is not bound to the executing trusted revision'
  grep -qF 'persist-credentials: false' <<<"$checkout" \
    || printf '%s\n' 'verifier checkout persists credentials'
  grep -qF 'scripts/ci-gate/verify-arm-receipt.sh' <<<"$checkout" \
    || printf '%s\n' 'verifier checkout is not sparse-scoped to the arm verifier'
  [ "$(grep -cE '^[[:space:]]+(- )?uses:' <<<"$terminal")" -eq 1 ] \
    || printf '%s\n' 'terminal merge job executes an action besides the canonical verifier checkout'
  ! grep -qE 'github\.event\.pull_request|github\.head_ref|repository:.*TARGET_REPO|ref:.*EXPECTED_HEAD_SHA' <<<"$terminal" \
    || printf '%s\n' 'terminal merge job can check out PR-controlled material'
}

assert_contract() {
  local review="$1" privileged="$2" description="$3" errors
  errors="$(contract_errors "$review" "$privileged")"
  if [ -z "$errors" ]; then pass "$description"; else printf '  %s\n' "$errors"; fail "$description"; fi
}

assert_mutation_rejected() {
  local description="$1" errors
  errors="$(contract_errors "$tmp/review.yml" "$tmp/privileged.yml")"
  if [ -n "$errors" ]; then pass "$description"; else fail "$description"; fi
}

reset_fixtures() {
  cp "$review_workflow" "$tmp/review.yml"
  cp "$privileged_workflow" "$tmp/privileged.yml"
}

assert_contract "$review_workflow" "$privileged_workflow" \
  'current split keeps the broad merge token and immutable verifier inside trusted boundaries'

reset_fixtures
sed -i '/^permissions:$/i\\  ORG_ADMIN_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}' "$tmp/review.yml"
assert_mutation_rejected 'mutation: review workflow cannot receive ORG_ADMIN_TOKEN'

reset_fixtures
sed -i '/^  resolve_privileged_route:$/a\\    env:\n      ORG_ADMIN_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}' "$tmp/privileged.yml"
assert_mutation_rejected 'mutation: routing job cannot receive ORG_ADMIN_TOKEN'

reset_fixtures
sed -i '0,/persist-credentials: false/s//persist-credentials: true/' "$tmp/privileged.yml"
assert_mutation_rejected 'mutation: immutable verifier checkout cannot persist credentials'

reset_fixtures
sed -i '0,/repository: Verjson\/.github/s//repository: ${{ github.repository }}/' "$tmp/privileged.yml"
assert_mutation_rejected 'mutation: verifier cannot be checked out from the target repository'

reset_fixtures
sed -i '0,/ref: ${{ steps.trusted-revision.outputs.sha }}/s//ref: ${{ inputs.expected_head_sha }}/' "$tmp/privileged.yml"
assert_mutation_rejected 'mutation: verifier cannot be checked out from the PR head'

reset_fixtures
sed -i '/^      - name: Attempt terminal merge from trusted metadata$/i\\      - uses: attacker/pr-controlled-action@main' "$tmp/privileged.yml"
assert_mutation_rejected 'mutation: terminal merge job cannot execute an additional action'

if [ "$failures" -ne 0 ]; then
  printf '%d test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf 'All require-secrets tests passed.\n'
