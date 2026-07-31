#!/usr/bin/env bash
# Tests that the privileged merge step accepts an *organization-ruleset required
# workflow* run as trusted gate provenance (Verjson/.github#259, ADR 0039).
#
# Verjson consumers do not install the gate as a repo-local file or a reusable
# `uses:` caller: the org ruleset `main-protection` mandates
# Verjson/.github/.github/workflows/ai-review-merge.yml@refs/heads/main. Runs of
# that shape carry a *repo-scoped* workflow_id, an empty referenced_workflows,
# and a workflow_url under /actions/required_workflows/, so both original
# matchers missed them and every privileged run — dispatched and
# pull_request_target alike — timed out on "trusted gate/checks did not become
# green" while the PR kept a cancelled privileged_merge check.
#
# The organization ruleset is the whole trust anchor, so every clause of it is
# pinned here individually: a mutation that relaxes any one of them must turn a
# case red. Negative cases assert the *specific* terminal error, so a future
# harness regression cannot make them pass by failing somewhere else.
#
# The step's `run:` block is extracted from the shipped workflow (single source
# of truth) and exercised against a stubbed `gh`. Plain bash + awk + jq.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-privileged-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

script="$tmp/privileged.sh"
awk '
  $0 == "      - name: Privileged merge from trusted metadata only" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$script"
if ! grep -q 'trusted gate/checks did not become green' "$script" ||
   ! grep -q 'pr merge' "$script"; then
  echo "FAIL - could not extract the privileged merge run block from $wf"
  exit 1
fi

HEAD_SHA=f7d77ea9044bc2352423d4e6eca5c63c1847201d
OTHER_SHA=1111111111111111111111111111111111111111
TRUSTED_SHA=0123456789abcdef0123456789abcdef01234567
TRUSTED_WF_ID=312358392
TRUSTED_REPO_ID=1269388380
GATE_RUN_ID=30601252875
CONSUMER=Verjson/verjson-consumer
REQ_URL="https://api.github.com/repos/$CONSUMER/actions/required_workflows/318934643"

mkdir -p "$tmp/bin"

# `sleep` is a no-op so the bounded wait loop and the base-ref retry reach their
# terminal states in-process.
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"
# The attestation archive is never really zipped here; `unzip -p` yields the
# fixture the step then shape-validates for real.
printf '#!/usr/bin/env bash\ncat "$ATTESTATION_FILE"\n' >"$tmp/bin/unzip"

