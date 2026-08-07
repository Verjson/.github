#!/usr/bin/env bash
# Documentation contracts for immutable reusable-workflow and release refs (#353).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
versioning_docs="$root/docs/reusable-workflow-versioning.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

awk '
  /^[[:space:]]*```ya?ml[[:space:]]*$/ { in_yaml = 1; next }
  in_yaml && /^[[:space:]]*```[[:space:]]*$/ { in_yaml = 0; next }
  in_yaml && /uses:[[:space:]]*Verjson\/\.github\/\.github\/workflows\/.*@main([[:space:]#]|$)/ {
    print FILENAME ":" FNR ":" $0
  }
' "$root"/docs/*.md >"$tmp/mutable-workflow-refs"

if [ ! -s "$tmp/mutable-workflow-refs" ]; then
  pass "copyable workflow examples never target @main"
else
  fail "copyable workflow examples target mutable @main refs"
  sed 's/^/diag - /' "$tmp/mutable-workflow-refs"
fi

release_block="$(awk '
  /^[[:space:]]*```bash[[:space:]]*$/ { in_bash = 1; block = ""; next }
  in_bash && /^[[:space:]]*```[[:space:]]*$/ {
    if (block ~ /gh release create/) print block
    in_bash = 0
    next
  }
  in_bash { block = block $0 "\n" }
' "$versioning_docs")"

if grep -qE 'verified_sha=.*git rev-parse --verify [^[:space:]]+\^\{commit\}' <<<"$release_block"; then
  pass "release instructions capture a verified full commit SHA"
else
  fail "release instructions do not capture a verified full commit SHA"
fi

if grep -qF -- "--target \"\$verified_sha\"" <<<"$release_block" \
  && ! grep -qE -- '--target[[:space:]]+(main|origin/main|HEAD)([[:space:]\\]|$)' <<<"$release_block"; then
  pass "release creation targets the quoted verified SHA, never a mutable ref"
else
  fail "release creation does not exclusively target the quoted verified SHA"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi

echo "$fails test(s) failed."
exit 1
