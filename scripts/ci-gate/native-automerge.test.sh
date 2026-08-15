#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/ai-privileged-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

awk '
  $0 == "      - name: Attempt terminal merge from trusted metadata" { found=1; next }
  found && $0 == "        run: |" { run=1; next }
  run { sub(/^          /, ""); print }
' "$workflow" >"$tmp/promote.sh"
[ -s "$tmp/promote.sh" ] || { echo "FAIL - promotion block missing"; exit 1; }

mkdir -p "$tmp/bin" "$tmp/run/.gate-trust/scripts/ci-gate"
cat >"$tmp/run/.gate-trust/scripts/ci-gate/verify-arm-receipt.sh" <<'SH'
#!/usr/bin/env bash
printf 'verify-arm-receipt\n' >>"$CALLS"
exit "${VERIFY_RC:-0}"
SH
chmod 0644 "$tmp/run/.gate-trust/scripts/ci-gate/verify-arm-receipt.sh"
cp "$root/scripts/ci-gate/review-policy-envelope.py" "$tmp/run/.gate-trust/scripts/ci-gate/review-policy-envelope.py"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "pr view "*) cat "$META_FILE" ;;
  *"repos/$TARGET_REPO --jq"*) printf '%s\n' main ;;
  *"commits/$EXPECTED_HEAD_SHA/check-runs?per_page=100"*) cat "$CI_CHECKS_FILE" ;;
  *"actions/workflows/315894159/runs?head_sha=$EXPECTED_HEAD_SHA&event=pull_request&per_page=100"*) cat "$WORKFLOW_RUNS_FILE" ;;
  *"actions/workflows/315894159"*)
    [ "${WORKFLOW_METADATA_RC:-0}" = 0 ] || exit "$WORKFLOW_METADATA_RC"
    cat "$WORKFLOW_METADATA_FILE" ;;
  *"actions/runs/7002/jobs?per_page=100"*) cat "$CI_JOBS_FILE" ;;
  *"actions/runs/7002"*) cat "$CI_RUN_FILE" ;;
  *"contents/.github/workflows/actions-ci.yml?ref=$EXPECTED_HEAD_SHA"*) printf '%s\n' "$WORKFLOW_BLOB_HEAD" ;;
  *"contents/.github/workflows/actions-ci.yml?ref=main"*) printf '%s\n' "$WORKFLOW_BLOB_TRUSTED" ;;
  *"repos/Verjson/.github/commits/main"*) printf '%s\n' "$EXECUTING_WORKFLOW_SHA" ;;
  *"check-runs/$AUTHORIZATION_CHECK_ID"*) cat "$CHECK_FILE" ;;
  *"pulls/$PR_NUMBER/reviews?per_page=100"*) cat "$REVIEWS_FILE" ;;
  "pr merge "*)
    if [ "${MERGE_CONFIRMED:-true}" = true ]; then
      jq '.state="MERGED"' "$META_FILE" >"$META_FILE.next" && mv "$META_FILE.next" "$META_FILE"
    fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" META_FILE="$tmp/meta.json" CHECK_FILE="$tmp/check.json" REVIEWS_FILE="$tmp/reviews.json" CI_CHECKS_FILE="$tmp/ci-checks.json" CI_RUN_FILE="$tmp/ci-run.json" CI_JOBS_FILE="$tmp/ci-jobs.json"
