#!/usr/bin/env bash
# Unit tests for scripts/fleet-watchdog.sh against a stubbed `gh`.
#
# The watchdog cancels other people's CI runs, so the tests that matter are the
# ones proving it does NOT: an unreadable fleet, spare capacity, an empty queue,
# and young jobs must all leave everything alone. Plain bash + jq, no framework.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/fleet-watchdog.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - watchdog script not found"; exit 1; }

mkdir -p "$tmp/bin"
# Stub `gh`. Fixtures are files so each case can reshape one facet at a time.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
# Emulate the real `gh api --jq`: the filter is applied client-side, so a stub
# that ignores it hands the script raw JSON where it expects a number or a TSV
# stream — every guard then reads as "0 / nothing found" and the tests pass for
# the wrong reason.
filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "--jq" ] && filter="${args[$((i + 1))]}"
done
emit() {
  if [ -n "$filter" ]; then jq -r "$filter" "$1"; else cat "$1"; fi
}
case "$*" in
  *"actions/runners"*)
    [ "${RUNNERS_FAIL:-false}" = true ] && exit 1
    emit "$RUNNERS_FILE"; exit 0 ;;
  *"/cancel"*)
    echo "CANCELLED $*" >>"$ACTIONLOG"; exit 0 ;;
  *"orgs/"*"/repos"*)
    printf '%s\n' "${REPOS:-alpha}"; exit 0 ;;
  *"status=queued"*)   emit "$QUEUED_FILE"; exit 0 ;;
  *"status=in_progress"*) emit "$INPROGRESS_FILE"; exit 0 ;;
  *"/jobs"*)           emit "$JOBS_FILE"; exit 0 ;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

# jq is invoked with --jq by the real gh; our stub ignores it, so the script's
# own `jq` calls do the filtering. Provide well-formed payloads.
busy_pool()  { printf '{"runners":[{"status":"online","busy":true,"labels":[{"name":"general"}]},{"status":"online","busy":true,"labels":[{"name":"general"}]}]}\n'; }
idle_pool()  { printf '{"runners":[{"status":"online","busy":false,"labels":[{"name":"general"}]}]}\n'; }
# `gh api --paginate` emits one document per page. Two busy pages must aggregate
# to one saturated pool, not to two per-page counts (#355).
busy_pool_2pages() {
  printf '{"runners":[{"status":"online","busy":true,"labels":[{"name":"general"}]}]}\n'
  printf '{"runners":[{"status":"online","busy":true,"labels":[{"name":"general"}]}]}\n'
}
# Same two pages, but the second one holds the only idle runner. A per-page
# reader sees page 1 and cancels; a correct reader sees spare capacity.
mixed_pool_2pages() {
  printf '{"runners":[{"status":"online","busy":true,"labels":[{"name":"general"}]}]}\n'
  printf '{"runners":[{"status":"online","busy":false,"labels":[{"name":"general"}]}]}\n'
}
# A page without its `.runners` array is an unusable response, not an empty pool.
malformed_pool_2pages() {
  printf '{"runners":[{"status":"online","busy":true,"labels":[{"name":"general"}]}]}\n'
  printf '{"message":"Bad credentials"}\n'
}

# A subshell, so a `WATCHDOG_DRY_RUN=true run_watchdog` prefix cannot leak into
# the cases that follow — bash keeps prefix assignments on a function call, which
# would silently disarm every later "it SHOULD cancel" assertion.
run_watchdog() (
  export PATH="$tmp/bin:$PATH"
  export WATCHDOG_ORG=TestOrg WATCHDOG_MIN_AGE_MINUTES=35 WATCHDOG_MIN_POLL_MINUTES=10
  export WATCHDOG_DRY_RUN="${WATCHDOG_DRY_RUN:-false}"
  export ACTIONLOG="$tmp/act.log"; : >"$ACTIONLOG"
  bash "$script" >"$tmp/out.txt" 2>&1
  printf 'rc=%s' "$?"
)
cancelled() { grep -qF CANCELLED "$tmp/act.log"; }

# Fixtures: one stale poll job, one queued run.
old_iso="$(date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
mid_iso="$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
new_iso="$(date -u -d '2 minutes ago'  +%Y-%m-%dT%H:%M:%SZ)"

# The gate names the step that polls; the watchdog reads that step's state
# instead of inferring "waiting" from age (#343).
POLL_STEP='Wait once for the rest of CI to be green'
gate_job() { # $1 = started_at, $2 = poll step status
  printf '{"jobs":[{"status":"in_progress","started_at":"%s","steps":[{"name":"%s","status":"%s"}]}]}\n' \
    "$1" "$POLL_STEP" "$2"
}

