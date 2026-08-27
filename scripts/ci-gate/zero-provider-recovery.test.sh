#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
verifier="$here/verify-zero-provider-recovery.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

if python3 - "$here/../../.github/workflows/ai-review-merge.yml" <<'PY'
import copy
import sys
import yaml

def valid(document):
    preflight = document["jobs"]["preflight"]
    complete = document["jobs"]["complete-authorization"]
    steps = preflight["steps"]
    checkout = next(step for step in steps if step.get("name") == "Check out immutable zero-provider recovery verifier")
    recovery = next(step for step in steps if step.get("name") == "Verify receipt-bound direct review admission")
    freshness = next(step for step in steps if step.get("name") == "Update branch if behind; hold on conflict")
    return (
        preflight["permissions"].get("actions") == "read"
        and preflight["permissions"].get("checks") == "read"
        and preflight["outputs"].get("head_sha") == "${{ steps.classify.outputs.head_sha || inputs.expected_head_sha }}"
        and preflight["outputs"].get("zero_provider_recovery") == "${{ steps.zero-provider-recovery.outputs.eligible || 'false' }}"
        and checkout["if"] == "github.event_name == 'workflow_dispatch'"
        and checkout["with"].get("ref") == "${{ steps.recovery-revision.outputs.sha }}"
        and checkout["with"].get("persist-credentials") is False
        and "verify-zero-provider-recovery.sh" in checkout["with"].get("sparse-checkout", "")
        and recovery["if"] == checkout["if"]
        and recovery["env"].get("GH_TOKEN") == "${{ github.token }}"
        and recovery["env"].get("EXPECTED_HEAD_SHA") == "${{ inputs.expected_head_sha }}"
        and "bash .gate-recovery/scripts/ci-gate/verify-zero-provider-recovery.sh" in recovery["run"]
        and 'if [ "$REVIEW_RUN_ATTEMPT" -gt 1 ]; then' in recovery["run"]
        and "eligible=true" in recovery["run"]
        and "eligible=false" in recovery["run"]
        and freshness["env"].get("ZERO_PROVIDER_RECOVERY") == "${{ steps.zero-provider-recovery.outputs.eligible || 'false' }}"
        and '[ "${ZERO_PROVIDER_RECOVERY:-false}" != true ]; then' in freshness["run"]
        and complete["env"].get("EXPECTED_HEAD_SHA") == "${{ inputs.expected_head_sha }}"
        and complete["env"].get("EXPECTED_REVIEWED_HEAD_SHA") == "${{ inputs.expected_head_sha }}"
    )

with open(sys.argv[1], encoding="utf-8") as stream:
    workflow = yaml.safe_load(stream)
assert valid(workflow), "zero-provider workflow integration is invalid"

mutations = []
changed = copy.deepcopy(workflow)
del changed["jobs"]["preflight"]["permissions"]["checks"]
mutations.append(changed)
changed = copy.deepcopy(workflow)
recovery = next(
    step for step in changed["jobs"]["preflight"]["steps"]
    if step.get("name") == "Verify receipt-bound direct review admission"
)
del recovery["env"]["EXPECTED_HEAD_SHA"]
mutations.append(changed)
changed = copy.deepcopy(workflow)
checkout = next(step for step in changed["jobs"]["preflight"]["steps"] if step.get("name") == "Check out immutable zero-provider recovery verifier")
checkout["with"]["ref"] = "main"
mutations.append(changed)
changed = copy.deepcopy(workflow)
checkout = next(step for step in changed["jobs"]["preflight"]["steps"] if step.get("name") == "Check out immutable zero-provider recovery verifier")
checkout["if"] = "inputs.explicit_rereview == true && github.run_attempt != 1"
mutations.append(changed)
changed = copy.deepcopy(workflow)
recovery = next(step for step in changed["jobs"]["preflight"]["steps"] if step.get("name") == "Verify receipt-bound direct review admission")
recovery["run"] = "echo 'eligible=true' >>\"$GITHUB_OUTPUT\""
mutations.append(changed)
changed = copy.deepcopy(workflow)
freshness = next(step for step in changed["jobs"]["preflight"]["steps"] if step.get("name") == "Update branch if behind; hold on conflict")
freshness["run"] = freshness["run"].replace('[ "${ZERO_PROVIDER_RECOVERY:-false}" != true ]; then', 'false; then')
mutations.append(changed)
assert all(not valid(mutation) for mutation in mutations), "zero-provider workflow mutation escaped"
PY
then
  pass "trusted workflow admits only receipt-verified same-run recovery"
else
  fail "trusted workflow recovery integration is invalid"
fi

