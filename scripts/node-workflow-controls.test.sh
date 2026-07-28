#!/usr/bin/env bash
# Guards the bounded-runtime and npm-download-cache contracts from #152.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
ci="$root/.github/workflows/node-ci.yml"
release="$root/.github/workflows/node-release.yml"
composite="$root/.github/actions/setup-verjson-node/action.yml"
actions_ci="$root/.github/workflows/actions-ci.yml"
cache_probe="$root/.github/workflows/node-cache-integration.yml"
docs="$root/docs/node-workflows.md"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

workflow_input() {
  local workflow="$1" input="$2"
  awk -v input="$input" '
    $0 == "      " input ":" { capture = 1; print; next }
    capture && /^      [a-zA-Z0-9_-]+:$/ { exit }
    capture { print }
  ' "$workflow"
}

composite_input() {
  local input="$1"
  awk -v input="$input" '
    $0 == "  " input ":" { capture = 1; print; next }
    capture && /^  [a-zA-Z0-9_-]+:$/ { exit }
    capture { print }
  ' "$composite"
}

for workflow in "$ci" "$release"; do
  name="$(basename "$workflow")"

  timeout_input="$(workflow_input "$workflow" timeout-minutes)"
  { grep -qF 'type: number' <<<"$timeout_input" \
    && grep -qF 'default: 30' <<<"$timeout_input"; } \
    && pass "$name exposes a numeric 30-minute default bound" \
    || fail "$name does not expose the expected numeric timeout-minutes input"

  cache_input="$(workflow_input "$workflow" cache)"
  { grep -qF 'type: boolean' <<<"$cache_input" \
    && grep -qF 'default: true' <<<"$cache_input"; } \
    && pass "$name defaults npm caching on" \
    || fail "$name does not expose a default-on boolean cache input"

  dependency_input="$(workflow_input "$workflow" cache-dependency-path)"
  { grep -qF 'type: string' <<<"$dependency_input" \
    && grep -qF 'default: package-lock.json' <<<"$dependency_input"; } \
    && pass "$name defaults its cache key to the root npm lockfile" \
    || fail "$name does not expose cache-dependency-path with the expected default"

  scope_input="$(workflow_input "$workflow" scope)"
  { grep -qF 'empty to skip registry auth' <<<"$scope_input" \
    && grep -qF 'type: string' <<<"$scope_input" \
    && grep -qF "default: '@verjson'" <<<"$scope_input"; } \
    && pass "$name documents public-only mode and preserves the private @verjson default" \
    || fail "$name does not expose the expected public/private scope contract"

  grep -qF "cache: \${{ inputs.cache && hashFiles(inputs.cache-dependency-path) != '' && 'npm' || '' }}" "$workflow" \
    && pass "$name enables setup-node's npm cache only for a matching lockfile" \
    || fail "$name does not condition npm caching on cache-dependency-path"
  grep -qF 'cache-dependency-path: ${{ inputs.cache-dependency-path }}' "$workflow" \
    && pass "$name keys setup-node caching by the caller-selected lockfile" \
    || fail "$name does not pass cache-dependency-path to setup-node"
  grep -qF 'package-manager-cache: false' "$workflow" \
    && pass "$name disables setup-node automatic package-manager caching" \
    || fail "$name can bypass the explicit cache/lockfile controls via setup-node auto-caching"
  grep -qF "registry-url: \${{ inputs.scope != '' && 'https://npm.pkg.github.com' || '' }}" "$workflow" \
    && grep -qF 'scope: ${{ inputs.scope }}' "$workflow" \
    && pass "$name leaves setup-node registry unset for public-only installs" \
    || fail "$name does not gate GitHub Packages registry setup on a non-empty scope"
done

[ "$(grep -cF 'timeout-minutes: ${{ inputs.timeout-minutes }}' "$ci")" -eq 2 ] \
  && pass "node-ci bounds both eligibility and build-test jobs" \
  || fail "node-ci does not apply the caller bound to both jobs"
