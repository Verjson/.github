#!/usr/bin/env bash
# Pins the merge gate's diff-size-keyed review budget (Verjson/.github#181, ADR
# 0032) by extracting the exact `run:` block of the preflight `classify` step
# from ai-review-merge.yml — single source of truth, so the test can't drift
# from the shipped logic — and executing it against a stubbed `gh`.
#
# Why: on Verjson/verjson-cli-cloud#163 a 1,586-changed-line PR was classified
# into the cheap tier ($0.15). The first pass burned $0.21 and died as
# `error_max_budget_usd`, forcing a ~$0.70 sonnet escalation on a PR whose only
# sin was being large. The selected budget must scale with the diff and remain
# the sole automatic paid-review ceiling.
# Plain bash + awk + jq; no test-framework dependency (runs on the bare pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

# Extract the classify step's run script verbatim (10-space-indented body under
# `run: |`, scoped to `id: classify`). Stop at the next step so a following
# `run: |` can't append unrelated code to the script under test.
script="$tmp/classify.sh"
awk '
  $0 == "        id: classify" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap && $0 ~ /^      - name:/ { exit }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$script"
if ! grep -q 'budget_usd' "$script" || ! grep -q 'out lane ai' "$script"; then
  echo "FAIL - could not extract the classify run block from $wf"
  exit 1
fi

# Fake `gh`. `pr view` → the meta fixture. `api .../files` → the files fixture
# emitted the way `--jq '.[]'` emits it (one object per line), because classify
# re-arrays it with `jq -s .`. `api .../status` → an explicit empty status list:
# falling through to a bare `exit 0` with empty stdout would make the
# release-age probe read as "no data" by accident rather than by fixture.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then cat "$META_FILE"; exit 0; fi
if [ "$1" = "api" ]; then
  case "$*" in
    */files*) jq -c '.[]' "$FILES_FILE"; exit 0 ;;
    */status*) printf '0\n'; exit 0 ;;
  esac
  printf '{}\n'; exit 0
fi
exit 0
GH
chmod +x "$tmp/bin/gh"

# classify <files-json> -> populates $tmp/out.txt with the step's GITHUB_OUTPUT.
classify() {
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export META_FILE="$tmp/meta.json" FILES_FILE="$tmp/files.json"
  export GITHUB_OUTPUT="$tmp/out.txt" GITHUB_EVENT_NAME=pull_request
  printf '%s' '{"labels":[],"title":"a PR","isDraft":false,"author":{"login":"human"},"headRefOid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","baseRefName":"main"}' >"$META_FILE"
  printf '%s' "$1" >"$FILES_FILE"
  : >"$GITHUB_OUTPUT"
  if ! bash "$script" >/dev/null 2>&1; then
    fail "the extracted classify step exited non-zero"
    return 1
  fi
}
out_of() { awk -F= -v k="$1" '$1==k{v=substr($0,length(k)+2)} END{print v}' "$tmp/out.txt"; }

# Build a files payload: files <count> <changes-each> <name-prefix>
files_json() {
  jq -nc --argjson n "$1" --argjson c "$2" --arg p "$3" \
    '[range($n) | {filename: ($p + (.|tostring) + ".ts"), changes: $c, status: "modified", patch: "@@ -1 +1 @@\n-a\n+b"}]'
}

# 1. Small non-sensitive diff uses the organization-wide first-pass policy.
classify "$(files_json 2 20 'src/small')"
[ "$(out_of budget_usd)" = "1.00" ] && [ "$(out_of model)" = "claude-haiku-4-5" ] &&
  pass "small non-sensitive diff uses Haiku 4.5 with the \$1.00 cap" ||
  fail "small non-sensitive budget/model wrong (budget=$(out_of budget_usd) model=$(out_of model))"

# 2. Large non-sensitive diffs use the same bounded first pass.
classify "$(files_json 8 200 'src/big')"   # 1,600 changed lines
big="$(out_of budget_usd)"
[ "$big" = "1.00" ] && [ "$(out_of model)" = "claude-haiku-4-5" ] &&
  pass "large non-sensitive diff uses Haiku 4.5 with the \$1.00 cap" ||
  fail "large non-sensitive first-pass policy wrong (budget=\$${big:-<unset>} model=$(out_of model))"

# 3. Sensitive paths remain classified but use the same default first pass.
classify "$(files_json 8 200 'src/auth/big')"
sbig="$(out_of budget_usd)"
{ [ "$(out_of model)" = "claude-haiku-4-5" ] && [ "$sbig" = "1.00" ] &&
  [ "$(out_of sensitive)" = "true" ]; } &&
  pass "large sensitive diff is classified and uses the bounded Haiku first pass" ||
  fail "large sensitive diff wrong (model=$(out_of model) budget=\$${sbig:-<unset>})"

