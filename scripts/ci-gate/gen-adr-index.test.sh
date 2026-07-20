#!/usr/bin/env bash
# Fixture-based unit tests for scripts/gen-adr-index.sh (Verjson/.github#67). CI
# runs the script with --check against live ADRs; this exercises its edge cases
# (dir with no README, malformed **Date:**, missing index markers, reverse-sort,
# --check staleness) against a stubbed docs/decisions/ tree, with clear pass/fail.
# It copies and runs the REAL script into a fixture root so the test can't drift.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
script="$repo_root/scripts/gen-adr-index.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - script not found: $script"; exit 1; }

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

# new_fixture -> fresh root with the real script + an index README carrying markers.
new_fixture() {
  local d; d="$(mktemp -d "$tmproot/fix.XXXXXX")"
  mkdir -p "$d/scripts" "$d/docs/decisions"
  cp "$script" "$d/scripts/gen-adr-index.sh"
  printf '# Decisions\n\n<!-- BEGIN ADR INDEX -->\n<!-- END ADR INDEX -->\n' > "$d/docs/decisions/README.md"
  printf '%s' "$d"
}
# adr <root> <slug> <h1> <date>
adr() { mkdir -p "$1/docs/decisions/$2"; printf '# %s\n\n- **Date:** %s\n' "$3" "$4" > "$1/docs/decisions/$2/README.md"; }
gen() { bash "$1/scripts/gen-adr-index.sh" "${2:-}" >/dev/null 2>&1; }

# 1. Happy path: valid ADRs generate a reverse-sorted table; --check then passes.
d="$(new_fixture)"
adr "$d" "0001-first"  "0001 — First"  "2026-07-01"
adr "$d" "0002-second" "0002 — Second" "2026-07-02"
gen "$d" && pass "generate succeeds on valid ADRs" || fail "generate should succeed on valid ADRs"
idx="$d/docs/decisions/README.md"
l2="$(grep -n '\[0002\]' "$idx" | cut -d: -f1)"; l1="$(grep -n '\[0001\]' "$idx" | cut -d: -f1)"
{ [ -n "$l2" ] && [ -n "$l1" ] && [ "$l2" -lt "$l1" ]; } \
  && pass "index rows are reverse-sorted (0002 above 0001)" || fail "index order wrong (0002=$l2 0001=$l1)"
gen "$d" --check && pass "--check passes when the table is current" || fail "--check should pass when current"

# 2. ADR directory with no README -> fail fast.
d="$(new_fixture)"; mkdir -p "$d/docs/decisions/0001-noreadme"
gen "$d" && fail "an ADR dir without README must fail" || pass "ADR dir without README fails fast"

# 3. Malformed ADR (missing **Date:**) -> fail fast.
d="$(new_fixture)"; mkdir -p "$d/docs/decisions/0001-nodate"
printf '# 0001 — No Date\n\n(no date line here)\n' > "$d/docs/decisions/0001-nodate/README.md"
gen "$d" && fail "missing **Date:** must fail" || pass "missing **Date:** fails fast"

# 4. Index README missing the markers -> fail fast.
d="$(new_fixture)"; printf '# Decisions\n(no markers)\n' > "$d/docs/decisions/README.md"
adr "$d" "0001-x" "0001 — X" "2026-07-01"
gen "$d" && fail "missing index markers must fail" || pass "missing index markers fails fast"

# 5. --check detects a stale table (new ADR added without regenerating).
d="$(new_fixture)"; adr "$d" "0001-x" "0001 — X" "2026-07-01"; gen "$d"
adr "$d" "0002-y" "0002 — Y" "2026-07-02"
gen "$d" --check && fail "--check must detect a stale table" || pass "--check detects a stale table"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; else echo "$fails test(s) failed."; exit 1; fi
