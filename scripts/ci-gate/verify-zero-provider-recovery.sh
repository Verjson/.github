#!/usr/bin/env bash
# Permit an explicit re-review workflow rerun only when every earlier attempt
# stopped before the paid provider boundary and the immutable arm receipt still
# binds the exact check, head, policy, and App identity.
set -euo pipefail

for value in TARGET_REPO PR_NUMBER EXPECTED_HEAD_SHA AUTHORIZATION_CHECK_ID ARM_RUN_ID ARM_RUN_ATTEMPT EXPECTED_APP_ID EXPECTED_APP_SLUG REVIEW_POLICY REVIEW_RUN_ID REVIEW_RUN_ATTEMPT DEFAULT_BRANCH; do
  [ -n "${!value:-}" ] || { echo "::error::missing zero-provider recovery identity: $value"; exit 1; }
done
[[ "$TARGET_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || exit 1
[[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$EXPECTED_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
[[ "$AUTHORIZATION_CHECK_ID" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$ARM_RUN_ID" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$ARM_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$EXPECTED_APP_ID" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$EXPECTED_APP_SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]] || exit 1
[[ "$REVIEW_POLICY" =~ ^[A-Za-z0-9_-]{1,2048}$ ]] || exit 1
[[ "$REVIEW_RUN_ID" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$REVIEW_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$DEFAULT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] &&
  [[ "$DEFAULT_BRANCH" != /* && "$DEFAULT_BRANCH" != *..* && "$DEFAULT_BRANCH" != *//* ]] || exit 1
for tool in gh jq; do command -v "$tool" >/dev/null || exit 1; done

receipt_verifier="${ZERO_PROVIDER_RECEIPT_VERIFIER:-$(dirname "$0")/verify-arm-receipt.sh}"
[ -f "$receipt_verifier" ] || { echo "::error::zero-provider receipt verifier is unavailable"; exit 1; }
GH_TOKEN="${GH_TOKEN:-}" bash "$receipt_verifier" || {
  echo "::error::zero-provider recovery receipt identity mismatch"
  exit 1
}

tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ai-zero-provider-recovery.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
api() {
  local phase="$1" output="$2"
  shift 2
  if ! gh api "$@" >"$output" 2>"$tmp/$phase.stderr"; then
    echo "::error::$phase lookup failed"
    return 1
  fi
}

api review-run "$tmp/review-run.json" "repos/$TARGET_REPO/actions/runs/$REVIEW_RUN_ID"
expected_title="AI review authorization $AUTHORIZATION_CHECK_ID from arm $ARM_RUN_ID.$ARM_RUN_ATTEMPT"
jq -e --argjson run "$REVIEW_RUN_ID" --argjson attempt "$REVIEW_RUN_ATTEMPT" \
  --arg title "$expected_title" --arg branch "$DEFAULT_BRANCH" --arg repo "$TARGET_REPO" '
    .id == $run and .run_attempt == $attempt and .event == "workflow_dispatch" and
    .path == ".github/workflows/ai-review-merge.yml" and .display_title == $title and
    .head_branch == $branch and .head_repository.full_name == $repo and
    .repository.full_name == $repo and .status == "in_progress"
  ' "$tmp/review-run.json" >/dev/null || {
    echo "::error::zero-provider recovery run identity mismatch"
    exit 1
  }

api current-head "$tmp/pr.json" "repos/$TARGET_REPO/pulls/$PR_NUMBER"
jq -e --arg head "$EXPECTED_HEAD_SHA" '
  .state == "open" and .head.sha == $head
  ' "$tmp/pr.json" >/dev/null || {
    echo "::error::zero-provider recovery head is stale"
    exit 1
  }

api authorization-check "$tmp/check.json" "repos/$TARGET_REPO/check-runs/$AUTHORIZATION_CHECK_ID"
jq -e --argjson id "$AUTHORIZATION_CHECK_ID" --arg head "$EXPECTED_HEAD_SHA" \
  --argjson app "$EXPECTED_APP_ID" --arg slug "$EXPECTED_APP_SLUG" '
    .id == $id and .name == "AI review authorization" and .head_sha == $head and
    .app.id == $app and .app.slug == $slug
  ' "$tmp/check.json" >/dev/null || {
    echo "::error::zero-provider recovery check or App identity mismatch"
    exit 1
  }

if [ "$REVIEW_RUN_ATTEMPT" -eq 1 ]; then
  jq -e '.status == "in_progress" and .conclusion == null' "$tmp/check.json" >/dev/null || {
    echo "::error::initial direct review cannot replay a retained authorization"
    exit 1
  }
  jq -e '
    .actor.login == "github-actions[bot]" and
    .triggering_actor.login == "github-actions[bot]"
    ' "$tmp/review-run.json" >/dev/null || {
      echo "::error::initial direct review dispatch is not trusted-arm owned"
      exit 1
    }
  api correlated-runs "$tmp/correlated-runs.json" --paginate --slurp \
    "repos/$TARGET_REPO/actions/workflows/ai-review-merge.yml/runs?event=workflow_dispatch&per_page=100"
  jq -e --argjson run "$REVIEW_RUN_ID" --arg title "$expected_title" \
    --arg branch "$DEFAULT_BRANCH" --arg repo "$TARGET_REPO" '
      [.[].workflow_runs[] | select(
        .display_title == $title and .event == "workflow_dispatch" and
        .path == ".github/workflows/ai-review-merge.yml" and .head_branch == $branch and
        .head_repository.full_name == $repo and .repository.full_name == $repo
      )] as $matching |
      ($matching | length) == 1 and $matching[0].id == $run and
      $matching[0].run_attempt == 1
    ' "$tmp/correlated-runs.json" >/dev/null || {
      echo "::error::initial direct review dispatch is missing or not unique"
      exit 1
    }
  echo "Initial trusted-arm review dispatch verified for run $REVIEW_RUN_ID."
  exit 0
fi

jq -e '.status == "completed" and .conclusion == "failure"' "$tmp/check.json" >/dev/null || {
  echo "::error::zero-provider recovery authorization is not the failed prior attempt"
  exit 1
}

api prior-jobs "$tmp/prior-jobs.json" --paginate --slurp \
  "repos/$TARGET_REPO/actions/runs/$REVIEW_RUN_ID/jobs?filter=all&per_page=100"
jq -e --argjson attempt "$REVIEW_RUN_ATTEMPT" '
  [.[].jobs[] | select(.run_attempt < $attempt)] as $prior |
  ($attempt > 1) and
  ([range(1; $attempt)] | all(.[]; . as $n |
    ([$prior[] | select(.run_attempt == $n and .name == "preflight")] | length) == 1 and
    ([$prior[] | select(.run_attempt == $n and .name == "gate")] | length) == 1 and
    ([$prior[] | select(.run_attempt == $n and .name == "complete-authorization")] | length) == 1 and
    ([$prior[] | select(.run_attempt == $n and .name == "dispatch-merge")] | length) == 1 and
    all($prior[] | select(.run_attempt == $n and .name == "preflight");
      .status == "completed" and (.conclusion == "success" or .conclusion == "failure" or .conclusion == "skipped")) and
    all($prior[] | select(.run_attempt == $n and .name == "gate");
      .status == "completed" and .conclusion == "skipped" and (.steps | length) == 0) and
    all($prior[] | select(.run_attempt == $n and .name == "complete-authorization");
      .status == "completed" and .conclusion == "failure") and
    all($prior[] | select(.run_attempt == $n and .name == "dispatch-merge");
      .status == "completed" and .conclusion == "skipped" and (.steps | length) == 0)
  ))
  ' "$tmp/prior-jobs.json" >/dev/null || {
    echo "::error::prior review attempt reached or ambiguously approached the provider boundary"
    exit 1
  }

api prior-reviews "$tmp/reviews.json" --paginate --slurp \
  "repos/$TARGET_REPO/pulls/$PR_NUMBER/reviews?per_page=100"
jq -e --arg head "$EXPECTED_HEAD_SHA" --arg login "${EXPECTED_APP_SLUG}[bot]" \
  --arg check "$AUTHORIZATION_CHECK_ID" '
    all(.[][];
      ((.commit_id // "") != $head) or
      (((.user.login // "") != $login) and
       ((.body // "") | contains("check:" + $check + " head:" + $head) | not)))
  ' "$tmp/reviews.json" >/dev/null || {
    echo "::error::provider reservation, submission, or review evidence exists for this exact head"
    exit 1
  }

echo "Zero-provider recovery verified for review run $REVIEW_RUN_ID attempt $REVIEW_RUN_ATTEMPT."
