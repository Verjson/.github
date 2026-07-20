#!/usr/bin/env bash
# Fixture-based unit tests for scripts/render-next.sh (Verjson/.github#67). CI only
# smoke-runs the script against live NEXT/ content; this exercises its edge cases
# (missing dir, no fragments, newest-first ordering, README exclusion, archive
# sorting last) against a stubbed NEXT/ tree, with clear pass/fail. It copies and
# runs the REAL script into a fixture root so the test can't drift from it.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
script="$repo_root/scripts/render-next.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - script not found: $script"; exit 1; }

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

# new_fixture -> prints a fresh fixture root with the real script + an empty NEXT/.
new_fixture() {
  local d; d="$(mktemp -d "$tmproot/fix.XXXXXX")"
  mkdir -p "$d/scripts" "$d/NEXT"
  cp "$script" "$d/scripts/render-next.sh"
  printf '%s' "$d"
}

# 1. Happy path: newest-first, README excluded, 0000-archive sorts last.
d="$(new_fixture)"
printf '# older\n'   > "$d/NEXT/2026-07-19-older.md"
printf '# newer\n'   > "$d/NEXT/2026-07-20-newer.md"
printf '# archive\n' > "$d/NEXT/0000-archive.md"
printf 'ignore me\n' > "$d/NEXT/README.md"
out="$(bash "$d/scripts/render-next.sh")"
[ "$(printf '%s\n' "$out" | grep -c '^ignore me$')" -eq 0 ] \
  && pass "README.md is excluded from the log" || fail "README.md must be excluded"
order="$(printf '%s\n' "$out" | grep -E '^# ' | paste -sd, -)"
[ "$order" = "# newer,# older,# archive" ] \
  && pass "fragments render newest-first, archive last" || fail "wrong order: $order"

# 2. Missing NEXT/ directory -> non-zero exit.
d="$(new_fixture)"; rm -rf "$d/NEXT"
bash "$d/scripts/render-next.sh" >/dev/null 2>&1 \
  && fail "missing NEXT/ must exit non-zero" || pass "missing NEXT/ exits non-zero"

# 3. No fragments (only README) -> non-zero exit.
d="$(new_fixture)"; printf 'x\n' > "$d/NEXT/README.md"
bash "$d/scripts/render-next.sh" >/dev/null 2>&1 \
  && fail "no fragments must exit non-zero" || pass "no fragments exits non-zero"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; else echo "$fails test(s) failed."; exit 1; fi
