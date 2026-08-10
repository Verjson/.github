#!/usr/bin/env bash
# Verify that a dedicated-App check is named by immutable evidence from the
# exact trusted gate-arm run. All identity inputs arrive through the environment.
set -euo pipefail

for value in TARGET_REPO PR_NUMBER EXPECTED_HEAD_SHA AUTHORIZATION_CHECK_ID ARM_RUN_ID ARM_RUN_ATTEMPT EXPECTED_APP_ID EXPECTED_APP_SLUG REVIEW_POLICY; do
  [ -n "${!value:-}" ] || { echo "::error::missing arm receipt identity: $value"; exit 1; }
done
[[ "$TARGET_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || exit 1
[[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$EXPECTED_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
[[ "$AUTHORIZATION_CHECK_ID" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$ARM_RUN_ID" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$ARM_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$EXPECTED_APP_ID" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$EXPECTED_APP_SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]] || exit 1
for tool in gh jq unzip sha256sum; do command -v "$tool" >/dev/null || exit 1; done
review_policy_json="$(python3 "$(dirname "$0")/review-policy-envelope.py" decode "$REVIEW_POLICY")" || exit 1
review_actor="$(jq -r .actor <<<"$review_policy_json")"
receipt_permission="$(jq -r .actor_permission <<<"$review_policy_json")"
if [ "$receipt_permission" != automation ] && [ "${REVERIFY_ACTOR_PERMISSION:-true}" != false ]; then
  [[ "$review_actor" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || exit 1
  case "$receipt_permission" in admin|maintain) ;; *) exit 1 ;; esac
  current_permission="$(gh api "repos/$TARGET_REPO/collaborators/$review_actor/permission" --jq '.permission // ""')" || exit 1
  case "$current_permission" in admin|maintain) ;; *) echo "::error::re-review actor no longer has maintain/admin permission"; exit 1 ;; esac
fi

arm_workflow_id="$(gh api "repos/$TARGET_REPO/actions/workflows/gate-rearm.yml" --jq '.id // ""')"
[[ "$arm_workflow_id" =~ ^[1-9][0-9]*$ ]] || exit 1
arm_run="$(gh api "repos/$TARGET_REPO/actions/runs/$ARM_RUN_ID")"
jq -e --argjson workflow_id "$arm_workflow_id" --argjson run_id "$ARM_RUN_ID" --argjson attempt "$ARM_RUN_ATTEMPT" --arg repo "$TARGET_REPO" '
  .id == $run_id and .run_attempt == $attempt and
  .workflow_id == $workflow_id and .event == "pull_request_target" and
  .path == ".github/workflows/gate-rearm.yml" and .head_repository.full_name == $repo
' <<<"$arm_run" >/dev/null || { echo "::error::arm run provenance mismatch"; exit 1; }

artifact_name="ai-review-arm-$ARM_RUN_ID-$ARM_RUN_ATTEMPT"
artifacts="$(gh api "repos/$TARGET_REPO/actions/runs/$ARM_RUN_ID/artifacts?per_page=100")"
artifact="$(jq -c --arg name "$artifact_name" '
  [.artifacts[] | select(.name == $name and .expired == false)]
  | if length == 1 then .[0] else error("receipt artifact missing or ambiguous") end
' <<<"$artifacts")" || { echo "::error::arm receipt artifact missing or ambiguous"; exit 1; }
artifact_id="$(jq -r '.id // ""' <<<"$artifact")"
artifact_size="$(jq -r '.size_in_bytes // ""' <<<"$artifact")"
artifact_digest="$(jq -r '.digest // ""' <<<"$artifact")"
[[ "$artifact_id" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$artifact_size" =~ ^[1-9][0-9]*$ ]] && [ "$artifact_size" -le 16384 ] || exit 1
[[ "$artifact_digest" =~ ^sha256:([0-9a-f]{64})$ ]] || exit 1
expected_zip_sha="${BASH_REMATCH[1]}"

tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ai-review-receipt.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
gh api "repos/$TARGET_REPO/actions/artifacts/$artifact_id/zip" >"$tmp/receipt.zip"
actual_zip_sha="$(sha256sum "$tmp/receipt.zip" | awk '{print $1}')"
[ "$actual_zip_sha" = "$expected_zip_sha" ] || { echo "::error::arm receipt artifact digest mismatch"; exit 1; }
[ "$(unzip -Z1 "$tmp/receipt.zip")" = receipt.json ] || { echo "::error::arm receipt archive shape is invalid"; exit 1; }
unzip -p "$tmp/receipt.zip" receipt.json >"$tmp/receipt.json"
[ "$(wc -c <"$tmp/receipt.json")" -le 8192 ] || exit 1

check="$(gh api "repos/$TARGET_REPO/check-runs/$AUTHORIZATION_CHECK_ID")"
details_url="$GITHUB_SERVER_URL/$TARGET_REPO/actions/runs/$ARM_RUN_ID"
jq -e \
  --arg repository "$TARGET_REPO" --argjson pr_number "$PR_NUMBER" --arg head "$EXPECTED_HEAD_SHA" \
  --argjson check_id "$AUTHORIZATION_CHECK_ID" --argjson run_id "$ARM_RUN_ID" --argjson attempt "$ARM_RUN_ATTEMPT" \
  --arg details_url "$details_url" --argjson app_id "$EXPECTED_APP_ID" --arg app_slug "$EXPECTED_APP_SLUG" \
  --arg review_policy "$REVIEW_POLICY" '
  (keys | sort) == (["app_id","app_slug","arm_run_attempt","arm_run_id","check_run_id","details_url","external_id","head_sha","nonce","pr_number","repository","review_policy","schema"] | sort) and
  .schema == 1 and .repository == $repository and .pr_number == $pr_number and .head_sha == $head and
  .check_run_id == $check_id and .arm_run_id == $run_id and .arm_run_attempt == $attempt and
  .details_url == $details_url and .app_id == $app_id and .app_slug == $app_slug and
  .review_policy == $review_policy and
  (.nonce | type == "string" and test("^[0-9a-f]{64}$")) and
  .external_id == ("ai-review:v1:" + $repository + ":" + ($pr_number|tostring) + ":" + $head + ":" +
                   ($run_id|tostring) + ":" + ($attempt|tostring) + ":" + .nonce)
' "$tmp/receipt.json" >/dev/null || { echo "::error::arm receipt content mismatch"; exit 1; }

receipt_external_id="$(jq -r .external_id "$tmp/receipt.json")"
jq -e --arg head "$EXPECTED_HEAD_SHA" --argjson check_id "$AUTHORIZATION_CHECK_ID" \
  --arg external_id "$receipt_external_id" --arg details_url "$details_url" \
  --argjson app_id "$EXPECTED_APP_ID" --arg app_slug "$EXPECTED_APP_SLUG" '
  .id == $check_id and .name == "AI review authorization" and .head_sha == $head and
  .external_id == $external_id and .details_url == $details_url and
  .app.id == $app_id and .app.slug == $app_slug
' <<<"$check" >/dev/null || { echo "::error::authorization check is not receipt-bound"; exit 1; }

current_head="$(gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" --json headRefOid,state --jq 'select(.state == "OPEN") | .headRefOid // ""')"
[ "$current_head" = "$EXPECTED_HEAD_SHA" ] || { echo "::error::authorization head is stale"; exit 1; }
echo "Arm receipt verified for check $AUTHORIZATION_CHECK_ID on $EXPECTED_HEAD_SHA."
