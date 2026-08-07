#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
wf="$root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

preflight="$(awk '/^  preflight:/{cap=1} cap&&/^  gate:/{exit} cap{print}' "$wf")"
gate="$(awk '/^  gate:/{cap=1} cap&&/^  dispatch-merge:/{exit} cap{print}' "$wf")"
dispatch="$(awk '/^  dispatch-merge:/{cap=1} cap{print}' "$wf")"

grep -q '^      actions: read$' <<<"$gate" \
  && grep -q '^      checks: read$' <<<"$gate" \
  && grep -q '^      statuses: read$' <<<"$gate" \
  && ! grep -q '^      actions: write$' <<<"$gate" \
  && ! grep -q '^      checks: write$' <<<"$gate" \
  && ! grep -q '^      statuses: write$' <<<"$gate" \
  && pass "PR checkout/review gate has actions/checks/statuses read only" \
  || fail "PR checkout/review gate permission placement drifted"
[ "$(grep -c '^      checks: read$' "$wf")" -eq 1 ] \
  && [ "$(grep -c '^      statuses: read$' "$wf")" -eq 2 ] \
  && grep -q '^      statuses: read$' <<<"$preflight" \
  && ! grep -qE '^      checks: (read|write)$' <<<"$preflight" \
  && ! grep -q '^      statuses: write$' <<<"$preflight" \
  && ! grep -qE '^      checks: (read|write)$' <<<"$dispatch" \
  && ! grep -qE '^      statuses: (read|write)$' <<<"$dispatch" \
  && pass "status reads are limited to classification/review; check reads stay in review" \
  || fail "checks/statuses permission escaped the classification/review boundary"
[ "$(grep -c '^      actions: write$' "$wf")" -eq 1 ] \
  && grep -q '^      contents: read$' <<<"$dispatch" \
  && grep -q '^      pull-requests: read$' <<<"$dispatch" \
  && pass "dispatch has minimum contents/read + actions/write + PR/read" \
  || fail "dispatch permissions are duplicated or over-broad"
grep -qF 'runs-on: ${{ inputs.runner_labels && fromJSON(inputs.runner_labels) ||' <<<"$dispatch" \
  && grep -qF 'GH_TOKEN: ${{ github.token }}' <<<"$dispatch" \
  && ! grep -q 'secrets\.' <<<"$dispatch" \
  && pass "caller-selected dispatch runner receives only the scoped workflow token" \
  || fail "dispatch routing or token binding exposes authority beyond the caller-selected runner"
timeout_minutes="$(sed -n 's/^    timeout-minutes: //p' <<<"$dispatch" | head -n 1)"
probe_attempts="$(sed -n 's/^      MERGE_PROBE_ATTEMPTS: //p' <<<"$dispatch")"
probe_interval="$(sed -n 's/^      MERGE_PROBE_INTERVAL_SECONDS: //p' <<<"$dispatch")"
privileged_timeout="$(sed -n 's/^      PRIVILEGED_MERGE_TIMEOUT_MINUTES: //p' <<<"$dispatch")"
queue_margin="$(sed -n 's/^      MERGE_QUEUE_MARGIN_MINUTES: //p' <<<"$dispatch")"
api_margin="$(sed -n 's/^      MERGE_API_MARGIN_MINUTES: //p' <<<"$dispatch")"
if [[ "$timeout_minutes" =~ ^[1-9][0-9]*$ ]] \
  && [[ "$probe_attempts" =~ ^[1-9][0-9]*$ ]] \
  && [[ "$probe_interval" =~ ^[1-9][0-9]*$ ]] \
  && [[ "$privileged_timeout" =~ ^[1-9][0-9]*$ ]] \
  && [[ "$queue_margin" =~ ^[1-9][0-9]*$ ]] \
  && [[ "$api_margin" =~ ^[1-9][0-9]*$ ]] \
  && [ "$(((probe_attempts - 1) * probe_interval))" -ge "$(((privileged_timeout + queue_margin + api_margin) * 60))" ] \
  && [ "$((probe_attempts * probe_interval + 60))" -le "$((timeout_minutes * 60))" ]; then
  pass "probe covers privileged timeout plus queue/API margins with job headroom"
