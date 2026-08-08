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
  seen && $0 == "        run: |" { cap = 1; seen = 0; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$script"
if ! grep -q 'Review these first' "$script"; then
  echo "FAIL - could not extract the submit run block (or the pinpoint render is gone) from $wf"
  exit 1
fi
grep -qF 'SELECTED_PASS_TERMINAL_ERROR: ${{ steps.retry_outcome.outputs.selected_pass_terminal_error }}' "$wf" || {
  echo "FAIL - submit step is not wired to the selected pass terminal-error fact"
  exit 1
}

# Fake gh: captures the --body of whichever call is made, logs the action.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
args=("$@"); body=""
for ((i=0;i<${#args[@]};i++)); do [ "${args[$i]}" = "--body" ] && body="${args[$((i+1))]}"; done
case "$1 $2" in
  "pr review")
    echo "REVIEW ${args[*]}" >>"$ACTIONLOG"; printf '%s' "$body" >"$BODYFILE"
    case "${REVIEW_FAIL_MODE:-}" in
      self) echo "Can not approve your own pull request" >&2; exit 1 ;;
      policy) echo "GraphQL: GitHub Actions is not permitted to approve pull requests. (addPullRequestReview)" >&2; exit 1 ;;
      policy_cli) echo "failed to create review: GraphQL: GitHub Actions is not permitted to approve pull requests. (addPullRequestReview)" >&2; exit 1 ;;
      mixed) printf '%s\n' "GraphQL: GitHub Actions is not permitted to approve pull requests. (addPullRequestReview)" "unexpected review transport failure" >&2; exit 1 ;;
      unknown) echo "unexpected review transport failure" >&2; exit 1 ;;
    esac
    ;;
  "pr comment") echo "COMMENT" >>"$ACTIONLOG"; printf '%s' "$body" >"$COMMENTFILE" ;;
  "pr edit") echo "EDIT ${args[*]}" >>"$ACTIONLOG" ;;
  "api --paginate")
    if [[ " ${args[*]} " == *" --slurp "* ]]; then
      echo "unknown flag: --slurp" >&2
      exit 1
    fi
    if [ "${REVIEWS_LIST_FAIL:-}" = "true" ]; then
      echo "simulated reviews API failure" >&2
      exit 1
    fi
    cat "$REVIEWS_FILE"
    ;;
  "api --method")
    review_id=$(printf '%s' "${args[3]}" | sed -n 's#.*/reviews/\([0-9][0-9]*\)/dismissals.*#\1#p')
    echo "DISMISS $review_id" >>"$ACTIONLOG"
    if [ "$review_id" = "${DISMISS_FAIL_ID:-}" ]; then
      echo "simulated dismissal failure for $review_id" >&2
      exit 1
    fi
    ;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

run_submit() {
  # run_submit <verdict-json> [selected-pass-terminal-error] [budget-exhausted]
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7 HEAD_SHA=deadbeef MODEL=haiku PATCH_ID=pid00feed GITHUB_RUN_ID=12345
  export ACTIONLOG="$tmp/act.log" BODYFILE="$tmp/body.txt" COMMENTFILE="$tmp/comment.txt"
  export GITHUB_OUTPUT="$tmp/gh_output.txt" REVIEWS_FILE="$tmp/reviews.json" SUBMIT_LOG="$tmp/submit.log"
  : >"$ACTIONLOG"
  : >"$BODYFILE"
  : >"$COMMENTFILE"
  : >"$GITHUB_OUTPUT"
  : >"$SUBMIT_LOG"
  printf '%s' "${REVIEWS_JSON:-[]}" >"$REVIEWS_FILE"
  export VERDICT="$1" SELECTED_PASS_TERMINAL_ERROR="${2:-false}" BUDGET_EXHAUSTED="${3:-false}"
  bash -eo pipefail "$script" >"$SUBMIT_LOG" 2>&1
  echo "rc=$?"
}
body_has() { grep -qF "$1" "$tmp/body.txt"; }
comment_has() { grep -qF "$1" "$tmp/comment.txt"; }
act_has() { grep -q "$1" "$tmp/act.log"; }
output_has() { grep -qF "$1" "$tmp/gh_output.txt"; }
log_has() { grep -qF "$1" "$tmp/submit.log"; }