# 4. Small sensitive diffs use the same default first pass.
classify "$(files_json 1 30 'src/auth/small')"
[ "$(out_of budget_usd)" = "1.00" ] && [ "$(out_of model)" = "claude-haiku-4-5" ] &&
  pass "small sensitive diff uses Haiku 4.5 with the \$1.00 cap" ||
  fail "small sensitive budget/model wrong (budget=$(out_of budget_usd) model=$(out_of model))"

# ---------------------------------------------------------------------------
# Part 2 — the terminal outcome. When the paid pass runs out of budget, the
# gate must present a legible `budget-exceeded` outcome that requests human
# review, and it must stay fail-closed: block the merge, never approve.
# ---------------------------------------------------------------------------

submit="$tmp/submit.sh"
awk '
  $0 == "      - name: Submit deterministic PR review" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap && $0 ~ /^      - name:/ { exit }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$submit"
grep -q 'Review these first' "$submit" || { echo "FAIL - could not extract the submit run block from $wf"; exit 1; }

# Fake `gh` for the submit block: log every action, capture bodies. `pr merge`
# is logged too — the fail-closed assertion is that it is never reached.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
args=("$@"); body=""
for ((i=0;i<${#args[@]};i++)); do [ "${args[$i]}" = "--body" ] && body="${args[$((i+1))]}"; done
case "$1 $2" in
  "pr review")  echo "REVIEW ${args[*]}" >>"$ACTIONLOG"; printf '%s' "$body" >"$BODYFILE" ;;
  "pr comment") echo "COMMENT" >>"$ACTIONLOG"; printf '%s' "$body" >"$COMMENTFILE" ;;
  "pr edit")    echo "EDIT ${args[*]}" >>"$ACTIONLOG" ;;
  "pr merge")   echo "MERGE" >>"$ACTIONLOG" ;;
  "api --paginate") printf '[]' ;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

# The run id Actions always injects. The approval body embeds it as the
# `ai-review-run:` marker, and the step runs under `set -u`, so omitting it here
# killed the approve path before any `gh` call and made the recovered-verdict
# case look like a production regression (#251). It is fixture, not workaround:
# case 9a asserts the marker actually reaches the body, and case 9b asserts that
# an absent run id still fails CLOSED.
GATE_RUN_ID=4242424242

# run_submit <verdict> <budget_exhausted> -> prints rc=N
run_submit() {
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export HEAD_SHA=deadbeef MODEL=claude-haiku-4-5 PATCH_ID=pid00feed
  export ACTIONLOG="$tmp/act.log" BODYFILE="$tmp/body.txt" COMMENTFILE="$tmp/comment.txt"
  export GITHUB_OUTPUT="$tmp/gh_output.txt"
  if [ -n "$GATE_RUN_ID" ]; then export GITHUB_RUN_ID="$GATE_RUN_ID"; else unset GITHUB_RUN_ID; fi
  : >"$ACTIONLOG"; : >"$BODYFILE"; : >"$COMMENTFILE"; : >"$GITHUB_OUTPUT"
  export VERDICT="$1" BUDGET_EXHAUSTED="$2" CHANGED_LINES="${3-1586}" BUDGET_USD="${4-0.60}"
  bash -eo pipefail "$submit" >/dev/null 2>&1
  echo "rc=$?"
}
comment_has() { grep -qF "$1" "$tmp/comment.txt"; }
act_has() { grep -q "$1" "$tmp/act.log"; }

# 6. Budget-exhausted with no verdict: blocked (exit 1), never merged, and the
#    posted comment names budget exhaustion and asks for a human — not an
#    opaque `error_max_budget_usd`.
rc=$(run_submit '' true)
{ [ "$rc" = "rc=1" ] && ! act_has approve && act_has COMMENT && comment_has 'budget'; } &&
  pass "budget-exceeded: blocks the merge and posts a comment" ||
  fail "budget-exceeded must block and comment ($rc, log=$(tr '\n' ',' <"$tmp/act.log"))"

{ comment_has 'budget-exceeded' && comment_has '1586' && comment_has '0.60'; } &&
  pass "budget-exceeded: comment names the outcome, the diff size and the cap" ||
  fail "budget-exceeded comment must name the outcome/diff size/cap, got: $(head -c 400 "$tmp/comment.txt")"

comment_has 'not' && act_has 'EDIT.*ai-review-inconclusive' &&
  pass "budget-exceeded: still labels the PR inconclusive and says it was not merged" ||
  fail "budget-exceeded must keep the inconclusive label and the not-merged statement"

