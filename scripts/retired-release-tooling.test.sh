#!/usr/bin/env bash
# Guards the completed semantic-release retirement (Verjson/.github#509).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

for retired_path in \
  .github/release-tooling/package.json \
  .github/workflows/node-cache-integration.yml \
  scripts/release-tooling-audit.sh \
  scripts/release-tooling-audit.test.sh; do
  if [ -e "$root/$retired_path" ]; then
    fail "$retired_path still exists"
  else
    pass "$retired_path is absent"
  fi
done

live_surfaces=(
  "$root/.github/workflows/actions-ci.yml"
  "$root/renovate.json"
  "$root/scripts/node-workflow-controls.test.sh"
  "$root/scripts/node-workflow-pins.test.sh"
  "$root/scripts/ci-gate/runner-routing-policy.test.sh"
)

if grep -En '\.github/release-tooling|node-cache-integration|release-tooling-audit\.(sh|test)' "${live_surfaces[@]}"; then
  fail "live CI or maintenance surfaces still reference retired release tooling"
else
  pass "live CI and maintenance surfaces contain no retired release-tooling references"
fi

actions_ci="$root/.github/workflows/actions-ci.yml"
for command in \
  'bash scripts/node-workflow-controls.test.sh' \
  'bash scripts/node-workflow-pins.test.sh' \
  'bash scripts/node-release-publish.test.sh' \
  'bash scripts/retired-release-tooling.test.sh'; do
  grep -qF "run: $command" "$actions_ci" \
    && pass "actions-ci runs $command" \
    || fail "actions-ci does not run $command"
done

[ "$fails" -eq 0 ] || exit 1
