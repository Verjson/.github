#!/usr/bin/env bash
# Guards the bounded-runtime and runner-aware npm-download-cache contracts from
# #152 and #166.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
ci="$root/.github/workflows/node-ci.yml"
release="$root/.github/workflows/node-release.yml"
composite="$root/.github/actions/setup-verjson-node/action.yml"
actions_ci="$root/scripts/actions-ci-groups.tsv"
actions_ci_workflow="$root/.github/workflows/actions-ci.yml"
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
    && grep -qF 'default: false' <<<"$cache_input"; } \
    && pass "$name defaults Actions npm caching off for persistent runners" \
    || fail "$name does not expose a default-off boolean cache input"

  cache_max_input="$(workflow_input "$workflow" cache-max-mb)"
  { grep -qF 'type: number' <<<"$cache_max_input" \
    && grep -qF 'default: 1024' <<<"$cache_max_input"; } \
    && pass "$name bounds explicitly enabled cache uploads at 1024 MB by default" \
    || fail "$name does not expose the expected cache-max-mb guard"

  dependency_input="$(workflow_input "$workflow" cache-dependency-path)"
  { grep -qF 'type: string' <<<"$dependency_input" \
    && grep -qF 'default: package-lock.json' <<<"$dependency_input"; } \
    && pass "$name defaults its cache key to the root npm lockfile" \
    || fail "$name does not expose cache-dependency-path with the expected default"

  scope_input="$(workflow_input "$workflow" scope)"
  if [ "$workflow" = "$release" ]; then
    { grep -qF 'Required lowercase npm scope' <<<"$scope_input" \
      && grep -qF 'type: string' <<<"$scope_input" \
      && grep -qF "default: '@verjson'" <<<"$scope_input"; } \
      && pass "$name documents its required GitHub Packages scope" \
      || fail "$name does not expose the required publication scope contract"
  else
    { grep -qF 'empty to skip registry auth' <<<"$scope_input" \
      && grep -qF 'type: string' <<<"$scope_input" \
      && grep -qF "default: '@verjson'" <<<"$scope_input"; } \
      && pass "$name documents public-only mode and preserves the private @verjson default" \
      || fail "$name does not expose the expected public/private scope contract"
  fi

  cache_guard="cache: \${{ inputs.cache && hashFiles(inputs.cache-dependency-path) != '' && 'npm' || '' }}"
  [ "$workflow" = "$ci" ] \
    && cache_guard="cache: \${{ !(inputs.secretless-pr || inputs.secretless-trusted-ref) && inputs.cache && hashFiles(inputs.cache-dependency-path) != '' && 'npm' || '' }}"
  grep -qF "$cache_guard" "$workflow" \
    && pass "$name enables setup-node's npm cache only for a matching lockfile" \
    || fail "$name does not condition npm caching on cache-dependency-path"
  grep -qF 'cache-dependency-path: ${{ inputs.cache-dependency-path }}' "$workflow" \
    && pass "$name keys setup-node caching by the caller-selected lockfile" \
    || fail "$name does not pass cache-dependency-path to setup-node"
  grep -qF 'package-manager-cache: false' "$workflow" \
    && pass "$name disables setup-node automatic package-manager caching" \
    || fail "$name can bypass the explicit cache/lockfile controls via setup-node auto-caching"
  { grep -qF 'echo "npm_config_cache=$RUNNER_TEMP/verjson-npm-cache" >> "$GITHUB_ENV"' "$workflow" \
      && grep -qF 'cache_dir="$RUNNER_TEMP/verjson-npm-cache"' "$workflow" \
      && grep -qF 'find "$cache_dir" -mindepth 1 -delete' "$workflow" \
      && grep -qF 'CACHE_MAX_MB: ${{ inputs.cache-max-mb }}' "$workflow"; } \
    && pass "$name scopes and bounds explicitly enabled cache uploads" \
    || fail "$name can archive an accumulated or unbounded persistent-runner npm cache"
  if [ "$workflow" = "$release" ]; then
    grep -qF 'registry-url: https://npm.pkg.github.com' "$workflow" \
      && grep -qF 'scope: ${{ inputs.scope }}' "$workflow" \
      && pass "$name always configures the validated GitHub Packages registry" \
      || fail "$name does not bind publication to GitHub Packages"
  else
    grep -qF "registry-url: \${{ inputs.scope != '' && 'https://npm.pkg.github.com' || '' }}" "$workflow" \
      && grep -qF 'scope: ${{ inputs.scope }}' "$workflow" \
      && pass "$name leaves setup-node registry unset for public-only installs" \
      || fail "$name does not gate GitHub Packages registry setup on a non-empty scope"
  fi
done

[ "$(grep -cF 'timeout-minutes: ${{ inputs.timeout-minutes }}' "$ci")" -eq 3 ] \
  && grep -qF 'timeout-minutes: 5' "$ci" \
  && pass "node-ci bounds eligibility, acquisition, build-test, and cleanup jobs" \
  || fail "node-ci does not apply the caller bound to every job"
