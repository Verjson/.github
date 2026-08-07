#!/usr/bin/env bash
# Tests the gate re-arm bridge (Verjson/.github#468, ADR 0063) by extracting the
# exact `run:` block of the `rearm` step from gate-rearm.yml — single source of
# truth, so the test cannot drift from the shipped logic — and exercising it
# against a stubbed `gh`.
#
# The bridge exists because `ai-review-merge.yml` is scheduled by the
# `main-protection` required-workflow rule, which fires for `opened`,
# `synchronize` and `reopened` only; the gate's own `ready_for_review`/`labeled`/
# `unlabeled` types never produce a run. This file pins the two invariants that
# make the bridge safe rather than merely present: it dispatches the gate when a
# PR genuinely re-enters review, and it dispatches NOTHING when the PR is held,
# draft, closed, or when the PR state cannot be read at all.
#
# Plain bash + awk + jq; no test-framework dependency (runs on the bare pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/gate-rearm.yml"
gate_wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

# --- extraction --------------------------------------------------------------
# The 10-space-indented body under `run: |`, scoped to the step with `id: rearm`.
# Capture stops at the next step's `- name:`; clearing `cap` alone would leave
# `seen` set, so a following step's `run: |` would re-arm capture and append
# unrelated code to the script under test (the hold.test.sh lesson).
script="$tmp/rearm.sh"
awk '
  $0 == "        id: rearm" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap && $0 ~ /^      - name:/ { exit }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$script"

# Bound the extraction by SIZE as well as by structure. A step that is reshaped
# — or a second `run:` block that leaks in — changes the line count long before
# it changes the marker strings, and an unbounded extraction is how a test ends
# up exercising something other than the step it names.
lines="$(wc -l <"$script")"
{ [ "$lines" -ge 20 ] && [ "$lines" -le 45 ]; } \
  && pass "extracted rearm step is $lines lines (bounded 20..45)" \
  || fail "extracted rearm step is $lines lines, outside the expected 20..45 band"

# The extracted text must be a runnable shell script, not a workflow fragment: a
# surviving `${{ }}` would be a bash parse error, and it would also mean a
# PR-controlled value reaches the shell instead of arriving through `env:`.
grep -q '\${{' "$script" \
  && fail "extracted step still contains a \${{ }} expression" \
  || pass "extracted step is pure shell; every input arrives through env:"

for marker in 'set -euo pipefail' 'gh pr view' 'gh workflow run ai-review-merge.yml'; do
  grep -qF "$marker" "$script" \
    || { echo "FAIL - could not extract the rearm run block from $wf (missing: $marker)"; exit 1; }
done

# --- stub gh -----------------------------------------------------------------
# `pr view` → the meta fixture (or a forced failure); `workflow run` → log it.
# The stub NEVER exits 0 silently for an unrecognised call: a fall-through that
# looked like success is what lets a fail-open ship (#143).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  [ "${GH_VIEW_FAILS:-0}" = "1" ] && { echo "gh: could not resolve PR" >&2; exit 1; }
  cat "$META_FILE"
  exit 0
fi
if [ "$1" = "workflow" ] && [ "$2" = "run" ]; then
  shift 2
  echo "DISPATCH $*" >>"$ACTIONLOG"
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 64
GH
chmod +x "$tmp/bin/gh"

run_case() {
  # run_case <meta-json> [PR_NUMBER] [TARGET_REPO] [EVENT_ACTION] [REMOVED_LABEL]
  export PATH="$tmp/bin:$PATH"
  # `${2-7}`, not `${2:-7}`: an explicitly EMPTY pr number is one of the cases
  # under test, and `:-` would silently substitute the valid default for it.
  export PR_NUMBER="${2-7}"
  export TARGET_REPO="${3-Verjson/.github}"
  export GITHUB_REPOSITORY="Verjson/.github"
  export EVENT_ACTION="${4-ready_for_review}"
  export REMOVED_LABEL="${5-}"
  export META_FILE="$tmp/meta.json" ACTIONLOG="$tmp/act.log"
  : >"$ACTIONLOG"
  printf '%s' "$1" >"$META_FILE"
  bash "$script" >"$tmp/out.txt" 2>&1
  echo "rc=$?"
}
out_has() { grep -qF "$1" "$tmp/out.txt"; }
dispatched() { grep -q '^DISPATCH' "$tmp/act.log"; }

