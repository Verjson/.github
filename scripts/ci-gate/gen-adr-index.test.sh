#!/usr/bin/env bash
# Fixture-based unit tests for scripts/gen-adr-index.sh
# (Verjson/.github#67, #78, #79). CI runs the script with --check against live
# ADRs; this exercises its edge cases (dir with no README, malformed **Date:**,
# both H1 separators, missing index markers, reverse-sort, --check staleness)
# against a stubbed docs/decisions/ tree, with clear pass/fail. It copies and
# runs the REAL script into a fixture root so the test can't drift.
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
adr "$d" "0001-first"  "0001 — First"  "2024-02-29"
adr "$d" "0002-second" "0002 - Second" "2026-07-02"
gen "$d" && pass "generate succeeds on valid ADRs" || fail "generate should succeed on valid ADRs"
idx="$d/docs/decisions/README.md"
l2="$(grep -n '\[0002\]' "$idx" | cut -d: -f1)"; l1="$(grep -n '\[0001\]' "$idx" | cut -d: -f1)"
{ [ -n "$l2" ] && [ -n "$l1" ] && [ "$l2" -lt "$l1" ]; } \
  && pass "index rows are reverse-sorted (0002 above 0001)" || fail "index order wrong (0002=$l2 0001=$l1)"
grep -qF '| Second |' "$idx" \
  && pass "plain hyphen H1 separator is stripped (#79)" \
  || fail "plain hyphen H1 separator was not stripped (#79)"
gen "$d" --check && pass "--check passes when the table is current" || fail "--check should pass when current"

# 1b. The generated table does not depend on the ambient collation. The zero-
# padded number prefix dominates the sort today, so this guards the invariant
# rather than reproducing a break: it is what stops a later numbering or slug
# change from making `--check` pass on one machine and fail on another (#1214).
if locale -a 2>/dev/null | grep -qix 'en_US.utf8'; then
  utf8_index="$(LC_ALL=en_US.UTF-8 bash "$d/scripts/gen-adr-index.sh" --check >/dev/null 2>&1; echo $?)"
  [ "$utf8_index" = 0 ] \
    && pass "the generated index is current under a UTF-8 collation too" \
    || fail "--check disagreed with the C-collation index under en_US.UTF-8"
else
  pass "skipped UTF-8 collation check — en_US.UTF-8 not installed"
fi

# 2. ADR directory with no README -> fail fast.
d="$(new_fixture)"; mkdir -p "$d/docs/decisions/0001-noreadme"
gen "$d" && fail "an ADR dir without README must fail" || pass "ADR dir without README fails fast"

# 3. Malformed ADR (missing **Date:**) -> fail fast.
d="$(new_fixture)"; mkdir -p "$d/docs/decisions/0001-nodate"
printf '# 0001 — No Date\n\n(no date line here)\n' > "$d/docs/decisions/0001-nodate/README.md"
gen "$d" && fail "missing **Date:** must fail" || pass "missing **Date:** fails fast"

# 4. Malformed **Date:** value -> fail fast.
d="$(new_fixture)"
adr "$d" "0001-bad-date" "0001 — Bad Date" "July 1, 2026"
gen "$d" && fail "malformed **Date:** must fail (#78)" || pass "malformed **Date:** fails fast (#78)"

# 5. ISO-shaped but impossible dates -> fail fast; leap-day boundaries matter.
d="$(new_fixture)"
adr "$d" "0001-bad-day" "0001 — Bad Day" "2026-02-30"
gen "$d" && fail "impossible calendar date must fail (#78)" || pass "impossible calendar date fails fast (#78)"

d="$(new_fixture)"
adr "$d" "0001-non-leap" "0001 — Non Leap" "2025-02-29"
gen "$d" && fail "non-leap February 29 must fail (#78)" || pass "non-leap February 29 fails fast (#78)"

# 6. Index README missing the markers -> fail fast.
d="$(new_fixture)"; printf '# Decisions\n(no markers)\n' > "$d/docs/decisions/README.md"
adr "$d" "0001-x" "0001 — X" "2026-07-01"
gen "$d" && fail "missing index markers must fail" || pass "missing index markers fails fast"

# 7. --check detects a stale table (new ADR added without regenerating).
d="$(new_fixture)"; adr "$d" "0001-x" "0001 — X" "2026-07-01"; gen "$d"
adr "$d" "0002-y" "0002 — Y" "2026-07-02"
gen "$d" --check && fail "--check must detect a stale table" || pass "--check detects a stale table"

# 8. Different slugs cannot reuse one durable ADR number. Both conflicting
# paths must be actionable, and a failed generation must not rewrite the index.
d="$(new_fixture)"
adr "$d" "0042-first-decision" "0042 — First Decision" "2026-07-03"
adr "$d" "0042-second-decision" "0042 — Second Decision" "2026-07-04"
index_before="$(cat "$d/docs/decisions/README.md")"
if duplicate_output="$(bash "$d/scripts/gen-adr-index.sh" 2>&1)"; then
  fail "duplicate ADR numbers must fail before rendering"
elif grep -qF "$d/docs/decisions/0042-first-decision" <<<"$duplicate_output" \
  && grep -qF "$d/docs/decisions/0042-second-decision" <<<"$duplicate_output"; then
  pass "duplicate ADR failure names both conflicting paths (#555)"
else
  fail "duplicate ADR failure did not name both conflicting paths: $duplicate_output"
fi
[ "$(cat "$d/docs/decisions/README.md")" = "$index_before" ] \
  && pass "duplicate ADR failure leaves the generated index untouched" \
  || fail "duplicate ADR failure rewrote the index"
if duplicate_check_output="$(bash "$d/scripts/gen-adr-index.sh" --check 2>&1)"; then
  fail "--check must reject duplicate ADR numbers"
elif grep -qF "$d/docs/decisions/0042-first-decision" <<<"$duplicate_check_output" \
  && grep -qF "$d/docs/decisions/0042-second-decision" <<<"$duplicate_check_output"; then
  pass "--check rejects duplicates and names both conflicting paths"
else
  fail "--check duplicate failure did not name both conflicting paths: $duplicate_check_output"
fi

# Supersession is a relationship between distinct decisions, not duplicate
# numbering. Preserve that valid shape while rejecting number collisions.
d="$(new_fixture)"
adr "$d" "0042-original" "0042 — Original" "2026-07-03"
adr "$d" "0043-replacement" "0043 — Replacement" "2026-07-04"
printf '%s\n' '- **Supersedes:** ADR 0042' >>"$d/docs/decisions/0043-replacement/README.md"
gen "$d" \
  && grep -qF '[0042](0042-original/README.md)' "$d/docs/decisions/README.md" \
  && grep -qF '[0043](0043-replacement/README.md)' "$d/docs/decisions/README.md" \
  && pass "distinct superseding ADRs remain valid" \
  || fail "duplicate guard rejected valid supersession"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; else echo "$fails test(s) failed."; exit 1; fi