export RUNNERS_FILE="$tmp/runners.json" QUEUED_FILE="$tmp/queued.json"
export INPROGRESS_FILE="$tmp/inprog.json" JOBS_FILE="$tmp/jobs.json"
printf '{"workflow_runs":[{"id":1,"name":"AI privileged merge"}]}\n' >"$INPROGRESS_FILE"
printf '{"workflow_runs":[{"id":9,"name":"CI"}]}\n' >"$QUEUED_FILE"
printf '{"jobs":[{"status":"in_progress","started_at":"%s"}]}\n' "$old_iso" >"$JOBS_FILE"
busy_pool >"$RUNNERS_FILE"

# --- the one case where it SHOULD act ---------------------------------------
run_watchdog >/dev/null
cancelled \
  && pass "preempts a stale poll job when the pool is full and work is queued" \
  || { fail "did not preempt a stale poll job"; sed 's/^/diag - /' "$tmp/out.txt"; }

# --- every case where it must NOT ------------------------------------------
idle_pool >"$RUNNERS_FILE"
run_watchdog >/dev/null
! cancelled && pass "spare capacity — cancels nothing" || fail "cancelled despite an idle runner"
busy_pool >"$RUNNERS_FILE"

printf '{"workflow_runs":[]}\n' >"$QUEUED_FILE"
run_watchdog >/dev/null
! cancelled && pass "empty queue — a long poll harms nobody, cancels nothing" || fail "cancelled with nothing queued"
printf '{"workflow_runs":[{"id":9,"name":"CI"}]}\n' >"$QUEUED_FILE"

printf '{"jobs":[{"status":"in_progress","started_at":"%s"}]}\n' "$new_iso" >"$JOBS_FILE"
run_watchdog >/dev/null
! cancelled && pass "a young poll job is left alone" || fail "cancelled a job under the age threshold"
printf '{"jobs":[{"status":"in_progress","started_at":"%s"}]}\n' "$old_iso" >"$JOBS_FILE"

# A CI run must never be a candidate, however long it has been going.
printf '{"workflow_runs":[{"id":1,"name":"CI"}]}\n' >"$INPROGRESS_FILE"
run_watchdog >/dev/null
! cancelled && pass "never preempts a non-poll workflow (CI)" || fail "cancelled a CI run — it would lose real work"
printf '{"workflow_runs":[{"id":1,"name":"AI privileged merge"}]}\n' >"$INPROGRESS_FILE"

# Unknown fleet state is inconclusive, and inconclusive must not authorise a
# cancel. Exit 2 (fault), not 0 (all clear).
export RUNNERS_FAIL=true
rc="$(run_watchdog)"
{ [ "$rc" = "rc=2" ] && ! cancelled; } \
  && pass "an unreadable runner list is a fault, never a licence to cancel" \
  || fail "unreadable fleet did not fail closed ($rc)"
unset RUNNERS_FAIL; export RUNNERS_FAIL=false

# Dry run reports without acting.
WATCHDOG_DRY_RUN=true run_watchdog >/dev/null
{ ! cancelled && grep -q 'DRY RUN' "$tmp/out.txt"; } \
  && pass "dry run reports candidates without cancelling" \
  || fail "dry run either cancelled or reported nothing"

# --- #342: the arm/disarm switch has no implicit default --------------------
# #336 shipped armed because two layers each carried a default and the running
# log described the other one. Pin the DEFAULT, not only the guarded value.
run_bare() { # run without WATCHDOG_DRY_RUN in the environment at all
  ( export PATH="$tmp/bin:$PATH"
    export WATCHDOG_ORG=TestOrg WATCHDOG_MIN_AGE_MINUTES=35 WATCHDOG_MIN_POLL_MINUTES=10
    export ACTIONLOG="$tmp/act.log"; : >"$ACTIONLOG"
    unset WATCHDOG_DRY_RUN
    [ -n "${1:-}" ] && export WATCHDOG_DRY_RUN="$1"
    bash "$script" >"$tmp/out.txt" 2>&1
    printf 'rc=%s' "$?" )
}

rc="$(run_bare)"
{ [ "$rc" = "rc=2" ] && ! cancelled; } \
  && pass "an unset WATCHDOG_DRY_RUN is a fault, not an implicit licence to cancel (#342)" \
  || fail "unset WATCHDOG_DRY_RUN did not fail closed ($rc)"

