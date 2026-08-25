#!/usr/bin/env bash
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; workflow="$root/.github/workflows/gate-rearm.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; fails=0
pass(){ printf 'ok   - %s\n' "$1"; }; fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }
guard_name='Complete the authorization when no review was dispatched'

if python3 - "$workflow" "$guard_name" <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = workflow["jobs"]["arm"]["steps"]
by_name = {step.get("name"): step for step in steps}
receipt, dispatch, guard = (by_name[n] for n in (
    "Upload immutable arm receipt", "Dispatch trusted review after receipt publication", sys.argv[2]))
assert receipt["if"] == "steps.arm.outputs.armed == 'true'"
assert dispatch["if"] == "steps.arm.outputs.armed == 'true'"
assert "always()" in guard["if"] and "env.AUTHORIZATION_CHECK_CREATED_ID != ''" in guard["if"]
assert "steps.arm.outputs" not in guard["if"]
assert guard["env"]["CHECK_ID"] == "${{ env.AUTHORIZATION_CHECK_CREATED_ID }}"
run = guard["run"]
for binding in (".id == $id", ".app.id == $app_id", ".app.slug == $slug", ".head_sha == $head",
                ".external_id == $external_id", ".details_url == $url"):
    assert binding in run
assert "conclusion=failure" in run and "conclusion=success" not in run
PY
then pass "cleanup is durable-output-independent and exact-identity-bound"
else fail "cleanup contract is missing or drifted"
fi

awk -v name="      - name: $guard_name" '$0==name{f=1;next} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' \
  "$workflow" >"$tmp/guard.sh"
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"--method PATCH "*"check-runs/9001"*)
    [ "$SCENARIO" != patch-failure ] || exit 91
    [ "$SCENARIO" != patch-malformed ] || { printf '{}\n'; exit 0; }
    printf 'completed\n' >"$STATE"; cat "$COMPLETED" ;;
  *"check-runs/9001"*)
    [ "$SCENARIO" != read-failure ] || exit 92
    [ "$SCENARIO" != read-malformed ] || { printf '{}\n'; exit 0; }
    if [ "$SCENARIO" = identity-mismatch ]; then jq '.app.id=9999' "$LIVE"; else cat "$LIVE"; fi ;;
  *) exit 93 ;;
esac
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" TARGET_REPO=Verjson/example CHECK_ID=9001 APP_TOKEN=token
export APP_ID=4242 APP_SLUG=ai-review-authorization EXPECTED_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export GITHUB_RUN_ID=7001 GITHUB_RUN_ATTEMPT=1 GITHUB_SERVER_URL=https://github.com
export EXPECTED_EXTERNAL_ID="ai-review:v1:$TARGET_REPO:7:$EXPECTED_HEAD_SHA:$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT:$(printf 'a%.0s' {1..64})"
export EXPECTED_DETAILS_URL="$GITHUB_SERVER_URL/$TARGET_REPO/actions/runs/$GITHUB_RUN_ID"
export LIVE="$tmp/live" COMPLETED="$tmp/completed" STATE="$tmp/state"
write_json(){
  jq -nc --argjson id 9001 --argjson app 4242 --arg slug "$APP_SLUG" --arg head "$EXPECTED_HEAD_SHA" \
    --arg ext "$EXPECTED_EXTERNAL_ID" --arg url "$EXPECTED_DETAILS_URL" --arg status "$1" --arg conclusion "$2" \
    '{id:$id,app:{id:$app,slug:$slug},head_sha:$head,external_id:$ext,details_url:$url,status:$status,
      conclusion:(if $conclusion=="null" then null else $conclusion end)}'
}
write_json in_progress null >"$LIVE"; write_json completed failure >"$COMPLETED"
run_case(){
  local scenario="$1" expect="$2" label="$3" result
  export SCENARIO="$scenario"; rm -f "$STATE"
  if bash "$tmp/guard.sh" >"$tmp/out" 2>&1; then result=success; else result=failure; fi
  if [ "$result" = "$expect" ]; then pass "$label"; else fail "$label"; fi
}
run_case success success "verified pending check is terminalized"
cp "$COMPLETED" "$LIVE"; run_case success success "already-terminal failure is unchanged"; write_json in_progress null >"$LIVE"
run_case identity-mismatch failure "cleanup rejects identity mismatch without mutation"
run_case read-malformed failure "cleanup rejects malformed API state"
run_case read-failure failure "cleanup fails loudly on read failure"
run_case patch-failure failure "cleanup fails loudly on terminalization failure"
run_case patch-malformed failure "cleanup rejects malformed terminalization response"
printf '%d failing assertion(s)\n' "$fails"; [ "$fails" -eq 0 ]
