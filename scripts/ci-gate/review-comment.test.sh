#!/usr/bin/env bash
# Tests the merge gate's "Submit deterministic PR review" step by extracting its
# exact `run:` block from ai-review-merge.yml (single source of truth — no drift)
# and driving it against a stubbed `gh`. Guards the review-comment rendering,
# specifically the ADR-0007 "👀 Review these first" pinpointing block, plus the
# blocking / approve / no-verdict paths. Plain bash + awk + jq; no dependency.
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

script="$tmp/submit.sh"
awk '
  $0 == "      - name: Submit deterministic PR review" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    cap = 0
  }
' "$wf" >"$script"
if ! grep -q 'Review these first' "$script"; then
  echo "FAIL - could not extract the submit run block (or the pinpoint render is gone) from $wf"
  exit 1
fi

# Fake gh: captures the --body of whichever call is made, logs the action.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
args=("$@"); body=""
for ((i=0;i<${#args[@]};i++)); do [ "${args[$i]}" = "--body" ] && body="${args[$((i+1))]}"; done
case "$1 $2" in
  "pr review")
    echo "REVIEW ${args[*]}" >>"$ACTIONLOG"; printf '%s' "$body" >"$BODYFILE"
    [ "${REVIEW_FAIL:-0}" = "1" ] && { echo "Can not approve your own pull request" >&2; exit 1; }
    ;;
  "pr comment") echo "COMMENT" >>"$ACTIONLOG"; printf '%s' "$body" >"$COMMENTFILE" ;;
  "pr edit") echo "EDIT ${args[*]}" >>"$ACTIONLOG" ;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

run_submit() {
  # run_submit <verdict-json>
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7 HEAD_SHA=deadbeef MODEL=haiku
  export ACTIONLOG="$tmp/act.log" BODYFILE="$tmp/body.txt" COMMENTFILE="$tmp/comment.txt"
  export GITHUB_OUTPUT="$tmp/gh_output.txt" # the runner provides this; the step writes the verdict here
  : >"$ACTIONLOG"
  : >"$BODYFILE"
  : >"$COMMENTFILE"
  : >"$GITHUB_OUTPUT"
  export VERDICT="$1"
  bash "$script" >/dev/null 2>&1
  echo "rc=$?"
}
body_has() { grep -qF "$1" "$tmp/body.txt"; }
comment_has() { grep -qF "$1" "$tmp/comment.txt"; }
act_has() { grep -q "$1" "$tmp/act.log"; }
output_has() { grep -qF "$1" "$tmp/gh_output.txt"; }

# 1. Approve + review_first -> the pinpoint block renders in the review body.
run_submit '{"blocking":false,"summary":"looks good","review_first":[{"location":"auth.ts:42","why":"gates the admin path"}],"findings":[]}' >/dev/null
{ body_has '👀 Review these first' && body_has 'auth.ts:42' && body_has 'gates the admin path'; } &&
  pass "approve: review_first renders as a pinpoint block" ||
  fail "approve: review_first not rendered"

# 1b. Approve + followups -> renders a Follow-ups block AND emits the verdict to
#     $GITHUB_OUTPUT (so ai-merge can file the issues on merge).
run_submit '{"blocking":false,"summary":"ok","review_first":[],"followups":[{"location":"util.ts:9","note":"missing null guard"}],"findings":[]}' >/dev/null
{ body_has 'Follow-ups' && body_has 'util.ts:9' && body_has 'missing null guard' && output_has 'verdict<<' && output_has 'missing null guard'; } &&
  pass "approve: followups render and the verdict is emitted for ai-merge" ||
  fail "approve: followups render / verdict-output missing"

# 2. Approve + empty review_first -> summary only, no pinpoint header.
run_submit '{"blocking":false,"summary":"trivial docs tweak","review_first":[],"findings":[]}' >/dev/null
{ body_has 'trivial docs tweak' && ! body_has 'Review these first'; } &&
  pass "approve: empty review_first omits the pinpoint block" ||
  fail "approve: empty review_first still rendered a block"

# 3. Blocking -> request-changes body carries both pinpoint + findings; exit 1.
rc=$(run_submit '{"blocking":true,"summary":"has a bug","review_first":[{"location":"x.ts:1","why":"the mutation"}],"findings":["x.ts:1 — off-by-one"]}')
{ [ "$rc" = "rc=1" ] && body_has 'Review these first' && body_has 'x.ts:1 — off-by-one'; } &&
  pass "blocking: pinpoint + findings render and step exits 1" ||
  fail "blocking path wrong ($rc)"

# 4. Blocking on own PR (request-changes rejected) -> falls back to a comment.
rc=$(REVIEW_FAIL=1 run_submit '{"blocking":true,"summary":"bug","review_first":[],"findings":["a:1 — boom"]}')
{ [ "$rc" = "rc=1" ] && comment_has 'Merge gate: blocking verdict' && comment_has 'a:1 — boom'; } &&
  pass "blocking on own PR falls back to a findings comment, still exits 1" ||
  fail "blocking own-PR fallback wrong ($rc)"

# 5. No usable verdict -> inconclusive label + comment + exit 1 (fail closed).
rc=$(run_submit 'not-json')
{ [ "$rc" = "rc=1" ] && act_has EDIT && comment_has 'review could not complete'; } &&
  pass "no verdict: labels inconclusive, comments, exits 1 (fail closed)" ||
  fail "no-verdict path wrong ($rc)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
