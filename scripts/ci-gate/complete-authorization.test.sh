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
    workflow_head = "current_head=\"$(GH_TOKEN=\"$ACTIONS_TOKEN\" gh api \"repos/$TARGET_REPO/pulls/$PR_NUMBER\" --jq '.head.sha // \"\"')\""
    return (
        env.get("EXPECTED_HEAD_SHA") == "${{ needs.preflight.outputs.head_sha }}"
        and env.get("EXPECTED_APP_ID") == "${{ vars.AI_REVIEW_APP_ID }}"
        and env.get("EXPECTED_REVIEWED_HEAD_SHA") == env.get("EXPECTED_HEAD_SHA")
        and env.get("EXPECTED_AUTHORIZED_HEAD_SHA") == "${{ inputs.expected_head_sha }}"
        and env.get("REVIEW_AUTHORITY") == "${{ needs.preflight.outputs.authority }}"
        and env.get("REVIEW_OUTCOME") == "${{ needs.gate.outputs.review_outcome }}"
        and env.get("APP_CLIENT_ID") == "${{ vars.AI_REVIEW_CLIENT_ID }}"
        and token["with"].get("client-id") == "${{ vars.AI_REVIEW_CLIENT_ID }}"
        and "app-id" not in token["with"]
        and token["with"].get("permission-checks") == "write"
        and token["with"].get("permission-contents") == "read"
        and token["with"].get("permission-pull-requests") == "write"
        and document["jobs"]["complete-authorization"]["permissions"].get("actions") == "read"
        and document["jobs"]["complete-authorization"]["permissions"].get("checks") == "read"
        and document["jobs"]["complete-authorization"]["permissions"].get("pull-requests") == "read"
        and complete["env"].get("APP_TOKEN") == "${{ steps.app-token.outputs.token }}"
        and complete["env"].get("MINTED_APP_SLUG") == "${{ steps.app-token.outputs.app-slug }}"
        and complete["env"].get("INSTALLATION_ID") == "${{ steps.app-token.outputs.installation-id }}"
        and complete["env"].get("REVERIFY_ACTOR_PERMISSION") == "false"
        and "GH_TOKEN" not in complete["env"]
        and 'GH_TOKEN="$APP_TOKEN" gh api' in run
        and 'app_api app-approval "$approval_file" --method POST' in run
        and 'app_api authorization-check "$RUNNER_TEMP/authorization-check.json" --method PATCH' in run
        and 'app_api persisted-approval "$persisted_file"' in run
        and 'approval="$(app_api' not in run
        and 'persisted="$(app_api' not in run
        and workflow_head in run
        and "workflow token REST head lookup failed" in run
        and "gh pr view" not in run
        and run.index("verify-arm-receipt.sh") < run.index("-f event=APPROVE")
        and run.index("-f event=APPROVE") < run.index("-f status=completed")
        and ('GH_TOKEN="$ACTIONS_TOKEN" bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh'
             ' || receipt_ok=false') in run
        and '[ "$receipt_ok" = true ] && [ "$GATE_STATUS" = success ]' in run
        and "reviews/$approval_id" in run
        and '[ "$REVIEW_OUTCOME" = approved ]' in run
        and '[ "$REVIEW_AUTHORITY" = ai-approve ]' in run
        and '[ "$REVIEW_AUTHORITY" = ai-merge ]' in run
        and 'echo "ai_authorized=$ai_authorized" >> "$GITHUB_OUTPUT"' in run
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
no_workflow_checks_read = copy.deepcopy(workflow)
del no_workflow_checks_read["jobs"]["complete-authorization"]["permissions"]["checks"]
assert not valid(no_workflow_checks_read), "missing workflow-token check read permission escaped"
reordered = copy.deepcopy(workflow)
complete = next(step for step in reordered["jobs"]["complete-authorization"]["steps"]
                if step.get("name") == "Complete exact head authorization")
complete["run"] = complete["run"].replace(
    'GH_TOKEN="$ACTIONS_TOKEN" bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh',
    'true # verifier removed') + '\nGH_TOKEN="$ACTIONS_TOKEN" bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh'
assert not valid(reordered), "approval-before-receipt-verification mutation escaped"
graphql_head = copy.deepcopy(workflow)
complete = next(step for step in graphql_head["jobs"]["complete-authorization"]["steps"]
                if step.get("name") == "Complete exact head authorization")
complete["run"] = complete["run"].replace(
    """gh api "repos/$TARGET_REPO/pulls/$PR_NUMBER" --jq '.head.sha // ""'""",
    'gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" --json headRefOid --jq \'.headRefOid // ""\'')
assert not valid(graphql_head), "GraphQL head lookup mutation escaped least-privilege contract"
app_token_head = copy.deepcopy(workflow)
complete = next(step for step in app_token_head["jobs"]["complete-authorization"]["steps"]
                if step.get("name") == "Complete exact head authorization")
complete["run"] = complete["run"].replace(
    'current_head="$(GH_TOKEN="$ACTIONS_TOKEN" gh api',
    'current_head="$(gh api')
assert not valid(app_token_head), "App-token head lookup escaped token separation"
fatal_verifier = copy.deepcopy(workflow)
complete = next(step for step in fatal_verifier["jobs"]["complete-authorization"]["steps"]
                if step.get("name") == "Complete exact head authorization")
complete["run"] = complete["run"].replace(
    'bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh || receipt_ok=false',
    'bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh')
assert not valid(fatal_verifier), "aborting verifier mutation escaped; a failed receipt would wedge the check run"
unguarded_success = copy.deepcopy(workflow)
complete = next(step for step in unguarded_success["jobs"]["complete-authorization"]["steps"]
                if step.get("name") == "Complete exact head authorization")
complete["run"] = complete["run"].replace(
    '[ "$receipt_ok" = true ] && [ "$GATE_STATUS" = success ]',
    '[ "$GATE_STATUS" = success ]')
assert not valid(unguarded_success), "fail-open mutation escaped; an unverified receipt could conclude success"
permission_reverification = copy.deepcopy(workflow)
complete = next(step for step in permission_reverification["jobs"]["complete-authorization"]["steps"]
                if step.get("name") == "Complete exact head authorization")
complete["env"]["REVERIFY_ACTOR_PERMISSION"] = True
assert not valid(permission_reverification), "completion actor-permission revalidation escaped token boundary"
PY
[ "$?" -eq 0 ] || exit 1

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
  "api --method POST "*)
    if [ "${APPROVAL_RC:-0}" -ne 0 ]; then
      printf 'authorization: token leaked-test-token\nx-github-request-id: TEST:1234\n' >&2
      exit "$APPROVAL_RC"
    fi
    jq -nc --arg head "$EXPECTED_AUTHORIZED_HEAD_SHA" \
      --arg login "${EXPECTED_APP_SLUG}[bot]" --arg check "$AUTHORIZATION_CHECK_ID" \
      '{id:81,state:"APPROVED",commit_id:$head,user:{login:$login},body:("<!-- ai-review-authorization:"+$check+" -->")}' ;;
  "api repos/"*"/reviews/81")
    jq -nc --arg head "${PERSISTED_HEAD:-$EXPECTED_AUTHORIZED_HEAD_SHA}" \
      --arg login "${EXPECTED_APP_SLUG}[bot]" --arg check "$AUTHORIZATION_CHECK_ID" \
      '{id:81,state:"APPROVED",commit_id:$head,user:{login:$login},body:("<!-- ai-review-authorization:"+$check+" -->")}' ;;
  "api repos/"*"/pulls/"*)
    [ "${HEAD_RC:-0}" -eq 0 ] || exit "$HEAD_RC"
    printf '%s\n' "$EXPECTED_AUTHORIZED_HEAD_SHA" ;;
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
export GATE_STATUS=success ACTIONS_TOKEN=actions-token APP_TOKEN=app-token
export MINTED_APP_SLUG="$EXPECTED_APP_SLUG" INSTALLATION_ID=1234 RUNNER_TEMP="$tmp"
export REVIEW_AUTHORITY=ai-merge REVIEW_OUTCOME=approved GITHUB_OUTPUT="$tmp/github-output"