pr() {
  # pr <labels-json> [title] [isDraft] [state]
  printf '{"labels":%s,"title":"%s","isDraft":%s,"state":"%s"}' \
    "$1" "${2:-feat: x}" "${3:-false}" "${4:-OPEN}"
}

# --- the behaviour the ticket asks for ---------------------------------------
rc="$(run_case "$(pr '[]')")"
{ [ "$rc" = "rc=0" ] && dispatched; } \
  && pass "a readied, unheld PR re-arms the gate" \
  || fail "a readied, unheld PR did NOT re-arm the gate (#468)"

grep -qF 'DISPATCH ai-review-merge.yml --repo Verjson/.github -f pr_number=7' "$tmp/act.log" \
  && pass "the dispatch names the gate workflow and the PR under review" \
  || fail "dispatch payload is wrong: $(cat "$tmp/act.log")"

# --- ADR 0012: holds stay terminal -------------------------------------------
for label in hold 'DO NOT MERGE' do-not-merge Do_Not_Merge; do
  rc="$(run_case "$(pr "[{\"name\":\"$label\"}]")")"
  { [ "$rc" = "rc=0" ] && ! dispatched && out_has 'is held'; } \
    && pass "the '$label' label stays terminal (ADR 0012)" \
    || fail "the '$label' label did NOT hold the re-arm (rc=$rc)"
done

rc="$(run_case "$(pr '[]' 'chore: bump DO NOT MERGE until QA')")"
{ [ "$rc" = "rc=0" ] && ! dispatched; } \
  && pass "the DO NOT MERGE title marker stays terminal" \
  || fail "the DO NOT MERGE title marker did not hold the re-arm"

rc="$(run_case "$(pr '[]' 'feat: x' 'true')")"
{ [ "$rc" = "rc=0" ] && ! dispatched; } \
  && pass "a draft PR is never re-armed" \
  || fail "a draft PR was re-armed"

for state in CLOSED MERGED; do
  rc="$(run_case "$(pr '[]' 'feat: x' 'false' "$state")")"
  { [ "$rc" = "rc=0" ] && ! dispatched && out_has "is $state"; } \
    && pass "a $state PR is a no-op" \
    || fail "a $state PR was re-armed"
done

# --- failure modes must not dispatch -----------------------------------------
export GH_VIEW_FAILS=1
rc="$(run_case "$(pr '[]')")"
unset GH_VIEW_FAILS
{ [ "$rc" != "rc=0" ] && ! dispatched; } \
  && pass "an unreadable PR fails closed instead of dispatching" \
  || fail "a failed 'gh pr view' still dispatched (rc=$rc)"

rc="$(run_case 'not json at all')"
{ [ "$rc" != "rc=0" ] && ! dispatched; } \
  && pass "malformed PR metadata fails closed" \
  || fail "malformed PR metadata dispatched anyway (rc=$rc)"

rc="$(run_case '{"state":"OPEN"}')"
{ [ "$rc" != "rc=0" ] && ! dispatched; } \
  && pass "PR metadata missing the hold fields fails closed" \
  || fail "truncated PR metadata dispatched anyway (rc=$rc)"

for bad in 0 -1 abc '7; rm -rf /' ''; do
  rc="$(run_case "$(pr '[]')" "$bad")"
  { [ "$rc" != "rc=0" ] && ! dispatched; } \
    && pass "PR number '$bad' is rejected before any API call" \
    || fail "PR number '$bad' was accepted (rc=$rc)"
done

rc="$(run_case "$(pr '[]')" 7 'Attacker/elsewhere')"
{ [ "$rc" != "rc=0" ] && ! dispatched; } \
  && pass "a repository identity other than this one is rejected" \
  || fail "the bridge dispatched into a foreign repository (rc=$rc)"

rc="$(run_case "$(pr '[]')" 7 'not-a-repo')"
{ [ "$rc" != "rc=0" ] && ! dispatched; } \
  && pass "a malformed repository identity is rejected" \
  || fail "a malformed repository identity was accepted (rc=$rc)"

