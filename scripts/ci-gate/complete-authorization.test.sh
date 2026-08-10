#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
pass(){ printf 'ok   - %s\n' "$1"; }
fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

python3 - "$workflow" <<'PY'
import copy, sys, yaml

def valid(document):
    steps = document["jobs"]["complete-authorization"]["steps"]
    env = document["jobs"]["complete-authorization"]["env"]
    token = next(step for step in steps
                 if step.get("name") == "Mint dedicated authorization App token")
    complete = next(step for step in steps
                    if step.get("name") == "Complete exact head authorization")
    run = complete["run"]
    return (
        env.get("EXPECTED_HEAD_SHA") == "${{ needs.preflight.outputs.head_sha }}"
        and env.get("EXPECTED_APP_ID") == "${{ vars.AI_REVIEW_APP_ID }}"
        and env.get("EXPECTED_REVIEWED_HEAD_SHA") == env.get("EXPECTED_HEAD_SHA")
        and env.get("EXPECTED_AUTHORIZED_HEAD_SHA") == "${{ inputs.expected_head_sha }}"
        and env.get("APP_CLIENT_ID") == "${{ vars.AI_REVIEW_CLIENT_ID }}"
        and token["with"].get("client-id") == "${{ vars.AI_REVIEW_CLIENT_ID }}"
        and "app-id" not in token["with"]
        and token["with"].get("permission-checks") == "write"
        and token["with"].get("permission-contents") == "read"
        and token["with"].get("permission-pull-requests") == "write"
        and run.index("verify-arm-receipt.sh") < run.index("-f event=APPROVE")
        and run.index("-f event=APPROVE") < run.index("-f status=completed")
        and "reviews/$approval_id" in run
    )

with open(sys.argv[1], encoding="utf-8") as stream:
    workflow = yaml.safe_load(stream)
assert valid(workflow), "trusted completion head handoff is invalid"
missing = copy.deepcopy(workflow)
del missing["jobs"]["complete-authorization"]["env"]["EXPECTED_HEAD_SHA"]
assert not valid(missing), "missing EXPECTED_HEAD_SHA mutation escaped"
mismatch = copy.deepcopy(workflow)
mismatch["jobs"]["complete-authorization"]["env"]["EXPECTED_HEAD_SHA"] = "${{ inputs.expected_head_sha }}"
assert not valid(mismatch), "mismatched EXPECTED_HEAD_SHA mutation escaped"
client_id_as_identity = copy.deepcopy(workflow)
client_id_as_identity["jobs"]["complete-authorization"]["env"]["EXPECTED_APP_ID"] = "${{ vars.AI_REVIEW_CLIENT_ID }}"
assert not valid(client_id_as_identity), "client ID substitution escaped numeric App identity contract"
no_pr_write = copy.deepcopy(workflow)
token = next(step for step in no_pr_write["jobs"]["complete-authorization"]["steps"]
             if step.get("name") == "Mint dedicated authorization App token")
del token["with"]["permission-pull-requests"]
assert not valid(no_pr_write), "missing App pull-request write permission escaped"
no_contents_read = copy.deepcopy(workflow)
token = next(step for step in no_contents_read["jobs"]["complete-authorization"]["steps"]
             if step.get("name") == "Mint dedicated authorization App token")
del token["with"]["permission-contents"]
assert not valid(no_contents_read), "missing App contents read permission escaped"
reordered = copy.deepcopy(workflow)
complete = next(step for step in reordered["jobs"]["complete-authorization"]["steps"]
                if step.get("name") == "Complete exact head authorization")
complete["run"] = complete["run"].replace(
    'GH_TOKEN="$ACTIONS_TOKEN" bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh',
    'true # verifier removed') + '\nGH_TOKEN="$ACTIONS_TOKEN" bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh'
assert not valid(reordered), "approval-before-receipt-verification mutation escaped"
PY

awk '$0=="      - name: Complete exact head authorization"{f=1;next} f&&$0=="        run: |"{r=1;next} r{if($0~/^  [A-Za-z0-9_-]+:/)exit;sub(/^          /,"");print}' \
  "$workflow" >"$tmp/complete.sh"
[ -s "$tmp/complete.sh" ] || { echo "FAIL - completion block missing"; exit 1; }

