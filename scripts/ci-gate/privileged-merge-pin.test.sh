#!/usr/bin/env bash
# ADR 0042 requires a consumer's thin caller to pin `@main`, and until #278
# nothing enforced it. The caller file lives in the CONSUMER's repository, so
# `scripts/gen-privileged-merge-caller.sh` and `scripts/node-workflow-pins.test.sh`
# — both of which run here — bind nothing downstream. The existing runtime anchor
# pins the GATE's revision (`trusted_workflow_sha`), not this workflow's own, so
# ai-privileged-merge.yml could itself be executing from a fork or a stale ref
# with every other check passing.
#
# The step's `run:` block is extracted from the shipped workflow (single source
# of truth) and exercised against a stubbed `gh`, per house convention.
#
# Every negative case asserts the SPECIFIC terminal error, so a harness
# regression cannot make a case pass by failing somewhere else — the failure
# mode that let a fail-open guard ship green before.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-privileged-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

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
grep -q 'ADR 0042 requires callers to pin @main' "$script" \
  || { echo "FAIL - could not extract the pin check from $wf"; exit 1; }

# --- the WIRING, not just the values ----------------------------------------
# Everything below injects EXECUTING_WORKFLOW_* directly, so none of it can see
# where those variables come from. The first version of this change declared
# them in the JOB-level `env:`, where the `job` context is unavailable: they
# resolved empty, the fallbacks then described the CALLER instead of this file,
# and every consumer would have failed the identity check while `.github`'s own
# run stayed green. All twelve behavioural assertions passed.
#
# So assert the placement structurally, and note that no behavioural test in
# this file can substitute for it.
python3 - "$wf" <<'WIRING_PY' && pass "workflow identity is declared on the STEP, where the job context exists" \
  || fail "EXECUTING_WORKFLOW_* is missing or declared at job level, where \`job\` resolves empty"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
job = d["jobs"]["privileged_merge"]
# Job-level env must NOT carry them: `job` is not an available context there.
if any(k.startswith("EXECUTING_WORKFLOW_") for k in (job.get("env") or {})):
    sys.exit(1)
step = job["steps"][0]
env = step.get("env") or {}
want = {
    "EXECUTING_WORKFLOW_SHA": "${{ job.workflow_sha }}",
    "EXECUTING_WORKFLOW_REPOSITORY": "${{ job.workflow_repository }}",
}
sys.exit(0 if all(env.get(k) == v for k, v in want.items()) else 1)
WIRING_PY

MAIN_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_MAIN_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
FORK_SHA=cccccccccccccccccccccccccccccccccccccccc

mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"

# The stub answers only what the pin check needs and then makes the run stop.
# Anything unstubbed exits non-zero: falling through to a bare success with
# empty stdout is the fail-open shape this whole file exists to prevent.
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
case "$args" in
  *"/compare/"*)
    [ "${COMPARE_RC:-0}" -eq 0 ] || exit "${COMPARE_RC}"
    emit "$COMPARE_FIXTURE" ;;
  *"repos/Verjson/.github/actions/workflows/ai-review-merge.yml"*) emit '{"id":312358392}' ;;
  *"repos/Verjson/.github/commits/main"*) emit "{\"sha\":\"$MAIN_SHA\"}" ;;
  # Reached only AFTER the pin check passes. Failing here is how a positive case
  # proves the check let the run through rather than silently ending early.
  *"repos/Verjson/.github"*) echo "REACHED_PAST_PIN_CHECK" >&2; exit 42 ;;
esac
echo "UNSTUBBED gh $args" >&2
exit 1
GH
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"

run_case() {
  PATH="$tmp/bin:$PATH" \
  GH_TOKEN=stub-token RUNNER_TEMP="$tmp" \
  TARGET_REPO="${GITHUB_REPOSITORY_OVERRIDE:-Verjson/example}" TARGET_OWNER=Verjson \
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY_OVERRIDE:-Verjson/example}" \
  PR_NUMBER=7 EXPECTED_HEAD_SHA=f7d77ea9044bc2352423d4e6eca5c63c1847201d \
  GITHUB_EVENT_NAME=pull_request_target \
  MAIN_SHA="$MAIN_SHA" \
  EXECUTING_WORKFLOW_SHA="${EXECUTING_WORKFLOW_SHA:-}" \
  EXECUTING_WORKFLOW_REPOSITORY="${EXECUTING_WORKFLOW_REPOSITORY:-}" \
  SELF_WORKFLOW_SHA="${SELF_WORKFLOW_SHA:-}" \
  COMPARE_FIXTURE="${COMPARE_FIXTURE:-}" COMPARE_RC="${COMPARE_RC:-0}" \
    bash "$script" 2>&1
}

# --- the executing revision IS main -----------------------------------------
# Equality short-circuits before any compare call. The stub proves the run got
# past the check by failing loudly at the next API call.
out="$(EXECUTING_WORKFLOW_SHA="$MAIN_SHA" EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github run_case)"
grep -qF 'REACHED_PAST_PIN_CHECK' <<<"$out" \
  && ! grep -qF 'not on Verjson/.github@main' <<<"$out" \
  && pass "a run at main's tip passes without a compare call" \
  || fail "the tip revision was rejected: $out"

# --- reachable from main, i.e. main advanced mid-flight ----------------------
out="$(EXECUTING_WORKFLOW_SHA="$OLD_MAIN_SHA" EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github \
  COMPARE_FIXTURE='{"status":"ahead","behind_by":0}' run_case)"
