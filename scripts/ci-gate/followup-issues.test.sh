#!/usr/bin/env bash
# Tests the merge gate's "File follow-up issues for non-blocking findings" step
# (shared gate job) by extracting its exact `run:` block from ai-review-merge.yml —
# single source of truth, no drift — and driving it against a stubbed `gh`.
# Guards: files only on a MERGED PR, one issue per follow-up, per-PR dedup, and
# empty/absent follow-ups no-op. Plain bash + awk + jq; no dependency.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

script="$tmp/file.sh"
awk '
  $0 == "      - name: File follow-up issues for non-blocking findings" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    cap = 0
  }
' "$wf" >"$script"
if ! grep -q 'ai-review-followup' "$script" || ! grep -q 'MERGED' "$script"; then
  echo "FAIL - could not extract the follow-up-filing run block from $wf"
  exit 1
fi

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")   echo "${STATE:-}";;                 # --jq .state -> bare state
  "issue list") printf '%s' "${EXISTING:-}";;      # existing follow-up bodies
  "issue create")
    t=""; for ((i=1;i<=$#;i++)); do [ "${!i}" = "--title" ] && { j=$((i+1)); t="${!j}"; }; done
    echo "CREATE $t" >>"$ACTIONLOG";;
  "label create") : ;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

run_file() {
  # run_file <state> <verdict-json> [existing-bodies]
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export ACTIONLOG="$tmp/act.log" STATE="$1" VERDICT="$2" EXISTING="${3:-}"
  : >"$ACTIONLOG"
  bash "$script" >/dev/null 2>&1
  echo "rc=$?"
}
creates() { grep -c '^CREATE ' "$tmp/act.log" 2>/dev/null || true; }

TWO='{"followups":[{"location":"a.ts:1","note":"guard the null"},{"location":"b.ts:2","note":"rename for clarity"}]}'

run_file MERGED "$TWO" >/dev/null
[ "$(creates)" = "2" ] && pass "merged PR files one issue per follow-up" || fail "merged: expected 2 issues, got $(creates)"

run_file OPEN "$TWO" >/dev/null
[ "$(creates)" = "0" ] && pass "open PR files nothing (only merged PRs)" || fail "open PR filed $(creates) issue(s)"

key1=$(printf '%s|%s' "a.ts:1" "guard the null" | sha1sum | cut -c1-12)
key2=$(printf '%s|%s' "b.ts:2" "rename for clarity" | sha1sum | cut -c1-12)
run_file MERGED "$TWO" "<!-- ai-review-followup:pr7:$key1 --> already there" >/dev/null
[ "$(creates)" = "1" ] && pass "per-finding dedup re-files only the missing follow-up" || fail "partial dedup filed $(creates)"

run_file MERGED "$TWO" "x <!-- ai-review-followup:pr7:$key1 --> y <!-- ai-review-followup:pr7:$key2 --> z" >/dev/null
[ "$(creates)" = "0" ] && pass "full dedup: all findings already filed files nothing" || fail "full dedup filed $(creates)"

run_file MERGED '{"followups":[]}' >/dev/null
[ "$(creates)" = "0" ] && pass "empty follow-ups no-op" || fail "empty followups filed $(creates)"

run_file MERGED '{"blocking":true,"summary":"x"}' >/dev/null
[ "$(creates)" = "0" ] && pass "absent followups key no-op" || fail "absent followups filed $(creates)"

run_file MERGED '{"followups":[{"location":"c.ts:3","note":""},{"location":"d.ts:4","note":"real one"}]}' >/dev/null
[ "$(creates)" = "1" ] && pass "follow-up with empty note is skipped" || fail "empty-note handling filed $(creates)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
