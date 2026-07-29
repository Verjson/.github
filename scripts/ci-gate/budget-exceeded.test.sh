#!/usr/bin/env bash
# Pins the merge gate's diff-size-keyed review budget (Verjson/.github#181, ADR
# 0032) by extracting the exact `run:` block of the preflight `classify` step
# from ai-review-merge.yml — single source of truth, so the test can't drift
# from the shipped logic — and executing it against a stubbed `gh`.
#
# Why: on Verjson/verjson-cli-cloud#163 a 1,586-changed-line PR was classified
# into the cheap tier ($0.15). The first pass burned $0.21 and died as
# `error_max_budget_usd`, forcing a ~$0.70 sonnet escalation on a PR whose only
# sin was being large. The budget must scale with the diff, and must stay
# strictly below the $1.00 escalation cap so escalation is still a step up.
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
  bash "$script" >/dev/null 2>&1
}
out_of() { awk -F= -v k="$1" '$1==k{v=substr($0,length(k)+2)} END{print v}' "$tmp/out.txt"; }

# Build a files payload: files <count> <changes-each> <name-prefix>
files_json() {
  jq -nc --argjson n "$1" --argjson c "$2" --arg p "$3" \
    '[range($n) | {filename: ($p + (.|tostring) + ".ts"), changes: $c, status: "modified", patch: "@@ -1 +1 @@\n-a\n+b"}]'
}

# 1. Small non-sensitive diff keeps the cheap floor.
classify "$(files_json 2 20 'src/small')"
[ "$(out_of budget_usd)" = "0.15" ] && [ "$(out_of model)" = "claude-haiku-4-5" ] &&
  pass "small non-sensitive diff keeps the \$0.15 cheap tier" ||
  fail "small non-sensitive budget/model wrong (budget=$(out_of budget_usd) model=$(out_of model))"

# 2. The #163 case: a large non-sensitive diff must NOT be given the cheap floor
#    it demonstrably exhausts.
classify "$(files_json 8 200 'src/big')"   # 1,600 changed lines
big="$(out_of budget_usd)"
[ -n "$big" ] && awk -v b="$big" 'BEGIN{exit !(b > 0.15)}' &&
  pass "large non-sensitive diff (1600 lines) is raised above the cheap floor (got \$$big)" ||
  fail "large diff must get a bigger first-pass budget than \$0.15 (got \$${big:-<unset>}) — this is the #163 exhaustion"

# 3. The raised budget must stay strictly under the $1.00 escalation cap, or
#    escalation stops being an escalation.
[ -n "$big" ] && awk -v b="$big" 'BEGIN{exit !(b < 1.00)}' &&
  pass "large-diff budget stays below the \$1.00 escalation cap" ||
  fail "large-diff budget must stay < \$1.00 (got \$${big:-<unset>})"

# 4. Sensitive paths keep their stronger model and are also size-scaled, still
#    under the escalation cap.
classify "$(files_json 8 200 'src/auth/big')"
sbig="$(out_of budget_usd)"
{ [ "$(out_of model)" = "claude-sonnet-5" ] && [ -n "$sbig" ] &&
  awk -v b="$sbig" 'BEGIN{exit !(b > 0.50 && b < 1.00)}'; } &&
  pass "large sensitive diff keeps sonnet and is size-scaled under the cap (got \$$sbig)" ||
  fail "large sensitive diff wrong (model=$(out_of model) budget=\$${sbig:-<unset>})"

# 5. Small sensitive diff keeps its documented $0.50 floor (no accidental bump).
classify "$(files_json 1 30 'src/auth/small')"
[ "$(out_of budget_usd)" = "0.50" ] && [ "$(out_of model)" = "claude-sonnet-5" ] &&
  pass "small sensitive diff keeps the \$0.50 floor" ||
  fail "small sensitive budget/model wrong (budget=$(out_of budget_usd) model=$(out_of model))"

# ---------------------------------------------------------------------------
# Part 2 — the terminal outcome. When every pass still ran out of budget, the
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
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

