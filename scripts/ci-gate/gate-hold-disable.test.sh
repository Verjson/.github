#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/gate-rearm.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
pass(){ printf 'ok   - %s\n' "$1"; }
fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

awk '$0=="        id: arm"{f=1} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' \
  "$workflow" >"$tmp/arm.sh"
[ -s "$tmp/arm.sh" ] || { echo "FAIL - arm block missing"; exit 1; }

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "pr view "*)
    [ "${GH_VIEW_FAIL:-false}" != true ] || exit 1
    count="$(grep -c '^pr view ' "$CALLS")"
    if [ "$count" -eq 1 ]; then cat "$META_FILE"; else cat "$DISABLED_META_FILE"; fi ;;
  "api graphql "*) cat "$GRAPHQL_FILE" ;;
  *"commits/"*"/check-runs "*) cat "$LATEST_FILE" ;;
  *"actions/runs/7001 --jq"*) printf '2\n' ;;
  *"actions/runs/7001") printf '{"event":"pull_request_target","path":".github/workflows/gate-rearm.yml","head_repository":{"full_name":"Verjson/example"},"run_attempt":2}\n' ;;
  *"actions/runs/8000") printf '{"event":"pull_request_target","path":".github/workflows/ai-review-label-rearm.yml","run_attempt":1,"head_sha":"0123456789abcdef0123456789abcdef01234567","head_repository":{"full_name":"Verjson/example"},"repository":{"id":1234},"actor":{"login":"maintainer"}}\n' ;;
  *"actions/runs/7001/artifacts?per_page=100 --jq"*) printf '%s\n' "${RECEIPT_COUNT:-1}" ;;
  "run download 7001 "*)
    for arg in "$@"; do destination="$arg"; done
    mkdir -p "$destination"
    printf '{"review_policy":"%s"}\n' "$RECEIPT_POLICY" >"$destination/receipt.json" ;;
  *"collaborators/maintainer/permission"*) printf '%s\n' "${ACTOR_PERMISSION:-triage}" ;;
  *"issues/7/events?per_page=100"*) printf '[{"id":1,"event":"labeled","label":{"name":"ai-review"},"actor":{"login":"maintainer"}},{"id":2,"event":"labeled","label":{"name":"re-review"},"actor":{"login":"maintainer"}}]\n' ;;
  *"contents/.github/workflows/ai-review-merge.yml?ref=main"*) cat "$CALLER_FILE" ;;
  *"--method POST repos/Verjson/example/check-runs --input -"*)
    payload="$(cat)"
    jq '. + {id:9100,app:{id:4242,slug:"verjson-ai-review"}}' <<<"$payload" ;;
  *"--method PATCH repos/Verjson/example/check-runs/9100"*"status=in_progress"*)
    jq -nc --arg ext "$(cat "$EXTERNAL_ID_FILE")" \
      '{id:9100,app:{id:4242,slug:"verjson-ai-review"},external_id:$ext,status:"in_progress",conclusion:null}' ;;
  "workflow run "*) printf 'DISPATCH %s\n' "$*" >>"$CALLS" ;;
  "pr comment "*) printf 'COMMENT %s\n' "$*" >>"$CALLS" ;;
  "pr edit "*) [ "${PR_EDIT_FAIL:-false}" != true ] ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" META_FILE="$tmp/meta.json"
