#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
pass(){ printf 'ok   - %s\n' "$1"; }
fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

awk '/^          nonce="\$\(openssl rand -hex 32\)"/{copy=1} copy{print} /^          } >>"\$GITHUB_OUTPUT"/{exit}' \
  "$root/.github/workflows/gate-rearm.yml" | sed 's/^          //' \
  | sed '/echo "armed=true"/i\  [ "$SCENARIO" != process-before-outputs ] || exit 99' >"$tmp/lifecycle.sh"
[ -s "$tmp/lifecycle.sh" ] || { echo 'FAIL - lifecycle block missing'; exit 1; }
guard_name='Complete the authorization when no review was dispatched'
awk -v name="      - name: $guard_name" '$0==name{f=1;next} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' \
  "$root/.github/workflows/gate-rearm.yml" >"$tmp/guard.sh"

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"--method POST "*"/check-runs --input -"*)
    payload="$(cat)"
    jq -e '.status == "completed" and .conclusion == "failure"' <<<"$payload" >/dev/null || exit 90
    external_id="$(jq -r .external_id <<<"$payload")"; printf '%s' "$external_id" >"$EXTERNAL_ID"
    printf 'completed\n' >"$STATE"
    case "$SCENARIO" in
      post-malformed) printf '{}\n';;
      post-wrong-id) jq -nc --arg ext "$external_id" '{id:9002,app:{id:4242,slug:"ai-review-authorization"},external_id:$ext,status:"completed",conclusion:"failure"}';;
      post-wrong-app-id) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4243,slug:"ai-review-authorization"},external_id:$ext,status:"completed",conclusion:"failure"}';;
      post-wrong-slug) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4242,slug:"wrong-app"},external_id:$ext,status:"completed",conclusion:"failure"}';;
      post-wrong-external-id) jq -nc '{id:9001,app:{id:4242,slug:"ai-review-authorization"},external_id:"wrong",status:"completed",conclusion:"failure"}';;
      *) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4242,slug:"ai-review-authorization"},external_id:$ext,status:"completed",conclusion:"failure"}';;
    esac ;;
  *"--method PATCH "*"/check-runs/9001"*"status=in_progress"*)
    printf 'in_progress\n' >"$STATE"; external_id="$(cat "$EXTERNAL_ID")"
    [ "$SCENARIO" != patch-failure ] || exit 91
    [ "$SCENARIO" != activation-response-lost ] || exit 91
    case "$SCENARIO" in
      patch-malformed) printf '{}\n';;
      three-restoration-attempts-exhausted) printf '{}\n';;
      patch-wrong-id) jq -nc --arg ext "$external_id" '{id:9002,app:{id:4242,slug:"ai-review-authorization"},external_id:$ext,status:"in_progress",conclusion:null}';;
      patch-wrong-app-id) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4243,slug:"ai-review-authorization"},external_id:$ext,status:"in_progress",conclusion:null}';;
      patch-wrong-slug) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4242,slug:"wrong-app"},external_id:$ext,status:"in_progress",conclusion:null}';;
      patch-wrong-external-id) jq -nc '{id:9001,app:{id:4242,slug:"ai-review-authorization"},external_id:"wrong",status:"in_progress",conclusion:null}';;
      *) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4242,slug:"ai-review-authorization"},external_id:$ext,status:"in_progress",conclusion:null}';;
    esac ;;
  *"--method PATCH "*"/check-runs/9001"*"status=completed"*)
    count="$(cat "$RESTORE_COUNT" 2>/dev/null || echo 0)"; count=$((count + 1)); printf '%s' "$count" >"$RESTORE_COUNT"
    if [ "$SCENARIO" = three-restoration-attempts-exhausted ] && [ "$count" -le 3 ]; then exit 91; fi
    printf 'completed\n' >"$STATE"; external_id="$(cat "$EXTERNAL_ID")"
    jq -nc --arg ext "$external_id" --arg head "$HEAD_SHA" --arg url "$DETAILS_URL" \
      '{id:9001,app:{id:4242,slug:"ai-review-authorization"},head_sha:$head,details_url:$url,external_id:$ext,status:"completed",conclusion:"failure"}' ;;
  *"check-runs/9001"*)
    external_id="$(cat "$EXTERNAL_ID")"; status="$(cat "$STATE")"
    jq -nc --arg ext "$external_id" --arg head "$HEAD_SHA" --arg url "$DETAILS_URL" --arg status "$status" \
      '{id:9001,app:{id:4242,slug:"ai-review-authorization"},head_sha:$head,details_url:$url,external_id:$ext,status:$status,conclusion:(if $status=="completed" then "failure" else null end)}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 92 ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_case() {
  local scenario="$1" expected_result="$2" label="$3" result expected_state
  rm -rf "$tmp/receipt" "$tmp/output" "$tmp/env" "$tmp/state" "$tmp/external-id" "$tmp/restore-count"
  export SCENARIO="$scenario" STATE="$tmp/state" EXTERNAL_ID="$tmp/external-id" RESTORE_COUNT="$tmp/restore-count"
  export PATH="$tmp/bin:$PATH" TARGET_REPO=Verjson/example PR_NUMBER=7
  export APP_ID=4242 APP_SLUG=ai-review-authorization head_sha=0123456789abcdef0123456789abcdef01234567
  export head_owner=Verjson GITHUB_REPOSITORY_OWNER=Verjson GITHUB_RUN_ID=7001 GITHUB_RUN_ATTEMPT=1
  export GITHUB_SERVER_URL=https://github.com RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/output" GITHUB_ENV="$tmp/env"
  export HEAD_SHA="$head_sha" DETAILS_URL="$GITHUB_SERVER_URL/$TARGET_REPO/actions/runs/$GITHUB_RUN_ID"
  export review_policy=policy explicit_rereview=false explicit_ai_review=false explicit_label_delivery=false
  if bash "$tmp/lifecycle.sh" >"$tmp/out" 2>&1; then result=success; else result=failure; fi
  if [ "$result" = failure ] && [ "$(cat "$STATE" 2>/dev/null)" = in_progress ]; then
    while IFS='=' read -r key value; do export "$key=$value"; done <"$GITHUB_ENV"
    export CHECK_ID="$AUTHORIZATION_CHECK_CREATED_ID" EXPECTED_HEAD_SHA="$AUTHORIZATION_CHECK_CREATED_HEAD"
    export EXPECTED_EXTERNAL_ID="$AUTHORIZATION_CHECK_CREATED_EXTERNAL_ID" EXPECTED_DETAILS_URL="$AUTHORIZATION_CHECK_CREATED_DETAILS_URL"
    export APP_TOKEN=token
    bash "$tmp/guard.sh" >>"$tmp/out" 2>&1 || result=failure
  fi
  if [ "$expected_result" = success ]; then expected_state=in_progress; else expected_state=completed; fi
  if [ "$result" = "$expected_result" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$expected_state" ]; then
    pass "$label"
  else
    fail "$label (result=$result state=$(cat "$STATE" 2>/dev/null || echo absent))"
  fi
}

run_case success success "verified terminal check activates successfully"
for scenario in post-malformed post-wrong-id post-wrong-app-id post-wrong-slug post-wrong-external-id; do
  run_case "$scenario" failure "$scenario leaves the created check terminal"
done
for scenario in patch-failure patch-malformed patch-wrong-id patch-wrong-app-id patch-wrong-slug patch-wrong-external-id; do
  run_case "$scenario" failure "$scenario restores the check to terminal failure"
done
run_case activation-response-lost failure "accepted activation with a lost response is terminalized"
run_case process-before-outputs failure "process failure before outputs is terminalized from durable identity"
run_case three-restoration-attempts-exhausted failure "always cleanup terminalizes after inline restoration exhaustion"

[ "$fails" -eq 0 ] || exit 1
printf 'All tests passed.\n'