# --- workflow-level pins (evaluated by GitHub, so not executable here) --------
# Pin the EXACT list, not the presence of two members: adding `synchronize` here
# would make every push dispatch a second full model review from a privileged
# context, and a presence check would not notice.
types="$(awk '/^  pull_request_target:/{seen=1; next} seen && /^    types:/{print; exit}' "$wf" \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
[ "$types" = "types: [ready_for_review, unlabeled, labeled]" ] \
  && pass "the bridge subscribes to exactly the events the required workflow never sees" \
  || fail "bridge trigger types drifted: '$types'"

# Concurrency must be claimed by the job, never by the workflow: a workflow-level
# group is claimed before the job guard runs, so a run that the guard then skips
# would cancel an in-flight re-arm and dispatch nothing (#468 by another route).
awk 'NR>1 && /^concurrency:/{found=1} END{exit !found}' "$wf" \
  && fail "the bridge declares workflow-level concurrency; a skipped run would cancel a live re-arm" \
  || pass "concurrency is not claimed at workflow level"
job_concurrency="$(awk '
  $0 == "  rearm:" { in_job = 1 }
  in_job && $0 == "    concurrency:" { capture = 1; next }
  capture && /^      [a-z-]+:/ { print substr($0, 7); next }
  capture { exit }
' "$wf" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
[ "$job_concurrency" = "group: gate-rearm-\${{ github.event.pull_request.number }} cancel-in-progress: false" ] \
  && pass "the rearm job serialises per PR and never cancels a live re-arm" \
  || fail "bridge job concurrency drifted: '$job_concurrency'"

# The bridge runs in a privileged context. It must never materialise PR head
# content, which is the only way `pull_request_target` becomes dangerous.
grep -q 'uses:' "$wf" \
  && fail "the bridge uses an action; a pull_request_target job must not check out or run head code" \
  || pass "the bridge checks nothing out and runs no third-party action"

job_if="$(awk '
  $0 == "  rearm:" { in_job = 1; next }
  in_job && $0 == "    if: >" { capture = 1; next }
  capture && /^      / { print substr($0, 7); next }
  capture { exit }
' "$wf" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"

# Re-entrancy: the gate removes its own `re-review` label, which emits
# `unlabeled`. Admit every other removal because an Actions expression cannot
# reproduce the live predicate's separator normalizer; denying `re-review` by
# name prevents the gate from dispatching itself when it cleans up after review.
guard="( github.event.action == 'ready_for_review' || (github.event.action == 'labeled' && github.event.label.name == 're-review') || (github.event.action == 'unlabeled' && github.event.label.name != 're-review') )"
printf '%s' "$job_if" | grep -qF "$guard" \
  && pass "readying, re-review labelling and every non-re-review removal re-arm" \
  || fail "the bridge guard does not use the re-review denylist: $job_if"

# --- #481: the re-review lane, bridged for that label ONLY ------------------
# The gate documents this lane and guards it at ai-review-merge.yml:165, but a
# required workflow is scheduled by the ruleset, which fires only opened /
# synchronize / reopened — so applying the label never produced a run. #479 left
# it out because bridging `labeled` wholesale dispatches a paid model review on
# every label application from a privileged context, so the narrowing IS the fix
# and has to be asserted, not assumed.
grep -qE '^    types: \[ready_for_review, unlabeled, labeled\]$' "$wf" \
  && pass "#481: the bridge subscribes to labeled alongside ready_for_review and unlabeled" \
  || fail "#481: the trigger types do not include labeled: $(grep -n '    types:' "$wf")"

# The whole point of the narrowing: any OTHER label must not re-arm. Asserted on
# the guard text because the job never starts for it, so no run_case can observe
# the absence — a passing dispatch check would be vacuous here.
for churn in 'needs-review' 'blocked' 'documentation'; do
  printf '%s' "$job_if" | grep -qF "== '$churn'" \
    && fail "#481: the guard admits the '$churn' label, so ordinary labelling dispatches a paid review" \
    || pass "#481: labelling '$churn' does not re-arm the gate"
done

# The label name is matched in the GUARD, not only re-checked in the step. If it
# were only checked later, the job would start (and bill a runner) for every
# label on every PR in the fleet.
printf '%s' "$job_if" | grep -qF "github.event.action == 'labeled' && github.event.label.name == 're-review'" \
  && pass "#481: the re-review name is matched in the job guard, before the job starts" \
  || fail "#481: the labeled arm does not pin the label name in the guard"