export DISABLED_META_FILE="$tmp/disabled.json" GRAPHQL_FILE="$tmp/graphql.json" LATEST_FILE="$tmp/latest.json"
export TARGET_REPO=Verjson/example PR_NUMBER=7 APP_ID=4242 APP_SLUG=verjson-ai-review
export MINTED_APP_SLUG="$APP_SLUG"
export DEFAULT_BRANCH=main EVENT_LABEL=hold EVENT_OLD_TITLE='' GITHUB_REPOSITORY_OWNER=Verjson
export EVENT_NAME=pull_request_target REPOSITORY_ID=1234
export WORKFLOW_REF=Verjson/example/.github/workflows/ai-review-label-rearm.yml@refs/heads/main
export WORKFLOW_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export EVENT_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export ACTIONS_TOKEN=actions-token GH_TOKEN=app-token GITHUB_SERVER_URL=https://github.com
export GITHUB_RUN_ID=8000 GITHUB_RUN_ATTEMPT=1 RUNNER_TEMP="$tmp"
export GITHUB_OUTPUT="$tmp/github-output"
export GITHUB_ENV="$tmp/github-env"
export EXTERNAL_ID_FILE="$tmp/external-id"
CALLER_FILE="$tmp/current-caller.yml"
cp "$root/scripts/ci-gate/fixtures/ai-review-caller-a6b3ccc.yml" "$CALLER_FILE"
printf '# current schema caller\n' >>"$CALLER_FILE"
export CALLER_FILE
receipt_policy='eyJhY3RvciI6Im1haW50YWluZXIiLCJhY3Rvcl9wZXJtaXNzaW9uIjoibWFpbnRhaW4iLCJidWRnZXRfdXNkIjoiMS4wMCIsIm1vZGVsIjoiZ3B0LTUuNi1sdW5hIiwicHJpY2luZ192ZXJzaW9uIjoib3BlbmFpLWx1bmEtbG9uZy1jb250ZXh0LTIwMjYtMDgtMDgiLCJwcm92aWRlciI6Im9wZW5haSJ9'
substitute_policy='eyJhY3RvciI6InRydXN0ZWQtYXJtIiwiYWN0b3JfcGVybWlzc2lvbiI6ImF1dG9tYXRpb24iLCJidWRnZXRfdXNkIjoiYXV0byIsIm1vZGVsIjoiYXV0byIsInByaWNpbmdfdmVyc2lvbiI6ImFudGhyb3BpYy1uYXRpdmUtdjEiLCJwcm92aWRlciI6ImFudGhyb3BpYyJ9'
export RECEIPT_POLICY="$receipt_policy"
head_sha=0123456789abcdef0123456789abcdef01234567

write_hold() {
  : >"$CALLS"
  jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"hold"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:{enabledAt:"now"}}' >"$META_FILE"
  printf '{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"PR_id"}}}}\n' >"$GRAPHQL_FILE"
  printf '{"id":"PR_id","autoMergeRequest":null}\n' >"$DISABLED_META_FILE"
  export EVENT_NAME=pull_request_target EVENT_ACTION=synchronize
}
run_arm(){
  sed '/^external_id=/a\printf "%s" "$external_id" >"$EXTERNAL_ID_FILE"' \
    "${ARM_SCRIPT:-$tmp/arm.sh}" >"$tmp/arm-with-external-id.sh"
  bash "$tmp/arm-with-external-id.sh"
}
expect_fail(){ label="$1"; if run_arm >"$tmp/out" 2>&1; then fail "$label"; else pass "$label"; fi; }

write_hold
MINTED_APP_SLUG=renamed-app
if run_arm >"$tmp/out" 2>&1; then
  fail "minted App slug mismatch was accepted"
elif grep -q "AI review authorization App slug mismatch: expected 'verjson-ai-review', minted 'renamed-app'" "$tmp/out" \
  && ! grep -q -- '--method POST repos/Verjson/example/check-runs' "$CALLS"; then
  pass "minted App slug mismatch fails exactly before authorization creation"
else
  fail "minted App slug mismatch did not fail exactly before authorization creation"
fi
MINTED_APP_SLUG="$APP_SLUG"
write_hold
if run_arm >"$tmp/out" 2>&1; then pass "hold disables auto-merge only after authoritative confirmation"; else fail "confirmed hold failed"; fi
write_hold; printf '{"data":null,"errors":[{"message":"denied"}]}\n' >"$GRAPHQL_FILE"
expect_fail "HTTP-200 GraphQL errors fail the hold closed"
write_hold; printf '{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"wrong"}}}}\n' >"$GRAPHQL_FILE"
expect_fail "a mutation response for another PR fails closed"
write_hold; printf '{"id":"PR_id","autoMergeRequest":{"enabledAt":"still-on"}}\n' >"$DISABLED_META_FILE"
expect_fail "auto-merge remaining enabled after mutation fails closed"

write_terminal_hold() {
  : >"$CALLS"
  jq -nc --arg head "$head_sha" \
    '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' \
    >"$META_FILE"
  export EVENT_ACTION=synchronize EVENT_LABEL='' EVENT_OLD_TITLE=''
}

