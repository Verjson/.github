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
python3 - "$canonical" <<'PY' \
  && pass "canonical arm preserves exact permissions, concurrency, metadata validation and no-head-checkout boundaries" \
  || fail "canonical arm structural trust boundary drifted"
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    doc = yaml.load(stream, Loader=yaml.BaseLoader)

assert doc["permissions"] == {"contents": "read"}
assert doc["concurrency"] == {
    "group": "ai-review-arm-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}",
    "cancel-in-progress": "false",
}
arm = doc["jobs"]["arm"]
assert arm["permissions"] == {
    "actions": "write",
    "contents": "read",
    "issues": "write",
    "pull-requests": "write",
}
assert arm["env"]["PR_NUMBER"] == "${{ github.event.pull_request.number }}"
assert arm["env"]["TARGET_REPO"] == "${{ github.repository }}"
uses = [step["uses"] for step in arm["steps"] if "uses" in step]
assert uses and all(not value.startswith("actions/checkout@") for value in uses)
script = "\n".join(step.get("run", "") for step in arm["steps"])
for marker in (
    '[[ "$TARGET_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]',
    '[[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]',
    'gh pr view "$PR_NUMBER" --repo "$TARGET_REPO"',
    '--json id,state,isDraft,title,labels,headRefOid,headRepositoryOwner,autoMergeRequest',
    '[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]',
    '[ "$state" = OPEN ] || exit 0',
):
    assert marker in script
PY
if grep -qF 'client-id: ${{ vars.AI_REVIEW_CLIENT_ID }}' "$canonical" \
   && ! grep -qF 'app-id:' "$canonical" \
   && grep -qF 'APP_ID: ${{ vars.AI_REVIEW_APP_ID }}' "$canonical"; then
  pass "canonical caller target mints by client ID while retaining numeric App identity"
else
  fail "canonical caller target drifted to legacy token input or lost numeric App verification"
fi

# The immutable target matters only while the current executable arm, event
# authorization, and receipt verifier contracts remain green. Point at the
# registered suites that own each behavior instead of asking the receipt verifier
# suite to stand in for unrelated arm logic (#733).
for replacement in \
  'bash scripts/ci-gate/gate-hold-disable.test.sh' \
  'python3 scripts/ci-gate/event-driven-authorization.test.py' \
  'bash scripts/ci-gate/arm-receipt.test.sh'; do
  grep -q $'\t'"$replacement"'$' "$actions_ci" \
    && pass "actions-ci registers the canonical replacement: $replacement" \
    || fail "canonical replacement is not registered: $replacement"
done
bash "$here/gate-hold-disable.test.sh" >"$tmp/arm.out" 2>&1 \
  && pass "canonical arm retains live hold, event-rearm and fail-closed metadata behavior" \
  || fail "canonical arm behavior failed: $(tail -n 1 "$tmp/arm.out")"
python3 "$here/event-driven-authorization.test.py" >"$tmp/event.out" 2>&1 \
  && pass "canonical arm retains caller, App-permission and head-event authorization boundaries" \
  || fail "canonical event authorization failed: $(tail -n 1 "$tmp/event.out")"
bash "$here/arm-receipt.test.sh" >"$tmp/receipt.out" 2>&1 \
  && pass "canonical arm receipt verifier retains exact-run, artifact, App and head binding" \
  || fail "canonical arm receipt verifier failed: $(tail -n 1 "$tmp/receipt.out")"
grep -q $'\tbash scripts/ci-gate/gate-rearm-caller-contract.test.sh$' "$actions_ci" \
  && pass "actions-ci executes the generated caller contract" \
  || fail "generated caller contract is not wired into actions-ci"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