export WORKFLOW_METADATA_FILE="$tmp/workflow-metadata.json" WORKFLOW_RUNS_FILE="$tmp/workflow-runs.json"
export TARGET_REPO=Verjson/example PR_NUMBER=7 AUTHORIZATION_CHECK_ID=9001
export EXPECTED_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export ARM_RUN_ID=7001 ARM_RUN_ATTEMPT=2 EXPECTED_APP_ID=4242 EXPECTED_APP_SLUG=verjson-ai-review
export GH_TOKEN=admin-token GITHUB_REPOSITORY_OWNER=Verjson GITHUB_REF=refs/heads/main CALLER_REF=refs/heads/main
export EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github EXECUTING_WORKFLOW_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export GITHUB_SERVER_URL=https://github.com GITHUB_API_URL=https://api.github.com WORKFLOW_BLOB_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa WORKFLOW_BLOB_TRUSTED=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export REQUIRED_CHECK_POLICY='[{"name":"shell-tests","app_id":15368,"workflow_id":315894159,"workflow_path":".github/workflows/actions-ci.yml"}]'
encode_policy() { python3 "$root/scripts/ci-gate/review-policy-envelope.py" encode "$1"; }
ai_merge_policy='{"actor":"trusted-arm","actor_permission":"automation","authority":"ai-merge","budget_usd":"5.00","fallback_budget_usd":"5.00","fallback_model":"deepseek-v4-flash","model":"deepseek-v4-pro","pricing_version":"deepseek-v4-2026-08-10","provider":"deepseek"}'
ai_approve_policy='{"actor":"trusted-arm","actor_permission":"automation","authority":"ai-approve","budget_usd":"5.00","fallback_budget_usd":"5.00","fallback_model":"deepseek-v4-flash","model":"deepseek-v4-pro","pricing_version":"deepseek-v4-2026-08-10","provider":"deepseek"}'
export REVIEW_POLICY="$(encode_policy "$ai_merge_policy")"

write_base() {
  : >"$CALLS"
  unset VERIFY_RC
  unset MERGE_CONFIRMED
  unset WORKFLOW_METADATA_RC
  export WORKFLOW_BLOB_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa WORKFLOW_BLOB_TRUSTED=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  jq -nc --arg head "$EXPECTED_HEAD_SHA" '{state:"OPEN",isDraft:false,title:"change",labels:[],headRefOid:$head,headRepositoryOwner:{login:"Verjson"}}' >"$META_FILE"
  jq -nc --arg head "$EXPECTED_HEAD_SHA" --argjson app "$EXPECTED_APP_ID" --arg slug "$EXPECTED_APP_SLUG" \
    '{id:9001,name:"AI review authorization",head_sha:$head,status:"completed",conclusion:"success",app:{id:$app,slug:$slug}}' >"$CHECK_FILE"
  jq -nc --arg head "$EXPECTED_HEAD_SHA" --arg login "${EXPECTED_APP_SLUG}[bot]" --arg check "$AUTHORIZATION_CHECK_ID" \
    '[{id:81,state:"APPROVED",commit_id:$head,user:{login:$login},body:("<!-- ai-review-authorization:"+$check+" -->")}]' >"$REVIEWS_FILE"
  jq -nc --arg head "$EXPECTED_HEAD_SHA" '{check_runs:[{id:101,name:"shell-tests",head_sha:$head,status:"completed",conclusion:"success",details_url:"https://github.com/Verjson/example/actions/runs/7002/job/8002",app:{id:15368,slug:"github-actions"},check_suite:{id:6002}}]}' >"$CI_CHECKS_FILE"
  jq -nc --arg head "$EXPECTED_HEAD_SHA" '{id:7002,check_suite_id:6002,workflow_id:315894159,path:".github/workflows/actions-ci.yml",event:"pull_request",head_sha:$head,head_repository:{full_name:"Verjson/example"},status:"completed",conclusion:"success"}' >"$CI_RUN_FILE"
  jq -nc '{jobs:[{id:8002,name:"shell-tests",check_run_url:"https://api.github.com/repos/Verjson/example/check-runs/101"}]}' >"$CI_JOBS_FILE"
  jq -nc '{id:315894159,path:".github/workflows/actions-ci.yml",state:"active"}' >"$WORKFLOW_METADATA_FILE"
  jq -nc --arg head "$EXPECTED_HEAD_SHA" '{workflow_runs:[{id:7002,workflow_id:315894159,path:".github/workflows/actions-ci.yml",event:"pull_request",head_sha:$head,status:"completed",conclusion:"success"}]}' >"$WORKFLOW_RUNS_FILE"
}
run_promote() { (cd "$tmp/run" && bash "$tmp/promote.sh"); }
expect_pass() { label="$1"; shift; if "$@" >"$tmp/out" 2>&1; then pass "$label"; else fail "$label: $(tail -1 "$tmp/out")"; fi; }
expect_fail() { label="$1"; shift; if "$@" >"$tmp/out" 2>&1; then fail "$label"; else pass "$label"; fi; }

if (cd "$tmp/run" && .gate-trust/scripts/ci-gate/verify-arm-receipt.sh) >"$tmp/out" 2>&1; then
  fail "non-executable sparse-checkout fixture unexpectedly supports direct execution"
