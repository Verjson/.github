#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
merge_wf="$repo_root/.github/workflows/ai-privileged-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

untrusted="$(cat "$wf")"
privileged="$(cat "$merge_wf")"

if grep -q 'secrets\.ORG_ADMIN_TOKEN' <<<"$untrusted"; then
  fail "untrusted validation/review references ORG_ADMIN_TOKEN"
else
  pass "untrusted validation/review has no ORG_ADMIN_TOKEN reference"
fi
if grep -qE 'actions/(checkout|cache|upload-artifact|download-artifact)|GITHUB_(ENV|OUTPUT)|uses:' <<<"$privileged"; then
  fail "privileged job can ingest PR-controlled code, cache, artifact, env, or output"
else
  pass "privileged job consumes trusted API metadata only"
fi
grep -q '^  pull_request_target:' <<<"$privileged" \
  && grep -q '^  workflow_dispatch:' <<<"$privileged" \
  && grep -q 'source_run_id:' <<<"$privileged" \
  && pass "privileged job accepts base-branch PR events and attested local dispatch" \
  || fail "privileged triggers lost trusted PR or attested dispatch path"
grep -q 'trusted_workflow_id=' <<<"$privileged" \
  && grep -q 'newest_trusted_gate_run' <<<"$privileged" \
  && grep -q 'sort_by(\[(.created_at // ""), .id\])' <<<"$privileged" \
  && grep -q 'contains($needle)' <<<"$privileged" \
  && pass "merge authority verifies newest immutable workflow-run provenance" \
  || fail "merge can trust a spoofable check name without run provenance"
[ "$(grep -c 'secrets\.ORG_ADMIN_TOKEN' "$merge_wf")" -eq 1 ] \
  && ! grep -q 'secrets\.ORG_ADMIN_TOKEN' "$wf" \
  && pass "ORG_ADMIN_TOKEN has exactly one workflow reference" \
  || fail "ORG_ADMIN_TOKEN escaped its single privileged environment binding"

script="$tmp/merge.sh"
awk '
  $0 == "      - name: Privileged merge from trusted metadata only" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    exit
  }
' "$merge_wf" >"$script"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/unzip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$ATTESTATION_FIXTURE"
EOF
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "pr view" ]; then
  if [[ "$*" == *"reviews,comments"* ]]; then
    printf '%s\n' "${REVIEW_FIXTURE:-{\"reviews\":[],\"comments\":[]}}"
    exit 0
  fi
  count="$(cat "$VIEW_COUNT" 2>/dev/null || echo 0)"
  count=$((count + 1))
  printf '%s\n' "$count" >"$VIEW_COUNT"
  if [ "$count" -gt 1 ] && [ -n "${PR_FIXTURE_FINAL:-}" ]; then
    printf '%s\n' "$PR_FIXTURE_FINAL"
  else
    printf '%s\n' "$PR_FIXTURE"
  fi
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/actions/workflows/ai-review-merge.yml" ]]; then
  printf '42\n'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/commits/main" ]]; then
  printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$*" == *"/pulls/7/files"* ]]; then
  [ "${FILES_API_FAIL:-false}" != true ] || exit 1
  count="$(cat "$FILES_COUNT" 2>/dev/null || echo 0)"
  count=$((count + 1))
  printf '%s\n' "$count" >"$FILES_COUNT"
  if [ "$count" -gt 1 ] && [ -n "${FILES_FIXTURE_FINAL:-}" ]; then
    printf '%s' "$FILES_FIXTURE_FINAL"
  else
    printf '%s' "${FILES_FIXTURE:-}"
  fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/Verjson/.github" ]; then
  printf '1269388380\n'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" =~ /pulls/7$ ]]; then
  printf 'main\n'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/rules/branches/"* ]]; then
  # This suite exercises the workflow_id provenance shape; no required-workflow
  # rule applies, so required-workflow trust must stay off.
  printf '[]\n'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/artifacts?per_page=100" ]]; then
  if [ "${ARTIFACTS_EMPTY:-false}" = true ]; then
    printf '{"artifacts":[]}\n'
    exit 0
  fi
  run_id="$(sed -E 's#^.*/runs/([0-9]+)/artifacts.*#\1#' <<<"$2")"
  printf '{"artifacts":[{"id":555,"name":"merge-attestation-%s","expired":false}]}\n' "$run_id"
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/actions/artifacts/555/zip" ]]; then
  printf 'zip-fixture'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" =~ /actions/runs/[0-9]+$ ]]; then
  printf '%s\n' "$DISPATCH_RUN_FIXTURE"
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/actions/runs"* ]]; then
  printf '%s\n' "$RUN_FIXTURE"
  exit 0
