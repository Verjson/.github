#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
pass(){ printf 'ok   - %s\n' "$1"; }
fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

awk '/^          nonce="\$\(openssl rand -hex 32\)"/{copy=1} copy{print} /^          } >>"\$GITHUB_OUTPUT"/{exit}' \
  "$root/.github/workflows/gate-rearm.yml" | sed 's/^          //' >"$tmp/lifecycle.sh"
[ -s "$tmp/lifecycle.sh" ] || { echo 'FAIL - lifecycle block missing'; exit 1; }

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
    [ "$SCENARIO" != patch-failure ] || exit 91
    printf 'in_progress\n' >"$STATE"; external_id="$(cat "$EXTERNAL_ID")"
    case "$SCENARIO" in
      patch-malformed) printf '{}\n';;
      patch-wrong-id) jq -nc --arg ext "$external_id" '{id:9002,app:{id:4242,slug:"ai-review-authorization"},external_id:$ext,status:"in_progress",conclusion:null}';;
      patch-wrong-app-id) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4243,slug:"ai-review-authorization"},external_id:$ext,status:"in_progress",conclusion:null}';;
      patch-wrong-slug) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4242,slug:"wrong-app"},external_id:$ext,status:"in_progress",conclusion:null}';;
      patch-wrong-external-id) jq -nc '{id:9001,app:{id:4242,slug:"ai-review-authorization"},external_id:"wrong",status:"in_progress",conclusion:null}';;
      *) jq -nc --arg ext "$external_id" '{id:9001,app:{id:4242,slug:"ai-review-authorization"},external_id:$ext,status:"in_progress",conclusion:null}';;
    esac ;;
  *"--method PATCH "*"/check-runs/9001"*"status=completed"*)
    printf 'completed\n' >"$STATE"; external_id="$(cat "$EXTERNAL_ID")"
    jq -nc --arg ext "$external_id" '{id:9001,app:{id:4242,slug:"ai-review-authorization"},external_id:$ext,status:"completed",conclusion:"failure"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 92 ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_case() {
  local scenario="$1" expected_result="$2" label="$3" result expected_state
  rm -rf "$tmp/receipt" "$tmp/output" "$tmp/state" "$tmp/external-id"
  export SCENARIO="$scenario" STATE="$tmp/state" EXTERNAL_ID="$tmp/external-id"
  export PATH="$tmp/bin:$PATH" TARGET_REPO=Verjson/example PR_NUMBER=7
  export APP_ID=4242 APP_SLUG=ai-review-authorization head_sha=0123456789abcdef0123456789abcdef01234567
  export head_owner=Verjson GITHUB_REPOSITORY_OWNER=Verjson GITHUB_RUN_ID=7001 GITHUB_RUN_ATTEMPT=1
  export GITHUB_SERVER_URL=https://github.com RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/output"
  export review_policy=policy explicit_rereview=false explicit_ai_review=false explicit_label_delivery=false
  if bash "$tmp/lifecycle.sh" >"$tmp/out" 2>&1; then result=success; else result=failure; fi
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

[ "$fails" -eq 0 ] || exit 1
printf 'All tests passed.\n'
