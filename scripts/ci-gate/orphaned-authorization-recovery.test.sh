#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/gate-rearm.yml"
review_workflow="$root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
pass(){ printf 'ok   - %s\n' "$1"; }
fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

python3 - "$workflow" "$review_workflow" <<'PY' || exit 1
import sys, yaml
arm = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
review = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))
run = next(step["run"] for step in arm["jobs"]["arm"]["steps"] if step.get("name") == "Create exact-head authorization receipt")
assert "# BEGIN CROSS-RUN ORPHAN RECOVERY" in run
assert "# END CROSS-RUN ORPHAN RECOVERY" in run
assert "conclusion=success" not in run[run.index("# BEGIN CROSS-RUN ORPHAN RECOVERY"):run.index("# END CROSS-RUN ORPHAN RECOVERY")]
assert review["run-name"] == "AI review authorization ${{ inputs.authorization_check_id }} from arm ${{ inputs.arm_run_id }}.${{ inputs.arm_run_attempt }}"
PY

awk '
  /# BEGIN CROSS-RUN ORPHAN RECOVERY/{capture=1; next}
  /# END CROSS-RUN ORPHAN RECOVERY/{exit}
  capture{sub(/^          /, ""); print}
' "$workflow" >"$tmp/recover.sh"
[ -s "$tmp/recover.sh" ] || { echo 'recovery block missing'; exit 1; }

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  *"actions/runs/7001/artifacts"*)
    if [ "${RECEIPT_COUNT:-0}" = 1 ]; then
      printf '[{"artifacts":[{"name":"ai-review-arm-7001-1","expired":false}]}]\n'
    elif [ "${RECEIPT_COUNT:-0}" = 2 ]; then
      printf '[{"artifacts":[{"name":"ai-review-arm-7001-1","expired":false},{"name":"ai-review-arm-7001-1","expired":false}]}]\n'
    else
      printf '[{"artifacts":[]}]\n'
    fi ;;
  "api repos/Verjson/example/actions/runs/7001")
    printf '%s\n' "${SOURCE_RUN_JSON}" ;;
  *"actions/workflows/ai-review-merge.yml/runs"*)
    printf '[{"workflow_runs":%s}]\n' "${REVIEW_RUNS_JSON:-[]}" ;;
  "api repos/Verjson/example/check-runs/9001")
    printf '%s\n' "${CURRENT_CHECK_JSON}" ;;
  "api --method PATCH repos/Verjson/example/check-runs/9001"*)
    printf '%s\n' "${PATCH_JSON}" ;;
  "run download 7001 --repo Verjson/example --name ai-review-arm-7001-1 --dir "*)
    destination="${*: -1}"
    mkdir -p "$destination"
    printf '%s\n' "$RECEIPT_JSON" >"$destination/receipt.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" RUNNER_TEMP="$tmp"
export TARGET_REPO=Verjson/example PR_NUMBER=7 REPOSITORY_ID=42 DEFAULT_BRANCH=main
export head_sha=0123456789abcdef0123456789abcdef01234567 APP_ID=4528902 APP_SLUG=ai-review-authorization
export ACTIONS_TOKEN=actions-token GH_TOKEN=app-token GITHUB_RUN_ID=8002 GITHUB_RUN_ATTEMPT=1
export GITHUB_SERVER_URL=https://github.com explicit_rereview=false explicit_ai_review=false
export hold_removed=false
external_id="ai-review:v1:Verjson/example:7:$head_sha:7001:1:$(printf 'a%.0s' {1..64})"
export SOURCE_RUN_JSON='{"id":7001,"run_attempt":1,"status":"completed","event":"pull_request_target","path":".github/workflows/gate-rearm.yml","completed_at":"2020-01-01T00:00:00Z","head_repository":{"full_name":"Verjson/example"},"repository":{"id":42}}'
export CURRENT_CHECK_JSON="{\"id\":9001,\"status\":\"in_progress\",\"conclusion\":null,\"head_sha\":\"$head_sha\",\"external_id\":\"$external_id\",\"details_url\":\"https://github.com/Verjson/example/actions/runs/7001\",\"app\":{\"id\":4528902,\"slug\":\"ai-review-authorization\"}}"
export PATCH_JSON="{\"id\":9001,\"status\":\"completed\",\"conclusion\":\"failure\",\"head_sha\":\"$head_sha\",\"external_id\":\"$external_id\",\"details_url\":\"https://github.com/Verjson/example/actions/runs/7001\",\"app\":{\"id\":4528902,\"slug\":\"ai-review-authorization\"},\"output\":{\"title\":\"Orphaned authorization recovered\"}}"
export RECEIPT_JSON="{\"repository\":\"Verjson/example\",\"pr_number\":7,\"head_sha\":\"$head_sha\",\"check_run_id\":9001,\"arm_run_id\":7001,\"arm_run_attempt\":1,\"external_id\":\"$external_id\",\"details_url\":\"https://github.com/Verjson/example/actions/runs/7001\",\"app_id\":4528902,\"app_slug\":\"ai-review-authorization\"}"

