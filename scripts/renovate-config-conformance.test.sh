#!/usr/bin/env bash
# Guards the organization-owned Renovate policy boundary (Verjson/.github#699).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
checker="$root/scripts/renovate-config-conformance.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

check() {
  bash "$checker" --repo-root "$1"
}

mkdir -p "$tmp/compliant"
if check "$tmp/compliant" >"$tmp/compliant.out" 2>&1; then
  pass "a repository without a local Renovate override is accepted"
else
  fail "a repository without a local Renovate override was rejected"
fi

for path in \
  renovate.json \
  renovate.json5 \
  .github/renovate.json \
  .github/renovate.json5 \
  .renovaterc \
  .renovaterc.json \
  .renovaterc.json5; do
  fixture="$tmp/${path//\//-}"
  mkdir -p "$fixture/$(dirname "$path")"
  printf '{}\n' >"$fixture/$path"
  if check "$fixture" >"$tmp/path.out" 2>&1; then
    fail "$path was accepted"
  elif grep -qF "$path" "$tmp/path.out"; then
    pass "$path is rejected with an actionable diagnostic"
  else
    fail "$path was rejected without naming the override"
  fi
done

mkdir -p "$tmp/package-key"
printf '{"name":"fixture","renovate":{}}\n' >"$tmp/package-key/package.json"
if check "$tmp/package-key" >"$tmp/package-key.out" 2>&1; then
  fail "a package.json Renovate key was accepted"
elif grep -qF 'package.json#renovate' "$tmp/package-key.out"; then
  pass "a package.json Renovate key is rejected with an actionable diagnostic"
else
  fail "a package.json Renovate key was rejected without naming the override"
fi

if check "$root" >"$tmp/repository.out" 2>&1; then
  pass "the checked-in repository has no local Renovate override"
else
  fail "the checked-in repository still contains a local Renovate override"
fi

[ "$fails" -eq 0 ] || exit 1
