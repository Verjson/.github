#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
review_wf="$repo_root/.github/workflows/ai-review-merge.yml"
merge_wf="$repo_root/.github/workflows/ai-privileged-merge.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

! grep -q 'steps\.merge\.outcome.*steps\.submit\.outputs\.verdict' "$review_wf" \
  && pass "review job has no unreachable post-merge follow-up step" \
  || fail "review job still gates follow-ups on its disabled merge"
grep -q 'name: merge-attestation-${{ github.run_id }}' "$review_wf" \
  && grep -q 'Upload trusted merge attestation' "$review_wf" \
  && pass "review emits a run-bound merge attestation artifact" \
  || fail "review no longer emits the trusted follow-up handoff"

merge_line="$(grep -n -- '--match-head-commit "$EXPECTED_HEAD_SHA"' "$merge_wf" | cut -d: -f1)"
issue_line="$(grep -n 'gh issue create' "$merge_wf" | cut -d: -f1)"
if [[ "$merge_line" =~ ^[0-9]+$ && "$issue_line" =~ ^[0-9]+$ && "$issue_line" -gt "$merge_line" ]]; then
  pass "issue creation is reachable only after matched-head merge"
else
  fail "follow-up issue creation is not structurally post-merge"
fi
grep -q 'merge-attestation-$run_id' "$merge_wf" \
  && grep -q '.followups | type == "array" and length <= 50' "$merge_wf" \
  && pass "privileged path fetches the exact run artifact and shape-validates data" \
  || fail "follow-up metadata validation drifted"

# --------------------------------------------------------------------------
# Behaviour, not shape. The follow-up block fans out one subshell per item, and
# the failure mode it replaced is silent: behind `jq | while`, the loop body
# runs in the PIPELINE's subshell, so the background jobs are its children and
# the trailing `wait` has none to wait for. The step then finishes while the
# issue calls are still in flight, and on a runner that tears down immediately
# the follow-ups are simply lost — with every command having "succeeded".
#
# Extract the real block from the workflow (single source of truth) and run it
# against a stubbed `gh` that is slow enough that unwaited children cannot have
# finished by the time the block returns.
# --------------------------------------------------------------------------
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

awk '/^          followups="\$\(jq -c \.followups/{p=1} p{print} p&&/^          wait$/{exit}' \
  "$merge_wf" | sed 's/^          //' >"$sandbox/followups.sh"

if [ ! -s "$sandbox/followups.sh" ] || ! grep -q '^wait$' "$sandbox/followups.sh"; then
  fail "could not extract the follow-up block from $merge_wf"
else
  mkdir -p "$sandbox/bin"
  cat >"$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