for signal in do-not-merge-label do_not_merge-label title draft; do
  write_terminal_hold
  case "$signal" in
    do-not-merge-label) jq '.labels=[{"name":"do-not-merge"}]' "$META_FILE" >"$tmp/x" ;;
    do_not_merge-label) jq '.labels=[{"name":"Do_Not_Merge"}]' "$META_FILE" >"$tmp/x" ;;
    title) jq '.title="chore: DO NOT MERGE until QA"' "$META_FILE" >"$tmp/x" ;;
    draft) jq '.isDraft=true' "$META_FILE" >"$tmp/x" ;;
  esac
  mv "$tmp/x" "$META_FILE"
  if run_arm >"$tmp/out" 2>&1 && ! grep -q 'check-runs\|workflow run' "$CALLS"; then
    pass "$signal remains a terminal arm no-op"
  else
    fail "$signal reached authorization or dispatch"
  fi
done

for malformed in truncated labels-not-array label-name-not-string title-not-string; do
  write_terminal_hold
  case "$malformed" in
    truncated) printf '{"labels":[{"name":"hold"}],"title":"change","isDraft":fal' >"$META_FILE" ;;
    labels-not-array) jq '.labels="hold"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
    label-name-not-string) jq '.labels=[{"name":{"value":"hold"}}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
    title-not-string) jq '.title=42' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
  esac
  expect_fail "$malformed hold metadata fails closed before authorization"
  ! grep -q 'check-runs\|workflow run' "$CALLS" \
    && pass "$malformed hold metadata cannot authorize or dispatch" \
    || fail "$malformed hold metadata reached authorization or dispatch"
done

for unreadable in empty null missing-hold-fields; do
  write_terminal_hold
  case "$unreadable" in
    empty) : >"$META_FILE" ;;
    null) printf 'null\n' >"$META_FILE" ;;
    missing-hold-fields)
      jq 'del(.labels, .title, .isDraft)' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
  esac
  expect_fail "$unreadable PR metadata fails closed before authorization"
  ! grep -q 'check-runs\|workflow run' "$CALLS" \
    && pass "$unreadable PR metadata cannot authorize or dispatch" \
    || fail "$unreadable PR metadata reached authorization or dispatch"
done

write_terminal_hold
export GH_VIEW_FAIL=true
expect_fail "an arm metadata API failure fails closed"
unset GH_VIEW_FAIL
! grep -q 'check-runs\|workflow run' "$CALLS" \
  && pass "an arm metadata API failure cannot authorize or dispatch" \
  || fail "an arm metadata API failure reached authorization or dispatch"

for terminal_state in CLOSED MERGED; do
  write_terminal_hold
  jq --arg state "$terminal_state" '.state=$state' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
  if run_arm >"$tmp/out" 2>&1 && ! grep -q 'check-runs\|workflow run' "$CALLS"; then
    pass "$terminal_state PR is a terminal arm no-op"
  else
    fail "$terminal_state PR reached authorization or dispatch"
  fi
done

write_repromotion() {
  : >"$CALLS"
  jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
  jq -nc --arg head "$head_sha" '{id:9001,conclusion:"success",details_url:"https://github.com/Verjson/example/actions/runs/7001",head_sha:$head}' >"$LATEST_FILE"
  export EVENT_ACTION=unlabeled EVENT_LABEL=hold EVENT_OLD_TITLE='' RECEIPT_COUNT=1
}
write_repromotion
if run_arm >"$tmp/out" 2>&1 && grep -q 'workflow run ai-privileged-merge.yml' "$CALLS" \
  && grep -qF -- "-f review_policy=$receipt_policy" "$CALLS" && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
  pass "hold removal reuses a live receipt without another paid review"
else fail "hold removal did not reuse authorization: $(tail -1 "$tmp/out")"; fi

