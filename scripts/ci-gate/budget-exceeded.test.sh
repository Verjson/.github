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

# ---------------------------------------------------------------------------
# Part 4 — the WIRING, not just the loop (#293). Part 3 hands the probe three
# distinct fixture paths, so it can only ever prove the loop works. On PR #288
# the loop was fine and the gate still reported `budget_exhausted=false` for a
# run whose first pass died `error_max_budget_usd`, because every `EXEC_FILE_N`
# expression resolved to the ONE fixed path claude-code-action writes, and each
# pass overwrote the last. These cases therefore resolve `EXEC_FILE_N` from the
# workflow's own env block and replay the passes in order against that single
# fixed path — the shape of the real job, which is the only place the bug lives.
# ---------------------------------------------------------------------------

export RUNNER_TEMP="$tmp/runner-temp"
mkdir -p "$RUNNER_TEMP"
# The one path claude-code-action writes for every pass. It is `$RUNNER_TEMP`
# scoped and stable across steps in a job, which is why the overwrite is
# deterministic rather than flaky.
fixed_exec="$RUNNER_TEMP/claude-execution-output.json"

# The literal `EXEC_FILE_<N>:` expression from the retry-outcome step's env
# block, with the runner context resolved the way Actions would: `runner.temp`
# becomes the temp dir, and ANY `steps.<id>.outputs.execution_file` becomes the
# single fixed path the action really emits.
exec_file_wiring() {
  awk -v key="EXEC_FILE_$1:" '
    $0 == "      - name: Record model retry outcome" { seen = 1 }
    seen && $1 == key { $1 = ""; sub(/^ +/, ""); print; exit }
  ' "$wf" |
    sed -e "s|\${{ runner.temp }}|$RUNNER_TEMP|g" \
      -e "s|\${{ *steps\.[A-Za-z_0-9]*\.outputs\.execution_file *}}|$fixed_exec|g"
}

wire1="$(exec_file_wiring 1)"; wire2="$(exec_file_wiring 2)"; wire3="$(exec_file_wiring 3)"
{ [ -n "$wire1" ] && [ -n "$wire2" ] && [ -n "$wire3" ]; } ||
  { echo "FAIL - could not read EXEC_FILE_1/2/3 from the retry-outcome env block"; exit 1; }

# The per-pass snapshot step's run block, extracted by step name. Absent (or
# renamed) leaves an empty script, which replays as "nothing was snapshotted" —
# i.e. exactly the #293 behaviour, so the case below fails rather than errors.
extract_run_block() { # extract_run_block <step-name> <outfile>
  awk -v want="      - name: $1" '
    $0 == want { seen = 1 }
    seen && $0 == "        run: |" { cap = 1; next }
    cap && $0 ~ /^      - name:/ { exit }
    cap {
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      if ($0 ~ /^[ \t]*$/) { print ""; next }
      exit
    }
  ' "$wf" >"$2"
}
for n in 1 2 3; do
  extract_run_block "Snapshot pass $n execution transcript (#293)" "$tmp/snapshot$n.sh"
done

# Where pass N's snapshot step is configured to write, read from the workflow
# rather than assumed here — otherwise the replay could "prove" a wiring the
# gate does not actually have.
snapshot_dest() { # snapshot_dest <n>
  awk -v want="      - name: Snapshot pass $1 execution transcript (#293)" '
    $0 == want { seen = 1; next }
    seen && $0 ~ /^      - name:/ { exit }
    seen && $1 == "DEST:" { $1 = ""; sub(/^ +/, ""); print; exit }
  ' "$wf" | sed -e "s|\${{ runner.temp }}|$RUNNER_TEMP|g"
}
dest1="$(snapshot_dest 1)"; dest2="$(snapshot_dest 2)"; dest3="$(snapshot_dest 3)"

# One model pass, the way the job runs it: the action writes its transcript to
# the fixed path (or, for a skipped pass, writes nothing and reports an empty
# `execution_file`), and the snapshot step for that pass runs straight after,
# into the destination the workflow gives it.
replay_pass() { # replay_pass <n> <subtype|"">
  local n="$1" subtype="$2" src="" dest
  eval "dest=\$dest$n"
  if [ -n "$subtype" ]; then exec_file "$fixed_exec" "$subtype"; src="$fixed_exec"; fi
  { [ -s "$tmp/snapshot$n.sh" ] && [ -n "$dest" ]; } || return 0
  SRC="$src" DEST="$dest" bash "$tmp/snapshot$n.sh" >>"$tmp/snapshot.log" 2>&1
}

