#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
generator="$root/scripts/gen-changelog-caller.sh"
ref="$(git -C "$root" rev-parse HEAD)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$generator" pr-gate "$ref" >"$tmp/changelog-contract.yml"

grep -q '^  changelog-contract:$' "$tmp/changelog-contract.yml"
grep -q 'runs-on: \[self-hosted, general\]' "$tmp/changelog-contract.yml"
grep -q 'VERJSON_CHANGELOG_TOOL_CACHE=\$RUNNER_TEMP/verjson-changelog-tools' \
  "$tmp/changelog-contract.yml"
grep -q 'bash scripts/changelog-contract.test.sh' "$tmp/changelog-contract.yml"
! grep -q '/opt/verjson/changelog-tools' "$tmp/changelog-contract.yml"

cache_line="$(grep -n 'VERJSON_CHANGELOG_TOOL_CACHE=' "$tmp/changelog-contract.yml" | cut -d: -f1)"
test_line="$(grep -n 'bash scripts/changelog-contract.test.sh' "$tmp/changelog-contract.yml" | cut -d: -f1)"
[ "$cache_line" -lt "$test_line" ]

echo "ok - generated PR gate uses a job-writable changelog cache before validation"
