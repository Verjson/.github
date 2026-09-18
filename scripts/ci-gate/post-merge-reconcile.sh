#!/usr/bin/env bash
set -euo pipefail
declare -A seen=()
while IFS= read -r item; do
  location="$(jq -r .location <<<"$item")"
  note="$(jq -r .note <<<"$item")"
  hash="$(printf '%s' "$location"$'\n'"$note" | sha256sum | cut -c1-12)"
  [ -z "${seen[$hash]+x}" ] || continue
  seen[$hash]=1
  marker="<!-- ai-review-followup:pr${PR_NUMBER}:${hash} -->"
  existing="$(gh issue list --repo "$TARGET_REPO" --state all --search "$marker in:body" --json number --jq 'length')"
  [ "$existing" -eq 0 ] || continue
  gh issue create --repo "$TARGET_REPO" --title "AI-review follow-up: ${location:0:70}" \
    --body "Non-blocking AI review follow-up from PR #$PR_NUMBER.

**Location:** \`$location\`

$note

$marker" >/dev/null
done < <(jq -c '.followups[]' "$ATTESTATION_FILE")
if [ "$HEAD_REPO" = "$TARGET_REPO" ] && [ -n "$HEAD_REF" ] &&
  [ "$HEAD_REF" != "$BASE_REF" ] && [ "$HEAD_REF" != "$DEFAULT_BRANCH" ]; then
  # $HEAD_REF is the contributor's branch name and reaches a PATH segment of a read and of
  # a DELETE. Encode it with @uri alone: restoring "/" would let the name re-address the
  # endpoint, which on the DELETE would target a ref this step never inspected.
  head_ref_path="$(jq -rn --arg branch "$HEAD_REF" '$branch | @uri')"
  live_sha="$(gh api "repos/$TARGET_REPO/git/ref/heads/$head_ref_path" --jq '.object.sha // ""' 2>/dev/null || true)"
  if [ "$live_sha" = "$MERGED_HEAD_SHA" ]; then
    gh api --method DELETE "repos/$TARGET_REPO/git/refs/heads/$head_ref_path" >/dev/null 2>&1 ||
      echo "::notice::merged head ref already absent or protected"
  elif [ -n "$live_sha" ]; then
    echo "::notice::merged head ref advanced or was recreated; leaving it intact"
  fi
fi
