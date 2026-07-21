#!/usr/bin/env bash
# Guards the immutable nested dependencies in the reusable Node workflows
# (Verjson/.github#89): audited action SHAs, release tooling co-located at the
# called workflow's own SHA, an exact lockfile, and Renovate maintenance.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
ci="$root/.github/workflows/node-ci.yml"
release="$root/.github/workflows/node-release.yml"
actions_ci="$root/.github/workflows/actions-ci.yml"
package="$root/.github/release-tooling/package.json"
lock="$root/.github/release-tooling/package-lock.json"
renovate="$root/renovate.json"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

checkout='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7'
setup_node='actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7'
for wf in "$ci" "$release"; do
  name="$(basename "$wf")"
  expected_checkouts=1
  [ "$wf" = "$release" ] && expected_checkouts=2
  pinned_checkouts="$(grep -cF "uses: $checkout" "$wf")"
  all_checkouts="$(grep -cE 'uses: actions/checkout@' "$wf")"
  { [ "$pinned_checkouts" -eq "$expected_checkouts" ] && [ "$all_checkouts" -eq "$expected_checkouts" ]; } \
    && pass "$name pins every checkout use to the audited v7 commit" \
    || fail "$name checkout is not pinned to the audited v7 commit"
  pinned_setups="$(grep -cF "uses: $setup_node" "$wf")"
  all_setups="$(grep -cE 'uses: actions/setup-node@' "$wf")"
  { [ "$pinned_setups" -eq 1 ] && [ "$all_setups" -eq 1 ]; } \
    && pass "$name pins every setup-node use to the audited v7 commit" \
    || fail "$name setup-node is not pinned to the audited v7 commit"
  grep -Eq 'uses: actions/(checkout|setup-node)@v[0-9]+' "$wf" \
    && fail "$name still contains a mutable nested action tag" \
    || pass "$name contains no mutable checkout/setup-node tag"
done

{ grep -qF 'repository: ${{ job.workflow_repository }}' "$release" \
  && grep -qF 'ref: ${{ job.workflow_sha }}' "$release"; } \
  && pass "release tooling is checked out from the called workflow commit" \
  || fail "release tooling is not tied to the called workflow commit"
{ grep -qF 'RELEASE_TOOLING_DIR: ${{ runner.temp }}/verjson-release-tooling' "$release" \
  && grep -qF 'cp .verjson-workflow/.github/release-tooling/package-lock.json "$RELEASE_TOOLING_DIR/"' "$release" \
  && grep -qF 'rm -rf -- .verjson-workflow' "$release" \
  && grep -qF 'npm ci --ignore-scripts --prefix "$RELEASE_TOOLING_DIR"' "$release"; } \
  && pass "release tooling installs from its lockfile" \
  || fail "release tooling does not use lockfile-backed npm ci"
grep -qF '"$RELEASE_TOOLING_DIR/node_modules/.bin/semantic-release"' "$release" \
  && pass "release runs the locked semantic-release binary" \
  || fail "release does not run the locked semantic-release binary"
remove_line="$(grep -n 'rm -rf -- .verjson-workflow' "$release" | cut -d: -f1)"
release_line="$(grep -n 'node_modules/.bin/semantic-release' "$release" | cut -d: -f1)"
{ [ -n "$remove_line" ] && [ -n "$release_line" ] && [ "$remove_line" -lt "$release_line" ]; } \
  && pass "central checkout is removed before publishing the caller package" \
  || fail "central checkout can leak into the caller release"
grep -Eq 'npx .*semantic-release|semantic-release@[~^*0-9]' "$release" \
  && fail "release workflow still resolves semantic-release dynamically" \
  || pass "release workflow has no dynamic semantic-release invocation"

jq -e '.dependencies["semantic-release"] == "25.0.8"' "$package" >/dev/null \
  && pass "semantic-release dependency is exact" \
  || fail "semantic-release dependency is not exact"
grep -qF 'semantic-release requires ^22.14.0 or >=24.10.0' "$release" \
  && pass "release workflow documents semantic-release's Node floor" \
  || fail "release workflow does not document the locked tool's Node floor"
jq -e '
  .lockfileVersion >= 3 and
  .packages[""].dependencies["semantic-release"] == "25.0.8" and
  .packages["node_modules/semantic-release"].version == "25.0.8" and
  (.packages["node_modules/semantic-release"].integrity | startswith("sha512-")) and
  ([.packages | to_entries[] |
    select(.key != "" and (.value.link // false) == false and .value.resolved != null and .value.integrity == null)] |
    length == 0)
' "$lock" >/dev/null \
  && pass "semantic-release 25.0.8 and all resolved integrities are locked" \
  || fail "semantic-release lockfile entry is missing or mutable"

jq -e '
  any(.packageRules[];
    .pinDigests == true and
    (.matchManagers | index("github-actions")) != null and
    (.matchFileNames | index(".github/workflows/node-ci.yml")) != null and
    (.matchFileNames | index(".github/workflows/node-release.yml")) != null)
' "$renovate" >/dev/null \
  && pass "Renovate maintains both reusable-workflow digest pins" \
  || fail "Renovate digest-pin maintenance is not configured"

audit_setup_line="$(grep -nF "uses: $setup_node" "$actions_ci" | cut -d: -f1)"
audit_line="$(grep -nF 'run: npm audit --package-lock-only --omit=dev --audit-level=high' "$actions_ci" | cut -d: -f1)"
{ [ -n "$audit_setup_line" ] && [ -n "$audit_line" ] && [ "$audit_setup_line" -lt "$audit_line" ] \
  && sed -n "${audit_setup_line},$((audit_setup_line + 3))p" "$actions_ci" | grep -qF "node-version: '24'"; } \
  && pass "actions-ci provisions pinned Node 24 before auditing release tooling" \
  || fail "actions-ci does not provision pinned Node 24 before auditing release tooling"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