[ "$(grep -cF 'timeout-minutes: ${{ inputs.timeout-minutes }}' "$release")" -eq 1 ] \
  && pass "node-release bounds its release job" \
  || fail "node-release does not apply the caller bound to its job"

{ grep -qF 'submodules: ${{ (inputs.secretless-pr || inputs.secretless-trusted-ref) && '\''false'\'' || '\''recursive'\'' }}' "$ci" \
  && grep -qF "inputs.schema-dir != ''" "$ci" \
  && grep -qF 'working-directory: ${{ inputs.schema-dir }}' "$ci" \
  && [ "$(grep -cF 'NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}' "$ci")" -ge 2 ]; } \
  && pass "node-ci preserves schema checkout/install and private-package auth" \
  || fail "node-ci regressed schema-submodule or NODE_AUTH_TOKEN wiring"
grep -qF 'run: npm run typecheck --if-present' "$ci" \
  && pass "node-ci runs a declared consumer typecheck without requiring the script" \
  || fail "node-ci does not conditionally enforce the consumer typecheck"
grep -qF 'echo "VERJSON_CHANGELOG_TOOL_CACHE=$RUNNER_TEMP/verjson-changelog-tools" >> "$GITHUB_ENV"' "$ci" \
  && pass "node-ci gives changelog tooling a job-writable cache" \
  || fail "node-ci does not scope the changelog tool cache beneath runner.temp"
grep -qF 'echo "VERJSON_CHANGELOG_TOOL_CACHE=$RUNNER_TEMP/verjson-changelog-tools" >> "$GITHUB_ENV"' "$release" \
  && pass "node-release gives publish builds a job-writable changelog tool cache" \
  || fail "node-release does not scope the changelog tool cache beneath runner.temp"