# 1. Approve + review_first -> the pinpoint block renders in the review body.
run_submit '{"blocking":false,"summary":"looks good","review_first":[{"location":"auth.ts:42","why":"gates the admin path"}],"findings":[]}' >/dev/null
{ body_has '👀 Review these first' && body_has 'auth.ts:42' && body_has 'gates the admin path'; } &&
  pass "approve: review_first renders as a pinpoint block" ||
  fail "approve: review_first not rendered"

# 1a. The approval marker carries the head SHA AND the PR net patch-id (#120) so a
#     base-merge-only re-fire can detect an unchanged diff and skip the model.
body_has '<!-- ai-review-head:deadbeef patchid:pid00feed model:haiku -->' &&
  pass "approve: marker embeds ai-review-head + patchid (#120)" ||
  fail "approve: marker missing head/patchid token (#120)"

# 1b. Approve + followups -> renders a Follow-ups block AND emits the verdict to
#     $GITHUB_OUTPUT (so the shared gate can file the issues on merge).
run_submit '{"blocking":false,"summary":"ok","review_first":[],"followups":[{"location":"util.ts:9","note":"missing null guard"}],"findings":[]}' >/dev/null
{ body_has 'Follow-ups' && body_has 'util.ts:9' && body_has 'missing null guard' && output_has 'verdict<<' && output_has 'missing null guard'; } &&
  pass "approve: followups render and the verdict is emitted for the gate" ||
  fail "approve: followups render / verdict-output missing"

# 2. Approve + empty review_first -> summary only, no pinpoint header.
run_submit '{"blocking":false,"summary":"trivial docs tweak","review_first":[],"findings":[]}' >/dev/null
{ body_has 'trivial docs tweak' && ! body_has 'Review these first'; } &&
  pass "approve: empty review_first omits the pinpoint block" ||
  fail "approve: empty review_first still rendered a block"

# Public adopters may run the older GitHub CLI from their runner image. The gh
# stub rejects its unsupported --slurp flag, so this success also proves that an
# empty public review list is collected through portable gh + jq pagination.
run_submit '{"blocking":false,"summary":"public adopter","review_first":[],"findings":[]}' >/dev/null
act_has REVIEW &&
  pass "public adopter: empty review list works without gh --slurp (#608)" ||
  fail "public adopter review listing depends on unsupported gh --slurp"

# 3. Blocking -> request-changes body carries both pinpoint + findings; exit 1.
rc=$(run_submit '{"blocking":true,"summary":"has a bug","review_first":[{"location":"x.ts:1","why":"the mutation"}],"findings":[{"location":"x.ts:1","reason":"off-by-one","failure_scenario":"the final item is skipped"}]}')
{ [ "$rc" = "rc=1" ] && body_has 'Review these first' && body_has 'x.ts:1' && body_has 'off-by-one'; } &&
  pass "blocking: pinpoint + findings render and step exits 1" ||
  fail "blocking path wrong ($rc)"

# 4. Blocking on own PR (request-changes rejected) -> falls back to a comment.
rc=$(REVIEW_FAIL_MODE=self run_submit '{"blocking":true,"summary":"bug","review_first":[],"findings":[{"location":"a:1","reason":"boom","failure_scenario":"the process exits"}]}')
{ [ "$rc" = "rc=1" ] && comment_has 'Merge gate: blocking verdict' && comment_has 'a:1' && comment_has 'boom'; } &&
  pass "blocking on own PR falls back to a findings comment, still exits 1" ||
  fail "blocking own-PR fallback wrong ($rc)"

# 4a. A non-blocking verdict cannot always be published as an approval. Both
#      GitHub's self-review guard and an approval-disabled repository retain the
#      gate verdict as an audit comment; unexpected errors remain fail-closed.
for mode in self policy policy_cli; do
  rc=$(REVIEW_FAIL_MODE="$mode" run_submit '{"blocking":false,"summary":"safe","review_first":[],"findings":[]}')
  { [ "$rc" = "rc=0" ] && comment_has 'Merge gate: approved verdict' && comment_has 'safe'; } &&
    pass "approve denied ($mode): falls back to an audit comment (#242)" ||
    fail "approve denied ($mode) fallback wrong ($rc)"