run_complete(){ (cd "$tmp/run" && bash "$tmp/complete.sh"); }
if (cd "$tmp/run" && .gate-trust/scripts/ci-gate/verify-arm-receipt.sh) >"$tmp/out" 2>&1; then
  fail "non-executable completion verifier unexpectedly supports direct execution"
else
  pass "non-executable completion verifier rejects direct execution"
fi
: >"$CALLS"
: >"$GITHUB_OUTPUT"
if run_complete >"$tmp/out" 2>&1 && grep -q 'conclusion=success' "$CALLS" \
   && grep -q "ai-review-authorized:v1:${AUTHORIZATION_CHECK_ID}:${EXPECTED_AUTHORIZED_HEAD_SHA}" "$CALLS"; then
  pass "trusted preflight head receives persisted App approval before authorization completion"
else fail "valid completion head handoff failed: $(tail -1 "$tmp/out")"; fi

: >"$CALLS"; : >"$GITHUB_OUTPUT"; APPROVAL_RC=1 run_complete >"$tmp/out" 2>&1
if [ "$?" -eq 0 ] && grep -q 'conclusion=success' "$CALLS" \
   && grep -q 'ai_authorized=false' "$GITHUB_OUTPUT" \
   && ! grep -q 'ai-review-authorized:v1:' "$CALLS" \
  && grep -q 'app-approval failed' "$tmp/out" \
  && grep -q 'x-github-request-id: TEST:1234' "$tmp/out" \
  && grep -q 'authorization: token \*\*\*' "$tmp/out" \
  && ! grep -q 'leaked-test-token' "$tmp/out"; then
  pass "rejected App approval falls back to human authorization without leaking credentials"