else
  fail "merge probe budget can expire before the privileged timeout/margins or consume the job"
fi
grep -q 'name: Publish typed merge remediation' <<<"$dispatch" \
  && grep -q 'GITHUB_STEP_SUMMARY' <<<"$dispatch" \
  && grep -q 'true|false|unknown' <<<"$dispatch" \
  && pass "dispatch outputs have a tri-state-validated summary consumer" \
  || fail "dispatch outputs remain inert or their tri-state contract is unenforced"
if grep -qE 'uses:|actions/(checkout|cache|upload-artifact|download-artifact)|\beval\b|^[[:space:]]*(source|\.)[[:space:]]|github\.event\.pull_request\.(title|body)' <<<"$dispatch"; then
  fail "dispatch job can consume/execute PR-controlled content"
else
  pass "dispatch job has no checkout, artifact/cache, eval/source, or PR prose"
fi
grep -q 'needs: \[preflight, gate\]' <<<"$dispatch" \
  && grep -q "if: needs.gate.result == 'success'" <<<"$dispatch" \
  && pass "dispatch requires successful gate and preflight identity" \
  || fail "dispatch dependency/condition drifted"

script="$tmp/dispatch.sh"
awk '
  $0 == "      - name: Dispatch fixed trusted merge continuation" { seen=1 }
  seen && $0 == "        run: |" { cap=1; next }
  cap {
    if (substr($0,1,10) == "          ") { print substr($0,11); next }
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    exit
  }
' "$wf" >"$script"
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = api ]; then
  [ "$2" = --paginate ] &&
    [ "$3" = repos/Verjson/example/actions/workflows ] &&
    [ "$4" = --jq ] &&
    [ "$5" = '.workflows[] | select(.path == ".github/workflows/ai-privileged-merge.yml") | .path' ] ||
    exit 2
  [ "${API_FAILURE:-false}" = false ] || exit 1
  printf '%s' "${WORKFLOW_PATH-.github/workflows/ai-privileged-merge.yml}"
  [ -z "${WORKFLOW_PATH-.github/workflows/ai-privileged-merge.yml}" ] || printf '\n'
  exit 0