# Fake `gh`. Every branch returns an explicit, well-formed payload and anything
# unstubbed exits non-zero and is reported: falling through to a bare `exit 0`
# with empty stdout is exactly the fail-open shape these guards exist to prevent.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
ARGV=("$@")
args="$*"
emit() {
  local payload="$1" filter="" i
  for ((i = 0; i < ${#ARGV[@]}; i++)); do
    [ "${ARGV[$i]}" = "--jq" ] && filter="${ARGV[$((i + 1))]}"
  done
  if [ -n "$filter" ]; then jq -r "$filter" <<<"$payload"; else printf '%s\n' "$payload"; fi
  exit 0
}
bump() {
  local n
  n="$(cat "$1" 2>/dev/null || echo 0)"
  n=$((n + 1))
  printf '%s\n' "$n" >"$1"
  printf '%s' "$n"
}

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then echo "MERGE $args" >>"$ACTIONLOG"; exit 0; fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ "$(bump "$tmp_view_count")" -gt 1 ] && [ -s "$META_FINAL_FILE" ]; then
    emit "$(cat "$META_FINAL_FILE")"
  fi
  emit "$(cat "$META_FILE")"
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then emit '[]'; fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then echo "ISSUE" >>"$ACTIONLOG"; exit 0; fi

if [ "${1:-}" = "api" ]; then
  case "$args" in
    *"repos/Verjson/.github/actions/workflows/ai-review-merge.yml"*)
      emit "{\"id\":$TRUSTED_WF_ID}" ;;
    *"repos/Verjson/.github/commits/main"*)
      emit "{\"sha\":\"$TRUSTED_SHA\"}" ;;
    *"repos/Verjson/.github"*)
      emit "{\"id\":$TRUSTED_REPO_ID}" ;;
    */rules/branches/*)
      # Raw stdout: `--paginate` streams one JSON array per page, so a fixture
      # may hold several arrays, or nothing at all. The second read is the
      # pre-merge re-check, and may see a different rule set.
      if [ "$(bump "$tmp_rules_count")" -gt 1 ] && [ -s "$RULES_FINAL_FILE" ]; then
        cat "$RULES_FINAL_FILE"; exit 0
      fi
      # RULES_RC models `gh --paginate` emitting whole pages and then failing:
      # the pages that arrived must not be mistaken for the complete rule set.
      cat "$RULES_FILE"; exit "${RULES_RC:-0}" ;;
    */pulls/*/files*)
      emit '[{"filename":"src/index.ts"}]' ;;
    */pulls/18*)
      [ "${PULLS_RC:-0}" -eq 0 ] || exit "$PULLS_RC"
      if [ "$(bump "$tmp_base_count")" -gt 1 ] && [ -n "${BASE_REF_FINAL:-}" ]; then
        emit "{\"base\":{\"ref\":\"$BASE_REF_FINAL\"}}"
      fi
      emit "{\"base\":{\"ref\":\"$BASE_REF\"}}" ;;
    */actions/runs/*/artifacts*)
      emit "$(cat "$ARTIFACTS_FILE")" ;;
    */actions/artifacts/*/zip*)
      printf 'zip-bytes\n'; exit 0 ;;
    */actions/runs\?head_sha=*)
      emit "{\"workflow_runs\":$(cat "$RUNS_FILE")}" ;;
    */actions/runs/*)
      emit "$(jq -c '.[0]' "$RUNS_FILE")" ;;
  esac
fi
echo "UNSTUBBED gh $args" >>"$ACTIONLOG"
exit 1
GH
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep" "$tmp/bin/unzip"

org_entry() {
  # org_entry <source_type> <source> <repository_id> <ref>
  printf '{"type":"workflows","ruleset_source_type":"%s","ruleset_source":"%s","parameters":{"workflows":[{"path":".github/workflows/ai-review-merge.yml","ref":"%s","repository_id":%s}]}}' \
    "$1" "$2" "$4" "$3"
}
trusted_rules="[$(org_entry Organization Verjson "$TRUSTED_REPO_ID" refs/heads/main)]"

required_workflow_run="$(cat <<JSON
[{"id":$GATE_RUN_ID,"created_at":"2026-07-31T03:18:39Z","event":"pull_request","status":"completed",
  "conclusion":"success","workflow_id":318934643,"referenced_workflows":[],
  "path":".github/workflows/ai-review-merge.yml","head_sha":"$HEAD_SHA",
  "workflow_url":"$REQ_URL","repository":{"full_name":"$CONSUMER"}}]
JSON
)"

meta_open="$(cat <<JSON
{"headRefOid":"$HEAD_SHA","isDraft":false,"state":"OPEN","labels":[],
 "statusCheckRollup":[
   {"name":"gate","conclusion":"SUCCESS","detailsUrl":"https://github.com/$CONSUMER/actions/runs/$GATE_RUN_ID/job/1"},
   {"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
   {"name":"privileged_merge","status":"COMPLETED","conclusion":"CANCELLED"}]}
JSON
)"

attestation="$(cat <<JSON
{"version":1,"repository":"$CONSUMER","pr_number":18,"head_sha":"$HEAD_SHA","run_id":$GATE_RUN_ID,"followups":[]}
JSON
)"

reset_fixtures() {
  RULES="$trusted_rules"
  RULES_FINAL=""
  RUNS="$required_workflow_run"
  META="$meta_open"
  META_FINAL=""
  BASE_REF=main
  RULES_RC=0
  PULLS_RC=0
  BASE_REF_FINAL=""
}

run_case() { # run_case <event-name>
  export PATH="$tmp/bin:$PATH"
  export GH_TOKEN=stub-token RUNNER_TEMP="$tmp"
  export TARGET_REPO="$CONSUMER" TARGET_OWNER=Verjson GITHUB_REPOSITORY="$CONSUMER"
  export PR_NUMBER=18 EXPECTED_HEAD_SHA="$HEAD_SHA" SOURCE_RUN_ID="$GATE_RUN_ID"
  export GITHUB_EVENT_NAME="$1"
  # The shipped default (asserted at the end) is 80; the harness needs only
  # enough attempts to prove the loop reaches its terminal state.
  export MERGE_WAIT_ATTEMPTS=2
  export TRUSTED_WF_ID TRUSTED_REPO_ID TRUSTED_SHA BASE_REF BASE_REF_FINAL
  export RULES_RC PULLS_RC
  export RULES_FILE="$tmp/rules.json" RULES_FINAL_FILE="$tmp/rules-final.json"
  export RUNS_FILE="$tmp/runs.json"
  export META_FILE="$tmp/meta.json" META_FINAL_FILE="$tmp/meta-final.json"
  export ARTIFACTS_FILE="$tmp/artifacts.json" ATTESTATION_FILE="$tmp/attestation.json"
  export ACTIONLOG="$tmp/act.log"
  export tmp_view_count="$tmp/view.count" tmp_base_count="$tmp/base.count"
  export tmp_rules_count="$tmp/rules.count"
  : >"$ACTIONLOG"; : >"$tmp_view_count"; : >"$tmp_base_count"; : >"$tmp_rules_count"
  printf '%s' "$RULES" >"$RULES_FILE"
  printf '%s' "$RULES_FINAL" >"$RULES_FINAL_FILE"
  printf '%s' "$RUNS" >"$RUNS_FILE"
  printf '%s' "$META" >"$META_FILE"
  printf '%s' "$META_FINAL" >"$META_FINAL_FILE"
  printf '%s' "$attestation" >"$ATTESTATION_FILE"
  printf '{"artifacts":[{"id":42,"name":"merge-attestation-%s","expired":false}]}' \
    "$GATE_RUN_ID" >"$ARTIFACTS_FILE"
  bash -eo pipefail "$script" >"$tmp/out.txt" 2>&1
  rc=$?
  reset_fixtures
}
merged() { grep -q '^MERGE' "$tmp/act.log"; }
# A jq compile/runtime error ends in the same terminal message as a real
# rejection, so every case must rule it out or the negatives go vacuous.
# `error("unusable rules page")` is a deliberate fail-closed abort, not a defect.
jq_broke() { grep 'jq: error\|compile error' "$tmp/out.txt" | grep -qv 'unusable rules page'; }
unstubbed() { grep -q '^UNSTUBBED' "$tmp/act.log"; }

assert_merged() { # <label>
  if jq_broke; then fail "jq filter did not compile — $1"
  elif unstubbed; then fail "reached an unstubbed gh call — $1"
  elif merged && [ "$rc" -eq 0 ]; then pass "$1"
  else fail "$1 (rc=$rc)"; fi
}
assert_rejected() { # <label> <expected error substring>
  if merged; then fail "FAIL-OPEN: merged — $1"
  elif jq_broke; then fail "vacuous case (jq filter did not compile) — $1"
  elif unstubbed; then fail "vacuous case (aborted on an unstubbed gh call) — $1"
  elif [ "$rc" -eq 0 ]; then fail "terminated successfully without merging — $1"
  elif ! grep -q "$2" "$tmp/out.txt"; then
    fail "rejected for the wrong reason (wanted '$2') — $1"
  else pass "$1"; fi
}
assert_noop() { # <label> <expected notice substring>
  if merged; then fail "FAIL-OPEN: merged — $1"
  elif jq_broke; then fail "vacuous case (jq filter did not compile) — $1"
  elif [ "$rc" -ne 0 ] || ! grep -q "$2" "$tmp/out.txt"; then fail "$1 (rc=$rc)"
  else pass "$1"; fi
}

NOT_GREEN='trusted gate/checks did not become green'
reset_fixtures

# --- the two shapes that were dead before this fix -------------------------
run_case workflow_dispatch
assert_merged "dispatched continuation trusts an org required-workflow gate run and merges"

run_case pull_request_target
assert_merged "pull_request_target path trusts an org required-workflow gate run and merges"

# --- every clause of the organization-ruleset trust anchor -----------------
RULES="[$(org_entry Organization Verjson 999 refs/heads/main)]"
run_case workflow_dispatch
assert_rejected "required workflow sourced from an untrusted repository is not trusted" "$NOT_GREEN"

RULES="[$(org_entry Repository Verjson "$TRUSTED_REPO_ID" refs/heads/main)]"
run_case workflow_dispatch
assert_rejected "a non-Organization ruleset source cannot mint required-workflow trust" "$NOT_GREEN"

RULES="[$(org_entry Organization OtherOrg "$TRUSTED_REPO_ID" refs/heads/main)]"
run_case workflow_dispatch
assert_rejected "an organization ruleset owned by another org is not trusted" "$NOT_GREEN"

RULES="[$(org_entry Organization Verjson "$TRUSTED_REPO_ID" refs/heads/attacker)]"
run_case workflow_dispatch
assert_rejected "a required workflow pinned to a non-main ref is not trusted" "$NOT_GREEN"

# The invariant is "every rule at this path names the trusted source", not
# "some rule does": a valid entry must not launder an impostor beside it.
RULES="[$(org_entry Organization Verjson "$TRUSTED_REPO_ID" refs/heads/main),$(org_entry Repository "$CONSUMER" 999 refs/heads/main)]"
run_case workflow_dispatch
assert_rejected "an impostor rule alongside the valid one withdraws trust" "$NOT_GREEN"

RULES='[]'
run_case workflow_dispatch
assert_rejected "no workflows rule on the base branch leaves provenance untrusted" "$NOT_GREEN"

# An empty body must never read as "nothing objectionable found".
RULES=''
run_case workflow_dispatch
assert_rejected "an empty rules response does not grant trust" "$NOT_GREEN"

# The anchor is only sound over the complete rule set, and this endpoint pages.
RULES="[$(org_entry Organization Verjson "$TRUSTED_REPO_ID" refs/heads/main)]
[$(org_entry Repository "$CONSUMER" 999 refs/heads/main)]"
run_case workflow_dispatch
assert_rejected "an impostor on a later rules page still withdraws trust" "$NOT_GREEN"

RULES='{"message":"Not Found"}'
run_case workflow_dispatch
assert_rejected "an unusable rules page is not an empty rule set" "$NOT_GREEN"

# The dangerous shape is a *partial* read: a valid first page can otherwise
# stand in for the whole rule set while a later page hides an impostor.
RULES="[$(org_entry Organization Verjson "$TRUSTED_REPO_ID" refs/heads/main)]
{\"message\":\"Server Error\"}"
run_case workflow_dispatch
assert_rejected "an unusable page after a valid one withdraws trust" "$NOT_GREEN"

RULES_RC=1
run_case workflow_dispatch
assert_rejected "pages already received do not survive a failed rules read" "$NOT_GREEN"

# --- the run must itself be the required-workflow shape --------------------
RUNS="$(jq -c ".[0].workflow_url = \"https://api.github.com/repos/$CONSUMER/actions/workflows/318934643\" | ." <<<"$required_workflow_run")"
run_case workflow_dispatch
assert_rejected "a repo-local workflow at the trusted path is not required-workflow trusted" "$NOT_GREEN"

RUNS="$(jq -c '.[0].path = ".github/workflows/evil.yml" | .' <<<"$required_workflow_run")"
run_case workflow_dispatch
assert_rejected "a required workflow at another path is not the trusted gate" "$NOT_GREEN"

RUNS="$(jq -c '.[0].workflow_url = "https://api.github.com/repos/Evil/other/actions/required_workflows/1" | .' <<<"$required_workflow_run")"
run_case workflow_dispatch
assert_rejected "a required-workflow URL for another repository is not trusted" "$NOT_GREEN"

RUNS="$(jq -c ".[0].head_sha = \"$OTHER_SHA\" | ." <<<"$required_workflow_run")"
run_case workflow_dispatch
assert_rejected "dispatched source run for a different head is rejected" "$NOT_GREEN"

RUNS="$(jq -c '.[0].event = "push" | .' <<<"$required_workflow_run")"
run_case workflow_dispatch
assert_rejected "dispatched source run from an unexpected event is rejected" "$NOT_GREEN"

# --- base-branch handling --------------------------------------------------
BASE_REF='main/../../evil'
run_case workflow_dispatch
assert_rejected "a base ref with path traversal never reaches the rules lookup" "$NOT_GREEN"

BASE_REF='main?ref=refs/heads/evil'
run_case workflow_dispatch
assert_rejected "a base ref carrying URL syntax never reaches the rules lookup" "$NOT_GREEN"

BASE_REF_FINAL=release
run_case workflow_dispatch
assert_rejected "a base branch retargeted before merge is rejected" "base branch changed before merge"

# The anchor authorises a historical run, so it must still hold at merge time —
# not merely when the wait loop started.
RULES_FINAL="[$(org_entry Repository "$CONSUMER" 999 refs/heads/main)]"
run_case workflow_dispatch
assert_rejected "an anchor withdrawn before merge stops the merge" "trust anchor withdrawn before merge"

# --- terminal PR states ----------------------------------------------------
META="$(jq -c '.state = "MERGED"' <<<"$meta_open")"
run_case workflow_dispatch
assert_noop "a PR already merged at the expected head is a terminal no-op" "already merged"

# Head equality is asserted before the state read, so a merge at some *other*
# head must not be mistaken for this run's own outcome.
META="$(jq -c ".state = \"MERGED\" | .headRefOid = \"$OTHER_SHA\"" <<<"$meta_open")"
run_case workflow_dispatch
assert_rejected "a MERGED PR at a different head still fails on the stale head" "stale head"

META="$(jq -c '.state = "CLOSED"' <<<"$meta_open")"
run_case workflow_dispatch
assert_rejected "a closed-unmerged PR is not a no-op" "no longer open"

META_FINAL="$(jq -c '.state = "MERGED"' <<<"$meta_open")"
run_case workflow_dispatch
assert_noop "a PR merged between the wait loop and the final recheck settles clean" "already merged"

# The final block's no-op is only safe because head equality precedes it there
# too: a merge at some *other* head is not this run's outcome.
META_FINAL="$(jq -c ".state = \"MERGED\" | .headRefOid = \"$OTHER_SHA\"" <<<"$meta_open")"
run_case workflow_dispatch
assert_rejected "a merge at another head after the loop is not a no-op" "head changed before merge"

PULLS_RC=1
run_case workflow_dispatch
assert_rejected "an unreadable PR resource fails closed on the base branch" "could not resolve the PR base branch"

META="$(jq -c ".headRefOid = \"$OTHER_SHA\"" <<<"$meta_open")"
run_case workflow_dispatch
assert_rejected "stale head still fails closed" "stale head"

grep -q 'merge_wait_attempts="${MERGE_WAIT_ATTEMPTS:-80}"' "$wf" \
  && pass "shipped wait bound defaults to 80 attempts" \
  || fail "the production merge wait bound drifted from its 80-attempt default"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