for release_case in normalized-label ready-for-review edited-title; do
  write_repromotion
  case "$release_case" in
    normalized-label) export EVENT_ACTION=unlabeled EVENT_LABEL='Do__Not--Merge' EVENT_OLD_TITLE='' ;;
    ready-for-review) export EVENT_ACTION=ready_for_review EVENT_LABEL='' EVENT_OLD_TITLE='' ;;
    edited-title) export EVENT_ACTION=edited EVENT_LABEL='' EVENT_OLD_TITLE='chore: DO NOT MERGE until QA' ;;
  esac
  if run_arm >"$tmp/out" 2>&1 && grep -q 'workflow run ai-privileged-merge.yml' "$CALLS" \
      && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
    pass "$release_case reuses exact-head authorization without another paid review"
  else
    fail "$release_case did not follow the receipt-preserving re-arm path"
  fi
done

write_repromotion
export EVENT_ACTION=unlabeled EVENT_LABEL=documentation EVENT_OLD_TITLE=''
if run_arm >"$tmp/out" 2>&1 && ! grep -q 'commits/.*/check-runs\|workflow run' "$CALLS"; then
  pass "unrelated label removal exits before authorization lookup or dispatch"
else
  fail "unrelated label removal reached authorization lookup or dispatch"
fi
sed "s|review_policy=\"\$(jq -er .*|review_policy=\"$substitute_policy\"|" "$tmp/arm.sh" >"$tmp/arm-substituted.sh"
write_repromotion
if ARM_SCRIPT="$tmp/arm-substituted.sh" run_arm >"$tmp/out" 2>&1 \
  && grep -qF -- "-f review_policy=$substitute_policy" "$CALLS" \
  && ! grep -qF -- "-f review_policy=$receipt_policy" "$CALLS"; then
  pass "valid constant substitution is detected instead of matching the recovered receipt policy"
else fail "constant substitution mutation escaped the exact-value assertion"; fi
write_repromotion; export RECEIPT_COUNT=0
expect_fail "expired receipt requires explicit admin recovery"
! grep -q 'workflow run ai-review-merge.yml' "$CALLS" \
  && pass "expired receipt never automatically dispatches another paid review" \
  || fail "expired receipt dispatched paid review"

write_repromotion
jq '.status="completed" | .conclusion="failure"' "$LATEST_FILE" >"$tmp/x" && mv "$tmp/x" "$LATEST_FILE"
if run_arm >"$tmp/out" 2>&1 && grep -q 're-review' "$CALLS" && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
  pass "failed authorization requires an explicit paid re-review decision"
else fail "failed authorization hold-clear guidance is missing"; fi

write_repromotion
jq '.status="in_progress" | .conclusion=null' "$LATEST_FILE" >"$tmp/x" && mv "$tmp/x" "$LATEST_FILE"
if run_arm >"$tmp/out" 2>&1 && grep -q 'still in progress' "$CALLS" && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
  pass "receipt-proven pending authorization tells maintainers to wait without redispatch"
else fail "pending authorization was not handled spend-safely"; fi

write_repromotion
jq '.status="in_progress" | .conclusion=null' "$LATEST_FILE" >"$tmp/x" && mv "$tmp/x" "$LATEST_FILE"
export RECEIPT_COUNT=0
expect_fail "unproven pending authorization requires admin recovery"
grep -q 'administrator must recover' "$CALLS" \
  && pass "unproven pending authorization emits recovery guidance" \
  || fail "unproven pending authorization guidance missing"
! grep -q 'workflow run ai-review-merge.yml' "$CALLS" \
  && pass "pending recovery never automatically dispatches another paid review" \
  || fail "pending recovery dispatched a paid review"

: >"$CALLS"
jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"re-review"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
export EVENT_ACTION=labeled EVENT_LABEL=re-review REQUEST_ACTOR=maintainer ACTOR_PERMISSION=triage
export EVENT_NAME=pull_request_target
export REREVIEW_PROVIDER=openai REREVIEW_MODEL=gpt-5.6-luna REREVIEW_BUDGET_USD=1.00
expect_fail "triage actor cannot authorize a paid re-review"
! grep -q 'check-runs' "$CALLS" && pass "unauthorized actor fails before receipt or paid dispatch" || fail "unauthorized actor reached authorization creation"

: >"$CALLS"
jq '.labels=[]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
export ACTOR_PERMISSION=maintain
expect_fail "withdrawn re-review label fails authoritative current-state validation"
! grep -q -- '--method POST repos/Verjson/example/check-runs\|workflow run ai-review-merge.yml' "$CALLS" \
  && pass "withdrawn re-review cannot create a receipt check or dispatch" \
  || fail "withdrawn re-review reached authorization or paid dispatch"