else
  pass "non-executable sparse-checkout fixture rejects direct execution"
fi
write_base; expect_pass "explicit bash invocation supports a non-executable sparse-checkout verifier" run_promote
grep -q -- '--admin --squash --match-head-commit' "$CALLS" \
  && pass "all-success promotion merges the exact authorized head" || fail "terminal promotion did not use exact-head admin squash merge"
write_base; REVIEW_POLICY="$(encode_policy "$ai_approve_policy")" expect_fail "ai-approve authority never reaches terminal merge" run_promote
! grep -q 'pr merge' "$CALLS" || fail "ai-approve authority attempted a terminal merge"
write_base; jq '.conclusion="failure"' "$CHECK_FILE" >"$tmp/x" && mv "$tmp/x" "$CHECK_FILE"; expect_fail "failed authorization never promotes" run_promote
write_base; jq '.conclusion=null' "$CHECK_FILE" >"$tmp/x" && mv "$tmp/x" "$CHECK_FILE"; expect_fail "inconclusive authorization never promotes" run_promote
write_base; printf '[]\n' >"$REVIEWS_FILE"; expect_fail "missing exact App approval never promotes" run_promote
write_base; jq '.[0].user.login="attacker[bot]"' "$REVIEWS_FILE" >"$tmp/x" && mv "$tmp/x" "$REVIEWS_FILE"; expect_fail "wrong approval identity never promotes" run_promote
write_base; jq '.[0].commit_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$REVIEWS_FILE" >"$tmp/x" && mv "$tmp/x" "$REVIEWS_FILE"; expect_fail "stale App approval never promotes" run_promote
write_base; jq '.headRepositoryOwner.login="outsider"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_fail "fork PR fails closed" run_promote
write_base; jq '.isDraft=true' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "draft PR is a terminal no-op" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "draft merged"
write_base; jq '.labels=[{"name":"hold"}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "held PR is a terminal no-op" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "hold merged"
write_base; jq '.labels=[{"name":"DO NOT MERGE"}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "DO NOT MERGE label is a terminal no-op" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "DO NOT MERGE label merged"
write_base; jq '.labels=[{"name":"Do__Not--Merge"}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "normalized hold label is a terminal no-op" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "normalized hold label merged"
write_base; jq '.title="chore: DO NOT MERGE until QA"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "DO NOT MERGE title is a terminal no-op" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "DO NOT MERGE title merged"
for malformed in truncated labels-not-array label-name-not-string title-not-string; do
  write_base
  case "$malformed" in
    truncated) printf '{"state":"OPEN","isDraft":false,"title":"change","labels":[' >"$META_FILE" ;;
    labels-not-array) jq '.labels="hold"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
    label-name-not-string) jq '.labels=[{"name":{"value":"hold"}}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
    title-not-string) jq '.title=42' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
  esac
  expect_fail "$malformed hold metadata fails closed" run_promote
  ! grep -q 'pr merge' "$CALLS" || fail "$malformed hold metadata merged"
done
for unreadable in empty null; do
  write_base
  case "$unreadable" in
    empty) : >"$META_FILE" ;;
    null) printf 'null\n' >"$META_FILE" ;;
  esac
  expect_pass "$unreadable PR metadata is a terminal no-op" run_promote
  ! grep -q 'pr merge' "$CALLS" || fail "$unreadable PR metadata merged"