export TARGET_REPO=Verjson/example PR_NUMBER=7
export EXPECTED_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export AUTHORIZATION_CHECK_ID=9001 ARM_RUN_ID=7001 ARM_RUN_ATTEMPT=1
export EXPECTED_APP_ID=4528902 EXPECTED_APP_SLUG=ai-review-authorization
export REVIEW_POLICY=ZXhhY3QtcG9saWN5
export EXPECTED_POLICY="$REVIEW_POLICY"
export REVIEW_RUN_ID=8001 REVIEW_RUN_ATTEMPT=2 DEFAULT_BRANCH=main
export GITHUB_SERVER_URL=https://github.com RUNNER_TEMP="$tmp"

mkdir "$tmp/bin"
cat >"$tmp/receipt-verifier" <<'SH'
#!/usr/bin/env bash
[ "$REVIEW_POLICY" = "$EXPECTED_POLICY" ] &&
  [ "$AUTHORIZATION_CHECK_ID" = 9001 ] &&
  [ "$EXPECTED_APP_ID" = 4528902 ] &&
  [ "$EXPECTED_APP_SLUG" = ai-review-authorization ]
SH
chmod +x "$tmp/receipt-verifier"
export ZERO_PROVIDER_RECEIPT_VERIFIER="$tmp/receipt-verifier"

cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "api repos/$TARGET_REPO/actions/runs/$REVIEW_RUN_ID")
    jq -nc --argjson id "$REVIEW_RUN_ID" --argjson attempt "$REVIEW_RUN_ATTEMPT" \
      --arg title "${RUN_TITLE:-AI review authorization $AUTHORIZATION_CHECK_ID from arm $ARM_RUN_ID.$ARM_RUN_ATTEMPT}" \
      --arg repo "$TARGET_REPO" --arg branch "$DEFAULT_BRANCH" \
      --arg actor "${RUN_ACTOR:-github-actions[bot]}" \
      '{id:$id,run_attempt:$attempt,event:"workflow_dispatch",path:".github/workflows/ai-review-merge.yml",
        display_title:$title,head_branch:$branch,head_repository:{full_name:$repo},repository:{full_name:$repo},
        actor:{login:$actor},triggering_actor:{login:$actor},status:"in_progress"}' ;;
  "api --paginate --slurp repos/$TARGET_REPO/actions/workflows/ai-review-merge.yml/runs?event=workflow_dispatch&per_page=100")
    jq -nc --argjson id "$REVIEW_RUN_ID" \
      --arg title "${RUN_TITLE:-AI review authorization $AUTHORIZATION_CHECK_ID from arm $ARM_RUN_ID.$ARM_RUN_ATTEMPT}" \
      --arg repo "$TARGET_REPO" --arg branch "$DEFAULT_BRANCH" \
      --argjson duplicate "${DUPLICATE_CORRELATED_RUN:-false}" '
      [{workflow_runs: ([{
        id:$id,run_attempt:1,event:"workflow_dispatch",path:".github/workflows/ai-review-merge.yml",
        display_title:$title,head_branch:$branch,head_repository:{full_name:$repo},repository:{full_name:$repo}
      }] + (if $duplicate then [{
        id:($id + 1),run_attempt:1,event:"workflow_dispatch",path:".github/workflows/ai-review-merge.yml",
        display_title:$title,head_branch:$branch,head_repository:{full_name:$repo},repository:{full_name:$repo}
      }] else [] end))}]' ;;
  "api --paginate --slurp repos/$TARGET_REPO/actions/runs/$REVIEW_RUN_ID/jobs?filter=all&per_page=100")
    pre="${PREFLIGHT_CONCLUSION:-failure}"; gate="${GATE_CONCLUSION:-skipped}"
    gate_steps='[]'; [ "$gate" = skipped ] || gate_steps='[{"name":"Reserve AI review pass 1","status":"completed","conclusion":"success"}]'
    prefix="${JOB_NAME_PREFIX:-}"
    jq -nc --arg pre "$pre" --arg gate "$gate" --arg prefix "$prefix" --argjson gate_steps "$gate_steps" \
      --argjson attempt "$REVIEW_RUN_ATTEMPT" '
      [{jobs:[range(1; $attempt) as $n |
        {name:($prefix + "preflight"),run_attempt:$n,status:"completed",conclusion:$pre,steps:[]},
        {name:($prefix + "gate"),run_attempt:$n,status:"completed",conclusion:$gate,steps:$gate_steps},
        {name:($prefix + "complete-authorization"),run_attempt:$n,status:"completed",conclusion:"failure",steps:[]},
        {name:($prefix + "dispatch-merge"),run_attempt:$n,status:"completed",conclusion:"skipped",steps:[]}
      ]}]' ;;
  "api repos/$TARGET_REPO/pulls/$PR_NUMBER")
    jq -nc --arg head "${CURRENT_HEAD:-$EXPECTED_HEAD_SHA}" '{state:"open",head:{sha:$head}}' ;;
  "api repos/$TARGET_REPO/check-runs/$AUTHORIZATION_CHECK_ID")
    jq -nc --argjson id "${RETURNED_CHECK_ID:-$AUTHORIZATION_CHECK_ID}" --arg head "$EXPECTED_HEAD_SHA" \
      --argjson app "${RETURNED_APP_ID:-$EXPECTED_APP_ID}" --arg slug "${RETURNED_APP_SLUG:-$EXPECTED_APP_SLUG}" \
      --argjson attempt "$REVIEW_RUN_ATTEMPT" \
      '{id:$id,name:"AI review authorization",head_sha:$head,app:{id:$app,slug:$slug}} +
       (if $attempt == 1 and env.AUTHORIZATION_STATE != "retained" then {status:"in_progress",conclusion:null}
        else {status:"completed",conclusion:"failure"} end)' ;;
  "api --paginate --slurp repos/$TARGET_REPO/pulls/$PR_NUMBER/reviews?per_page=100")
    if [ "${PROVIDER_REVIEW:-false}" = true ]; then
      jq -nc --arg head "$EXPECTED_HEAD_SHA" --arg login "${EXPECTED_APP_SLUG}[bot]" \
        '[[{commit_id:$head,state:"COMMENTED",user:{login:$login},body:"reserved"}]]'
    else printf '[[]]\n'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