# Re-entrancy, restated for the new arm: the gate CONSUMES `re-review` by removing
# it, which emits `unlabeled`. Pin both halves — the removal path denying
# `re-review`, and the gate actually being the thing that removes it.
printf '%s' "$job_if" | grep -qF "github.event.action == 'unlabeled' && github.event.label.name != 're-review'" \
  && pass "#481: removal of re-review still does not re-arm (no self-dispatch loop)" \
  || fail "#481: the unlabeled arm now admits re-review, which would loop the gate"
grep -qF -- '--remove-label re-review' "$gate_wf" \
  && pass "#481: the gate is the actor that consumes the re-review label" \
  || fail "#481: the gate no longer removes re-review, so the loop analysis above is stale"

# Every separator variant is admitted by the generic unlabeled arm. Each spelling
# is also asserted to be a hold by the live predicate above, so a spelling the
# normalizer accepts can never become stranded by a finite guard enumeration.
for spelling in 'do-not-merge' 'do_not_merge' 'DO__NOT__MERGE'; do
  printf '%s' "$job_if" | grep -qF "github.event.action == 'unlabeled' && github.event.label.name != 're-review'" \
    && pass "the denylist guard admits removal of '$spelling'" \
    || fail "the denylist guard ignores removal of '$spelling'"
  run_case "$(pr "[{\"name\":\"$spelling\"}]")" >/dev/null
  ! dispatched \
    && pass "the live predicate counts '$spelling' as a hold" \
    || fail "'$spelling' did NOT hold the re-arm"
done

export GH_VIEW_FAILS=1
rc="$(run_case "$(pr '[]')" 7 Verjson/.github unlabeled documentation)"
unset GH_VIEW_FAILS
{ [ "$rc" = "rc=0" ] && ! dispatched && out_has "is not a terminal hold"; } \
  && pass "unrelated label removal exits before API reads or paid gate dispatch" \
  || fail "unrelated label removal reached the live-state API or gate dispatch (rc=$rc)"

rc="$(run_case "$(pr '[]')" 7 Verjson/.github unlabeled 'DO__NOT__MERGE')"
{ [ "$rc" = "rc=0" ] && dispatched; } \
  && pass "a normalized terminal-hold removal still re-arms the gate" \
  || fail "a normalized terminal-hold removal was filtered out (rc=$rc)"

for terminal in \
  "!github.event.pull_request.draft" \
  "!contains(github.event.pull_request.labels.*.name, 'hold')" \
  "!contains(github.event.pull_request.labels.*.name, 'DO NOT MERGE')" \
  "!contains(github.event.pull_request.title, 'DO NOT MERGE')"; do
  printf '%s' "$job_if" | grep -qF "$terminal" \
    && pass "guard keeps terminal: $terminal" \
    || fail "guard no longer honours: $terminal"
done

# Least privilege: the bridge dispatches a workflow and reads a PR. Anything
# that can write to the repository, or to the PR, is more than it needs.
job_perms="$(awk '
  $0 == "  rearm:" { in_job = 1 }
  in_job && $0 == "    permissions:" { capture = 1; next }
  capture && /^      [a-z-]+:/ { print substr($0, 7); next }
  capture { exit }
' "$wf" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
[ "$job_perms" = "contents: read actions: write pull-requests: read" ] \
  && pass "the bridge job holds only contents:read, actions:write, pull-requests:read" \
  || fail "bridge job permissions drifted: '$job_perms'"

# The hold predicate is a third copy of the gate's. Pin it to the original so
# the bridge and the gate can never disagree about what "held" means.
predicate='([.labels[].name | ascii_upcase | gsub("[ _-]+";" ")]) as $l | ($l | index("HOLD")) or ($l | index("DO NOT MERGE")) or (.title | ascii_upcase | contains("DO NOT MERGE")) or .isDraft'
{ grep -qF "$predicate" "$wf" && grep -qF "$predicate" "$gate_wf"; } \
  && pass "the bridge reuses the gate's hold predicate verbatim" \
  || fail "the bridge's hold predicate has drifted from the gate's"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
