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
  && pass "privileged job runs only from the trusted base-branch event" \
  || fail "privileged job is not isolated behind pull_request_target"
grep -q 'trusted_workflow_id=' <<<"$privileged" \
  && grep -q "gate check provenance mismatch" <<<"$privileged" \
  && pass "merge authority verifies the immutable workflow-run identity" \
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
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "pr view" ]; then
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
if [ "$1" = "api" ] && [[ "$2" == *"/actions/runs/"* ]]; then
  printf '%s\n' "$RUN_FIXTURE"
  exit 0
fi
if [ "$1 $2" = "pr merge" ]; then
  printf '%s\n' "$*" >>"$MERGE_LOG"
  exit 0
fi
exit 2
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"

sha=0123456789abcdef0123456789abcdef01234567
green='{"headRefOid":"'"$sha"'","isDraft":false,"labels":[],"state":"OPEN","files":[],"statusCheckRollup":[{"name":"gate","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/Verjson/example/actions/runs/99/job/1"},{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]}'
trusted_run='{"workflow_id":42,"head_sha":"'"$sha"'","event":"pull_request","conclusion":"success","repository":{"full_name":"Verjson/example"}}'
run_case() {
  local fixture="$1" token="${2-present}" expected="${3-$sha}"
  : >"$tmp/merge.log"
  : >"$tmp/view-count"
  PATH="$tmp/bin:$PATH" PR_FIXTURE="$fixture" MERGE_LOG="$tmp/merge.log" \
    VIEW_COUNT="$tmp/view-count" PR_FIXTURE_FINAL="${PR_FIXTURE_FINAL:-}" \
    RUN_FIXTURE="${RUN_FIXTURE:-$trusted_run}" \
    GH_TOKEN="$token" TARGET_REPO=Verjson/example TARGET_OWNER=Verjson \
    GITHUB_REPOSITORY=Verjson/example PR_NUMBER=7 EXPECTED_HEAD_SHA="$expected" \
    bash "$script" >/dev/null 2>&1
}

for actor in dependabot renovate fork ordinary; do
  if run_case "$green" && grep -q -- "--match-head-commit $sha" "$tmp/merge.log"; then
    pass "$actor PR merges only with the immutable reviewed head"
  else
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
workflow_change="${green/\"files\":[]/\"files\":[{\"path\":\".github\\/workflows\\/caller.yml\"}]}"
run_case "$workflow_change" \
  && fail "PR-controlled workflow change was accepted" \
  || pass "workflow changes require a human merge"
spoofed_run="${trusted_run/\"workflow_id\":42/\"workflow_id\":777}"
RUN_FIXTURE="$spoofed_run" run_case "$green" \
  && fail "spoofed gate workflow identity was accepted" \
  || pass "spoofed gate workflow identity is rejected"
newer_pending="${green/\"name\":\"build\"/\"name\":\"gate\",\"status\":\"IN_PROGRESS\",\"conclusion\":null,\"detailsUrl\":\"https:\\/\\/github.com\\/Verjson\\/example\\/actions\\/runs\\/100\\/job\\/1\"},{\"name\":\"build\"}"
run_case "$newer_pending" \
  && fail "an older success bypassed a newer pending re-review" \
  || pass "newest gate run controls re-review admission"
PR_FIXTURE_FINAL="$red" run_case "$green" \
  && fail "a final-read check regression was accepted" \
  || pass "checks are revalidated immediately before merge"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
