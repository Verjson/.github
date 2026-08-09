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
    count="$(grep -c '^pr view ' "$CALLS")"
    if [ "$count" -eq 1 ]; then cat "$META_FILE"; else cat "$DISABLED_META_FILE"; fi ;;
  "api graphql "*) cat "$GRAPHQL_FILE" ;;
  *"commits/"*"/check-runs "*) cat "$LATEST_FILE" ;;
  *"actions/runs/7001 --jq"*) printf '2\n' ;;
  *"actions/runs/7001") printf '{"event":"pull_request_target","path":".github/workflows/gate-rearm.yml","head_repository":{"full_name":"Verjson/example"},"run_attempt":2}\n' ;;
  *"actions/runs/7001/artifacts?per_page=100 --jq"*) printf '%s\n' "${RECEIPT_COUNT:-1}" ;;
  "run download 7001 "*)
    for arg in "$@"; do destination="$arg"; done
    mkdir -p "$destination"
    printf '{"review_policy":"%s"}\n' "$RECEIPT_POLICY" >"$destination/receipt.json" ;;
  *"collaborators/maintainer/permission"*) printf '%s\n' "${ACTOR_PERMISSION:-triage}" ;;
  "workflow run "*) printf 'DISPATCH %s\n' "$*" >>"$CALLS" ;;
  "pr comment "*) printf 'COMMENT %s\n' "$*" >>"$CALLS" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" META_FILE="$tmp/meta.json"
export DISABLED_META_FILE="$tmp/disabled.json" GRAPHQL_FILE="$tmp/graphql.json" LATEST_FILE="$tmp/latest.json"
export TARGET_REPO=Verjson/example PR_NUMBER=7 APP_ID=4242 APP_SLUG=verjson-ai-review
export DEFAULT_BRANCH=main EVENT_LABEL=hold EVENT_OLD_TITLE='' GITHUB_REPOSITORY_OWNER=Verjson
export ACTIONS_TOKEN=actions-token GH_TOKEN=app-token GITHUB_SERVER_URL=https://github.com
export GITHUB_RUN_ID=8000 GITHUB_RUN_ATTEMPT=1 RUNNER_TEMP="$tmp"
receipt_policy='eyJhY3RvciI6Im1haW50YWluZXIiLCJhY3Rvcl9wZXJtaXNzaW9uIjoibWFpbnRhaW4iLCJidWRnZXRfdXNkIjoiMS4wMCIsIm1vZGVsIjoiZ3B0LTUuNi1sdW5hIiwicHJpY2luZ192ZXJzaW9uIjoib3BlbmFpLWx1bmEtbG9uZy1jb250ZXh0LTIwMjYtMDgtMDgiLCJwcm92aWRlciI6Im9wZW5haSJ9'
substitute_policy='eyJhY3RvciI6InRydXN0ZWQtYXJtIiwiYWN0b3JfcGVybWlzc2lvbiI6ImF1dG9tYXRpb24iLCJidWRnZXRfdXNkIjoiYXV0byIsIm1vZGVsIjoiYXV0byIsInByaWNpbmdfdmVyc2lvbiI6ImFudGhyb3BpYy1uYXRpdmUtdjEiLCJwcm92aWRlciI6ImFudGhyb3BpYyJ9'
export RECEIPT_POLICY="$receipt_policy"
head_sha=0123456789abcdef0123456789abcdef01234567

write_hold() {
  : >"$CALLS"
  jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"hold"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:{enabledAt:"now"}}' >"$META_FILE"
  printf '{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"PR_id"}}}}\n' >"$GRAPHQL_FILE"
  printf '{"id":"PR_id","autoMergeRequest":null}\n' >"$DISABLED_META_FILE"
  export EVENT_ACTION=labeled
}
run_arm(){ bash "${ARM_SCRIPT:-$tmp/arm.sh}"; }
expect_fail(){ label="$1"; if run_arm >"$tmp/out" 2>&1; then fail "$label"; else pass "$label"; fi; }

write_hold
if run_arm >"$tmp/out" 2>&1; then pass "hold disables auto-merge only after authoritative confirmation"; else fail "confirmed hold failed"; fi
write_hold; printf '{"data":null,"errors":[{"message":"denied"}]}\n' >"$GRAPHQL_FILE"
expect_fail "HTTP-200 GraphQL errors fail the hold closed"
write_hold; printf '{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"wrong"}}}}\n' >"$GRAPHQL_FILE"
expect_fail "a mutation response for another PR fails closed"
write_hold; printf '{"id":"PR_id","autoMergeRequest":{"enabledAt":"still-on"}}\n' >"$DISABLED_META_FILE"
expect_fail "auto-merge remaining enabled after mutation fails closed"

write_repromotion() {
  : >"$CALLS"
  jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
  jq -nc --arg head "$head_sha" '{id:9001,conclusion:"success",details_url:"https://github.com/Verjson/example/actions/runs/7001",head_sha:$head}' >"$LATEST_FILE"
  export EVENT_ACTION=unlabeled RECEIPT_COUNT=1
}
write_repromotion
if run_arm >"$tmp/out" 2>&1 && grep -q 'workflow run ai-privileged-merge.yml' "$CALLS" \
  && grep -qF -- "-f review_policy=$receipt_policy" "$CALLS" && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
  pass "hold removal reuses a live receipt without another paid review"
else fail "hold removal did not reuse authorization: $(tail -1 "$tmp/out")"; fi
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
export REREVIEW_PROVIDER=openai REREVIEW_MODEL=gpt-5.6-luna REREVIEW_BUDGET_USD=1.00
expect_fail "triage actor cannot authorize a paid re-review"
! grep -q 'check-runs' "$CALLS" && pass "unauthorized actor fails before receipt or paid dispatch" || fail "unauthorized actor reached authorization creation"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."; exit 1