# An `ai-review` label may be added after the ordinary human-path authorization
# already completed for this head. That explicit, maintainer-authorized opt-in
# must create a fresh receipt instead of being mistaken for a duplicate event.
: >"$CALLS"; : >"$GITHUB_OUTPUT"
jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"ai-review"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
jq -nc --arg head "$head_sha" '{id:9001,status:"completed",conclusion:"success",details_url:"https://github.com/Verjson/example/actions/runs/7001",head_sha:$head}' >"$LATEST_FILE"
export EVENT_ACTION=labeled EVENT_LABEL=ai-review REQUEST_ACTOR=maintainer ACTOR_PERMISSION=maintain
export EVENT_NAME=pull_request_target
export REVIEW_AUTHORITY=human PRIMARY_PROVIDER=deepseek PRIMARY_MODEL=deepseek-v4-pro PRIMARY_BUDGET_USD=5.00
export PRIMARY_FALLBACK_MODEL=deepseek-v4-flash PRIMARY_FALLBACK_BUDGET_USD=5.00
if run_arm >"$tmp/out" 2>&1 && grep -q -- '--method POST repos/Verjson/example/check-runs --input -' "$CALLS" \
  && grep -q '^check_id=9100$' "$GITHUB_OUTPUT" \
  && policy_envelope="$(sed -n 's/^review_policy=//p' "$GITHUB_OUTPUT")" \
  && policy_json="$(python3 "$root/scripts/ci-gate/review-policy-envelope.py" decode "$policy_envelope")" \
  && [ "$(jq -r '.actor + ":" + .actor_permission' <<<"$policy_json")" = maintainer:maintain ]; then
  pass "post-open ai-review opt-in bypasses the existing human-path authorization"
else
  fail "post-open ai-review opt-in lost its verified actor permission or failed before receipt creation"
fi

# Persistent label state is not a delivery and must never be reusable authority.
: >"$CALLS"; : >"$GITHUB_OUTPUT"
sync_opt_in_temp="$tmp/sync-opt-in"; mkdir "$sync_opt_in_temp"; export RUNNER_TEMP="$sync_opt_in_temp"
export EVENT_NAME=pull_request_target EVENT_ACTION=synchronize EVENT_LABEL='' REQUEST_ACTOR=pusher ACTOR_PERMISSION=maintain
if run_arm >"$tmp/out" 2>&1 \
  && ! grep -q 'collaborators/maintainer/permission\|--method POST repos/Verjson/example/check-runs' "$CALLS"; then
  pass "synchronize cannot promote persistent ai-review label state into authority"
else
  fail "synchronize reused persistent ai-review label state"
fi
export RUNNER_TEMP="$tmp"

# A repository-level provider choice overrides the inherited organization
# DeepSeek policy as a unit. Stale Pro->Flash fallback variables must not make
# Anthropic/OpenAI invalid or leak into their receipt policy.
: >"$CALLS"; : >"$GITHUB_OUTPUT"
provider_temp="$tmp/provider-anthropic"; mkdir "$provider_temp"; export RUNNER_TEMP="$provider_temp"
export EVENT_NAME=pull_request_target EVENT_ACTION=synchronize EVENT_LABEL=''
jq '.labels=[]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
printf '{}\n' >"$LATEST_FILE"
export PRIMARY_PROVIDER=anthropic PRIMARY_MODEL=auto PRIMARY_BUDGET_USD=auto
export PRIMARY_FALLBACK_MODEL=deepseek-v4-flash PRIMARY_FALLBACK_BUDGET_USD=5.00
if run_arm >"$tmp/out" 2>&1 \
  && policy_envelope="$(sed -n 's/^review_policy=//p' "$GITHUB_OUTPUT")" \
  && policy_json="$(python3 "$root/scripts/ci-gate/review-policy-envelope.py" decode "$policy_envelope")" \
  && [ "$(jq -r '.provider + ":" + .fallback_model + ":" + .fallback_budget_usd' <<<"$policy_json")" = 'anthropic::' ]; then
  pass "repository Anthropic override clears inherited DeepSeek fallback policy"
