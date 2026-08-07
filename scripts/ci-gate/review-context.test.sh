#!/usr/bin/env bash
# Pin the review model's PR-head versus base-branch evidence boundary (#377).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
workflow="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

prompt="$tmp/review-prompt.txt"
awk '
  $0 == "            cat <<EOF" { capture = 1; next }
  capture && $0 == "          EOF" { exit }
  capture { print }
' "$workflow" >"$prompt"

grep -qF 'You are the autonomous merge gate' "$prompt" || {
  echo "FAIL - could not extract the active review prompt from $workflow"
  exit 1
}

grep -qF 'The checked-out workspace and git HEAD are the PR head, not the base or default branch.' "$prompt" \
  && pass "the prompt identifies HEAD as the untrusted PR head" \
  || fail "the prompt does not distinguish PR HEAD from the base branch"

grep -qF 'Never use HEAD, the current checkout, or matching blob hashes as evidence that content is already on the base branch.' "$prompt" \
  && pass "the prompt forbids the false duplicate evidence from PR #376" \
  || fail "the prompt permits PR-head evidence for base-branch claims"

grep -qF 'Do not block because you infer this PR submission is stale, duplicate, closed, or already merged; the deterministic API recheck owns PR lifecycle state.' "$prompt" \
  && pass "deterministic code, not the model, owns PR lifecycle state" \
  || fail "the model can still block on unverifiable PR lifecycle state"

grep -qF 'Still review duplicate-processing and idempotency defects in the proposed behavior normally.' "$prompt" \
  && pass "the lifecycle boundary preserves duplicate-behavior review" \
  || fail "the prompt can suppress duplicate-processing defects"

# #394: exercise the shipped context-preparation block, including the GitHub
# diff transport boundary, against a stateful gh stub.
prep="$tmp/prep.sh"
awk '
  $0 == "      - name: Prepare bounded review context" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap && $0 ~ /^      - name:/ { exit }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    exit
  }
' "$workflow" >"$prep"
sed -i 's/${{ needs.preflight.outputs.head_sha }}/0123456789abcdef0123456789abcdef01234567/g' "$prep"
grep -q 'pr.full.diff' "$prep" || {
  echo "FAIL - could not extract the active context-preparation block"
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/run"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "pr diff" ]; then
  count=$(cat "$DIFF_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" >"$DIFF_COUNT"
  if [ "$count" -le "${DIFF_FAILURES:-0}" ]; then
    case "${DIFF_ERROR_KIND:-500}" in
      500) echo "could not find pull request diff: HTTP 503: Service Unavailable response-marker-must-stay-masked" >&2 ;;
      404) echo "could not find pull request diff: HTTP 404: Not Found" >&2 ;;
      403) echo "could not find pull request diff: HTTP 403: rate limit exceeded" >&2 ;;
      transport) echo "error connecting to api.github.com: connection reset by peer" >&2 ;;
    esac
    exit 1
  fi
  printf '%s\n' 'diff --git a/src/a.ts b/src/a.ts' '@@ -1 +1 @@' '-old' '+new'
  exit 0
fi
if [ "$1 $2" = "pr view" ]; then
  case "$*" in
    *headRefOid*) printf '%s\n' 0123456789abcdef0123456789abcdef01234567 ;;
    *) printf '%s\n' '{"title":"test","body":"","author":{"login":"author"},"labels":[],"baseRefName":"main","headRefName":"feature","additions":1,"deletions":1,"changedFiles":1}' ;;
  esac
  exit 0
fi
exit 2
GH
cat >"$tmp/bin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$SLEEP_LOG"
SH
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"

run_prep() {
  printf '0\n' >"$tmp/diff-count"
  : >"$tmp/sleep.log"
  : >"$tmp/github-output.txt"
  (
    cd "$tmp/run" || exit
    PATH="$tmp/bin:$PATH" GH_TOKEN=token TARGET_REPO=Verjson/example PR_NUMBER=7 \
      DEPENDENCY_MAJOR=false DIFF_COUNT="$tmp/diff-count" SLEEP_LOG="$tmp/sleep.log" \
      GITHUB_OUTPUT="$tmp/github-output.txt" DIFF_FAILURES="${1-0}" DIFF_ERROR_KIND="${2-500}" \
      bash "$prep"
  ) >"$tmp/prep.out" 2>&1
}

run_prep 1 500 \
  && [ "$(cat "$tmp/diff-count")" -eq 2 ] \
  && grep -q '^1$' "$tmp/sleep.log" \
  && grep -q 'result=retry' "$tmp/prep.out" \
  && pass "one GitHub 5xx retries with bounded backoff and then succeeds" \
  || fail "transient 5xx did not recover through the bounded retry"

run_prep 1 transport \
  && [ "$(cat "$tmp/diff-count")" -eq 2 ] \
  && grep -q 'kind=transport' "$tmp/prep.out" \
  && pass "transport failure retries and then succeeds" \
  || fail "transient transport error did not recover"

run_prep 9 500 \
  && fail "persistent GitHub 5xx was allowed through" \
  || {
    [ "$(cat "$tmp/diff-count")" -eq 4 ] \
      && grep -q 'kind=infrastructure_unavailable' "$tmp/prep.out" \
      && grep -q '^review_input_failure=infrastructure_unavailable$' "$tmp/github-output.txt" \
      && [ "$(tr '\n' ',' <"$tmp/sleep.log")" = "1,2,4," ] \
      && ! grep -q 'response-marker-must-stay-masked' "$tmp/prep.out" \
      && pass "exhausted 5xx retry fails closed with typed infrastructure state" \
      || fail "exhausted 5xx lacks exponential backoff, masking, or typed failure evidence"
  }

run_prep 9 transport \
  && fail "persistent transport failure was allowed through" \
  || {
    [ "$(cat "$tmp/diff-count")" -eq 4 ] \
      && grep -q 'source=transport http_status=none' "$tmp/prep.out" \
      && grep -q '^review_input_failure=infrastructure_unavailable$' "$tmp/github-output.txt" \
      && pass "exhausted transport retry shares the typed unavailable outcome" \
      || fail "exhausted transport retry lacks typed infrastructure evidence"
  }

run_prep 9 404 \
  && fail "GitHub 4xx was allowed through" \
  || {
    [ "$(cat "$tmp/diff-count")" -eq 1 ] \
      && ! grep -q 'result=retry' "$tmp/prep.out" \
      && grep -q 'kind=client_error http_status=404' "$tmp/prep.out" \
      && pass "GitHub 4xx fails closed immediately without retry" \
      || fail "4xx was retried or lacked typed client-error evidence"
  }

run_prep 9 403 \
  && fail "rate-limit response was allowed through" \
  || {
    [ "$(cat "$tmp/diff-count")" -eq 1 ] \
      && [ ! -s "$tmp/sleep.log" ] \
      && grep -q 'kind=client_error http_status=403' "$tmp/prep.out" \
      && pass "rate-limit 4xx fails immediately without amplifying API load" \
      || fail "rate-limit response was retried or misclassified"
  }

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
