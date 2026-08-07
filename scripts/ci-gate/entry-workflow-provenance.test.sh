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

# --- #279: reusable-caller provenance is repository-authorable -------------
# Even at the canonical path, a consumer-authored caller can reference the gate
# under `if: false`, mint the named check and upload matching JSON. Until the
# payload is signed by the producing workflow (#261), this shape is review-only
# and must never authorize privileged merge.
run_case pull_request_target
assert_rejected "an unsigned reusable caller cannot authorize pull_request_target merge" "$NOT_GREEN"

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
assert_rejected "an unsigned reusable caller cannot authorize dispatched merge" "$NOT_GREEN"

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

# Where the organization ruleset mandates the gate, the matchers are exclusive:
# only the run the ruleset injected is honest. Every case above runs with no
# `workflows` rule, so none of them reach this branch — and without these two the
# entry binding stays forgeable for every Verjson repository, which is the only
# shape any of them are in (#279, ADR 0044).
org_rule="$(printf '[{"type":"workflows","ruleset_source_type":"Organization","ruleset_source":"Verjson","parameters":{"workflows":[{"path":".github/workflows/ai-review-merge.yml","ref":"refs/heads/main","repository_id":%s}]}}]' "$TRUSTED_REPO_ID")"

# The forgery the entry conjunct alone does not stop: a write-access actor ADDS a
# repo-local `.github/workflows/ai-review-merge.yml` that merely names the gate
# and never runs it. It satisfies the entry path and the reference matcher; only
# its `workflow_url` betrays it as repo-local rather than ruleset-injected.
RULES="$org_rule"
RUNS="$caller_run"
run_case pull_request_target
assert_rejected "a repo-local workflow at the gate path cannot borrow ruleset trust" "$NOT_GREEN"

RULES="$org_rule"
RUNS="$(printf '%s' "$caller_run" | sed "s|\"workflow_url\":\"$CALLER_URL\"|\"workflow_url\":\"https://api.github.com/repos/$CONSUMER/actions/required_workflows/77\"|")"
run_case pull_request_target
assert_merged "the run the organization ruleset injected is still trusted"

# The extracted block is the shipped one, but pin the predicate's shape too: a
# refactor that keeps the defs and stops applying them would pass every case
# above only if the fixtures happened to cover it. Assert both directly.
grep -q 'gate_is_entry_workflow and (' "$wf" \
  && pass "the shipped predicate applies the entry-workflow conjunct to every matcher" \
  || fail "the entry-workflow conjunct is no longer applied across the trusted-run matchers"

grep -q 'if $required then' "$wf" && grep -q 'injected_by_ruleset' "$wf" \
  && pass "ruleset-mandated repositories are matched only by the injected run" \
  || fail "the required-workflow matcher is additive again, re-opening the repo-local forgery"

! sed -n '/trusted_run_def=/,/^[[:space:]]*'\''$/p' "$wf" \
    | grep -q 'referenced_workflows' \
  && pass "repository-authored reusable references never grant merge authority" \
  || fail "the privileged trust predicate still accepts forgeable reusable references"

# --- #263: draft and hold are terminal no-ops, not red checks ---------------
# The repository's own guidance says to open non-trivial work as a draft so the
# gate skips it. This job fired anyway and died with `::error::PR is draft` +
# exit 1, so every PR that followed the guidance carried a red
# `privileged_merge` — which is how a fleet learns to merge past red. ADR 0037
# already established the shape for the workflow-files hold: notice + exit 0.
#
# The invariant is TWO-SIDED and both sides are asserted, because either alone is
# satisfiable by a wrong fix. It must not merge, and it must not fail.
assert_terminal_no_op() { # <label> <expected notice substring>
  if merged; then fail "FAIL-OPEN: merged — $1"
  elif jq_broke; then fail "vacuous case (jq filter did not compile) — $1"
  elif unstubbed; then fail "vacuous case (aborted on an unstubbed gh call) — $1"
  elif [ "$rc" -ne 0 ]; then fail "still a red check instead of a no-op (rc=$rc) — $1"
  elif ! grep -q "$2" "$tmp/out.txt"; then
    fail "exited 0 without saying why (wanted '$2') — $1"
  else pass "$1"; fi
}

META="$(jq -c '.isDraft = true' <<<"$meta_open")"
run_case pull_request_target
assert_terminal_no_op "#263: a draft PR is a terminal no-op, not a red check" 'is a draft'

for label in hold 'DO NOT MERGE' do-not-merge Do_Not_Merge; do
  META="$(jq -c --arg l "$label" '.labels = [{"name": $l}]' <<<"$meta_open")"
  run_case pull_request_target
  assert_terminal_no_op "#263: a '$label' label is a terminal no-op, not a red check" 'hold label'
done

# The fail-closed direction, which is why this could not be a literal reading of
# #263. `jq -e '.isDraft | not' || exit 1` was fail-CLOSED only because its
# failure branch exited non-zero; switching that to `exit 0` would have turned a
# jq error on unreadable PR metadata into a SILENT SUCCESS on the workflow that
# carries merge authority — #480's defect, freshly introduced. An unreadable
# signal is neither a hold nor a pass.
for bad in \
  'a draft flag that is a string:{"headRefOid":"HEADSHA","isDraft":"maybe","state":"OPEN","labels":[]}' \
  'labels that are not an array:{"headRefOid":"HEADSHA","isDraft":false,"state":"OPEN","labels":"hold"}' \
  'a label name that is an object:{"headRefOid":"HEADSHA","isDraft":false,"state":"OPEN","labels":[{"name":{"x":1}}]}' \
; do
  label="${bad%%:*}"
  META="${bad#*:}"
  META="${META//HEADSHA/$HEAD_SHA}"
  run_case pull_request_target
  if merged; then
    fail "FAIL-OPEN: $label was MERGED — an unreadable hold signal must never merge"
  elif [ "$rc" -eq 0 ]; then
    fail "FAIL-OPEN: $label exited 0 as a no-op — an unreadable signal is not a hold (#480)"
  else
    pass "#263/#480: $label fails closed rather than passing as a hold ($rc)"
  fi
done

# A truthy `.isDraft` string is not a draft. jq's `if` treats every non-null,
# non-false value as true, so a naive materialisation would report the string
# "maybe" as a hold and silently stop merging real PRs. The case above pins that
# it is an ERROR instead — the distinction between "held" and "unreadable".
grep -q 'could not read the draft state' "$wf" \
  && pass "#480: an unreadable draft state has its own error, distinct from a hold" \
  || fail "#480: the draft check cannot distinguish unreadable from held"

reset_fixtures

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