# 6d. The empty verdict is the shape the workflow actually produces when every
#     pass returns no structured_output. Whitespace-only and the JSON literals
#     that `jq -e` treats specially must land in the same fail-closed branch —
#     `jq -e` exits 0 on empty input, which is how this fell through to
#     `--approve` before #181.
for v in '' '   ' '
' 'null' 'false' '{}' '{"blocking":"true"}' '{"blocking":null}' '[]'; do
  rc=$(run_submit "$v" false)
  { [ "$rc" = "rc=1" ] && ! act_has 'approve' && act_has COMMENT; } ||
    fail "verdict [$v] must fail closed without approving ($rc, log=$(tr '\n' ',' <"$tmp/act.log"))"
done
pass "blank/whitespace/null/false/{}/[]/wrong-typed verdicts all fail closed, none approve"

# 7. Fail-open trap: a garbage/unset BUDGET_EXHAUSTED must never soften the
#    outcome. Any non-`true` value falls back to the generic no-verdict text and
#    the PR is still blocked.
for flag in '' 'false' 'yes' 'null' '1'; do
  rc=$(run_submit 'not-json' "$flag")
  { [ "$rc" = "rc=1" ] && ! act_has approve && act_has COMMENT; } ||
    fail "no-verdict with BUDGET_EXHAUSTED='$flag' must still block and comment ($rc)"
done
pass "no-verdict stays fail-closed for every BUDGET_EXHAUSTED value ('' false yes null 1)"

# 8. A malformed size/cap must not abort the fail-closed comment (unset
#    CHANGED_LINES/BUDGET_USD is what a skipped upstream step produces).
rc=$(run_submit '' true '' '')
{ [ "$rc" = "rc=1" ] && act_has COMMENT && ! act_has approve; } &&
  pass "budget-exceeded survives empty CHANGED_LINES/BUDGET_USD and still blocks" ||
  fail "empty CHANGED_LINES/BUDGET_USD broke the fail-closed comment ($rc)"

# 9. The flag must not hijack a real verdict: an approving verdict still
#    approves even if a prior pass had been budget-exhausted and recovered.
rc=$(run_submit '{"blocking":false,"summary":"fine","review_first":[],"findings":[],"followups":[]}' true)
{ [ "$rc" = "rc=0" ] && act_has REVIEW; } &&
  pass "a recovered verdict still approves despite the exhaustion flag" ||
  fail "recovered verdict must still approve ($rc, log=$(tr '\n' ',' <"$tmp/act.log"))"

# 9a. That approval must carry the run marker, which is what makes the run id a
#     required part of the environment rather than an incidental one.
grep -qF "ai-review-run:$GATE_RUN_ID" "$tmp/body.txt" &&
  pass "the approval body carries the ai-review-run marker for this run" ||
  fail "approval body lost the ai-review-run:$GATE_RUN_ID marker: $(tail -c 200 "$tmp/body.txt")"

# 9b. Fail-closed direction of the same dependency: if the run id is somehow
#     absent, the step must die rather than approve. `set -u` gives that for
#     free — pinning it stops a later `${GITHUB_RUN_ID:-}` "tidy-up" from
#     silently turning a broken environment into an approval.
GATE_RUN_ID=''
rc=$(run_submit '{"blocking":false,"summary":"fine","review_first":[],"findings":[],"followups":[]}' false)
{ [ "$rc" != "rc=0" ] && ! act_has approve; } &&
  pass "an absent run id fails closed instead of approving" ||
  fail "missing GITHUB_RUN_ID must not approve ($rc, log=$(tr '\n' ',' <"$tmp/act.log"))"
GATE_RUN_ID=4242424242

# ---------------------------------------------------------------------------
# Part 3 — detection + legibility. `error_max_budget_usd` is emitted by the
# third-party action as a failure-level annotation even when a later pass
# recovers (this is what made verjson-cli-cloud#163 unreadable: a recovered
# first pass left a red annotation that looked like the cause of the failure).
# The gate must classify the outcome itself and say so in plain words.
# ---------------------------------------------------------------------------

outcome="$tmp/outcome.sh"
awk '
  $0 == "      - name: Record single-pass model outcome" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap && $0 ~ /^      - name:/ { exit }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$outcome"
grep -q 'phase=model' "$outcome" || { echo "FAIL - could not extract the retry-outcome run block from $wf"; exit 1; }

exec_file() { # exec_file <path> <subtype>
  jq -n --arg s "$2" '[{type:"system",subtype:"init"},{type:"result",subtype:$s,is_error:true,total_cost_usd:0.206,num_turns:18}]' >"$1"
}