write_latest(){
  export latest="$CURRENT_CHECK_JSON" latest_id=9001 latest_status=in_progress latest_conclusion='' latest_title=''
}
run_case(){
  : >"$CALLS"; write_latest
  bash -c 'set -euo pipefail; source "$1"; printf "latest_id=%s recovered=%s\n" "$latest_id" "$recovered_orphan"' _ "$tmp/recover.sh"
}

export RECEIPT_COUNT=0 REVIEW_RUNS_JSON='[]'
if output="$(run_case 2>&1)" && grep -q 'latest_id= recovered=true' <<<"$output" \
   && grep -q 'method PATCH.*check-runs/9001' "$CALLS"; then
  pass 'a terminal source with accepted-but-lost activation and no dispatch owner is recovered'
else fail 'accepted-but-lost activation was not recovered'; fi

export RECEIPT_COUNT=1
if output="$(run_case 2>&1)" && grep -q 'latest_id= recovered=true' <<<"$output"; then
  pass 'an exhausted same-job cleanup is recovered through its exact durable receipt'
else fail 'receipt-bound exhausted cleanup was not recovered'; fi

export REVIEW_RUNS_JSON='[{"display_title":"AI review authorization 9001 from arm 7001.1","event":"workflow_dispatch","path":".github/workflows/ai-review-merge.yml","head_branch":"main","status":"in_progress","head_repository":{"full_name":"Verjson/example"},"repository":{"full_name":"Verjson/example"}}]'
if run_case >/dev/null 2>&1 && ! grep -q 'method PATCH' "$CALLS"; then
  pass 'an active exact receipt-bound downstream review retains ownership'
else fail 'active downstream ownership was terminated'; fi

export REVIEW_RUNS_JSON='[]' RECEIPT_COUNT=0
CURRENT_CHECK_JSON="${CURRENT_CHECK_JSON/\"status\":\"in_progress\"/\"status\":\"completed\"}"
if ! run_case >/dev/null 2>&1 && ! grep -q 'method PATCH' "$CALLS"; then
  pass 'a concurrent terminal transition fails closed without overwriting state'
else fail 'concurrent recovery overwrote terminal state'; fi
CURRENT_CHECK_JSON="${CURRENT_CHECK_JSON/\"status\":\"completed\"/\"status\":\"in_progress\"}"

export RECEIPT_COUNT=2
if ! run_case >/dev/null 2>&1 && ! grep -q 'method PATCH' "$CALLS"; then
  pass 'ambiguous durable receipts fail closed'
else fail 'ambiguous receipt state reached mutation'; fi

export RECEIPT_COUNT=0
SOURCE_RUN_JSON="${SOURCE_RUN_JSON/\"status\":\"completed\"/\"status\":\"in_progress\"}"
if run_case >/dev/null 2>&1 && ! grep -q 'method PATCH' "$CALLS"; then
  pass 'a nonterminal source arm cannot be recovered'
else fail 'nonterminal source arm was mutated'; fi
SOURCE_RUN_JSON="${SOURCE_RUN_JSON/\"status\":\"in_progress\"/\"status\":\"completed\"}"

if latest="$PATCH_JSON" latest_id=9001 latest_status=completed latest_conclusion=failure \
   latest_title='Orphaned authorization recovered' bash -c \
   'set -euo pipefail; hold_removed=false; explicit_rereview=false; explicit_ai_review=false; source "$1"; [ -z "$latest_id" ] && [ "$recovered_orphan" = true ]' _ "$tmp/recover.sh"; then
  pass 'a rerun resumes after a prior exact recovery marker without another patch'
else fail 'idempotent recovery rerun did not resume'; fi

printf '%d failing assertion(s)\n' "$fails"
[ "$fails" -eq 0 ]