done

for mode in unknown mixed; do
  rc=$(REVIEW_FAIL_MODE="$mode" run_submit '{"blocking":false,"summary":"safe","review_first":[],"findings":[]}')
  { [ "$rc" = "rc=1" ] && ! act_has COMMENT; } &&
    pass "unexpected approval publication failure ($mode) remains fail-closed" ||
    fail "unexpected approval failure ($mode) was swallowed ($rc)"
done

# 5. No usable verdict -> inconclusive label + comment + exit 1 (fail closed).
rc=$(run_submit 'not-json')
{ [ "$rc" = "rc=1" ] && act_has EDIT && comment_has 'review could not complete'; } &&
  pass "no verdict: labels inconclusive, comments, exits 1 (fail closed)" ||
  fail "no-verdict path wrong ($rc)"

# 6. A schema-valid verdict is still absent when its producing SDK pass ended
#    in a terminal error subtype. The model may emit required-field filler while
#    exhausting its turns or budget; publishing that as CHANGES_REQUESTED would
#    fabricate findings rather than report an inconclusive review (#441).
degenerate='{"blocking":true,"summary":"test","review_first":[{"location":"a:1","why":"b"}],"findings":[{"location":"c:1","reason":"d","failure_scenario":"e"}],"followups":[]}'
rc=$(run_submit "$degenerate" true)
{ [ "$rc" = "rc=1" ] && act_has EDIT && comment_has 'review could not complete' && ! act_has REVIEW && ! output_has '"location":"c:1"'; } &&
  pass "terminal-error pass: schema-valid filler is routed to no-verdict fail-closed" ||
  fail "terminal-error filler escaped the no-verdict branch ($rc)"

# A budget subtype with filler is still factual budget exhaustion. With one
# paid pass there is no escalation-count claim to avoid; name the cost cap while
# rejecting the filler as a verdict.
rc=$(run_submit "$degenerate" true true)
{ [ "$rc" = "rc=1" ] && comment_has 'budget-exceeded' && comment_has 'single automatic paid review'; } &&
  pass "budget-terminal filler reports the one-pass cost cap without becoming a verdict" ||
  fail "budget-terminal filler lost its factual one-pass budget outcome ($rc)"

# The subtype fact, not content quality, decides usability: the identical terse
# verdict from a successful pass remains a real blocking verdict.
rc=$(run_submit "$degenerate" false)
{ [ "$rc" = "rc=1" ] && act_has REVIEW && body_has 'c' && ! act_has EDIT; } &&
  pass "successful pass: terse schema-valid blocking verdict remains usable" ||
  fail "successful terse verdict was rejected by a content heuristic ($rc)"

# 7. #452: once a new-head verdict is non-blocking, dismiss only the gate bot's
#    stale CHANGES_REQUESTED review. Dismissal preserves the original finding in
#    the timeline while removing its stale reviewDecision veto.
reviews='[{"id":101,"state":"CHANGES_REQUESTED","commit_id":"old-head","user":{"login":"github-actions[bot]"}}]'
rc=$(REVIEWS_JSON="$reviews" run_submit '{"blocking":false,"summary":"fixed","review_first":[],"findings":[],"followups":[]}')
dismiss_line=$(grep -n '^DISMISS 101$' "$tmp/act.log" | cut -d: -f1)
review_line=$(grep -n '^REVIEW ' "$tmp/act.log" | cut -d: -f1)
{ [ "$rc" = "rc=0" ] && [ -n "$dismiss_line" ] && [ -n "$review_line" ] && [ "$dismiss_line" -lt "$review_line" ]; } &&
  pass "nonblocking new-head verdict dismisses the stale gate-bot review before green" ||
  fail "stale gate-bot review was not dismissed ($rc, log=$(tr '\n' ',' <"$tmp/act.log"))"

