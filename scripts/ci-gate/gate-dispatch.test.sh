#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/gate-rearm.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; pass(){ printf 'ok   - %s\n' "$1"; }; fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }
awk '$0=="      - name: Dispatch trusted review after receipt publication"{f=1;next} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' "$workflow" >"$tmp/dispatch.sh"
sed -i 's/${{ steps.arm.outputs.explicit_rereview || false }}/false/' "$tmp/dispatch.sh"
sed -i 's/${{ steps.arm.outputs.review_policy }}/eyJhY3RvciI6InRydXN0ZWQtYXJtIiwiYWN0b3JfcGVybWlzc2lvbiI6ImF1dG9tYXRpb24iLCJidWRnZXRfdXNkIjoiYXV0byIsIm1vZGVsIjoiYXV0byIsInByaWNpbmdfdmVyc2lvbiI6ImFudGhyb3BpYy1uYXRpdmUtdjEiLCJwcm92aWRlciI6ImFudGhyb3BpYyJ9/' "$tmp/dispatch.sh"
[ -s "$tmp/dispatch.sh" ] || { echo "FAIL - dispatch block missing"; exit 1; }
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "workflow run "*) [ "${DISPATCH_FAIL:-false}" != true ] ;;
  "api --method PATCH "*) exit 0 ;;
  "pr edit "*) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" DEFAULT_BRANCH=main TARGET_REPO=Verjson/example PR_NUMBER=7
export EXPECTED_HEAD_SHA=0123456789abcdef0123456789abcdef01234567 CHECK_ID=9001 APP_TOKEN=app-token GH_TOKEN=actions-token
export GITHUB_RUN_ID=7001 GITHUB_RUN_ATTEMPT=2 EVENT_ACTION=synchronize EVENT_LABEL=''
run_dispatch(){ : >"$CALLS"; bash "$tmp/dispatch.sh"; }
if run_dispatch >/dev/null 2>&1 && grep -q 'arm_run_id=7001' "$CALLS" && ! grep -q 'method PATCH' "$CALLS"; then pass "successful dispatch carries exact arm receipt identity once"; else fail "successful trusted dispatch drifted"; fi
export DISPATCH_FAIL=true
if run_dispatch >/dev/null 2>&1; then fail "dispatch failure reported green"; elif grep -q 'method PATCH.*check-runs/9001' "$CALLS"; then pass "dispatch failure completes the dedicated-App check as failure"; else fail "dispatch failure did not fail the authorization"; fi
unset DISPATCH_FAIL
DEFAULT_BRANCH='../bad?ref'
if run_dispatch >/dev/null 2>&1; then fail "unsafe default branch reached dispatch"; else pass "unsafe dispatch ref fails closed"; fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }; echo "$fails test(s) failed."; exit 1