python3 - "$release" <<'PY' \
  && pass "node-release prepares the changelog cache before every publish step" \
  || fail "node-release prepares the changelog cache too late"
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert doc["jobs"]["release"]["steps"][0].get("name") == "Prepare job-scoped changelog tool cache"
PY
grep -qF 'echo "VERJSON_CHANGELOG_TOOL_CACHE=" >> "$GITHUB_ENV"' "$actions_ci_workflow" \
  && pass "actions-ci clears the persistent runner changelog cache override" \
  || fail "actions-ci does not restore per-fixture changelog cache isolation"
{ grep -qF 'NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}' "$release" \
  && grep -qF 'NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$release"; } \
  && pass "node-release preserves private install and publish authentication" \
  || fail "node-release regressed NODE_AUTH_TOKEN wiring"

composite_cache="$(composite_input cache)"
composite_dependency="$(composite_input cache-dependency-path)"
composite_scope="$(composite_input scope)"
composite_registry="$(composite_input registry-url)"
{ grep -qF "default: 'false'" <<<"$composite_cache" \
  && grep -qF 'default: package-lock.json' <<<"$composite_dependency" \
  && grep -qF "cache: \${{ inputs.cache == 'true' && hashFiles(inputs.cache-dependency-path) != '' && 'npm' || '' }}" "$composite" \
  && grep -qF 'cache-dependency-path: ${{ inputs.cache-dependency-path }}' "$composite" \
  && grep -qF 'package-manager-cache: false' "$composite" \
  && grep -qF 'echo "npm_config_cache=$RUNNER_TEMP/verjson-npm-cache" >> "$GITHUB_ENV"' "$composite"; } \
  && pass "setup-verjson-node implements the same default-off, job-scoped cache contract" \
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
  'bash scripts/ci-gate/node-ci-cache-service.test.sh' \
  'bash scripts/ci-gate/ci-eligibility.test.sh' \
  'bash scripts/node-workflow-pins.test.sh' \
  'bash scripts/node-release-publish.test.sh' \
  'bash scripts/retired-release-tooling.test.sh'; do
  grep -qF "$(printf '\t%s' "$test_command")" "$actions_ci" \
    && pass "actions-ci runs $test_command" \
    || fail "actions-ci does not run $test_command"
done

changelog_cache_script="$(mktemp)"
awk '
  /- name: Prepare job-scoped changelog tool cache/ { found = 1; next }
  found && /^        run: / { sub(/^        run: /, ""); print; exit }
' "$ci" > "$changelog_cache_script"
changelog_runner_temp="$(mktemp -d)"
changelog_github_env="$(mktemp)"
if RUNNER_TEMP="$changelog_runner_temp" GITHUB_ENV="$changelog_github_env" bash "$changelog_cache_script" \
  && grep -Fx "VERJSON_CHANGELOG_TOOL_CACHE=$changelog_runner_temp/verjson-changelog-tools" "$changelog_github_env"; then
  pass "node-ci exports a cold-cache location writable by the job user"
else
  fail "node-ci cannot prepare a writable cold-cache location"
fi
rm -f "$changelog_cache_script" "$changelog_github_env"
rm -rf "$changelog_runner_temp"

publish_runner_temp="$(mktemp -d)"
ambient_publish_cache="/proc/verjson-persistent-changelog-cache"
export VERJSON_CHANGELOG_TOOL_CACHE="$ambient_publish_cache"
publish_contract_sha="0123456789abcdef0123456789abcdef01234567"
publish_cache_step="$(mktemp)"
python3 - "$release" >"$publish_cache_step" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for step in doc["jobs"]["release"]["steps"]:
    if step.get("name") == "Prepare job-scoped changelog tool cache":
        print(step["run"])
PY
publish_github_env="$(mktemp)"
RUNNER_TEMP="$publish_runner_temp" GITHUB_ENV="$publish_github_env" \
  bash -eo pipefail "$publish_cache_step"
publish_cache="$(sed -n 's/^VERJSON_CHANGELOG_TOOL_CACHE=//p' "$publish_github_env")"
populate_publish_cache() {
  mkdir -p "$VERJSON_CHANGELOG_TOOL_CACHE/$publish_contract_sha" \
    && printf published >"$VERJSON_CHANGELOG_TOOL_CACHE/$publish_contract_sha/changelog.py"
}
if VERJSON_CHANGELOG_TOOL_CACHE="$publish_cache" populate_publish_cache \
  && [ "$(cat "$publish_cache/$publish_contract_sha/changelog.py")" = published ] \
  && [ "$VERJSON_CHANGELOG_TOOL_CACHE" = "$ambient_publish_cache" ] \
  && [ ! -e "$ambient_publish_cache" ]; then
  pass "node-release publish builds override a hostile persistent cache and populate a cold SHA beneath runner.temp"
else
  fail "node-release publish builds still depend on a persistent runner cache"
fi

release_without_cache="$(mktemp)"
cp "$release" "$release_without_cache"
sed -i '/^      - name: Prepare job-scoped changelog tool cache$/,+1d' "$release_without_cache"
missing_publish_step="$(mktemp)"
python3 - "$release_without_cache" >"$missing_publish_step" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for step in doc["jobs"]["release"]["steps"]:
    if step.get("name") == "Prepare job-scoped changelog tool cache":
        print(step["run"])
PY
[ ! -s "$missing_publish_step" ] || fail "the publish-cache removal mutation left an override step"
if VERJSON_CHANGELOG_TOOL_CACHE="$ambient_publish_cache" populate_publish_cache 2>/dev/null; then
  fail "the publish build survived removal of the runner.temp cache override"
else
  pass "removing the publish override reproduces the hostile persistent-cache failure (#630)"
fi
unset VERJSON_CHANGELOG_TOOL_CACHE
rm -f "$release_without_cache" "$publish_cache_step" "$publish_github_env" "$missing_publish_step"
rm -rf "$publish_runner_temp"

{ grep -qF '`timeout-minutes`' "$docs" \
  && grep -qF '`cache-dependency-path`' "$docs" \
  && grep -qF '`cache: false`' "$docs" \
  && grep -qF '`NODE_AUTH_TOKEN`' "$docs" \
  && grep -qF 'cancel-in-progress: true' "$docs" \
  && grep -qF '`cancel-in-progress: false`' "$docs"; } \
  && pass "usage docs cover timeout, cache, auth, and caller concurrency decisions" \
  || fail "usage docs omit a required timeout/cache/concurrency contract"

# Execute the workflow-owned guard, not a copied test implementation. This
# proves an oversized job-scoped cache is emptied while an in-bound cache is
# preserved, and confines deletion beneath RUNNER_TEMP.
guard_script="$(mktemp)"
guard_root="$(mktemp -d)"
trap 'rm -f "$guard_script"; rm -rf "$guard_root"' EXIT
awk '
  /- name: Bound npm cache upload/ { found = 1; next }
  found && /^        run: \|$/ { capture = 1; next }
  capture && /^          / { sub(/^          /, ""); print; next }
  capture { exit }
' "$ci" > "$guard_script"
summary="$guard_root/summary.md"
cache_dir="$guard_root/verjson-npm-cache"
mkdir -p "$cache_dir"
dd if=/dev/zero of="$cache_dir/oversized" bs=1048576 count=2 status=none
if RUNNER_TEMP="$guard_root" CACHE_MAX_MB=1 GITHUB_STEP_SUMMARY="$summary" \
    bash "$guard_script" >/dev/null \
    && [ -d "$cache_dir" ] \
    && [ -z "$(find "$cache_dir" -mindepth 1 -print -quit)" ] \
    && grep -qF -- '- size:' "$summary" \
    && grep -qF -- '- upload limit: 1 MB' "$summary"; then
  pass "cache guard reports and clears an oversized job-scoped cache"
else
  fail "cache guard did not safely clear an oversized job-scoped cache"
fi

: > "$summary"
printf 'keep' > "$cache_dir/in-bound"
if RUNNER_TEMP="$guard_root" CACHE_MAX_MB=1 GITHUB_STEP_SUMMARY="$summary" \
    bash "$guard_script" >/dev/null \
    && [ -f "$cache_dir/in-bound" ]; then
  pass "cache guard preserves an in-bound job-scoped cache"
else
  fail "cache guard removed an in-bound job-scoped cache"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