# run_submit <verdict> <budget_exhausted> -> prints rc=N
run_submit() {
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export HEAD_SHA=deadbeef MODEL=claude-haiku-4-5 PATCH_ID=pid00feed
  export ACTIONLOG="$tmp/act.log" BODYFILE="$tmp/body.txt" COMMENTFILE="$tmp/comment.txt"
  export GITHUB_OUTPUT="$tmp/gh_output.txt"
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

# ---------------------------------------------------------------------------
# Part 3 — detection + legibility. `error_max_budget_usd` is emitted by the
# third-party action as a failure-level annotation even when a later pass
# recovers (this is what made verjson-cli-cloud#163 unreadable: a recovered
# first pass left a red annotation that looked like the cause of the failure).
# The gate must classify the outcome itself and say so in plain words.
# ---------------------------------------------------------------------------

outcome="$tmp/outcome.sh"
awk '
  $0 == "      - name: Record model retry outcome" { seen = 1 }
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

# run_outcome <exec1> <exec2> <exec3> <first_verdict> <retry1_verdict> <retry2_verdict>
run_outcome() {
  export GITHUB_OUTPUT="$tmp/outcome_out.txt" STARTED_EPOCH=1
  export EXEC_FILE_1="$1" EXEC_FILE_2="$2" EXEC_FILE_3="$3"
  export FIRST_VERDICT="$4" RETRY1_VERDICT="$5" RETRY2_VERDICT="$6"
  export RETRY1_CONCLUSION=success RETRY2_CONCLUSION=skipped
  : >"$GITHUB_OUTPUT"
  bash "$outcome" >"$tmp/outcome.log" 2>&1
  echo "rc=$?"
}
oout() { awk -F= -v k="$1" '$1==k{v=substr($0,length(k)+2)} END{print v}' "$tmp/outcome_out.txt"; }
olog() { grep -qF "$1" "$tmp/outcome.log"; }

exec_file "$tmp/e_budget.json" error_max_budget_usd
exec_file "$tmp/e_flake.json"  error_max_structured_output_retries
printf 'not json at all' >"$tmp/e_bad.json"

# 10. The #163 shape: cheap pass exhausted its budget, escalation recovered.
#     Detected as exhaustion, and the log must say it was RECOVERED so the red
#     `error_max_budget_usd` annotation is not read as the failure cause.
rc=$(run_outcome "$tmp/e_budget.json" "" "" false true false)
{ [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" = "true" ] && olog 'budget_exhausted=true' && olog 'recovered'; } &&
  pass "recovered budget exhaustion is detected and explained as recovered" ||
  fail "recovered exhaustion not detected/explained ($rc exhausted=$(oout budget_exhausted)): $(cat "$tmp/outcome.log")"

# 11. Every pass exhausted and none recovered -> exhausted, and NOT reported as
#     recovered (that flag is what the submit step turns into its comment).
rc=$(run_outcome "$tmp/e_budget.json" "$tmp/e_budget.json" "$tmp/e_budget.json" false false false)
{ [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" = "true" ] && ! olog 'recovered'; } &&
  pass "unrecovered budget exhaustion is detected and not called recovered" ||
  fail "unrecovered exhaustion wrong ($rc exhausted=$(oout budget_exhausted)): $(cat "$tmp/outcome.log")"

# 12. A structured-output flake is NOT a budget problem — mislabelling it would
#     tell a maintainer to split a PR that is not too big.
rc=$(run_outcome "$tmp/e_flake.json" "$tmp/e_flake.json" "" false false false)
{ [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" != "true" ]; } &&
  pass "a structured-output flake is not reported as budget exhaustion" ||
  fail "flake misreported as budget exhaustion ($rc exhausted=$(oout budget_exhausted))"

# 13. Missing / unparseable / unset execution files must degrade to "not a
#     budget problem" without aborting: this step is `always()` telemetry and
#     must never be the thing that fails the gate, and a false `true` here would
#     put a misleading budget-exceeded comment on an ordinary failure.
printf '[1,2,3]' >"$tmp/e_scalars.json"        # valid JSON, wrong shape
printf '{"type":"result"}' >"$tmp/e_nosub.json" # result message, no subtype
printf '' >"$tmp/e_empty.json"                  # zero-byte transcript
for f in "" "$tmp/does-not-exist.json" "$tmp/e_bad.json" "$tmp/e_scalars.json" "$tmp/e_nosub.json" "$tmp/e_empty.json"; do
  rc=$(run_outcome "$f" "$f" "$f" false false false)
  { [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" != "true" ]; } ||
    fail "execution file '$f' must degrade to non-exhausted without failing ($rc exhausted=$(oout budget_exhausted))"
done
pass "missing/unset/unparseable/wrong-shape/empty execution files degrade safely to non-exhausted"

# 13a. Exhaustion in ANY pass counts, not just the first — the escalations use
#      the same subtype and a later exhaustion is the one that blocks.
rc=$(run_outcome "$tmp/e_flake.json" "$tmp/e_bad.json" "$tmp/e_budget.json" false false false)
{ [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" = "true" ]; } &&
  pass "exhaustion detected in a later pass, alongside a flake and a bad transcript" ||
  fail "later-pass exhaustion missed ($rc exhausted=$(oout budget_exhausted))"

# 14. Clean run, no exhaustion anywhere.
rc=$(run_outcome "" "" "" true false false)
{ [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" != "true" ] && ! olog 'recovered'; } &&
  pass "a clean first pass reports no budget exhaustion" ||
  fail "clean run misreported ($rc exhausted=$(oout budget_exhausted))"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; else echo "$fails test(s) failed."; exit 1; fi