else fail "rejected App approval did not preserve the human path"; fi

: >"$CALLS"; : >"$GITHUB_OUTPUT"; PERSISTED_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_complete >"$tmp/out" 2>&1
if [ "$?" -eq 0 ] && grep -q 'conclusion=success' "$CALLS" && grep -q 'ai_authorized=false' "$GITHUB_OUTPUT" \
   && ! grep -q 'ai-review-authorized:v1:' "$CALLS"; then
  pass "stale App approval cannot authorize AI but leaves the human path ready"
else fail "stale persisted approval escaped into AI authority"; fi

: >"$CALLS"; : >"$GITHUB_OUTPUT"; REVIEW_AUTHORITY=human REVIEW_OUTCOME=skipped run_complete >"$tmp/out" 2>&1
if [ "$?" -eq 0 ] && grep -q 'conclusion=success' "$CALLS" && ! grep -q 'api --method POST' "$CALLS" \
   && grep -q 'ai_authorized=false' "$GITHUB_OUTPUT" && ! grep -q 'ai-review-authorized:v1:' "$CALLS"; then
  pass "human authority never asks the App to approve"
else fail "human authority still depends on AI approval"; fi

# A failed receipt must still complete the check run. The job carries `if: always()`
# so it can report that failure; aborting before the PATCH leaves the check run
# `in_progress` forever, which blocks the PR with no signal and no rerun path.
# The approval POST must still never happen — that is the authorization mutation.
: >"$CALLS"; : >"$GITHUB_OUTPUT"; EXPECTED_HEAD_SHA= run_complete >"$tmp/out" 2>&1
if [ "$?" -ne 0 ] && grep -q 'api --method PATCH' "$CALLS" \
  && grep -q 'conclusion=failure' "$CALLS" \
  && ! grep -q 'api --method POST' "$CALLS" \
  && grep -q 'ai_authorized=false' "$GITHUB_OUTPUT"; then
  pass "omitted EXPECTED_HEAD_SHA completes the check run as failure without requesting approval"
else fail "missing completion head left the authorization check unresolved"; fi

: >"$CALLS"; : >"$GITHUB_OUTPUT"; EXPECTED_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_complete >"$tmp/out" 2>&1
if [ "$?" -ne 0 ] && grep -q 'api --method PATCH' "$CALLS" \
  && grep -q 'conclusion=failure' "$CALLS" \
  && ! grep -q 'api --method POST' "$CALLS" \
  && grep -q 'ai_authorized=false' "$GITHUB_OUTPUT"; then
  pass "mismatched EXPECTED_HEAD_SHA completes the check run as failure without requesting approval"
else fail "mismatched completion head left the authorization check unresolved"; fi

: >"$CALLS"; : >"$GITHUB_OUTPUT"; HEAD_RC=1 run_complete >"$tmp/out" 2>&1
if [ "$?" -ne 0 ] && grep -q 'api --method PATCH' "$CALLS" \
  && grep -q 'conclusion=failure' "$CALLS" \
  && ! grep -q 'api --method POST' "$CALLS" \
  && grep -q 'workflow token REST head lookup failed' "$tmp/out"; then
  pass "failed head lookup completes the check run as failure without requesting approval"
else fail "failed head lookup left the authorization check unresolved"; fi

# Fail-closed direction: a verifier failure must never reach conclusion=success,
# even when every other precondition is green.
: >"$CALLS"; : >"$GITHUB_OUTPUT"; EXPECTED_HEAD_SHA= GATE_STATUS=success run_complete >"$tmp/out" 2>&1
if ! grep -q 'conclusion=success' "$CALLS"; then
  pass "unverified receipt cannot conclude success while the gate is green"
else fail "unverified receipt concluded success — fail-open"; fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."; exit 1