# gh emits one top-level JSON array for each paginated response. Exercise an
# actual two-document stream and put the dismissal target on page two so this
# test fails if collection silently inspects only the first page.
reviews=$'[]\n[{"id":111,"state":"CHANGES_REQUESTED","commit_id":"page-two-head","user":{"login":"github-actions[bot]"}}]'
rc=$(REVIEWS_JSON="$reviews" run_submit '{"blocking":false,"summary":"fixed","review_first":[],"findings":[],"followups":[]}')
{ [ "$rc" = "rc=0" ] && act_has '^DISMISS 111$' && act_has REVIEW; } &&
  pass "paginated review listing dismisses a stale gate review from page two (#608)" ||
  fail "paginated review listing ignored the second page ($rc, log=$(tr '\n' ',' <"$tmp/act.log"))"

# Human reviews and a bot review bound to the current head are live decisions,
# not stale gate residue. A second stale bot review remains the only target.
reviews='[{"id":201,"state":"CHANGES_REQUESTED","commit_id":"old-head","user":{"login":"human-reviewer"}},{"id":202,"state":"CHANGES_REQUESTED","commit_id":"deadbeef","user":{"login":"github-actions[bot]"}},{"id":203,"state":"CHANGES_REQUESTED","commit_id":"older-head","user":{"login":"github-actions[bot]"}},{"id":204,"state":"CHANGES_REQUESTED","commit_id":null,"user":{"login":"github-actions[bot]"}}]'
rc=$(REVIEWS_JSON="$reviews" run_submit '{"blocking":false,"summary":"fixed","review_first":[],"findings":[],"followups":[]}')
{ [ "$rc" = "rc=0" ] && act_has '^DISMISS 203$' && ! act_has '^DISMISS 201$' && ! act_has '^DISMISS 202$' && ! act_has '^DISMISS 204$'; } &&
  pass "dismissal excludes human, current-head, and unbound blocking reviews" ||
  fail "dismissal crossed reviewer/head trust boundaries ($rc, log=$(tr '\n' ',' <"$tmp/act.log"))"

# A current blocking verdict must never retract the prior blocking record.
rc=$(REVIEWS_JSON="$reviews" run_submit '{"blocking":true,"summary":"still broken","review_first":[],"findings":[{"location":"x:1","reason":"broken","failure_scenario":"the request fails"}],"followups":[]}')
{ [ "$rc" = "rc=1" ] && ! act_has DISMISS; } &&
  pass "current blocking verdict does not dismiss any prior review" ||
  fail "blocking verdict retracted a review ($rc, log=$(tr '\n' ',' <"$tmp/act.log"))"

# Both the review-list read and each dismissal write are merge-decision inputs:
# an API failure must stay red, emit explicit evidence, and never approve.
rc=$(REVIEWS_LIST_FAIL=true run_submit '{"blocking":false,"summary":"fixed","review_first":[],"findings":[],"followups":[]}')
{ [ "$rc" = "rc=1" ] && ! act_has REVIEW && log_has 'could not list prior pull request reviews'; } &&
  pass "review-list API failure is explicit and fail-closed" ||
  fail "review-list API failure did not fail closed with evidence ($rc)"

rc=$(REVIEWS_JSON='{"not":"pages"}' run_submit '{"blocking":false,"summary":"fixed","review_first":[],"findings":[],"followups":[]}')
{ [ "$rc" = "rc=1" ] && ! act_has REVIEW && log_has 'could not validate prior pull request reviews'; } &&
  pass "malformed review-list payload is explicit and fail-closed" ||
  fail "malformed review payload did not fail closed with evidence ($rc)"

rc=$(REVIEWS_JSON='[{"id":301,"state":"CHANGES_REQUESTED","commit_id":"old-head","user":{"login":"github-actions[bot]"}}]' DISMISS_FAIL_ID=301 run_submit '{"blocking":false,"summary":"fixed","review_first":[],"findings":[],"followups":[]}')
{ [ "$rc" = "rc=1" ] && act_has '^DISMISS 301$' && ! act_has REVIEW && log_has 'could not dismiss stale gate review 301'; } &&
  pass "dismissal API failure is explicit and fail-closed" ||
  fail "dismissal API failure did not fail closed with evidence ($rc)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