grep -qF 'REACHED_PAST_PIN_CHECK' <<<"$out" \
  && pass "a revision still reachable from main is accepted" \
  || fail "an ancestor of main was rejected: $out"

# Accepted, but never silently: this is the SHA-pinned-caller case as well as
# the benign race, and the two are indistinguishable here. Losing the warning
# would turn a stated residual risk back into an unrecorded one.
grep -qF '::warning::' <<<"$out" \
  && grep -qF 'SHA-pinned' <<<"$out" \
  && pass "the behind-but-reachable case warns that it may be a forbidden pin" \
  || fail "behind-but-reachable produced no warning: $out"

# --- not on main at all ------------------------------------------------------
for status in behind diverged; do
  out="$(EXECUTING_WORKFLOW_SHA="$FORK_SHA" EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github \
    COMPARE_FIXTURE="{\"status\":\"$status\",\"behind_by\":3}" run_case)"
  grep -qF 'not on Verjson/.github@main' <<<"$out" \
    && ! grep -qF 'REACHED_PAST_PIN_CHECK' <<<"$out" \
    && pass "a '$status' revision is rejected and the run stops there" \
    || fail "a '$status' revision was not rejected: $out"
done

# `ahead` with a non-zero behind_by is a diverged history that merely shares an
# ancestor. Matching on status alone would accept it.
out="$(EXECUTING_WORKFLOW_SHA="$FORK_SHA" EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github \
  COMPARE_FIXTURE='{"status":"ahead","behind_by":2}' run_case)"
grep -qF 'not on Verjson/.github@main' <<<"$out" \
  && pass "'ahead' with commits behind is rejected — status alone is not enough" \
  || fail "a diverged revision passed on status alone: $out"

# --- the comparison itself cannot be read ------------------------------------
# Undetermined provenance must stop the run. Treating an API failure as "assume
# fine" is the fail-open this repository has shipped twice before.
out="$(EXECUTING_WORKFLOW_SHA="$FORK_SHA" EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github \
  COMPARE_RC=1 run_case)"
grep -qF 'cannot compare the executing revision' <<<"$out" \
  && ! grep -qF 'REACHED_PAST_PIN_CHECK' <<<"$out" \
  && pass "an unreadable comparison fails closed" \
  || fail "unreadable comparison did not fail closed: $out"

# A well-formed response missing `.status` must not be read as acceptance.
out="$(EXECUTING_WORKFLOW_SHA="$FORK_SHA" EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github \
  COMPARE_FIXTURE='{}' run_case)"
grep -qF 'not on Verjson/.github@main' <<<"$out" \
  && pass "a comparison with no status is rejected" \
  || fail "an empty comparison was accepted: $out"

# --- the workflow is not this repository's -----------------------------------
out="$(EXECUTING_WORKFLOW_SHA="$MAIN_SHA" EXECUTING_WORKFLOW_REPOSITORY=Attacker/evil run_case)"
grep -qF "is executing from 'Attacker/evil'" <<<"$out" \
  && ! grep -qF 'REACHED_PAST_PIN_CHECK' <<<"$out" \
  && pass "a workflow executing from another repository is rejected" \
  || fail "a foreign workflow repository was accepted: $out"

# --- the revision cannot be determined ---------------------------------------
# Both context spellings absent. Must name the real cause, not abort on an
# unbound variable three steps from anything actionable.
out="$(run_case)"
grep -qF 'cannot determine which revision' <<<"$out" \
  && ! grep -qF 'unbound variable' <<<"$out" \
  && pass "an undeterminable revision fails closed with a usable message" \
  || fail "absent workflow identity did not fail closed cleanly: $out"

# The `.github` pull_request_target shape, modelled as it actually occurs: the
# job is not reusable-defined, so BOTH job-context values are empty and the
# repository falls back to GITHUB_REPOSITORY. Setting EXECUTING_WORKFLOW_REPOSITORY
# explicitly here would test a shape production never produces — and would leave
# the repository fallback, the branch that really runs, uncovered.
out="$(GITHUB_REPOSITORY_OVERRIDE=Verjson/.github SELF_WORKFLOW_SHA="$MAIN_SHA" run_case)"
grep -qF 'REACHED_PAST_PIN_CHECK' <<<"$out" \
  && pass "a direct (non-reusable) run falls back to the run's own SHA and repository" \
  || fail "the direct-run fallback was rejected: $out"

# ...and the same shape in a CONSUMER repository must be rejected, not accepted
# by the same fallback. This is the case the job-level `env:` bug produced.
out="$(GITHUB_REPOSITORY_OVERRIDE=Verjson/example SELF_WORKFLOW_SHA="$MAIN_SHA" run_case)"
grep -qF "is executing from 'Verjson/example'" <<<"$out" \
  && ! grep -qF 'REACHED_PAST_PIN_CHECK' <<<"$out" \
  && pass "an empty job context in a consumer repository is rejected, not fallen back into" \
  || fail "empty workflow identity was accepted in a consumer repository: $out"

# A malformed SHA must be rejected on shape, not passed to the API.
out="$(EXECUTING_WORKFLOW_SHA='main; rm -rf /' EXECUTING_WORKFLOW_REPOSITORY=Verjson/.github run_case)"
grep -qF 'cannot determine which revision' <<<"$out" \
  && pass "a non-SHA revision value is rejected before any API call" \
  || fail "a malformed revision was not rejected on shape: $out"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