done
write_base; jq '.check_runs[0].conclusion=null | .check_runs[0].status="in_progress"' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; expect_pass "pending required CI exits immediately" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "pending CI merged"
write_base; jq '.check_runs[0].conclusion="failure"' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; expect_fail "terminal required CI failure blocks" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "failed CI merged"
write_base; jq '.check_runs=[]' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; printf '{"workflow_runs":[]}\n' >"$WORKFLOW_RUNS_FILE"; expect_pass "not-yet-started required CI remains pending without mutation" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "not-yet-started CI merged"
write_base; jq '.check_runs=[]' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; expect_fail "completed workflow without the reviewed check is a permanent rename/misconfiguration" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "renamed CI merged"
write_base; jq '.check_runs=[]' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; jq '.workflow_runs[0].status="in_progress" | .workflow_runs[0].conclusion=null' "$WORKFLOW_RUNS_FILE" >"$tmp/x" && mv "$tmp/x" "$WORKFLOW_RUNS_FILE"; expect_pass "active workflow with an unreported check remains pending" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "pending workflow merged"
write_base; export WORKFLOW_METADATA_RC=1; expect_fail "deleted required workflow fails closed before promotion" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "deleted workflow merged"
write_base; jq '.path=".github/workflows/renamed.yml"' "$WORKFLOW_METADATA_FILE" >"$tmp/x" && mv "$tmp/x" "$WORKFLOW_METADATA_FILE"; expect_fail "renamed required workflow path fails closed before promotion" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "renamed workflow merged"
write_base; jq '.check_runs += [{id:102,name:"shell-tests",status:"in_progress",conclusion:null,details_url:"https://github.com/Verjson/example/actions/runs/7002/job/8003",app:{id:15368,slug:"github-actions"}}]' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; expect_pass "newer pending check overrides older success" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "older success bypassed newer pending"
write_base; jq '.check_runs = [{id:100,name:"shell-tests",status:"completed",conclusion:"failure",details_url:"https://github.com/Verjson/example/actions/runs/7002/job/8001",app:{id:15368,slug:"github-actions"}}, .check_runs[0]]' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; expect_pass "newer success overrides older failure" run_promote
write_base; jq '.check_runs += [(.check_runs[0] | .id=102 | .app.id=999)]' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; expect_fail "newest duplicate context from wrong App cannot forge required CI" run_promote
write_base; jq '.workflow_id=999' "$CI_RUN_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_RUN_FILE"; expect_fail "wrong workflow identity cannot satisfy required CI" run_promote
write_base; jq '.check_runs[0].check_suite.id=9999' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; expect_fail "same-App forged check cannot claim an unrelated successful workflow run" run_promote
write_base; jq '.jobs[0].check_run_url="https://api.github.com/repos/Verjson/example/check-runs/9999"' "$CI_JOBS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_JOBS_FILE"; expect_fail "same-suite forged check must be the exact job check run" run_promote
write_base; jq '.jobs += [.jobs[0]]' "$CI_JOBS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_JOBS_FILE"; expect_fail "ambiguous duplicate job association fails closed" run_promote
grep -q -- 'api --paginate repos/Verjson/example/actions/runs/7002/jobs?per_page=100' "$CALLS" \
  && pass "trusted workflow job association is read with pagination" \
  || fail "trusted workflow job association did not paginate"
write_base; jq '.check_runs[0].details_url="https://attacker.invalid/actions/runs/7002/job/8002"' "$CI_CHECKS_FILE" >"$tmp/x" && mv "$tmp/x" "$CI_CHECKS_FILE"; expect_fail "wrong details URL cannot satisfy required CI" run_promote
write_base; export WORKFLOW_BLOB_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; expect_fail "PR-modified workflow revision cannot satisfy required CI" run_promote
write_base
if (export REQUIRED_CHECK_POLICY='[{"name":"wrong-check","app_id":15368,"workflow_id":315894159,"workflow_path":".github/workflows/actions-ci.yml"}]'; run_promote) >"$tmp/out" 2>&1; then
  fail "renamed check satisfied required CI"
elif grep -q 'missing or renamed' "$tmp/out" && ! grep -q 'pr merge' "$CALLS"; then
  pass "renamed required check fails closed after its trusted workflow completes"
else
  fail "renamed check did not produce permanent-misconfiguration evidence"
fi
write_base
if (export MERGE_CONFIRMED=false; run_promote) >"$tmp/out" 2>&1; then
  fail "unconfirmed merge postcondition did not fail closed"
else
  pass "unconfirmed merge postcondition fails closed"
fi
write_base; jq '.state="MERGED"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "duplicate promotion after merge is idempotent" run_promote; ! grep -q 'pr merge' "$CALLS" || fail "merged PR repeated mutation"
write_base; jq '.headRefOid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "superseded promotion is a terminal no-op" run_promote
! grep -q 'verify-arm-receipt' "$CALLS" || fail "stale promotion verified an obsolete receipt"
! grep -q 'pr merge' "$CALLS" || fail "stale promotion attempted a merge"
write_base; GH_TOKEN= expect_fail "missing privileged credential fails before mutation" run_promote

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