fi
if [ "$1 $2" = "pr merge" ]; then
  printf '%s\n' "$*" >>"$MERGE_LOG"
  exit 0
fi
if [ "$1 $2" = "issue list" ]; then
  printf '0\n'
  exit 0
fi
if [ "$1 $2" = "issue create" ]; then
  printf 'ISSUE %s\n' "$*" >>"$MERGE_LOG"
  exit 0
fi
exit 2
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep" "$tmp/bin/unzip"

sha=0123456789abcdef0123456789abcdef01234567
green='{"headRefOid":"'"$sha"'","isDraft":false,"labels":[],"state":"OPEN","files":[],"statusCheckRollup":[{"name":"gate","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/Verjson/example/actions/runs/99/job/1"},{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]}'
# `path` is the run's ENTRY workflow, and the privileged merge requires it to be
# the gate (#279, ADR 0044). It is a non-nullable field of every real workflow
# run — ADR 0039 transcribes it from live run 30601252875 — so carrying it here
# is fixture fidelity, not an accommodation: these cases assert the trusted merge
# path, and a payload the API never emits cannot stand for one.
trusted_run='{"id":99,"workflow_id":42,"path":".github/workflows/ai-review-merge.yml","head_sha":"'"$sha"'","event":"pull_request","conclusion":"success","created_at":"2026-07-30T10:00:00Z","run_started_at":"2026-07-30T10:05:00Z","repository":{"full_name":"Verjson/example"}}'
trusted_runs='{"workflow_runs":['"$trusted_run"']}'
default_attestation='{"version":1,"repository":"Verjson/example","pr_number":7,"head_sha":"'"$sha"'","run_id":99,"followups":[]}'
run_case() {
  local fixture="$1" token="${2-present}" expected="${3-$sha}"
  : >"$tmp/merge.log"
  : >"$tmp/view-count"
  : >"$tmp/files-count"
  PATH="$tmp/bin:$PATH" PR_FIXTURE="$fixture" MERGE_LOG="$tmp/merge.log" \
    VIEW_COUNT="$tmp/view-count" PR_FIXTURE_FINAL="${PR_FIXTURE_FINAL:-}" \
    FILES_COUNT="$tmp/files-count" FILES_FIXTURE="${FILES_FIXTURE:-}" \
    FILES_FIXTURE_FINAL="${FILES_FIXTURE_FINAL:-}" \
    FILES_API_FAIL="${FILES_API_FAIL:-false}" \
    RUN_FIXTURE="${RUN_FIXTURE:-$trusted_runs}" \
    REVIEW_FIXTURE="${REVIEW_FIXTURE:-}" \
    DISPATCH_RUN_FIXTURE="${DISPATCH_RUN_FIXTURE:-$trusted_run}" \
    ATTESTATION_FIXTURE="${ATTESTATION_FIXTURE:-$default_attestation}" \
    ARTIFACTS_EMPTY="${ARTIFACTS_EMPTY:-false}" \
    GITHUB_EVENT_NAME="${TEST_EVENT_NAME:-pull_request_target}" \
    SOURCE_RUN_ID="${SOURCE_RUN_ID:-}" \
    RUNNER_TEMP="$tmp" \
    GH_TOKEN="$token" TARGET_REPO=Verjson/example TARGET_OWNER=Verjson \
    GITHUB_REPOSITORY=Verjson/example PR_NUMBER=7 EXPECTED_HEAD_SHA="$expected" \
    EXECUTING_WORKFLOW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github \
    SELF_WORKFLOW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    bash "$script" >"$tmp/case-output.txt" 2>&1
}

for actor in dependabot renovate fork ordinary; do
  if run_case "$green" && grep -q -- "--match-head-commit $sha" "$tmp/merge.log"; then
    pass "$actor PR merges only with the immutable reviewed head"
  else
    sed 's/^/       /' "$tmp/case-output.txt"
    fail "$actor PR did not follow the trusted merge path"
  fi
done

