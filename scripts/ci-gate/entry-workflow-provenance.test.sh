#!/usr/bin/env bash
# Tests that the privileged merge trusts a gate run only when the gate is the
# run's ENTRY workflow (Verjson/.github#279, ADR 0044).
#
# `referenced_workflows[]` is a property of the workflow FILE, not of what
# executed: a job carrying `uses: Verjson/.github/.github/workflows/
# ai-review-merge.yml@main` under `if: false` still lists the reference. The
# original matcher trusted any run whose file merely named the gate at `main`'s
# SHA, so one crafted workflow in a consumer repository could mint all three
# signals the privileged merge asks for — reference the gate, publish a job
# literally named `gate` that succeeds, and upload a hand-written
# `merge-attestation-<run_id>` artifact — and obtain an `--admin` merge.
#
# The fixtures below therefore supply ALL of those signals on every negative
# case. A case that rejects only because the attestation or the `gate` check is
# missing would prove nothing about the provenance binding, so the forgeries
# here are complete and the entry workflow is the only thing that differs.
#
# The step's `run:` block is extracted from the shipped workflow (single source
# of truth) and exercised against a stubbed `gh`. Plain bash + awk + jq, matching
# required-workflow-provenance.test.sh.
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
CALLER_WF_ID=771122
CALLER_URL="https://api.github.com/repos/$CONSUMER/actions/workflows/$CALLER_WF_ID"
GATE_PATH=.github/workflows/ai-review-merge.yml

mkdir -p "$tmp/bin"

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

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then echo "MERGE $args" >>"$ACTIONLOG"; exit 0; fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then emit "$(cat "$META_FILE")"; fi
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
      cat "$RULES_FILE"; exit 0 ;;
    */pulls/*/files*)
      emit '[{"filename":"src/index.ts"}]' ;;
    */pulls/18*)
      emit '{"base":{"ref":"main"}}' ;;
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

# The reusable-caller shape (ADR 0022): the consumer's own thin caller is the
# entry workflow, it lives at the canonical gate path, and it delegates to
# Verjson/.github@main — which is what `referenced_workflows` records.
caller_run="$(cat <<JSON
[{"id":$GATE_RUN_ID,"created_at":"2026-08-01T03:18:39Z","event":"pull_request","status":"completed",
  "conclusion":"success","workflow_id":$CALLER_WF_ID,
  "referenced_workflows":[
    {"path":"Verjson/.github/.github/workflows/ai-review-merge.yml@main","sha":"$TRUSTED_SHA","ref":"refs/heads/main"}],
  "path":"$GATE_PATH","head_sha":"$HEAD_SHA",
  "workflow_url":"$CALLER_URL","repository":{"full_name":"$CONSUMER"}}]
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

# No organization `workflows` rule: this suite isolates the reference/entry
# matcher, so required-workflow trust (ADR 0039) can never mask a verdict.
reset_fixtures() {
  RULES='[]'
  RUNS="$caller_run"
  META="$meta_open"
}

