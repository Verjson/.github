#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
verifier="$here/verify-arm-receipt.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

export TARGET_REPO=Verjson/example PR_NUMBER=7
export EXPECTED_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export AUTHORIZATION_CHECK_ID=9001 ARM_RUN_ID=7001 ARM_RUN_ATTEMPT=2
export EXPECTED_APP_ID=4242 EXPECTED_APP_SLUG=verjson-ai-review
encode_policy() { python3 "$here/review-policy-envelope.py" encode "$1"; }
anthropic_policy='{"actor":"trusted-arm","actor_permission":"automation","budget_usd":"auto","model":"auto","pricing_version":"anthropic-native-v1","provider":"anthropic"}'
openai_policy='{"actor":"maintainer","actor_permission":"maintain","budget_usd":"1.00","model":"gpt-5.6-luna","pricing_version":"openai-luna-long-context-2026-08-08","provider":"openai"}'
export REVIEW_POLICY="$(encode_policy "$anthropic_policy")"
export GITHUB_SERVER_URL=https://github.com RUNNER_TEMP="$tmp"
nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
external_id="ai-review:v1:$TARGET_REPO:$PR_NUMBER:$EXPECTED_HEAD_SHA:$ARM_RUN_ID:$ARM_RUN_ATTEMPT:$nonce"
details_url="$GITHUB_SERVER_URL/$TARGET_REPO/actions/runs/$ARM_RUN_ID"

mkdir "$tmp/bin" "$tmp/archive"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${API_FAILURE_MATCH:-}" ] && [[ "$*" == *"$API_FAILURE_MATCH"* ]]; then
  printf 'authorization: token leaked-test-token\nx-github-request-id: TEST:719\n' >&2
  exit 1
fi
case "$*" in
  *"actions/workflows/gate-rearm.yml"*"--jq"*) printf '%s\n' 77 ;;
  *"actions/runs/$ARM_RUN_ID/artifacts"*) cat "$ARTIFACTS_FILE" ;;
  *"actions/runs/$ARM_RUN_ID"*) cat "$RUN_FILE" ;;
  *"actions/artifacts/"*"/zip"*) cat "$ZIP_FILE" ;;
  *"check-runs/$AUTHORIZATION_CHECK_ID"*) cat "$CHECK_FILE" ;;
  *"collaborators/maintainer/permission"*) printf '%s\n' "${CURRENT_PERMISSION:-maintain}" ;;
  *"pulls/$PR_NUMBER"*"--jq"*)
    [ "${CURRENT_STATE:-open}" = open ] && printf '%s\n' "${CURRENT_HEAD:-$EXPECTED_HEAD_SHA}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" RUN_FILE="$tmp/run.json" ARTIFACTS_FILE="$tmp/artifacts.json"
export CHECK_FILE="$tmp/check.json" ZIP_FILE="$tmp/receipt.zip"

write_base() {
  jq -nc --argjson id "$ARM_RUN_ID" --argjson attempt "$ARM_RUN_ATTEMPT" --arg repo "$TARGET_REPO" \
    '{id:$id,run_attempt:$attempt,workflow_id:77,event:"pull_request_target",path:".github/workflows/gate-rearm.yml",head_repository:{full_name:$repo}}' >"$RUN_FILE"
  jq -nc --argjson id "$AUTHORIZATION_CHECK_ID" --arg head "$EXPECTED_HEAD_SHA" --arg external "$external_id" \
    --arg url "$details_url" --argjson app "$EXPECTED_APP_ID" --arg slug "$EXPECTED_APP_SLUG" \
    '{id:$id,name:"AI review authorization",head_sha:$head,external_id:$external,details_url:$url,app:{id:$app,slug:$slug},status:"in_progress",conclusion:null}' >"$CHECK_FILE"
  jq -nc --arg repository "$TARGET_REPO" --argjson pr_number "$PR_NUMBER" --arg head_sha "$EXPECTED_HEAD_SHA" \
    --argjson check_run_id "$AUTHORIZATION_CHECK_ID" --argjson arm_run_id "$ARM_RUN_ID" --argjson arm_run_attempt "$ARM_RUN_ATTEMPT" \
    --arg nonce "$nonce" --arg external_id "$external_id" --arg details_url "$details_url" \
    --argjson app_id "$EXPECTED_APP_ID" --arg app_slug "$EXPECTED_APP_SLUG" \
    --arg review_policy "$REVIEW_POLICY" \
    '{schema:1,repository:$repository,pr_number:$pr_number,head_sha:$head_sha,check_run_id:$check_run_id,
      arm_run_id:$arm_run_id,arm_run_attempt:$arm_run_attempt,nonce:$nonce,external_id:$external_id,
      details_url:$details_url,app_id:$app_id,app_slug:$app_slug,review_policy:$review_policy}' >"$tmp/archive/receipt.json"
  rm -f "$ZIP_FILE"
  (cd "$tmp/archive" && python3 -m zipfile -c "$ZIP_FILE" receipt.json)
  digest="$(sha256sum "$ZIP_FILE" | awk '{print $1}')"
  size="$(wc -c <"$ZIP_FILE")"
  jq -nc --argjson size "$size" --arg digest "sha256:$digest" \
    '{artifacts:[{id:8001,name:"ai-review-arm-7001-2",expired:false,size_in_bytes:$size,digest:$digest}]}' >"$ARTIFACTS_FILE"
  unset CURRENT_HEAD
}