else
  fail "repository Anthropic override retained inherited DeepSeek fallback policy"
fi

: >"$CALLS"; : >"$GITHUB_OUTPUT"
provider_temp="$tmp/provider-openai"; mkdir "$provider_temp"; export RUNNER_TEMP="$provider_temp"
jq '.labels=[{"name":"re-review"}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
export EVENT_ACTION=labeled EVENT_LABEL=re-review REQUEST_ACTOR=maintainer ACTOR_PERMISSION=maintain
export EVENT_NAME=pull_request_target
export REREVIEW_PROVIDER=openai REREVIEW_MODEL=gpt-5.6-luna REREVIEW_BUDGET_USD=1.00
export REREVIEW_FALLBACK_MODEL=deepseek-v4-flash REREVIEW_FALLBACK_BUDGET_USD=5.00
if run_arm >"$tmp/out" 2>&1 \
  && policy_envelope="$(sed -n 's/^review_policy=//p' "$GITHUB_OUTPUT")" \
  && policy_json="$(python3 "$root/scripts/ci-gate/review-policy-envelope.py" decode "$policy_envelope")" \
  && [ "$(jq -r '.provider + ":" + .fallback_model + ":" + .fallback_budget_usd' <<<"$policy_json")" = 'openai::' ]; then
  pass "repository OpenAI override clears inherited DeepSeek fallback policy"
else
  fail "repository OpenAI override retained inherited DeepSeek fallback policy"
fi
export RUNNER_TEMP="$tmp"

# GitHub can omit a label-triggered pull_request_target delivery entirely. A
# maintainer can rerun a prior exact-head arm attempt; attempt 2 must bypass
# same-head deduplication only after the arm re-reads current PR/head state, and
# the new receipt must bind that run attempt. This does not simulate or claim a
# repaired label delivery.
: >"$CALLS"; : >"$GITHUB_OUTPUT"
jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"re-review"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
recovery_temp="$tmp/recovery"
mkdir "$recovery_temp"
export EVENT_NAME=pull_request_target EVENT_ACTION=labeled EVENT_LABEL=re-review REQUEST_ACTOR=maintainer ACTOR_PERMISSION=maintain GITHUB_RUN_ATTEMPT=2 RUNNER_TEMP="$recovery_temp"
expect_fail "rerun cannot replay an explicit re-review delivery"
! grep -q -- '--method POST repos/Verjson/example/check-runs' "$CALLS" \
  && pass "replayed delivery fails before authorization creation" \
  || fail "replayed delivery created authorization"

: >"$CALLS"; : >"$GITHUB_OUTPUT"
jq '.labels=[]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
repeated_recovery_temp="$tmp/repeated-recovery"
mkdir "$repeated_recovery_temp"
export GITHUB_RUN_ATTEMPT=3 RUNNER_TEMP="$repeated_recovery_temp"
expect_fail "later rerun remains fail-closed after label consumption"
export GITHUB_RUN_ATTEMPT=1 RUNNER_TEMP="$tmp"

: >"$CALLS"; : >"$GITHUB_OUTPUT"
jq '.labels=[{"name":"ai-review"}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
export EVENT_ACTION=labeled EVENT_LABEL=ai-review ACTOR_PERMISSION=triage PR_EDIT_FAIL=true
export EVENT_NAME=pull_request_target
expect_fail "unauthorized ai-review label fails even when cleanup cannot remove it"
: >"$CALLS"
export EVENT_NAME=pull_request_target EVENT_ACTION=synchronize EVENT_LABEL='' REQUEST_ACTOR=pusher
sync_retained_temp="$tmp/sync-retained"; mkdir "$sync_retained_temp"; export RUNNER_TEMP="$sync_retained_temp"
if run_arm >"$tmp/out" 2>&1 \
  && ! grep -q 'collaborators/maintainer/permission' "$CALLS" \
  && ! grep -q '^explicit_ai_review=true$' "$GITHUB_OUTPUT"; then
  pass "retained unauthorized label cannot become explicit review authority"
else
  fail "retained unauthorized label influenced the synchronized authorization policy"
fi
export RUNNER_TEMP="$tmp"
unset PR_EDIT_FAIL

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."; exit 1