rc="$(run_bare yes)"
{ [ "$rc" = "rc=2" ] && ! cancelled; } \
  && pass "an unparseable WATCHDOG_DRY_RUN is a fault, never treated as armed (#342)" \
  || fail "WATCHDOG_DRY_RUN=yes did not fail closed ($rc)"

rc="$(run_bare false)"
{ [ "$rc" = "rc=0" ] && cancelled; } \
  && pass "an explicit WATCHDOG_DRY_RUN=false still arms the cancel path" \
  || fail "explicit arming did not cancel ($rc)"

# --- #343: preemptability is a state, not an age ----------------------------
# The AI lane's own poll window is 30 minutes, shorter than MIN_AGE_MINUTES, so
# an age rule could only ever reach gates that had already left `ci_wait` and
# started spending model-review budget.
printf '{"workflow_runs":[{"id":1,"name":"AI review + auto-merge"}]}\n' >"$INPROGRESS_FILE"

gate_job "$mid_iso" in_progress >"$JOBS_FILE"
run_watchdog >/dev/null
cancelled \
  && pass "a gate still inside ci_wait at 20 minutes is a candidate (#343)" \
  || { fail "a provably polling gate was not preempted"; sed 's/^/diag - /' "$tmp/out.txt"; }

gate_job "$old_iso" completed >"$JOBS_FILE"
run_watchdog >/dev/null
! cancelled \
  && pass "a gate past ci_wait is never preempted, however old — that is model review (#343)" \
  || fail "cancelled a gate that had finished polling; that discards paid review work"

gate_job "$new_iso" in_progress >"$JOBS_FILE"
run_watchdog >/dev/null
! cancelled \
  && pass "a gate that has only just started polling is under the floor" \
  || fail "cancelled a gate below WATCHDOG_MIN_POLL_MINUTES"

# An unrecognised job shape must not be read as "polling".
printf '{"jobs":[{"status":"in_progress","started_at":"%s","steps":[]}]}\n' "$old_iso" >"$JOBS_FILE"
run_watchdog >/dev/null
! cancelled \
  && pass "a gate whose poll step cannot be found is left alone, not cancelled on age" \
  || fail "an unreadable step list authorised a cancel"

printf '{"workflow_runs":[{"id":1,"name":"AI privileged merge"}]}\n' >"$INPROGRESS_FILE"
printf '{"jobs":[{"status":"in_progress","started_at":"%s"}]}\n' "$old_iso" >"$JOBS_FILE"
run_watchdog >/dev/null
cancelled \
  && pass "a workflow with no separable poll step keeps the age rule" \
  || fail "the age fallback stopped selecting AI privileged merge"

# --- #355: the runner list is paginated -------------------------------------
busy_pool_2pages >"$RUNNERS_FILE"
run_watchdog >/dev/null
{ cancelled && grep -q 'online=2 idle=0' "$tmp/out.txt"; } \
  && pass "runner pages are aggregated, not counted per page (#355)" \
  || { fail "a two-page runner list did not aggregate"; sed 's/^/diag - /' "$tmp/out.txt"; }

mixed_pool_2pages >"$RUNNERS_FILE"
run_watchdog >/dev/null
{ ! cancelled && grep -q 'online=2 idle=1' "$tmp/out.txt"; } \
  && pass "an idle runner on a later page still means spare capacity (#355)" \
  || { fail "idle capacity on page 2 was missed"; sed 's/^/diag - /' "$tmp/out.txt"; }

malformed_pool_2pages >"$RUNNERS_FILE"
rc="$(run_watchdog)"
{ [ "$rc" = "rc=2" ] && ! cancelled; } \
  && pass "a malformed runner page is a fault, not an empty pool (#355)" \
  || fail "a malformed page did not fail closed ($rc)"
busy_pool >"$RUNNERS_FILE"

# --- the step name is a contract with ai-review-merge.yml -------------------
# If the gate renames its poll step, the watchdog stops finding it and silently
# reverts to the age rule that #343 exists to remove — with no failure anywhere.
# Pin both ends: the script's default must name a step the gate actually has.
default_step="$(grep -o 'AI review + auto-merge=[^}"]*' "$script" | head -n 1 | sed 's/^[^=]*=//')"
gate_wf="$here/../.github/workflows/ai-review-merge.yml"
if [ -f "$gate_wf" ]; then
  { [ -n "$default_step" ] && grep -qF -e "- name: $default_step" "$gate_wf"; } \
    && pass "the default poll step name still exists in ai-review-merge.yml" \
    || fail "poll step '$default_step' is not a step in ai-review-merge.yml — the #343 rule would silently fall back to age"
else
  fail "could not locate ai-review-merge.yml to pin the poll step name"
fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
