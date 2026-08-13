#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/ai-post-merge.yml"
script="$root/scripts/ci-gate/post-merge-reconcile.sh"
grep -q 'pull_request_target:' "$workflow"
grep -q 'github.event.pull_request.merged == true' "$workflow"
grep -q 'ai-review-authorization:' "$workflow"
grep -q 'ai-review-run:' "$workflow"
grep -q 'path == ".github/workflows/ai-review-merge.yml"' "$workflow"
grep -q 'ref: \${{ github.event.pull_request.base.sha }}' "$workflow"
grep -q "if: steps.evidence.outputs.eligible == 'true'" "$workflow"
! grep -Eq 'gh pr merge|workflow run ai-review-merge|sleep [0-9]' "$workflow" "$script"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk '$0=="      - name: Validate exact-head review evidence"{f=1;next} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' \
  "$workflow" >"$tmp/evidence.sh"
[ -s "$tmp/evidence.sh" ] || { echo "FAIL - post-merge evidence block missing"; exit 1; }

mkdir "$tmp/evidence-bin"
cat >"$tmp/evidence-bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$EVIDENCE_LOG"
case "$*" in
  *"commits/"*"/check-runs --jq "*) cat "$CHECK_FILE" ;;
  "api --paginate "*"/reviews?per_page=100") cat "$REVIEWS_FILE" ;;
  "api repos/"*"/check-runs/9001") cat "$CHECK_FILE" ;;
  "api repos/"*"/actions/runs/8001") cat "$RUN_FILE" ;;
  "api repos/"*"/actions/runs/8001/artifacts?per_page=100") cat "$ARTIFACTS_FILE" ;;
  "api https://api.github.test/artifacts/81") printf 'fixture zip\n' ;;
  *) echo "unexpected evidence gh call: $*" >&2; exit 2 ;;
esac
STUB
cat >"$tmp/evidence-bin/unzip" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "-p $RUNNER_TEMP/post-merge-evidence/evidence.zip attestation.json" ] || exit 2
cat "$ATTESTATION_SOURCE"
STUB
chmod +x "$tmp/evidence-bin/gh" "$tmp/evidence-bin/unzip"

export PATH="$tmp/evidence-bin:$PATH" EVIDENCE_LOG="$tmp/evidence.log"
export CHECK_FILE="$tmp/check.json" REVIEWS_FILE="$tmp/reviews.json" RUN_FILE="$tmp/run.json"
export ARTIFACTS_FILE="$tmp/artifacts.json" ATTESTATION_SOURCE="$tmp/attestation-source.json"
export TARGET_REPO=Verjson/example PR_NUMBER=7
export MERGED_HEAD_SHA=1111111111111111111111111111111111111111
export EXPECTED_APP_ID=4242 EXPECTED_APP_SLUG=verjson-ai-review-authorization
export RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/evidence-output"

write_check() {
  local summary="$1" status="${2:-completed}" conclusion="${3:-success}"
  jq -nc --arg head "$MERGED_HEAD_SHA" --arg summary "$summary" --arg status "$status" \
    --arg conclusion "$conclusion" \
    '{id:9001,name:"AI review authorization",head_sha:$head,status:$status,conclusion:$conclusion,
      app:{id:4242,slug:"verjson-ai-review-authorization"},output:{summary:$summary}}' >"$CHECK_FILE"
}
write_valid_ai_evidence() {
  jq -nc --arg head "$MERGED_HEAD_SHA" \
    '{state:"APPROVED",commit_id:$head,user:{login:"verjson-ai-review-authorization[bot]"},
      body:"<!-- ai-review-authorization:9001 -->\n<!-- ai-review-run:8001 -->"}' \
    | jq -s '.' >"$REVIEWS_FILE"
  jq -nc --arg head "$MERGED_HEAD_SHA" \
    '{repository:{full_name:"Verjson/example"},head_sha:$head,event:"workflow_dispatch",status:"completed",
      conclusion:"success",path:".github/workflows/ai-review-merge.yml"}' >"$RUN_FILE"
  printf '{"artifacts":[{"name":"merge-attestation-8001","expired":false,"archive_download_url":"https://api.github.test/artifacts/81"}]}\n' >"$ARTIFACTS_FILE"
  jq -nc --arg head "$MERGED_HEAD_SHA" \
    '{version:1,repository:"Verjson/example",pr_number:7,head_sha:$head,run_id:8001,followups:[]}' \
    >"$ATTESTATION_SOURCE"
}
run_evidence() {
  : >"$EVIDENCE_LOG"; : >"$GITHUB_OUTPUT"
  bash "$tmp/evidence.sh" >"$tmp/evidence.out" 2>&1
}
expect_noop() {
  local label="$1"
  if run_evidence && grep -qx 'eligible=false' "$GITHUB_OUTPUT" \
     && ! grep -q '/reviews\|/artifacts' "$EVIDENCE_LOG"; then
    printf 'ok   - %s\n' "$label"
  else
    printf 'FAIL - %s\n' "$label"
    exit 1
  fi
}
expect_rejected() {
  local label="$1"
  if ! run_evidence && ! grep -q '/artifacts' "$EVIDENCE_LOG"; then
    printf 'ok   - %s\n' "$label"
  else
    printf 'FAIL - %s\n' "$label"
    exit 1
  fi
}

