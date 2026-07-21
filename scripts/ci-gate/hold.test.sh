#!/usr/bin/env bash
# Tests the merge gate's terminal-hold predicate and event re-fire guards
# (Verjson/.github#51, #88, ADR 0012)
# by extracting the exact `run:` block of the `merge` step from
# ai-review-merge.yml — single source of truth, so the test can't drift from the
# shipped logic — and exercising it against a stubbed `gh`. #51: a PR carrying a
# `DO NOT MERGE` *label* (the natural maintainer action, not just the title
# marker) was auto-merged because the gate only matched the `hold` label + title.
# This guards the org-critical "held PRs never merge" invariant across every repo.
# Plain bash + awk + jq; no test-framework dependency (runs on the bare pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

# Extract the merge step's run script verbatim (10-space-indented body under
# `run: |`, scoped to the step with `id: merge`).
script="$tmp/merge.sh"
awk '
  $0 == "        id: merge" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    cap = 0
  }
' "$wf" >"$script"
if ! grep -q 'is held' "$script" || ! grep -q 'pr merge' "$script"; then
  echo "FAIL - could not extract merge run block from $wf"
  exit 1
fi

# Fake `gh`: `pr view --json ...statusCheckRollup...` → the rollup fixture;
# other `pr view` → the meta fixture; `pr merge`/`pr comment` → log the action.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *statusCheckRollup*) cat "$ROLLUP_FILE" ;;
    *) cat "$META_FILE" ;;
  esac
  exit 0
fi
[ "$1" = "pr" ] && [ "$2" = "merge" ] && { echo MERGE >>"$ACTIONLOG"; exit 0; }
[ "$1" = "pr" ] && [ "$2" = "comment" ] && { echo COMMENT >>"$ACTIONLOG"; exit 0; }
exit 0
GH
chmod +x "$tmp/bin/gh"

run_case() {
  # run_case <meta-json> [rollup-json]
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export LANE=ai LANE_REASON="n/a" EXPECTED_HEAD_SHA=expected-head
  export META_FILE="$tmp/meta.json" ROLLUP_FILE="$tmp/rollup.json"
  export ACTIONLOG="$tmp/act.log"
  : >"$ACTIONLOG"
  printf '%s' "$1" >"$META_FILE"
  printf '%s' "${2:-[]}" >"$ROLLUP_FILE"
  bash "$script" >"$tmp/out.txt" 2>&1
  echo "rc=$?"
}
out_has() { grep -q "$1" "$tmp/out.txt"; }
act_has() { grep -q "$1" "$tmp/act.log"; }

open() { printf '{"labels":%s,"title":"%s","isDraft":%s,"state":"OPEN","headRefOid":"expected-head"}' "$1" "${2:-feat: x}" "${3:-false}"; }

# --- #51 regression: a `DO NOT MERGE` *label* must hold, not merge -----------
run_case "$(open '[{"name":"DO NOT MERGE"}]')" >/dev/null
{ out_has 'is held' && ! act_has MERGE; } && pass "DO NOT MERGE label holds (#51)" || fail "DO NOT MERGE label was NOT held (#51 regression)"

# Separator/case variants of the label are the same hold signal.
run_case "$(open '[{"name":"do-not-merge"}]')" >/dev/null
{ out_has 'is held' && ! act_has MERGE; } && pass "do-not-merge label variant holds" || fail "do-not-merge label variant not held"

run_case "$(open '[{"name":"Do_Not_Merge"}]')" >/dev/null
{ out_has 'is held' && ! act_has MERGE; } && pass "Do_Not_Merge label variant holds" || fail "Do_Not_Merge label variant not held"

# --- existing hold signals still honored ------------------------------------
run_case "$(open '[{"name":"hold"}]')" >/dev/null
{ out_has 'is held' && ! act_has MERGE; } && pass "hold label still holds" || fail "hold label regressed"

