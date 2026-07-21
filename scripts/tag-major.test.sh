#!/usr/bin/env bash
# Exercises the exact tag-major workflow run block against a real temporary Git
# repository. ADR 0014 requires the moving vX annotated tag to point at the
# release commit; #73 caught that targeting an annotated vX.Y.Z tag directly
# instead creates an avoidable tag-of-a-tag chain.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
wf="$repo_root/.github/workflows/tag-major.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

script="$tmp/tag-major.sh"
awk '
  $0 == "      - name: Re-point moving major tag" { seen = 1 }
  seen && $0 == "        run: |" { capture = 1; next }
  capture {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    capture = 0
  }
' "$wf" >"$script"
if ! grep -q 'git tag -f -a' "$script" || ! grep -q 'git push --force' "$script"; then
  echo "FAIL - could not extract tag-major run block from $wf"
  exit 1
fi

git init --bare -q "$tmp/origin.git"
git init -q "$tmp/work"
cd "$tmp/work" || exit 1
git config user.name test
git config user.email test@example.com
git commit --allow-empty -qm initial
release_commit="$(git rev-parse HEAD)"
git tag -a v2.3.4 -m release
release_tag_object="$(git rev-parse v2.3.4)"
git remote add origin "$tmp/origin.git"

FULL_TAG=v2.3.4 bash "$script" >"$tmp/out.txt" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "valid SemVer release is re-tagged" || fail "valid release failed (rc=$rc)"

[ "$(git cat-file -t v2 2>/dev/null)" = "tag" ] \
  && pass "moving major remains annotated" \
  || fail "moving major is not an annotated tag"

major_target="$(git cat-file -p v2 2>/dev/null | awk '/^object /{print $2; exit}')"
major_type="$(git cat-file -p v2 2>/dev/null | awk '/^type /{print $2; exit}')"
{ [ "$major_type" = "commit" ] && [ "$major_target" = "$release_commit" ]; } \
  && pass "moving major tag object points directly at the release commit (#73)" \
  || fail "moving major points at type=$major_type object=$major_target, expected commit=$release_commit"

[ "$major_target" != "$release_tag_object" ] \
  && pass "moving major does not form a tag-of-a-tag chain" \
  || fail "moving major still targets the annotated release tag object"

remote_target="$(git --git-dir="$tmp/origin.git" rev-parse refs/tags/v2^{} 2>/dev/null)"
[ "$remote_target" = "$release_commit" ] \
  && pass "peeled moving major is pushed to origin" \
  || fail "origin moving major does not peel to the release commit"

before="$(git show-ref --tags)"
FULL_TAG=release-2.3.4 bash "$script" >"$tmp/invalid.txt" 2>&1
rc=$?
after="$(git show-ref --tags)"
{ [ "$rc" -eq 0 ] && [ "$before" = "$after" ]; } \
  && pass "non-SemVer release is a no-op" \
  || fail "non-SemVer release changed tags or failed"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