[ "$(grep -cF 'timeout-minutes: ${{ inputs.timeout-minutes }}' "$release")" -eq 1 ] \
  && pass "node-release bounds its release job" \
  || fail "node-release does not apply the caller bound to its job"

{ grep -qF 'submodules: recursive' "$ci" \
  && grep -qF 'if: inputs.schema-dir != ' "$ci" \
  && grep -qF 'working-directory: ${{ inputs.schema-dir }}' "$ci" \
  && [ "$(grep -cF 'NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}' "$ci")" -ge 2 ]; } \
  && pass "node-ci preserves schema checkout/install and private-package auth" \
  || fail "node-ci regressed schema-submodule or NODE_AUTH_TOKEN wiring"
{ grep -qF 'NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}' "$release" \
  && grep -qF 'NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$release"; } \
  && pass "node-release preserves private install and publish authentication" \
  || fail "node-release regressed NODE_AUTH_TOKEN wiring"

composite_cache="$(composite_input cache)"
composite_dependency="$(composite_input cache-dependency-path)"
composite_scope="$(composite_input scope)"
composite_registry="$(composite_input registry-url)"
{ grep -qF "default: 'true'" <<<"$composite_cache" \
  && grep -qF 'default: package-lock.json' <<<"$composite_dependency" \
  && grep -qF "cache: \${{ inputs.cache == 'true' && hashFiles(inputs.cache-dependency-path) != '' && 'npm' || '' }}" "$composite" \
  && grep -qF 'cache-dependency-path: ${{ inputs.cache-dependency-path }}' "$composite" \
  && grep -qF 'package-manager-cache: false' "$composite"; } \
  && pass "setup-verjson-node implements the same default-on lockfile cache contract" \
  || fail "setup-verjson-node cache inputs or setup-node wiring are incomplete"
{ grep -qF "default: '@verjson'" <<<"$composite_scope" \
  && grep -qF "default: 'https://npm.pkg.github.com'" <<<"$composite_registry" \
  && grep -qF "registry-url: \${{ inputs.scope != '' && inputs.registry-url || '' }}" "$composite" \
  && grep -qF 'NODE_AUTH_TOKEN: ${{ inputs.node-auth-token }}' "$composite"; } \
  && pass "setup-verjson-node gates public installs while preserving private registry auth" \
  || fail "setup-verjson-node regressed empty-scope gating or private registry auth"

for test_command in \
  'bash scripts/node-workflow-controls.test.sh' \
  'bash scripts/ci-gate/node-ci-db-service.test.sh' \
  'bash scripts/ci-gate/ci-eligibility.test.sh' \
  'bash scripts/node-workflow-pins.test.sh' \
  'bash scripts/node-release-version.test.sh'; do
  grep -qF "run: $test_command" "$actions_ci" \
    && pass "actions-ci runs $test_command" \
    || fail "actions-ci does not run $test_command"
done

{ grep -qF 'npm-cache-seed:' "$cache_probe" \
  && grep -qF 'npm-cache-restore:' "$cache_probe" \
  && grep -qF 'cache-dependency-path: .github/release-tooling/package-lock.json' "$cache_probe" \
  && grep -qF 'npm cache ls semantic-release@25.0.8' "$cache_probe" \
  && grep -qF 'group: node-cache-integration' "$cache_probe"; } \
  && pass "cold-runner probe restores the non-root lockfile-keyed npm cache" \
  || fail "the cold-runner workflow lacks the cache restore probe"

{ grep -qF '`timeout-minutes`' "$docs" \
  && grep -qF '`cache-dependency-path`' "$docs" \
  && grep -qF '`cache: false`' "$docs" \
  && grep -qF '`NODE_AUTH_TOKEN`' "$docs" \
  && grep -qF 'cancel-in-progress: true' "$docs" \
  && grep -qF '`cancel-in-progress: false`' "$docs"; } \
  && pass "usage docs cover timeout, cache, auth, and caller concurrency decisions" \
  || fail "usage docs omit a required timeout/cache/concurrency contract"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