mkdir -p "$tmp/run/.gate-trust/scripts/ci-gate" "$tmp/bin"
cat >"$tmp/run/.gate-trust/scripts/ci-gate/verify-arm-receipt.sh" <<'SH'
#!/usr/bin/env bash
[ "$EXPECTED_HEAD_SHA" = "$EXPECTED_AUTHORIZED_HEAD_SHA" ] &&
  [ "$EXPECTED_HEAD_SHA" = "$EXPECTED_REVIEWED_HEAD_SHA" ]
SH
chmod 0644 "$tmp/run/.gate-trust/scripts/ci-gate/verify-arm-receipt.sh"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "pr view "*) printf '%s\n' "$EXPECTED_AUTHORIZED_HEAD_SHA" ;;
  "api --method POST "*)
    [ "${APPROVAL_RC:-0}" -eq 0 ] || exit "$APPROVAL_RC"
    jq -nc --arg head "$EXPECTED_AUTHORIZED_HEAD_SHA" \
      --arg login "${EXPECTED_APP_SLUG}[bot]" --arg check "$AUTHORIZATION_CHECK_ID" \
      '{id:81,state:"APPROVED",commit_id:$head,user:{login:$login},body:("<!-- ai-review-authorization:"+$check+" -->")}' ;;
  "api repos/"*"/reviews/81")
    jq -nc --arg head "${PERSISTED_HEAD:-$EXPECTED_AUTHORIZED_HEAD_SHA}" \
      --arg login "${EXPECTED_APP_SLUG}[bot]" --arg check "$AUTHORIZATION_CHECK_ID" \
      '{id:81,state:"APPROVED",commit_id:$head,user:{login:$login},body:("<!-- ai-review-authorization:"+$check+" -->")}' ;;
  "api --method PATCH "*) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" TARGET_REPO=Verjson/example PR_NUMBER=7
export AUTHORIZATION_CHECK_ID=9001 ARM_RUN_ID=7001 ARM_RUN_ATTEMPT=2
export EXPECTED_APP_ID=4242 EXPECTED_APP_SLUG=verjson-ai-review
export EXPECTED_AUTHORIZED_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export EXPECTED_REVIEWED_HEAD_SHA="$EXPECTED_AUTHORIZED_HEAD_SHA" EXPECTED_HEAD_SHA="$EXPECTED_AUTHORIZED_HEAD_SHA"
export GATE_STATUS=success ACTIONS_TOKEN=actions-token GH_TOKEN=app-token

run_complete(){ (cd "$tmp/run" && bash "$tmp/complete.sh"); }
if (cd "$tmp/run" && .gate-trust/scripts/ci-gate/verify-arm-receipt.sh) >"$tmp/out" 2>&1; then
  fail "non-executable completion verifier unexpectedly supports direct execution"
else
  pass "non-executable completion verifier rejects direct execution"
fi
: >"$CALLS"
if run_complete >"$tmp/out" 2>&1 && grep -q 'conclusion=success' "$CALLS"; then
  pass "trusted preflight head receives persisted App approval before authorization completion"
else fail "valid completion head handoff failed: $(tail -1 "$tmp/out")"; fi

: >"$CALLS"; APPROVAL_RC=1 run_complete >"$tmp/out" 2>&1
if [ "$?" -ne 0 ] && grep -q 'conclusion=failure' "$CALLS" && ! grep -q 'conclusion=success' "$CALLS"; then
  pass "rejected App approval completes authorization as failure"
else fail "rejected App approval did not fail closed"; fi

: >"$CALLS"; PERSISTED_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_complete >"$tmp/out" 2>&1
if [ "$?" -ne 0 ] && grep -q 'conclusion=failure' "$CALLS"; then
  pass "persisted approval for another head fails closed"
else fail "stale persisted approval escaped"; fi

: >"$CALLS"; EXPECTED_HEAD_SHA= run_complete >"$tmp/out" 2>&1
if [ "$?" -ne 0 ] && ! grep -q 'api --method PATCH' "$CALLS"; then
  pass "omitted EXPECTED_HEAD_SHA fails before authorization mutation"
else fail "missing completion head escaped verifier"; fi

: >"$CALLS"; EXPECTED_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_complete >"$tmp/out" 2>&1
if [ "$?" -ne 0 ] && ! grep -q 'api --method PATCH' "$CALLS"; then
  pass "mismatched EXPECTED_HEAD_SHA fails before authorization mutation"
else fail "mismatched completion head escaped verifier"; fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."; exit 1