# `issue list` reports no duplicate; `issue create` records one line, slowly
# enough that a missing `wait` is observable rather than a race.
case "$1 ${2:-}" in
  "issue list") echo 0 ;;
  "issue create") sleep 0.4; echo "created" >>"$FOLLOWUP_LOG" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$sandbox/bin/gh"

  export FOLLOWUP_LOG="$sandbox/created.log"; : >"$FOLLOWUP_LOG"
  export PATH="$sandbox/bin:$PATH"
  export PR_NUMBER=99 TARGET_REPO=Verjson/example
  n=12
  attestation="$(jq -nc --argjson n "$n" \
    '{followups: [range(0;$n) | {location: ("src/f\(.).ts:1"), note: ("finding \(.)")}]}')"
  export attestation

  ( set -uo pipefail; . "$sandbox/followups.sh" ) >/dev/null 2>&1
  created="$(wc -l <"$FOLLOWUP_LOG" | tr -d ' ')"
  [ "$created" -eq "$n" ] \
    && pass "every follow-up issue is created before the step returns" \
    || fail "follow-up fan-out returned with $created/$n issues created — a missing wait, or a pipeline subshell swallowing the jobs"

  # The dedup path must still suppress an already-filed follow-up.
  cat >"$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "issue list") echo 1 ;;
  "issue create") echo "created" >>"$FOLLOWUP_LOG" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$sandbox/bin/gh"
  : >"$FOLLOWUP_LOG"
  ( set -uo pipefail; . "$sandbox/followups.sh" ) >/dev/null 2>&1
  [ "$(wc -l <"$FOLLOWUP_LOG" | tr -d ' ')" -eq 0 ] \
    && pass "an already-filed follow-up is not filed twice" \
    || fail "dedup stopped suppressing existing follow-ups"

  # Identical findings must be collapsed before workers start. The lookup stub
  # deliberately reports no existing issue, reproducing the same-run race:
  # without a pre-fan-out pass every duplicate worker reaches `issue create`.
  cat >"$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "issue list") echo 0 ;;
  "issue create")
    shift 2
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--body" ]; then
        printf '%s\n' "$2" | sed -n '1p' >>"$FOLLOWUP_LOG"
        exit 0
      fi
      shift
    done
    exit 1
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$sandbox/bin/gh"
  : >"$FOLLOWUP_LOG"
  injection_sentinel="$sandbox/injected"
  hostile_note="quote: \" and command: \$(touch $injection_sentinel) and \`false\`"
  attestation="$(jq -nc --arg hostile "$hostile_note" '{
    followups: [
      {location:"src/first.ts:1", note:"same finding"},
      {note:"same finding", location:"src/first.ts:1"},
      {location:"src/first.ts:1", note:"distinct finding"},
      {location:"src/odd name.ts:2", note:$hostile},
      {location:"src/odd name.ts:2", note:$hostile}
    ]
  }')"
  export attestation

  ( set -uo pipefail; . "$sandbox/followups.sh" ) >/dev/null 2>&1
  created="$(wc -l <"$FOLLOWUP_LOG" | tr -d ' ')"
  if [ "$created" -eq 3 ]; then
    pass "same-run duplicates collapse while distinct findings remain"
  else
    fail "same-run dedup created $created issues for 3 canonical findings"
  fi
  [ ! -e "$injection_sentinel" ] \
    && pass "follow-up text remains data under shell metacharacters" \
    || fail "follow-up text was evaluated as shell code"

  expected_markers="$sandbox/expected-markers"
  {
    printf '%s\n' '<!-- ai-review-followup:pr99:'"$(printf '%s' 'src/first.ts:1'$'\n''same finding' | sha256sum | cut -c1-12)"' -->'
    printf '%s\n' '<!-- ai-review-followup:pr99:'"$(printf '%s' 'src/first.ts:1'$'\n''distinct finding' | sha256sum | cut -c1-12)"' -->'
    printf '%s\n' '<!-- ai-review-followup:pr99:'"$(printf '%s' 'src/odd name.ts:2'$'\n'"$hostile_note" | sha256sum | cut -c1-12)"' -->'
  } | sort >"$expected_markers"
  if sort "$FOLLOWUP_LOG" | cmp -s - "$expected_markers"; then
    pass "canonical marker hashes are stable and retain distinct findings"
  else
    fail "canonical marker hashes or distinct-finding retention drifted"
  fi

  awk '/^          followups="\$\(jq -c \.followups/{p=1} p&&/^          max_parallel=8$/{exit} p{print}' \
    "$merge_wf" | sed 's/^          //' >"$sandbox/dedupe.sh"
  (
    set -uo pipefail
    unique_followups=()
    # shellcheck disable=SC1091
    . "$sandbox/dedupe.sh"
    for item in "${unique_followups[@]}"; do
      jq -r '[.location, .note] | @tsv' <<<"$item"
    done
  ) >"$sandbox/actual-order"
  {
    printf '%s\t%s\n' 'src/first.ts:1' 'same finding'
    printf '%s\t%s\n' 'src/first.ts:1' 'distinct finding'
    printf '%s\t%s\n' 'src/odd name.ts:2' "$hostile_note"
  } >"$sandbox/expected-order"
  if cmp -s "$sandbox/actual-order" "$sandbox/expected-order"; then
    pass "pre-fan-out dedup preserves first-seen ordering"
  else
    fail "pre-fan-out dedup reordered canonical findings"
  fi
fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
