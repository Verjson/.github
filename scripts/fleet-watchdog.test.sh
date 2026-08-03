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

run_watchdog() {
  export PATH="$tmp/bin:$PATH"
  export WATCHDOG_ORG=TestOrg WATCHDOG_MIN_AGE_MINUTES=35
  export ACTIONLOG="$tmp/act.log"; : >"$ACTIONLOG"
  bash "$script" >"$tmp/out.txt" 2>&1
  printf 'rc=%s' "$?"
}
cancelled() { grep -qF CANCELLED "$tmp/act.log"; }

# Fixtures: one stale poll job, one queued run.
old_iso="$(date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
new_iso="$(date -u -d '2 minutes ago'  +%Y-%m-%dT%H:%M:%SZ)"

export RUNNERS_FILE="$tmp/runners.json" QUEUED_FILE="$tmp/queued.json"
export INPROGRESS_FILE="$tmp/inprog.json" JOBS_FILE="$tmp/jobs.json"
printf '{"workflow_runs":[{"id":1,"name":"AI review + auto-merge"}]}\n' >"$INPROGRESS_FILE"
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
printf '{"workflow_runs":[{"id":1,"name":"AI review + auto-merge"}]}\n' >"$INPROGRESS_FILE"

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

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
