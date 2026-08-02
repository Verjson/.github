#!/usr/bin/env bash
# Contract check: every reusable-workflow example that pins a Verjson/.github tag
# must name a tag this repository actually has (Verjson/.github#287).
#
# Documentation drifted ahead of release state — README, docs/ and the reusable
# workflow headers all advertised `@v2.1.1` while tags stopped at `v2.1.0`, so a
# consumer copying the documented exact pin got an unresolved workflow reference.
#
# Scope is every tracked file, and every `...workflows/<name>.yml@<ref>` whose ref
# is tag-shaped (`v...`). `@main` and full-SHA pins name no tag and are skipped.
#
# Tag truth comes from local git (`git tag`), not the API: it needs no network at
# review time and cannot flake. CI must therefore check out with tags present
# (`actions/checkout` with `fetch-depth: 0`).
#
# Test seam: DOC_TAG_PINS_ROOT selects the repository to check.
set -uo pipefail

root="${DOC_TAG_PINS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

die() { printf 'doc-tag-pins: %s\n' "$1" >&2; exit 1; }

files="$(git -C "$root" ls-files)" \
  || die "could not list tracked files under $root — failing closed"

pins="$(
  printf '%s\n' "$files" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    grep -oE 'workflows/[A-Za-z0-9._-]+\.yml@v[A-Za-z0-9._-]+' "$root/$file" 2>/dev/null \
      | sed "s|^|$file	|"
  done
)"

tags="$(git -C "$root" tag --list)" \
  || die "could not read the tag list from $root — failing closed"

# A checkout without tags is the CI default, and it makes every pin look broken.
# Report the lookup, not the docs: a fault must never be mistaken for a verdict.
{ [ -z "$pins" ] || [ -n "$tags" ]; } \
  || die "the tag lookup in $root returned no tags at all — check out with tags before checking pins"

missing=0
while IFS="$(printf '\t')" read -r file pin; do
  [ -n "${pin:-}" ] || continue
  ref="${pin#*@}"
  if printf '%s\n' "$tags" | grep -qxF "$ref"; then
    continue
  fi
  printf 'doc-tag-pins: %s pins @%s, which is not a tag of this repository\n' "$file" "$ref" >&2
  missing=$((missing + 1))
done <<<"$pins"

[ "$missing" -eq 0 ] \
  || die "$missing example(s) pin a nonexistent tag — correct them to a released tag"

echo "doc-tag-pins: every documented tag pin resolves to an existing tag."