# #637 replaces the historical escalation chain with one paid pass. Exercise
# the extracted diagnostic using exactly that one transcript.
run_single_outcome() {
  export GITHUB_OUTPUT="$tmp/outcome_out.txt" STARTED_EPOCH=1
  export EXEC_FILE="$1" FIRST_VERDICT="$2" MODEL_CONCLUSION="${3:-success}"
  : >"$GITHUB_OUTPUT"
  bash "$outcome" >"$tmp/outcome.log" 2>&1
  echo "rc=$?"
}
oout() { awk -F= -v k="$1" '$1==k{v=substr($0,length(k)+2)} END{print v}' "$tmp/outcome_out.txt"; }
olog() { grep -qF "$1" "$tmp/outcome.log"; }

exec_file "$tmp/single-budget.json" error_max_budget_usd
exec_file "$tmp/single-turns.json" error_max_turns
exec_file "$tmp/single-terminal.json" error_during_execution
jq -n '[{type:"result",subtype:"error_max_budget_usd",is_error:true,permission_denials_count:5}]' >"$tmp/single-denied.json"
jq -n '[{type:"result",subtype:"success",is_error:false,permission_denials_count:2}]' >"$tmp/single-success-denied.json"

rc=$(run_single_outcome "$tmp/single-budget.json" false)
{ [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" = true ] &&
  [ "$(oout selected_pass_terminal_error)" = true ] &&
  olog 'no automatic retry is allowed' && olog 'apply re-review'; } \
  && pass 'single budget-exhausted pass fails closed with explicit re-review direction' \
  || fail "single budget exhaustion was not actionable ($rc): $(cat "$tmp/outcome.log")"

rc=$(run_single_outcome "$tmp/single-turns.json" false)
{ [ "$rc" = "rc=0" ] && [ "$(oout turns_exhausted)" = true ] &&
  [ "$(oout budget_exhausted)" = false ] && olog 'no automatic retry is allowed'; } \
  && pass 'single turn-exhausted pass is distinct and cannot auto-escalate' \
  || fail "single turn exhaustion was misclassified ($rc): $(cat "$tmp/outcome.log")"

rc=$(run_single_outcome "$tmp/single-terminal.json" true)
{ [ "$rc" = "rc=0" ] && [ "$(oout selected_pass_terminal_error)" = true ]; } \
  && pass 'terminal SDK result invalidates schema-valid filler' \
  || fail 'terminal SDK result did not invalidate the apparent verdict'

rc=$(run_single_outcome "$tmp/single-denied.json" false)
{ [ "$rc" = "rc=0" ] && [ "$(oout permission_denials)" = 5 ] &&
  olog 'denied tool calls prevented useful progress' && olog 'Align the prompt and allowedTools'; } \
  && pass 'permission-denial non-progress is distinguished from oversized-diff exhaustion' \
  || fail "permission denials were not actionable: $(cat "$tmp/outcome.log")"

rc=$(run_single_outcome "$tmp/single-success-denied.json" true)
{ [ "$rc" = "rc=0" ] && [ "$(oout selected_pass_terminal_error)" = false ] &&
  ! olog 'permission_denials=2 outcome=blocked'; } \
  && pass 'incidental permission denials do not contradict a usable successful verdict' \
  || fail "successful verdict was falsely reported blocked: $(cat "$tmp/outcome.log")"

rc=$(run_single_outcome '' true)
{ [ "$rc" = "rc=0" ] && [ "$(oout selected_pass_terminal_error)" = true ] &&
  olog 'terminal-evidence-missing outcome=blocked'; } \
  && pass 'a purported verdict without terminal evidence fails closed' \
  || fail 'missing terminal evidence could authorize a purported verdict'

rc=$(run_single_outcome '' false skipped)
olog 'automatic_paid_attempts=0' \
  && pass 'unchanged-patch model skip records zero paid attempts' \
  || fail 'unchanged-patch model skip overcounted paid attempts'

while IFS= read -r detector; do
  [ -n "$detector" ] || continue
  grep -qF "$detector" "$wf" \
    && pass "cheap-lane detector remains fail-closed (${detector:0:40}…)" \
    || fail "cheap-lane detector was changed (${detector:0:40}…)"
done <<'DETECTORS'
if jq -e 'all(.[]; .status == "removed")'
if jq -e 'all(.[]; (.patch // "") | test("^@@
if jq -e '[.[].filename] | all(test("(^NEXT
DETECTORS

if [ "$fails" -eq 0 ]; then echo 'All tests passed.'; exit 0; fi
echo "$fails test(s) failed."
exit 1
