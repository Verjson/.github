#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/fleet-watchdog-cadence.py"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 91
printf '%s\n' "$GH_FIXTURE"
EOF
chmod +x "$tmp/bin/gh"

run_probe() {
  local fixture=$1
  local summary=$2
  PATH="$tmp/bin:$PATH" \
    GH_FIXTURE="$fixture" \
    GITHUB_REPOSITORY=Verjson/.github \
    GITHUB_RUN_ID=200 \
    GITHUB_STEP_SUMMARY="$summary" \
    WATCHDOG_MAX_GAP_MINUTES=30 \
    python3 "$script"
}

normal='{"workflow_runs":[
  {"id":200,"event":"schedule","created_at":"2026-08-07T12:15:00Z"},
  {"id":199,"event":"schedule","created_at":"2026-08-07T12:00:00Z"}
]}'
run_probe "$normal" "$tmp/normal.md" >"$tmp/normal.out" 2>"$tmp/normal.err" \
  || fail "a nominal interval failed"
grep -qF 'Gap: 15 minutes' "$tmp/normal.md" \
  && grep -qF 'Status: within the 30-minute observation threshold' "$tmp/normal.md" \
  && [ ! -s "$tmp/normal.err" ] \
  && pass "a nominal interval is recorded without warning" \
  || fail "the nominal interval was not recorded cleanly"

late='{"workflow_runs":[
  {"id":200,"event":"schedule","created_at":"2026-08-07T14:30:00Z"},
  {"id":199,"event":"schedule","created_at":"2026-08-07T12:00:00Z"}
]}'
run_probe "$late" "$tmp/late.md" >"$tmp/late.out" 2>"$tmp/late.err" \
  || fail "an observed scheduler gap failed the workflow"
grep -qF 'Gap: 150 minutes' "$tmp/late.md" \
  && grep -qF 'Status: scheduler gap exceeded the 30-minute observation threshold' "$tmp/late.md" \
  && grep -qF '::warning title=Fleet watchdog cadence gap::' "$tmp/late.out" \
  && pass "a scheduler gap is a durable summary plus a visible warning" \
  || fail "the scheduler gap was not surfaced durably"

first='{"workflow_runs":[
  {"id":200,"event":"schedule","created_at":"2026-08-07T12:15:00Z"}
]}'
run_probe "$first" "$tmp/first.md" >"$tmp/first.out" 2>"$tmp/first.err" \
  || fail "the first observable run failed"
grep -qF 'No earlier scheduled run is available for comparison.' "$tmp/first.md" \
  && pass "the first observable run establishes a baseline" \
  || fail "the first observable run did not establish a baseline"

malformed='{"workflow_runs":[
  {"id":200,"event":"schedule","created_at":"not-a-time"},
  {"id":199,"event":"schedule","created_at":"2026-08-07T12:00:00Z"}
]}'
if run_probe "$malformed" "$tmp/malformed.md" >"$tmp/malformed.out" 2>"$tmp/malformed.err"; then
  fail "a malformed timestamp was accepted"
fi
grep -qF 'invalid created_at' "$tmp/malformed.err" \
  && pass "malformed run history fails visibly" \
  || fail "the malformed timestamp failure was not diagnostic"

wrong_event='{"workflow_runs":[
  {"id":200,"event":"workflow_dispatch","created_at":"2026-08-07T12:15:00Z"},
  {"id":199,"event":"schedule","created_at":"2026-08-07T12:00:00Z"}
]}'
if run_probe "$wrong_event" "$tmp/wrong-event.md" >"$tmp/wrong-event.out" 2>"$tmp/wrong-event.err"; then
  fail "a non-scheduled current run was accepted"
fi
grep -qF 'current scheduled run 200 was not found' "$tmp/wrong-event.err" \
  && pass "the probe cannot be repurposed by another trigger" \
  || fail "the trigger provenance failure was not diagnostic"

