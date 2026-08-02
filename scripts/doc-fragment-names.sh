#!/usr/bin/env bash
# Contract check: every changelog-fragment filename example in tracked
# documentation must be a name `scripts/changelog.py` actually accepts
# (Verjson/.github#305).
#
# Scope is tracked `*.md`, and every token shaped like a dated fragment file
# (`NEXT/2026-07-30-issue-249-slug.md`, prefix optional). Placeholder forms such
# as `NEXT/YYYY-MM-DD-issue-<issue-number>-<slug>.md` carry no date digits and
# are not examples, so they are skipped.
#
# Test seam: DOC_FRAGMENT_NAMES_ROOT selects the repository to check.
set -uo pipefail

root="${DOC_FRAGMENT_NAMES_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
engine="$root/scripts/changelog.py"

die() { printf 'doc-fragment-names: %s\n' "$1" >&2; exit 1; }

files="$(git -C "$root" ls-files '*.md')" \
  || die "could not list tracked files under $root — failing closed"

examples="$(
  printf '%s\n' "$files" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    grep -oE '(NEXT/)?[0-9]{4}-[0-9]{2}-[0-9]{2}-[A-Za-z0-9._-]+\.md' "$root/$file" 2>/dev/null \
      | sed "s|^|$file |"
  done
)"

# One engine call answers every name, so no batching can leave one unasked.
mapfile -t names < <(
  printf '%s\n' "$examples" | while IFS=' ' read -r _file name; do
    [ -n "$name" ] || continue
    printf '%s\n' "${name#NEXT/}"
  done | sort -u
)

checked=${#names[@]}
[ "$checked" -gt 0 ] \
  || die "found no fragment filename example in tracked documentation — the scan \
matches nothing, which agrees with every possible mistake"

verdicts="$(
  python3 -c '
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("verjson_changelog_engine", sys.argv[1])
module = importlib.util.module_from_spec(spec)
# The engine defines dataclasses, and @dataclass resolves its own module through
# sys.modules — an unregistered module makes the import itself raise.
sys.modules[spec.name] = module
spec.loader.exec_module(module)
# Probe the matcher before trusting it. A pattern that answers "accept" to
# everything is not an oracle, and it would ratify any documentation silently.
if not module.CANONICAL_NAME.fullmatch("2026-07-30-issue-1-probe.md") or module.CANONICAL_NAME.fullmatch(
    "2026-07-30-id-1-probe.md"
):
    print("engine CANONICAL_NAME failed its probes", file=sys.stderr)
    raise SystemExit(3)
for candidate in sys.argv[2:]:
    print("accept" if module.CANONICAL_NAME.fullmatch(candidate) else "reject", candidate)
' "$engine" "${names[@]}"
)" || die "could not consult the changelog engine at $engine — failing closed"

rejected=0
while IFS=' ' read -r verdict name; do
  [ -n "$name" ] || continue
  [ "$verdict" = reject ] || continue
  printf 'doc-fragment-names: documented example %s is not a name the engine accepts\n' \
    "$name" >&2
  rejected=$((rejected + 1))
done <<<"$verdicts"

[ "$rejected" -eq 0 ] \
  || die "$rejected documented fragment name(s) the engine rejects — correct them"

printf 'doc-fragment-names: %s documented fragment filename(s) accepted by the engine.\n' \
  "$checked"
