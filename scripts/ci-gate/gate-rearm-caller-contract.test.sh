#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
generator="$repo_root/scripts/gen-gate-rearm-caller.sh"
canonical="$repo_root/.github/workflows/gate-rearm.yml"
actions_ci="$repo_root/scripts/actions-ci-groups.tsv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

contract_sha=0123456789abcdef0123456789abcdef01234567
caller="$tmp/gate-rearm.yml"

if [ ! -x "$generator" ]; then
  fail "gate re-arm caller generator is missing or not executable"
else
  "$generator" "$contract_sha" >"$caller" \
    && pass "generator emits a caller for an immutable contract SHA" \
    || fail "generator rejected a valid immutable contract SHA"
fi

if [ -s "$caller" ]; then
  python3 - "$caller" "$contract_sha" <<'PY' \
    && pass "generated caller has the exact thin, privileged trigger contract" \
    || fail "generated caller shape, permissions, trigger, or immutable target drifted"
import sys
import yaml

path, sha = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    doc = yaml.load(stream, Loader=yaml.BaseLoader)

expected_uses = f"Verjson/.github/.github/workflows/gate-rearm.yml@{sha}"
assert set(doc) == {"name", "on", "permissions", "jobs"}
assert doc["on"] == {
    "pull_request_target": {
        "types": ["opened", "reopened", "synchronize", "ready_for_review", "converted_to_draft", "edited", "unlabeled", "labeled"],
    },
}
assert doc["permissions"] == {"contents": "read"}
assert set(doc["jobs"]) == {"rearm"}
job = doc["jobs"]["rearm"]
assert job == {
    "permissions": {
        "contents": "read",
        "actions": "write",
        "issues": "write",
        "pull-requests": "write",
    },
    "uses": expected_uses,
    "secrets": {"AI_REVIEW_APP_PRIVATE_KEY": "${{ secrets.AI_REVIEW_APP_PRIVATE_KEY }}"},
}
PY

  grep -qF "scripts/gen-gate-rearm-caller.sh $contract_sha" "$caller" \
    && pass "generated caller records an exact reproducible command" \
    || fail "generated caller lacks exact regeneration provenance"
  if grep -qE 'actions/checkout|github\.event\.pull_request\.(head|body|title)|^[[:space:]]+run:|secrets: inherit' "$caller"; then
    fail "generated pull_request_target caller can execute or expose PR-controlled content"
  else
    pass "generated caller delegates without checkout, shell, PR prose, or secrets"
  fi
fi

for invalid_ref in main v1 '' \
  0123456789abcdef0123456789abcdef0123456 \
  '0123456789abcdef0123456789abcdef01234567
jobs: {}'; do
  "$generator" "$invalid_ref" >"$tmp/rejected.yml" 2>/dev/null \
    && fail "generator accepted mutable, malformed, or injected ref '$invalid_ref'" \
    || pass "generator rejects unsafe ref '${invalid_ref:-<empty>}'"
done
"$generator" "$contract_sha" extra >"$tmp/rejected.yml" 2>/dev/null \
  && fail "generator ignored an extra argument" \
  || pass "generator rejects extra arguments"

grep -qE '^  workflow_call:' "$canonical" \
  && pass "canonical bridge accepts generated reusable callers" \
  || fail "canonical bridge has no workflow_call entry point"
if grep -qF 'client-id: ${{ vars.AI_REVIEW_CLIENT_ID }}' "$canonical" \
   && ! grep -qF 'app-id:' "$canonical" \
   && grep -qF 'APP_ID: ${{ vars.AI_REVIEW_APP_ID }}' "$canonical"; then
  pass "canonical caller target mints by client ID while retaining numeric App identity"
else
  fail "canonical caller target drifted to legacy token input or lost numeric App verification"
fi

# The immutable target matters only if the pinned canonical contract remains
# security-complete. Reuse the exhaustive canonical suite rather than copying
# its hold, recursion, checkout, metadata and permission assertions here.
bash "$here/arm-receipt.test.sh" >"$tmp/canonical.out" 2>&1 \
  && pass "canonical bridge retains hold, recursion, no-checkout and fail-closed guards" \
  || fail "canonical bridge contract failed: $(tail -n 1 "$tmp/canonical.out")"
grep -q $'\tbash scripts/ci-gate/gate-rearm-caller-contract.test.sh$' "$actions_ci" \
  && pass "actions-ci executes the generated caller contract" \
  || fail "generated caller contract is not wired into actions-ci"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