fi
if [ "$1 $2" = "workflow run" ]; then printf '%s\n' "$*" >>"$DISPATCH_LOG"; exit 0; fi
if [ "$1 $2" = "pr view" ]; then
  count=$(cat "$PR_VIEW_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" >"$PR_VIEW_COUNT"
  if [ "$count" -le "${PR_VIEW_FAILURES:-0}" ]; then
    echo "HTTP 403: Resource not accessible by integration" >&2
    exit 1
  fi
  printf '%s\n' "$PR_STATE_JSON"
  exit 0
fi
exit 2
EOF
chmod +x "$tmp/bin/gh"
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/sleep"

run_case() {
  local pr_state_json="${7-}"
  if [ -z "$pr_state_json" ]; then
    pr_state_json='{"state":"MERGED","mergedAt":"2026-08-07T12:00:00Z","reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN","headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
  fi
  : >"$tmp/dispatch.log"
  : >"$tmp/dispatch.out"
  : >"$tmp/github-output.txt"
  printf '0\n' >"$tmp/pr-view-count"
  PATH="$tmp/bin:$PATH" DISPATCH_LOG="$tmp/dispatch.log" GH_TOKEN=token \
    GITHUB_OUTPUT="$tmp/github-output.txt" PR_VIEW_COUNT="$tmp/pr-view-count" \
    GITHUB_REPOSITORY=Verjson/example TARGET_REPO="${1-Verjson/example}" \
    PR_NUMBER="${2-7}" EXPECTED_HEAD_SHA="${3-0123456789abcdef0123456789abcdef01234567}" \
    SOURCE_RUN_ID="${4-99}" WORKFLOW_PATH="${5-.github/workflows/ai-privileged-merge.yml}" \
    API_FAILURE="${6-false}" \
    MERGE_PROBE_ATTEMPTS="$probe_attempts" MERGE_PROBE_INTERVAL_SECONDS="$probe_interval" \
    PR_STATE_JSON="$pr_state_json" \
    PR_VIEW_FAILURES="${8-0}" bash "$script" >"$tmp/dispatch.out" 2>&1
}
run_case && grep -q 'workflow run ai-privileged-merge.yml' "$tmp/dispatch.log" \
  && pass "validated identities dispatch only the fixed workflow" \
  || fail "valid trusted dispatch failed"
run_case 'Verjson/example' 7 0123456789abcdef0123456789abcdef01234567 99 '' \
  && [ ! -s "$tmp/dispatch.log" ] \
  && grep -q 'requires human merge' "$tmp/dispatch.out" \
  && pass "absent privileged continuation is a green manual-merge no-op" \
  || fail "absent privileged continuation did not preserve green validation"
run_case 'Verjson/example' 7 0123456789abcdef0123456789abcdef01234567 99 '' true \
  && fail "workflow-list API failure did not fail closed" \
  || pass "workflow-list API failure remains terminal"
for bad in repo pr head run workflow; do
  case "$bad" in
    repo) args=('Other/example') ;;
    pr) args=('Verjson/example' '7;echo forged') ;;
    head) args=('Verjson/example' 7 'main') ;;
    run) args=('Verjson/example' 7 0123456789abcdef0123456789abcdef01234567 '9;bad') ;;
    workflow) args=('Verjson/example' 7 0123456789abcdef0123456789abcdef01234567 99 '.github/workflows/other.yml') ;;
  esac
  run_case "${args[@]}" \
    && fail "forged $bad input dispatched" \
    || pass "forged $bad input fails closed"
done

# #384: dispatch acceptance is the merge postcondition, not the HTTP success of
# workflow_dispatch. A clean but still-open PR must fail with a typed outcome.
open_clean='{"state":"OPEN","mergedAt":null,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false "$open_clean" \
  && fail "successful dispatch without a merge reported green" \
  || {
    grep -q 'blocker=merge_not_observed' "$tmp/dispatch.out" \
      && grep -q '^merge_observed=false$' "$tmp/github-output.txt" \
      && pass "dispatch success without an observed merge fails with typed state" \
      || fail "unmerged dispatch failure lacks typed postcondition evidence"
  }

# The two deterministic remediation classes stay distinct.
stale_review='{"state":"OPEN","mergedAt":null,"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"BLOCKED","headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false "$stale_review" \
  && fail "stale blocking review reported green" \
  || {
    grep -q 'blocker=review' "$tmp/dispatch.out" \
      && grep -q '^blocking_review=true$' "$tmp/github-output.txt" \
      && grep -q '^policy_blocked=false$' "$tmp/github-output.txt" \
      && pass "stale review block is typed for review remediation" \
      || fail "stale review block was not typed deterministically"
  }

required_review='{"state":"OPEN","mergedAt":null,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false "$required_review" \
  && fail "required-review block reported green" \
  || {
    grep -q 'blocker=review' "$tmp/dispatch.out" \
      && grep -q '^blocking_review=true$' "$tmp/github-output.txt" \
      && pass "required-review state is typed as review remediation" \
      || fail "required-review state was not typed deterministically"
  }

