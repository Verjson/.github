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
  $0 == "      - name: Enable native auto-merge from trusted metadata" { found=1; next }
  found && $0 == "        run: |" { run=1; next }
  run { sub(/^          /, ""); print }
' "$workflow" >"$tmp/promote.sh"
[ -s "$tmp/promote.sh" ] || { echo "FAIL - promotion block missing"; exit 1; }

mkdir -p "$tmp/bin" "$tmp/run/.gate-trust/scripts/ci-gate"
cat >"$tmp/run/.gate-trust/scripts/ci-gate/verify-arm-receipt.sh" <<'SH'
#!/usr/bin/env bash
exit "${VERIFY_RC:-0}"
SH
chmod 0644 "$tmp/run/.gate-trust/scripts/ci-gate/verify-arm-receipt.sh"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "pr view "*) cat "$META_FILE" ;;
  *"repos/$TARGET_REPO --jq"*) printf '%s\n' main ;;
  *"repos/Verjson/.github/commits/main"*) printf '%s\n' "$EXECUTING_WORKFLOW_SHA" ;;
  *"check-runs/$AUTHORIZATION_CHECK_ID"*) cat "$CHECK_FILE" ;;
  *"pulls/$PR_NUMBER/reviews?per_page=100"*) cat "$REVIEWS_FILE" ;;
  "api graphql "*) cat "$GRAPHQL_FILE" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" META_FILE="$tmp/meta.json" CHECK_FILE="$tmp/check.json" GRAPHQL_FILE="$tmp/graphql.json" REVIEWS_FILE="$tmp/reviews.json"
export TARGET_REPO=Verjson/example PR_NUMBER=7 AUTHORIZATION_CHECK_ID=9001
export EXPECTED_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export ARM_RUN_ID=7001 ARM_RUN_ATTEMPT=2 EXPECTED_APP_ID=4242 EXPECTED_APP_SLUG=verjson-ai-review
export GH_TOKEN=admin-token GITHUB_REPOSITORY_OWNER=Verjson GITHUB_REF=refs/heads/main CALLER_REF=refs/heads/main
export EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github EXECUTING_WORKFLOW_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

write_base() {
  : >"$CALLS"
  unset VERIFY_RC
  jq -nc --arg head "$EXPECTED_HEAD_SHA" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null,reviewDecision:"APPROVED"}' >"$META_FILE"
  jq -nc --arg head "$EXPECTED_HEAD_SHA" --argjson app "$EXPECTED_APP_ID" --arg slug "$EXPECTED_APP_SLUG" \
    '{id:9001,name:"AI review authorization",head_sha:$head,status:"completed",conclusion:"success",app:{id:$app,slug:$slug}}' >"$CHECK_FILE"
  jq -nc --arg head "$EXPECTED_HEAD_SHA" --arg login "${EXPECTED_APP_SLUG}[bot]" --arg check "$AUTHORIZATION_CHECK_ID" \
    '[{id:81,state:"APPROVED",commit_id:$head,user:{login:$login},body:("<!-- ai-review-authorization:"+$check+" -->")}]' >"$REVIEWS_FILE"
  jq -nc --arg head "$EXPECTED_HEAD_SHA" '{data:{enablePullRequestAutoMerge:{pullRequest:{headRefOid:$head,autoMergeRequest:{enabledAt:"2026-08-08T12:00:00Z"}}}}}' >"$GRAPHQL_FILE"
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
grep -q 'enablePullRequestAutoMerge' "$CALLS" && ! grep -qE 'statusCheckRollup|commits/.*/(status|check-runs)' "$CALLS" \
  && pass "promotion delegates CI waiting without reading the CI rollup" || fail "promotion still waits on ordinary CI"
write_base; printf '{"data":null,"errors":[{"message":"denied"}]}\n' >"$GRAPHQL_FILE"; expect_fail "GraphQL errors in an HTTP-200 payload fail closed" run_promote
write_base; jq '.conclusion="failure"' "$CHECK_FILE" >"$tmp/x" && mv "$tmp/x" "$CHECK_FILE"; expect_fail "failed authorization never enables auto-merge" run_promote
write_base; jq '.conclusion=null' "$CHECK_FILE" >"$tmp/x" && mv "$tmp/x" "$CHECK_FILE"; expect_fail "inconclusive authorization never enables auto-merge" run_promote
write_base; printf '[]\n' >"$REVIEWS_FILE"; expect_fail "missing exact App approval never enables auto-merge" run_promote
write_base; jq '.[0].user.login="attacker[bot]"' "$REVIEWS_FILE" >"$tmp/x" && mv "$tmp/x" "$REVIEWS_FILE"; expect_fail "wrong approval identity never enables auto-merge" run_promote
write_base; jq '.[0].commit_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$REVIEWS_FILE" >"$tmp/x" && mv "$tmp/x" "$REVIEWS_FILE"; expect_fail "stale App approval never enables auto-merge" run_promote
write_base; jq '.reviewDecision="REVIEW_REQUIRED"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_fail "missing dedicated App approval never enables auto-merge" run_promote
! grep -q enablePullRequestAutoMerge "$CALLS" || fail "REVIEW_REQUIRED state enabled auto-merge"
write_base; jq '.headRepositoryOwner.login="outsider"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_fail "fork PR fails closed" run_promote
write_base; jq '.isDraft=true' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "draft PR is a terminal no-op" run_promote; ! grep -q enablePullRequestAutoMerge "$CALLS" || fail "draft enabled auto-merge"
write_base; jq '.labels=[{"name":"hold"}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "held PR is a terminal no-op" run_promote; ! grep -q enablePullRequestAutoMerge "$CALLS" || fail "hold enabled auto-merge"
write_base; jq '.autoMergeRequest={"enabledAt":"2026-08-08T11:00:00Z"}' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"; expect_pass "duplicate promotion is idempotent" run_promote; ! grep -q enablePullRequestAutoMerge "$CALLS" || fail "duplicate promotion repeated mutation"
write_base; GH_TOKEN= expect_fail "missing privileged credential fails before mutation" run_promote

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