expect_pass() {
  local label="$1"; shift
  if "$@" >"$tmp/out" 2>&1; then pass "$label"; else fail "$label: $(tail -1 "$tmp/out")"; fi
}
expect_fail() {
  local label="$1" reason="$2"; shift 2
  if "$@" >"$tmp/out" 2>&1; then fail "$label"
  elif grep -qF "$reason" "$tmp/out"; then pass "$label"
  else fail "$label: $(tail -1 "$tmp/out")"; fi
}
verify() { bash "$verifier"; }

expect_pass "failed preflight with skipped gate is eligible for same-receipt recovery" verify
PREFLIGHT_CONCLUSION=success expect_pass "held preflight with skipped gate is eligible for same-receipt recovery" verify
PREFLIGHT_CONCLUSION=skipped expect_pass "skipped preflight is eligible for same-receipt recovery" verify
REVIEW_RUN_ATTEMPT=10 expect_pass "later same-run retry remains eligible with complete prior evidence" verify
RUN_TITLE='AI review' \
  expect_fail "generic run name cannot correlate recovery" "run identity mismatch" verify
RUN_TITLE="AI review authorization 9002 from arm $ARM_RUN_ID.$ARM_RUN_ATTEMPT" \
  expect_fail "substituted authorization check id cannot correlate recovery" "run identity mismatch" verify
RUN_TITLE="AI review authorization $AUTHORIZATION_CHECK_ID from arm 7002.$ARM_RUN_ATTEMPT" \
  expect_fail "substituted arm run id cannot correlate recovery" "run identity mismatch" verify
RUN_TITLE="AI review authorization $AUTHORIZATION_CHECK_ID from arm $ARM_RUN_ID.2" \
  expect_fail "substituted arm attempt cannot correlate recovery" "run identity mismatch" verify
unset RUN_TITLE
JOB_NAME_PREFIX='review / ' \
  expect_fail "synthetic reusable-job names cannot stand in for real direct-run history" "approached the provider boundary" verify
CURRENT_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  expect_fail "stale head recovery mutation fails closed" "recovery head is stale" verify
REVIEW_POLICY=different-policy \
  expect_fail "mismatched receipt policy mutation fails closed" "receipt identity mismatch" verify
RETURNED_CHECK_ID=9002 \
  expect_fail "mismatched authorization check mutation fails closed" "check or App identity mismatch" verify
RETURNED_APP_ID=9999 \
  expect_fail "mismatched authorization App mutation fails closed" "check or App identity mismatch" verify
GATE_CONCLUSION=success \
  expect_fail "provider-reservation step mutation fails closed" "approached the provider boundary" verify
PROVIDER_REVIEW=true \
  expect_fail "persisted provider review mutation fails closed" "provider reservation, submission, or review evidence" verify
REVIEW_RUN_ATTEMPT=1 \
  expect_pass "trusted-arm-owned unique initial dispatch admits the receipt" verify
REVIEW_RUN_ATTEMPT=1 RUN_ACTOR=maintainer \
  expect_fail "manual attempt-one dispatch cannot replay retained receipt" "not trusted-arm owned" verify
REVIEW_RUN_ATTEMPT=1 AUTHORIZATION_STATE=retained \
  expect_fail "attempt-one dispatch cannot replay a completed retained authorization" "cannot replay a retained authorization" verify
REVIEW_RUN_ATTEMPT=1 DUPLICATE_CORRELATED_RUN=true \
  expect_fail "duplicate attempt-one dispatch cannot replay retained receipt" "missing or not unique" verify

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."; exit 1
