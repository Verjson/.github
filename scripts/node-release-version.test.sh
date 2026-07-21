#!/usr/bin/env bash
# Exercises the semantic-release Node engine guard and its workflow placement.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
guard="$root/.github/release-tooling/check-node-version.sh"
workflow="$root/.github/workflows/node-release.yml"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

for version in v22.14.0 v22.99.1 v24.10.0 v25.0.0; do
  bash "$guard" "$version" >/dev/null 2>&1 \
    && pass "$version satisfies the semantic-release engine" \
    || fail "$version should satisfy the semantic-release engine"
done

for version in v22.09.0 v22.13.9 v23.11.0 v24.9.9 latest; do
  output="$(bash "$guard" "$version" 2>&1)" && status=0 || status=$?
  if [ "$status" -ne 0 ] && grep -qF 'semantic-release 25.0.8 requires ^22.14.0 or >=24.10.0' <<<"$output"; then
    pass "$version fails with the required Node floor"
  else
    fail "$version should fail with the required Node floor"
  fi
done

bash "$guard" >/dev/null 2>&1 \
  && pass "the active Node runtime satisfies the semantic-release engine" \
  || fail "the active Node runtime should satisfy the semantic-release engine"

guard_line="$(grep -nF 'bash .verjson-workflow/.github/release-tooling/check-node-version.sh' "$workflow" | cut -d: -f1)"
install_line="$(grep -nF 'npm ci --ignore-scripts --prefix "$RELEASE_TOOLING_DIR"' "$workflow" | cut -d: -f1)"
{ [ -n "$guard_line" ] && [ -n "$install_line" ] && [ "$guard_line" -lt "$install_line" ]; } \
  && pass "release workflow validates Node before installing locked tooling" \
  || fail "release workflow does not validate Node before installing locked tooling"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