stale="${green/$sha/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
run_case "$stale" && fail "stale head was accepted" || pass "stale head is rejected"
red="${green/\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"/\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"}"
run_case "$red" && fail "failed required check was accepted" || pass "failed required check is rejected"
run_case "$green" "" && fail "missing credentials were accepted" || pass "missing credentials fail closed"
draft="${green/\"isDraft\":false/\"isDraft\":true}"
run_case "$draft" && fail "draft PR was accepted" || pass "draft PR is rejected"
held="${green/\"labels\":[]/\"labels\":[{\"name\":\"hold\"}]}"
run_case "$held" && fail "held PR was accepted" || pass "held PR is rejected"
padding="$(for i in $(seq 1 100); do printf 'docs/pad-%03d.md\n' "$i"; done)"
FILES_FIXTURE="${padding}"$'\n''.github/workflows/caller.yml'$'\n' run_case "$green" \
  && ! grep -q '^pr merge ' "$tmp/merge.log" \
  && ! grep -q '^ISSUE ' "$tmp/merge.log" \
  && grep -q 'privileged auto-merge skipped; human review and merge required' "$tmp/case-output.txt" \
  && pass "paginated workflow changes beyond 100 files stop successfully for human review" \
  || fail "workflow change did not produce a successful no-merge human hold"
spoofed_run="${trusted_runs/\"workflow_id\":42/\"workflow_id\":777}"
RUN_FIXTURE="$spoofed_run" run_case "$green" \
  && fail "spoofed gate workflow identity was accepted" \
  || pass "spoofed gate workflow identity is rejected"
newer_pending_run='{"id":100,"workflow_id":42,"path":".github/workflows/ai-review-merge.yml","head_sha":"'"$sha"'","event":"pull_request","conclusion":null,"created_at":"2026-07-30T10:01:00Z","run_started_at":"2026-07-30T10:01:01Z","repository":{"full_name":"Verjson/example"}}'
reordered_runs='{"workflow_runs":['"$newer_pending_run"','"$trusted_run"']}'
RUN_FIXTURE="$reordered_runs" run_case "$green" \
  && fail "an older success bypassed a newer pending re-review" \
  || pass "explicit run timestamps make newest gate control re-review admission"
PR_FIXTURE_FINAL="$red" run_case "$green" \
  && fail "a final-read check regression was accepted" \
  || pass "checks are revalidated immediately before merge"
FILES_FIXTURE_FINAL='.github/workflows/late.yml'$'\n' run_case "$green" \
  && ! grep -q '^pr merge ' "$tmp/merge.log" \
  && ! grep -q '^ISSUE ' "$tmp/merge.log" \
  && grep -q 'privileged auto-merge skipped; human review and merge required' "$tmp/case-output.txt" \
  && pass "workflow files appearing at final recheck stop successfully for human review" \
  || fail "final workflow recheck did not produce a successful no-merge human hold"
FILES_API_FAIL=true run_case "$green" \
  && fail "unreadable paginated file list was accepted" \
  || pass "unreadable paginated file list fails closed"

followup_attestation='{"version":1,"repository":"Verjson/example","pr_number":7,"head_sha":"'"$sha"'","run_id":99,"followups":[{"location":"src/payments.ts:42","note":"Add a regression test."}]}'
if ATTESTATION_FIXTURE="$followup_attestation" run_case "$green" \
   && grep -q '^pr merge ' "$tmp/merge.log" \
   && grep -q '^ISSUE ' "$tmp/merge.log"; then
  pass "validated follow-ups file only after matched-head merge succeeds"
else
  sed 's/^/       /' "$tmp/case-output.txt"
  sed 's/^/       log: /' "$tmp/merge.log"
  fail "post-merge follow-up handoff did not file after successful merge"
fi
dispatch_run="${trusted_run/\"id\":99/\"id\":123}"
dispatch_run="${dispatch_run/\"event\":\"pull_request\"/\"event\":\"workflow_dispatch\"}"
dispatch_attestation="${default_attestation/\"run_id\":99/\"run_id\":123}"
if TEST_EVENT_NAME=workflow_dispatch SOURCE_RUN_ID=123 \
   DISPATCH_RUN_FIXTURE="$dispatch_run" ATTESTATION_FIXTURE="$dispatch_attestation" \
   run_case "$green" && grep -q '^pr merge ' "$tmp/merge.log"; then
  pass "successful local workflow_dispatch resumes through trusted merger"
else
  fail "trusted workflow_dispatch recovery path did not merge"
fi
if ATTESTATION_FIXTURE="$followup_attestation" run_case "$red" || true; then
  if grep -q '^ISSUE ' "$tmp/merge.log"; then
    fail "privileged failure filed a follow-up issue"
  else
    pass "privileged failure cannot file follow-up issues"
  fi
fi
forged_prose='{"reviews":[{"body":"<!-- ai-review-head:'"$sha"' patchid:fake model:fake --><!-- trusted-gate-run:99 head:'"$sha"' -->"}],"comments":[]}'
if ARTIFACTS_EMPTY=true REVIEW_FIXTURE="$forged_prose" run_case "$green"; then
  fail "forged PR prose authorized merge without a run-bound artifact"
else
  pass "forged PR prose cannot replace the authenticated artifact"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