# 15. The #288/#293 ordering: pass 1 exhausts the budget, both escalations then
#     fail as structured-output flakes and overwrite the transcript. The run is
#     still a budget-exceeded outcome and must be reported as one — that message
#     is the only one that names the cap, the diff size and the split advice.
rm -f "$fixed_exec" "$RUNNER_TEMP"/claude-execution-pass-*.json
: >"$tmp/snapshot.log"
replay_pass 1 error_max_budget_usd
replay_pass 2 error_max_structured_output_retries
replay_pass 3 error_max_structured_output_retries
rc=$(run_outcome "$wire1" "$wire2" "$wire3" false false false)
{ [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" = "true" ]; } &&
  pass "a first-pass budget failure survives two overwriting flake passes (#293)" ||
  fail "first-pass budget failure lost to later passes ($rc exhausted=$(oout budget_exhausted)) — EXEC_FILE_1/2/3 resolved to [$wire1] [$wire2] [$wire3]"

# 16. The invariant behind case 15, pinned directly: three passes need three
#     destinations. Any two sharing a path is the #293 bug returning.
{ [ "$wire1" != "$wire2" ] && [ "$wire2" != "$wire3" ] && [ "$wire1" != "$wire3" ]; } &&
  pass "EXEC_FILE_1/2/3 resolve to three distinct per-pass paths" ||
  fail "EXEC_FILE_1/2/3 must not alias: [$wire1] [$wire2] [$wire3]"

# 16b. Each snapshot must sit between its own pass and the next one. The replay
#      drives passes in order itself, so without this a snapshot hoisted next to
#      the following pass copies a transcript that pass already overwrote — the
#      #293 outage restored, with every other assertion still green.
line_of() { grep -n "$1" "$wf" | head -n 1 | cut -d: -f1; }
pass_line1="$(line_of '^        id: claude$')"
pass_line2="$(line_of '^        id: claude_retry$')"
pass_line3="$(line_of '^        id: claude_retry2$')"
snap_line1="$(line_of '^      - name: Snapshot pass 1 execution transcript')"
snap_line2="$(line_of '^      - name: Snapshot pass 2 execution transcript')"
snap_line3="$(line_of '^      - name: Snapshot pass 3 execution transcript')"
order_ok=true
for v in "$pass_line1" "$pass_line2" "$pass_line3" "$snap_line1" "$snap_line2" "$snap_line3"; do
  [ -n "$v" ] || order_ok=false
done
if [ "$order_ok" = true ]; then
  { [ "$pass_line1" -lt "$snap_line1" ] && [ "$snap_line1" -lt "$pass_line2" ] &&
    [ "$pass_line2" -lt "$snap_line2" ] && [ "$snap_line2" -lt "$pass_line3" ] &&
    [ "$pass_line3" -lt "$snap_line3" ]; } || order_ok=false
fi
[ "$order_ok" = true ] &&
  pass "each snapshot runs after its own pass and before the next one" ||
  fail "a snapshot step is out of order — it would capture a transcript a later pass overwrote"

# 16a. …and each snapshot must write to the path its own pass is read from.
#      Distinct-but-misconnected is the same outage with extra steps.
{ [ "$dest1" = "$wire1" ] && [ "$dest2" = "$wire2" ] && [ "$dest3" = "$wire3" ]; } &&
  pass "each snapshot destination is the EXEC_FILE the probe reads for that pass" ||
  fail "snapshot destinations do not match the probe inputs: [$dest1|$wire1] [$dest2|$wire2] [$dest3|$wire3]"

# 17. All three snapshot steps must exist and run the same block, so the cases
#     here (which replay one block per pass) really do cover all three.
{ [ -s "$tmp/snapshot1.sh" ] && cmp -s "$tmp/snapshot1.sh" "$tmp/snapshot2.sh" &&
  cmp -s "$tmp/snapshot1.sh" "$tmp/snapshot3.sh"; } &&
  pass "each model pass has a snapshot step and all three run identical logic" ||
  fail "snapshot steps missing or divergent (sizes: $(wc -c <"$tmp/snapshot1.sh") $(wc -c <"$tmp/snapshot2.sh") $(wc -c <"$tmp/snapshot3.sh"))"

# 18. The snapshot is `always()` bookkeeping and must be `continue-on-error`, or
#     a failed copy becomes a failed gate — telemetry deciding merges is exactly
#     the inversion this change exists to avoid.
snap_guard_ok=true
for n in 1 2 3; do
  awk -v want="      - name: Snapshot pass $n execution transcript (#293)" '
    $0 == want { seen = 1; next }
    seen && $0 ~ /^      - name:/ { exit }
    seen { print }
  ' "$wf" >"$tmp/snapmeta$n.txt"
  grep -q 'continue-on-error: true' "$tmp/snapmeta$n.txt" || snap_guard_ok=false
  grep -qx "        if: always() && needs.preflight.outputs.lane == 'ai'" "$tmp/snapmeta$n.txt" || snap_guard_ok=false
done
[ "$snap_guard_ok" = true ] &&
  pass "every snapshot step is always() and continue-on-error" ||
  fail "a snapshot step is missing always() or continue-on-error and could fail the gate"

# 19. A skipped pass must not inherit a stale transcript. On the persistent
#     self-hosted pool a leftover file at the destination would be read as this
#     pass's outcome and could invent a budget failure that never happened.
rm -f "$fixed_exec" "$RUNNER_TEMP"/claude-execution-pass-*.json
exec_file "$RUNNER_TEMP/claude-execution-pass-2.json" error_max_budget_usd  # stale
replay_pass 1 error_max_structured_output_retries
replay_pass 2 ""   # escalation skipped: no transcript, empty execution_file
replay_pass 3 ""
rc=$(run_outcome "$wire1" "$wire2" "$wire3" false false false)
{ [ "$rc" = "rc=0" ] && [ "$(oout budget_exhausted)" != "true" ] &&
  [ ! -e "$RUNNER_TEMP/claude-execution-pass-2.json" ]; } &&
  pass "a skipped pass drops its stale transcript instead of inheriting it" ||
  fail "stale transcript survived a skipped pass ($rc exhausted=$(oout budget_exhausted))"

# 20. A copy that cannot happen must degrade the message, never the gate: an
#     unreadable source and an unwritable destination both exit 0.
rm -f "$fixed_exec"
mkdir -p "$tmp/nowrite"; chmod 500 "$tmp/nowrite"
exec_file "$fixed_exec" error_max_budget_usd
SRC="$fixed_exec" DEST="$tmp/nowrite/pass.json" bash "$tmp/snapshot1.sh" >/dev/null 2>&1
copy_rc=$?
SRC="$tmp/no-such-transcript.json" DEST="$RUNNER_TEMP/claude-execution-pass-1.json" \
  bash "$tmp/snapshot1.sh" >/dev/null 2>&1
missing_rc=$?
chmod 700 "$tmp/nowrite"
{ [ "$copy_rc" = 0 ] && [ "$missing_rc" = 0 ]; } &&
  pass "an unwritable destination and a missing source never fail the snapshot step" ||
  fail "snapshot step must always exit 0 (unwritable=$copy_rc missing=$missing_rc)"

# 21. Fail-closed direction, end to end through the real wiring: a run that
#     produced no verdict is still blocked, whatever the telemetry concluded.
#     Telemetry chooses the wording for the human; it never chooses the merge.
rm -f "$fixed_exec" "$RUNNER_TEMP"/claude-execution-pass-*.json
replay_pass 1 error_max_budget_usd
replay_pass 2 error_max_structured_output_retries
replay_pass 3 error_max_structured_output_retries
run_outcome "$wire1" "$wire2" "$wire3" false false false >/dev/null
rc=$(run_submit '' "$(oout budget_exhausted)")
{ [ "$rc" = "rc=1" ] && ! act_has approve && comment_has 'budget-exceeded'; } &&
  pass "the #293 run blocks the merge and now names budget-exceeded, not a generic failure" ||
  fail "#293 run must block and name budget-exceeded ($rc, comment=$(head -c 200 "$tmp/comment.txt"))"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; else echo "$fails test(s) failed."; exit 1; fi