run_case "$(open '[]' 'chore: bump DO NOT MERGE until QA')" >/dev/null
{ out_has 'is held' && ! act_has MERGE; } && pass "DO NOT MERGE title marker still holds" || fail "DO NOT MERGE title regressed"

run_case "$(open '[]' 'feat: x' 'true')" >/dev/null
{ out_has 'is held' && ! act_has MERGE; } && pass "draft still holds" || fail "draft regressed"

# --- positive control: an unheld, all-green PR merges ------------------------
run_case "$(open '[{"name":"update/patch"}]')" '[]' >/dev/null
act_has MERGE && pass "unheld green PR merges" || fail "unheld green PR did not merge"

# A closed (non-OPEN) PR is a no-op, never merged.
run_case '{"labels":[],"title":"feat: x","isDraft":false,"state":"MERGED","headRefOid":"expected-head"}' >/dev/null
{ out_has 'no longer open' && ! act_has MERGE; } && pass "non-open PR is a no-op" || fail "non-open PR mishandled"

# The hold predicate is intentionally identical at both bash checkpoints
# (classify step + merge step). This test exercises the authoritative merge-step
# copy; pin the classify copy to it so the two can't silently drift.
copies=$(grep -c "index(\"HOLD\")) or (\$l | index(\"DO NOT MERGE\"))" "$wf")
[ "$copies" -eq 2 ] && pass "hold predicate present at both bash checkpoints (no drift)" || fail "expected 2 identical hold predicates, found $copies"

# --- #88 regression: removing a terminal hold re-fires the gate ------------
# Pin the workflow trigger and the exact event-filter grouping in the preflight
# job guard. GitHub evaluates this expression before a runner starts, so there is
# no run block to execute locally; extracting the shipped `if:` text keeps this
# check tied to the single source of truth.
types="$(awk '/^  pull_request:/{seen=1; next} seen && /^    types:/{print; exit}' "$wf")"
printf '%s' "$types" | grep -q 'unlabeled' \
  && pass "pull_request subscribes to unlabeled (#88)" \
  || fail "pull_request does not subscribe to unlabeled (#88)"

job_if() {
  local job="$1"
  awk -v target="  $job:" '
    $0 == target { in_job = 1; next }
    in_job && $0 == "    if: >" { capture = 1; next }
    capture && /^      / { print substr($0, 7); next }
    capture { exit }
  ' "$wf" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g'
}

event_filter="(github.event.action != 'labeled' && github.event.action != 'unlabeled') || (github.event.action == 'labeled' && github.event.label.name == 're-review') || (github.event.action == 'unlabeled' && (github.event.label.name == 'hold' || github.event.label.name == 'DO NOT MERGE'))"
for job in preflight; do
  predicate="$(job_if "$job")"
  printf '%s' "$predicate" | grep -qF "$event_filter" \
    && pass "$job admits re-review and terminal-hold removal only" \
    || fail "$job event filter does not safely re-fire for hold removal"
done

# Workflow concurrency is evaluated before the job guards. The gate consumes
# `re-review` itself, emitting `unlabeled`; that cleanup run must not cancel the
# review that removed it. Terminal-hold additions/removals and re-review requests
# do cancel stale work, while unrelated label churn does not.
cancel_if="$(awk '
  /^  cancel-in-progress: >-/{capture=1; next}
  capture && /^    / {print substr($0, 5); next}
  capture {exit}
' "$wf" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
cancel_filter="(github.event.action != 'labeled' && github.event.action != 'unlabeled') || (github.event.action == 'labeled' && (github.event.label.name == 're-review' || github.event.label.name == 'hold' || github.event.label.name == 'DO NOT MERGE')) || (github.event.action == 'unlabeled' && (github.event.label.name == 'hold' || github.event.label.name == 'DO NOT MERGE'))"
printf '%s' "$cancel_if" | grep -qF "$cancel_filter" \
  && pass "concurrency ignores re-review cleanup and unrelated label churn" \
  || fail "concurrency cancellation filter can strand or cancel gate runs"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