expect_pass() { label="$1"; shift; if "$@" >"$tmp/out" 2>&1; then pass "$label"; else fail "$label: $(tail -1 "$tmp/out")"; fi; }
expect_fail() { label="$1"; shift; if "$@" >"$tmp/out" 2>&1; then fail "$label"; else pass "$label"; fi; }
verify() { bash "$verifier"; }
repack() {
  rm -f "$ZIP_FILE"
  (cd "$tmp/archive" && python3 -m zipfile -c "$ZIP_FILE" receipt.json)
  digest="$(sha256sum "$ZIP_FILE" | awk '{print $1}')"; size="$(wc -c <"$ZIP_FILE")"
  jq -nc --argjson size "$size" --arg digest "sha256:$digest" \
    '{artifacts:[{id:8001,name:"ai-review-arm-7001-2",expired:false,size_in_bytes:$size,digest:$digest}]}' >"$ARTIFACTS_FILE"
}

write_base; expect_pass "exact dedicated-App check and immutable receipt are accepted" verify
write_base; REVIEW_POLICY="$(encode_policy "$openai_policy")" expect_fail "a provider change after authorization is rejected" verify
REVIEW_POLICY="$(encode_policy "$openai_policy")"; write_base; expect_pass "maintainer re-review evidence is reauthorized" verify
write_base; CURRENT_PERMISSION=triage REVERIFY_ACTOR_PERMISSION=false expect_pass "completion trusts the immutable arm permission without repository administration access" verify
write_base; CURRENT_PERMISSION=triage expect_fail "permission revocation after authorization fails closed" verify; unset CURRENT_PERMISSION
export REVIEW_POLICY="$(encode_policy "$anthropic_policy")"
write_base; jq '.details_url="https://github.com/Verjson/example/actions/runs/9999"' "$CHECK_FILE" >"$tmp/x" && mv "$tmp/x" "$CHECK_FILE"; expect_fail "forged same-App details URL is rejected" verify
write_base; jq '.check_run_id=9002' "$tmp/archive/receipt.json" >"$tmp/x" && mv "$tmp/x" "$tmp/archive/receipt.json"; repack; expect_fail "receipt/check ID mismatch is rejected" verify
write_base; jq '.nonce="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$tmp/archive/receipt.json" >"$tmp/x" && mv "$tmp/x" "$tmp/archive/receipt.json"; repack; expect_fail "nonce/external_id mismatch is rejected" verify
write_base; CURRENT_HEAD=ffffffffffffffffffffffffffffffffffffffff expect_fail "stale PR head is rejected" verify
write_base; API_FAILURE_MATCH='actions/workflows/gate-rearm.yml' expect_fail "workflow API failures fail closed" verify
grep -q 'arm-workflow failed' "$tmp/out" \
  && grep -q 'x-github-request-id: TEST:719' "$tmp/out" \
  && grep -q 'authorization: token \*\*\*' "$tmp/out" \
  && ! grep -q 'leaked-test-token' "$tmp/out" \
  && pass "workflow API failure identifies its phase without leaking credentials" \
  || fail "workflow API failure diagnostics are unsafe or ambiguous"
write_base; jq '.run_attempt=3' "$RUN_FILE" >"$tmp/x" && mv "$tmp/x" "$RUN_FILE"; expect_fail "run-attempt replay is rejected" verify
write_base; printf '{"artifacts":[]}\n' >"$ARTIFACTS_FILE"; expect_fail "missing arm artifact is rejected" verify
write_base; rm "$tmp/archive/receipt.json" "$ZIP_FILE"; printf 'bad\n' >"$tmp/archive/other"; (cd "$tmp/archive" && python3 -m zipfile -c "$ZIP_FILE" other); digest="$(sha256sum "$ZIP_FILE"|awk '{print $1}')"; size="$(wc -c <"$ZIP_FILE")"; jq -nc --argjson size "$size" --arg digest "sha256:$digest" '{artifacts:[{id:8001,name:"ai-review-arm-7001-2",expired:false,size_in_bytes:$size,digest:$digest}]}' >"$ARTIFACTS_FILE"; expect_fail "malformed artifact archive is rejected" verify
write_base; jq '.artifacts[0].digest="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$ARTIFACTS_FILE" >"$tmp/x" && mv "$tmp/x" "$ARTIFACTS_FILE"; expect_fail "substituted artifact digest is rejected" verify
write_base; jq '.app.id=9999' "$CHECK_FILE" >"$tmp/x" && mv "$tmp/x" "$CHECK_FILE"; expect_fail "shared or wrong App identity is rejected" verify

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
