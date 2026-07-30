#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
review_wf="$repo_root/.github/workflows/ai-review-merge.yml"
merge_wf="$repo_root/.github/workflows/ai-privileged-merge.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

! grep -q 'steps\.merge\.outcome.*steps\.submit\.outputs\.verdict' "$review_wf" \
  && pass "review job has no unreachable post-merge follow-up step" \
  || fail "review job still gates follow-ups on its disabled merge"
grep -q 'name: merge-attestation-${{ github.run_id }}' "$review_wf" \
  && grep -q 'Upload trusted merge attestation' "$review_wf" \
  && pass "review emits a run-bound merge attestation artifact" \
  || fail "review no longer emits the trusted follow-up handoff"

merge_line="$(grep -n -- '--match-head-commit "$EXPECTED_HEAD_SHA"' "$merge_wf" | cut -d: -f1)"
issue_line="$(grep -n 'gh issue create' "$merge_wf" | cut -d: -f1)"
if [[ "$merge_line" =~ ^[0-9]+$ && "$issue_line" =~ ^[0-9]+$ && "$issue_line" -gt "$merge_line" ]]; then
  pass "issue creation is reachable only after matched-head merge"
else
  fail "follow-up issue creation is not structurally post-merge"
fi
grep -q 'merge-attestation-$run_id' "$merge_wf" \
  && grep -q '.followups | type == "array" and length <= 50' "$merge_wf" \
  && pass "privileged path fetches the exact run artifact and shape-validates data" \
  || fail "follow-up metadata validation drifted"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
