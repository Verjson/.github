#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
wf="$root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

gate="$(awk '/^  gate:/{cap=1} cap&&/^  dispatch-merge:/{exit} cap{print}' "$wf")"
dispatch="$(awk '/^  dispatch-merge:/{cap=1} cap{print}' "$wf")"

grep -q '^      actions: read$' <<<"$gate" \
  && ! grep -q '^      actions: write$' <<<"$gate" \
  && pass "PR checkout/review gate has actions:read only" \
  || fail "PR checkout/review gate retained actions:write"
[ "$(grep -c '^      actions: write$' "$wf")" -eq 1 ] \
  && grep -q '^      contents: read$' <<<"$dispatch" \
  && pass "only dispatch job has minimum contents/read + actions/write" \
  || fail "dispatch permissions are duplicated or over-broad"
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
if [ "$1" = api ]; then printf '%s\n' "${WORKFLOW_PATH:-.github/workflows/ai-privileged-merge.yml}"; exit 0; fi
if [ "$1 $2" = "workflow run" ]; then printf '%s\n' "$*" >>"$DISPATCH_LOG"; exit 0; fi
exit 2
EOF
chmod +x "$tmp/bin/gh"

run_case() {
  : >"$tmp/dispatch.log"
  PATH="$tmp/bin:$PATH" DISPATCH_LOG="$tmp/dispatch.log" GH_TOKEN=token \
    GITHUB_REPOSITORY=Verjson/example TARGET_REPO="${1-Verjson/example}" \
    PR_NUMBER="${2-7}" EXPECTED_HEAD_SHA="${3-0123456789abcdef0123456789abcdef01234567}" \
    SOURCE_RUN_ID="${4-99}" WORKFLOW_PATH="${5-.github/workflows/ai-privileged-merge.yml}" \
    bash "$script" >/dev/null 2>&1
}
run_case && grep -q 'workflow run ai-privileged-merge.yml' "$tmp/dispatch.log" \
  && pass "validated identities dispatch only the fixed workflow" \
  || fail "valid trusted dispatch failed"
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

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