policy_block='{"state":"OPEN","mergedAt":null,"reviewDecision":"APPROVED","mergeStateStatus":"BLOCKED","headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false "$policy_block" \
  && fail "policy-blocked merge reported green" \
  || {
    [ "$(cat "$tmp/pr-view-count")" -eq "$probe_attempts" ] \
      && grep -q 'blocker=policy' "$tmp/dispatch.out" \
      && grep -q '^blocking_review=false$' "$tmp/github-output.txt" \
      && grep -q '^policy_blocked=true$' "$tmp/github-output.txt" \
      && pass "policy is classified only after the complete observation budget" \
      || fail "interim BLOCKED state was classified before terminal evidence"
  }

# UNKNOWN is also an interim queue state. It may time out as not observed, but
# must never be mislabeled as a branch-policy failure.
unknown_state='{"state":"OPEN","mergedAt":null,"reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN","headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false "$unknown_state" \
  && fail "unknown unmerged state reported green" \
  || {
    [ "$(cat "$tmp/pr-view-count")" -eq "$probe_attempts" ] \
      && grep -q 'blocker=merge_not_observed' "$tmp/dispatch.out" \
      && grep -q '^policy_blocked=false$' "$tmp/github-output.txt" \
      && pass "UNKNOWN remains non-policy through the complete observation budget" \
      || fail "UNKNOWN was classified as policy or exited before the observation budget"
  }
# A terminal CLOSED state cannot become merged and must stop after one read
# with a distinct remediation instead of burning the full probe budget.
closed_unmerged='{"state":"CLOSED","mergedAt":null,"reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN","headRefOid":"0123456789abcdef0123456789abcdef01234567"}'
run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false "$closed_unmerged" \
  && fail "closed-unmerged pull request reported green" \
  || {
    [ "$(cat "$tmp/pr-view-count")" -eq 1 ] \
      && grep -q 'blocker=closed_not_merged' "$tmp/dispatch.out" \
      && grep -q '^remediation=inspect_closed_pr$' "$tmp/github-output.txt" \
      && pass "closed-unmerged state exits early with typed remediation" \
      || fail "closed-unmerged state retried or lacked typed remediation"
  }

# A real merge is the sole acted-success state.
run_case \
  && grep -q '^merge_observed=true$' "$tmp/github-output.txt" \
  && grep -q 'result=merged' "$tmp/dispatch.out" \
  && pass "observed merged state satisfies the postcondition" \
  || fail "actual merged state did not satisfy the postcondition"

# A merge (or open state) for a different head cannot satisfy this run.
changed_head='{"state":"MERGED","mergedAt":"2026-08-07T12:00:00Z","reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN","headRefOid":"1123456789abcdef0123456789abcdef01234567"}'
run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false "$changed_head" \
  && fail "a different head satisfied the merge postcondition" \
  || {
    grep -q 'blocker=head_changed' "$tmp/dispatch.out" \
      && grep -q '^remediation=rerun_gate_for_current_head$' "$tmp/github-output.txt" \
      && pass "different-head state fails with deterministic rerun remediation" \
      || fail "different-head state lacks typed remediation"
  }

# Transient reads are retried, but exhausting the bounded probe remains red and
# explicitly says the state could not be determined.
run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false \
  '{"state":"MERGED","mergedAt":"2026-08-07T12:00:00Z","reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN","headRefOid":"0123456789abcdef0123456789abcdef01234567"}' 2 \
  && [ "$(cat "$tmp/pr-view-count")" -eq 3 ] \
  && pass "transient postcondition reads recover within the bounded retry" \
  || fail "transient postcondition reads did not recover"

run_case Verjson/example 7 0123456789abcdef0123456789abcdef01234567 99 .github/workflows/ai-privileged-merge.yml false "$open_clean" "$probe_attempts" \
  && fail "unreadable merge postcondition reported green" \
  || {
    grep -q 'blocker=state_unavailable' "$tmp/dispatch.out" \
      && [ -s "$tmp/github-output.txt" ] \
      && grep -q '^merge_observed=false$' "$tmp/github-output.txt" \
      && pass "exhausted postcondition reads fail closed with typed evidence" \
      || fail "unreadable postcondition lacks typed failure evidence"
  }

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