for outcome in human skipped inconclusive blocking failed-app-approval; do
  write_check "$outcome path; ordinary branch protection authorized the merge"
  expect_noop "$outcome post-merge path is a successful no-op"
done

write_check $'AI approval persisted.\n<!-- ai-review-authorized:v1:9001:1111111111111111111111111111111111111111:ai-approve -->'
expect_noop "ai-approve post-merge path is a successful no-op"
write_check $'AI approval persisted.\n<!-- ai-review-authorized:v1:9001:1111111111111111111111111111111111111111:ai-approve -->' completed failure
expect_rejected "unsuccessful ai-approve evidence fails closed"

write_valid_ai_evidence
write_check $'AI approval persisted.\n<!-- ai-review-authorized:v1:9001:1111111111111111111111111111111111111111:ai-merge -->'
if run_evidence && grep -qx 'eligible=true' "$GITHUB_OUTPUT" \
   && grep -q '^path=.*/post-merge-evidence/attestation.json$' "$GITHUB_OUTPUT"; then
  printf 'ok   - exact-head ai-merge evidence reaches attestation processing\n'
else
  echo 'FAIL - exact-head ai-merge evidence did not reach attestation processing'
  exit 1
fi

write_check $'AI approval persisted.\n<!-- ai-review-authorized:v1:9001:2222222222222222222222222222222222222222:ai-merge -->'
expect_rejected "stale AI authorization marker fails closed"
write_check $'AI approval persisted.\n<!-- ai-review-authorized:v1:9999:1111111111111111111111111111111111111111:ai-merge -->'
expect_rejected "forged AI authorization marker fails closed"
write_check $'AI approval persisted.\n<!-- ai-review-authorized:v1:not-a-check:1111111111111111111111111111111111111111:ai-merge -->'
expect_rejected "malformed AI authorization marker fails closed"
write_check $'AI approval persisted.\n<!-- ai-review-authorized:v1:9001:1111111111111111111111111111111111111111:ai-merge -->' completed failure
expect_rejected "unsuccessful check cannot carry AI merge evidence"
write_check $'AI approval persisted.\n<!-- ai-review-authorized:v1:9001:1111111111111111111111111111111111111111:ai-merge -->'
jq '.[0].body="<!-- ai-review-authorization:9999 -->\n<!-- ai-review-run:8001 -->"' \
  "$REVIEWS_FILE" >"$tmp/changed-reviews.json" && mv "$tmp/changed-reviews.json" "$REVIEWS_FILE"
expect_rejected "approval bound to another authorization check fails closed"

PATH="${PATH#*:}"
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '%s\n' "${EXISTING:-0}" ;;
  "issue create") printf 'create %s\n' "$*" >>"$GH_LOG" ;;
  "api repos/"*) printf '%s\n' "${LIVE_SHA:-}" ;;
  "api --method") printf 'delete %s\n' "$*" >>"$GH_LOG" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log"
export TARGET_REPO=Verjson/example PR_NUMBER=7 HEAD_REPO=Verjson/example HEAD_REF=feature/test
export BASE_REF=main DEFAULT_BRANCH=main MERGED_HEAD_SHA=1111111111111111111111111111111111111111
export LIVE_SHA="$MERGED_HEAD_SHA"
export ATTESTATION_FILE="$tmp/attestation.json"
jq -n '{followups:[{location:"src/a.ts:3",note:"Add coverage."},{location:"src/a.ts:3",note:"Add coverage."}]}' >"$ATTESTATION_FILE"
bash "$script"
[ "$(grep -c '^create ' "$GH_LOG")" -eq 1 ]
grep -q '^delete ' "$GH_LOG"
: >"$GH_LOG"
EXISTING=1 HEAD_REPO=someone/fork bash "$script"
[ ! -s "$GH_LOG" ]

: >"$GH_LOG"
EXISTING=1 LIVE_SHA=2222222222222222222222222222222222222222 bash "$script"
[ ! -s "$GH_LOG" ]

: >"$GH_LOG"
EXISTING=1 HEAD_REF=main LIVE_SHA="$MERGED_HEAD_SHA" bash "$script"
[ ! -s "$GH_LOG" ]

: >"$GH_LOG"
EXISTING=1 HEAD_REF=release BASE_REF=release DEFAULT_BRANCH=main LIVE_SHA="$MERGED_HEAD_SHA" bash "$script"
[ ! -s "$GH_LOG" ]
echo "All tests passed."