run_case() { # run_case <event-name>
  export PATH="$tmp/bin:$PATH"
  export GH_TOKEN=stub-token RUNNER_TEMP="$tmp"
  export TARGET_REPO="$CONSUMER" TARGET_OWNER=Verjson GITHUB_REPOSITORY="$CONSUMER"
  export PR_NUMBER=18 EXPECTED_HEAD_SHA="$HEAD_SHA" SOURCE_RUN_ID="$GATE_RUN_ID"
  export GITHUB_EVENT_NAME="$1"
  export EXECUTING_WORKFLOW_SHA="$TRUSTED_SHA"
  export EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github
  export SELF_WORKFLOW_SHA="$TRUSTED_SHA"
  export MERGE_WAIT_ATTEMPTS=2
  export TRUSTED_WF_ID TRUSTED_REPO_ID TRUSTED_SHA
  export RULES_FILE="$tmp/rules.json" RUNS_FILE="$tmp/runs.json"
  export META_FILE="$tmp/meta.json"
  export ARTIFACTS_FILE="$tmp/artifacts.json" ATTESTATION_FILE="$tmp/attestation.json"
  export ACTIONLOG="$tmp/act.log"
  : >"$ACTIONLOG"
  printf '%s' "$RULES" >"$RULES_FILE"
  printf '%s' "$RUNS" >"$RUNS_FILE"
  printf '%s' "$META" >"$META_FILE"
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

NOT_GREEN='trusted gate/checks did not become green'
reset_fixtures

# --- positive control: the legitimate shape must still merge ---------------
# Without this the negatives below could pass vacuously, e.g. because the
# harness never produces a trustworthy run at all.
run_case pull_request_target
assert_merged "a gate-entry run is trusted on the pull_request_target path"

# --- #279: referenced is not executed --------------------------------------
# Identical run in every respect the privileged merge can observe — the gate
# reference at main's SHA, a successful `gate` check bound to this run id, and a
# well-formed attestation artifact — except that the run's ENTRY workflow is a
# consumer-authored file. That is the forgery: the reference can come from a job
# that never ran.
RUNS="$(jq -c '.[0].path = ".github/workflows/release.yml" | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "a run that only REFERENCES the gate from another entry workflow is not trusted" "$NOT_GREEN"

# The dispatched continuation is the weaker path — it never consults the check
# rollup, so a hand-written `merge-attestation-<run_id>` artifact is the ONLY
# thing standing between a crafted run and the merge. The fixture supplies that
# artifact, correctly shaped and bound to this run, PR and head.
RUNS="$(jq -c '.[0].path = ".github/workflows/release.yml" | .' <<<"$caller_run")"
run_case workflow_dispatch
assert_rejected "a hand-written attestation from a non-gate entry workflow is not trusted" "$NOT_GREEN"

run_case workflow_dispatch
assert_merged "a gate-entry run is trusted on the dispatched continuation path"

# --- the entry binding applies to the workflow_id matcher too ---------------
# Shape 1 is `.github` running its own gate. The id is globally unique so it
# already implies the path, but the conjunct must not be shape-selective: a
# matcher exempted from it would carry the #279 hole for its own shape.
id_run="$(jq -c ".[0].workflow_id = $TRUSTED_WF_ID | .[0].referenced_workflows = [] | ." <<<"$caller_run")"
RUNS="$id_run"
run_case pull_request_target
assert_merged "the workflow_id matcher still trusts a run whose entry workflow is the gate"

RUNS="$(jq -c '.[0].path = ".github/workflows/release.yml" | .' <<<"$id_run")"
run_case pull_request_target
assert_rejected "the workflow_id matcher is entry-bound too" "$NOT_GREEN"

# --- boundaries around the entry path --------------------------------------
# Equality, never a prefix: a neighbouring file must not inherit the gate's name.
RUNS="$(jq -c '.[0].path = ".github/workflows/ai-review-merge.yml.bak" | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "an entry path that merely starts with the gate path is not the gate" "$NOT_GREEN"

RUNS="$(jq -c '.[0].path = "ai-review-merge.yml" | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "the gate filename outside .github/workflows is not the gate" "$NOT_GREEN"

# The reference itself must still be pinned to main's revision — the entry
# binding is an addition to that check, not a replacement for it.
RUNS="$(jq -c ".[0].referenced_workflows[0].sha = \"$OTHER_SHA\" | ." <<<"$caller_run")"
run_case pull_request_target
assert_rejected "a gate reference at a revision other than main's is still rejected" "$NOT_GREEN"

# --- malformed or absent API fields must fail CLOSED ------------------------
# The failure mode this repository keeps producing is a guard that reads as
# fail-closed and ships fail-open, so each missing-field shape is pinned.
RUNS="$(jq -c 'del(.[0].path) | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "a run with no path field is not trusted" "$NOT_GREEN"

RUNS="$(jq -c '.[0].path = null | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "a null path is not trusted" "$NOT_GREEN"

RUNS="$(jq -c '.[0].path = "" | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "an empty path is not trusted" "$NOT_GREEN"

RUNS="$(jq -c 'del(.[0].referenced_workflows) | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "a gate-path entry with no reference to the gate is not trusted" "$NOT_GREEN"

# A non-array in an array-shaped field must not abort the filter into a verdict:
# `jq` erroring out and a real rejection reach the same terminal message.
RUNS="$(jq -c '.[0].referenced_workflows = "not-an-array" | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "a non-array referenced_workflows fails closed rather than crashing" "$NOT_GREEN"

RUNS="$(jq -c '.[0].referenced_workflows = [{"sha":"'"$TRUSTED_SHA"'"}] | .' <<<"$caller_run")"
run_case pull_request_target
assert_rejected "a reference entry with no path fails closed" "$NOT_GREEN"

RUNS='[{}]'
run_case pull_request_target
assert_rejected "an empty run object is not trusted" "$NOT_GREEN"

RUNS='[]'
run_case pull_request_target
assert_rejected "no candidate run at the expected head is not trusted" "$NOT_GREEN"

RUNS='[{}]'
run_case workflow_dispatch
assert_rejected "an empty dispatched source run is not trusted" "$NOT_GREEN"

# The extracted block is the shipped one, but pin the conjunct's shape too: a
# refactor that keeps the def and stops applying it would pass every case above
# only if the fixtures happened to cover it. This asserts it directly.
grep -q 'gate_is_entry_workflow and (' "$wf" \
  && pass "the shipped predicate applies the entry-workflow conjunct to every matcher" \
  || fail "the entry-workflow conjunct is no longer applied across the trusted-run matchers"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
