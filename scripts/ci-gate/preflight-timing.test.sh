#!/usr/bin/env bash
# Pins the "Record preflight runner timing" diagnostic in ai-review-merge.yml
# (Verjson/.github#106, ADR 0017). The step computes a queue delta with bash
# arithmetic from a gh-reported created_at. A non-empty but *unparseable*
# timestamp makes `date -d` print nothing, so `$(( N -  ))` becomes an
# arithmetic syntax error — fatal even under `set -uo pipefail` (no -e) — which
# aborts the required preflight job, contradicting ADR 0017's promise that these
# diagnostics never change enforcement. This extracts the real `run:` block from
# the workflow (single source of truth) and drives it with a stubbed `gh`.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

# Extract the exact preflight timing run: block (dedent 10 spaces of body).
script="$tmp/preflight-timing.sh"
awk '
  $0 == "      - name: Record preflight runner timing" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$script"
grep -q 'initial_queue_seconds' "$script" \
  || { echo "FAIL - could not extract preflight timing block from $wf"; exit 1; }

# Stub gh so `gh api ... --jq .created_at` returns the value under test. `date`
# is intentionally the real one: an unparseable created_at must make real
# `date -d` fail exactly as it does on the runner.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s' "${CREATED_AT:-}"
exit 0
GH
chmod +x "$tmp/bin/gh"

run_preflight() {
  # run_preflight <created_at>
  export PATH="$tmp/bin:$PATH"
  export GITHUB_REPOSITORY="Verjson/foo" GITHUB_RUN_ID=123
  export CREATED_AT="$1"
  bash "$script" >"$tmp/out.txt" 2>&1
  echo "rc=$?"
}
out_has() { grep -q "$1" "$tmp/out.txt"; }

# (a) A valid created_at yields a numeric initial_queue_seconds.
rc="$(run_preflight "2020-01-01T00:00:00Z")"
{ [ "$rc" = "rc=0" ] && out_has 'initial_queue_seconds=[0-9]'; } \
  && pass "valid created_at yields a numeric initial_queue_seconds" \
  || fail "valid created_at did not produce a numeric delta ($rc)"

# (b) An empty created_at degrades to unknown and exits 0.
rc="$(run_preflight "")"
{ [ "$rc" = "rc=0" ] && out_has 'initial_queue_seconds=unknown'; } \
  && pass "empty created_at degrades to unknown, exit 0" \
  || fail "empty created_at did not degrade to unknown ($rc)"

# (c) A non-empty but unparseable created_at must NOT abort the job: exit 0 and
# degrade to unknown (or 0), never an arithmetic syntax error (#106).
rc="$(run_preflight "not-a-date")"
{ [ "$rc" = "rc=0" ] && { out_has 'initial_queue_seconds=unknown' || out_has 'initial_queue_seconds=0'; }; } \
  && pass "unparseable created_at does not abort the preflight job (#106)" \
  || fail "unparseable created_at aborted the job or errored ($rc)"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; else echo "$fails test(s) failed."; exit 1; fi
