#!/usr/bin/env bash
# The arm creates the "AI review authorization" check-run before it publishes the
# immutable receipt and dispatches the trusted review. Every failure path after
# creation must leave that check-run in a terminal state: a check-run stuck at
# in_progress blocks its PR forever, because ADR 0081's promotion retry treats a
# pending required check as "not ready yet" and never completes one itself.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/gate-rearm.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
pass(){ printf 'ok   - %s\n' "$1"; }
fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

guard_name='Complete the authorization when no review was dispatched'

if python3 - "$workflow" "$guard_name" <<'PY'
import sys
import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
guard_name = sys.argv[2]
steps = workflow["jobs"]["arm"]["steps"]
by_name = {step.get("name"): step for step in steps}

receipt = by_name["Upload immutable arm receipt"]
dispatch = by_name["Dispatch trusted review after receipt publication"]
guard = by_name[guard_name]

assert receipt.get("id") == "receipt"
assert dispatch.get("id") == "dispatch", "the dispatch step must be addressable by id"
assert steps.index(guard) > steps.index(dispatch), "the guard must run last"

condition = guard["if"]
assert "always()" in condition, "the guard must run after a failed receipt upload"
assert "steps.arm.outputs.check_id != ''" in condition, "no check-run means nothing to complete"
assert "steps.dispatch.outcome != 'success'" in condition, "a dispatched review owns its own check-run"

run = guard["run"]
assert "conclusion=failure" in run
assert "conclusion=success" not in run, "the guard must never grant authorization"
assert guard["env"].get("APP_TOKEN") == "${{ steps.app-token.outputs.token }}"
assert guard["env"].get("CHECK_ID") == "${{ steps.arm.outputs.check_id }}"
PY
then
  pass "the arm declares a terminal-state guard bound to the undispatched check-run"
else
  fail "the arm's authorization terminal-state guard is missing or drifted"
fi

awk -v name="      - name: $guard_name" '$0==name{f=1;next} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' \
  "$workflow" >"$tmp/guard.sh"
[ -s "$tmp/guard.sh" ] || { fail "terminal-state guard block missing"; printf '%d failing assertion(s)\n' "$fails"; exit 1; }

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  *"--method PATCH "*"check-runs/"*) printf '{}\n' ;;
  *"check-runs/"*)
    [ "${READ_FAIL:-false}" != true ] || exit 1
    printf '%s\n' "${CHECK_STATUS:-in_progress}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls"
export TARGET_REPO=Verjson/example CHECK_ID=9001 APP_TOKEN=app-token
run_guard(){ : >"$CALLS"; bash "$tmp/guard.sh"; }

if run_guard >/dev/null 2>&1 \
  && grep -q 'method PATCH.*check-runs/9001' "$CALLS" \
  && grep -q 'status=completed' "$CALLS" \
  && grep -q 'conclusion=failure' "$CALLS"; then
  pass "an undispatched in-progress authorization is completed as a failure"
else
  fail "the arm left an undispatched authorization pending"
fi

export CHECK_STATUS=completed
if run_guard >/dev/null 2>&1 && ! grep -q 'method PATCH' "$CALLS"; then
  pass "an already-completed authorization keeps its original conclusion and output"
else
  fail "the guard overwrote a terminal authorization"
fi
export CHECK_STATUS=in_progress

export READ_FAIL=true
if run_guard >/dev/null 2>&1; then
  fail "an unreadable authorization check reported green"
elif ! grep -q 'method PATCH' "$CALLS"; then
  pass "an unreadable authorization check fails loudly without a blind write"
else
  fail "the guard patched a check-run it could not read"
fi
export READ_FAIL=false

export CHECK_ID='9001 --method DELETE'
if run_guard >/dev/null 2>&1; then
  fail "a malformed check-run id reached the API"
elif ! grep -q 'method PATCH' "$CALLS"; then
  pass "a malformed check-run id fails closed"
else
  fail "a malformed check-run id was interpolated into an API call"
fi
export CHECK_ID=9001

printf '%d failing assertion(s)\n' "$fails"
[ "$fails" -eq 0 ]
