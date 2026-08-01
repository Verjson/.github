#!/usr/bin/env bash
# Guards the immutable nested dependencies in every Node workflow/setup surface
# (Verjson/.github#89, #152, #162): audited action SHAs, the complete live
# node-ci dependency graph, release tooling co-located at the called workflow's
# own SHA, an exact lockfile, and Renovate maintenance.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
ci="$root/.github/workflows/node-ci.yml"
release="$root/.github/workflows/node-release.yml"
cache_probe="$root/.github/workflows/node-cache-integration.yml"
composite="$root/.github/actions/setup-verjson-node/action.yml"
actions_ci="$root/.github/workflows/actions-ci.yml"
package="$root/.github/release-tooling/package.json"
lock="$root/.github/release-tooling/package-lock.json"
renovate="$root/renovate.json"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

checkout='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7'
setup_node='actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7'
for wf in "$ci" "$release" "$cache_probe" "$actions_ci"; do
  name="$(basename "$wf")"
  expected_checkouts=1
  expected_setups=1
  if [ "$wf" = "$release" ]; then
    expected_checkouts=2
  elif [ "$wf" = "$cache_probe" ]; then
    expected_checkouts=2
    expected_setups=2
  fi
  pinned_checkouts="$(grep -cF "uses: $checkout" "$wf")"
  all_checkouts="$(grep -cE 'uses: actions/checkout@' "$wf")"
  { [ "$pinned_checkouts" -eq "$expected_checkouts" ] && [ "$all_checkouts" -eq "$expected_checkouts" ]; } \
    && pass "$name pins every checkout use to the audited v7 commit" \
    || fail "$name checkout is not pinned to the audited v7 commit"
  pinned_setups="$(grep -cF "uses: $setup_node" "$wf")"
  all_setups="$(grep -cE 'uses: actions/setup-node@' "$wf")"
  { [ "$pinned_setups" -eq "$expected_setups" ] && [ "$all_setups" -eq "$expected_setups" ]; } \
    && pass "$name pins every setup-node use to the audited v7 commit" \
    || fail "$name setup-node is not pinned to the audited v7 commit"
  grep -Eq 'uses: actions/(checkout|setup-node)@v[0-9]+' "$wf" \
    && fail "$name still contains a mutable nested action tag" \
    || pass "$name contains no mutable checkout/setup-node tag"
done

{ [ "$(grep -cF "uses: $setup_node" "$composite")" -eq 1 ] \
  && [ "$(grep -cE 'uses: actions/setup-node@' "$composite")" -eq 1 ]; } \
  && pass "setup-verjson-node pins setup-node to the audited v7 commit" \
  || fail "setup-verjson-node does not pin setup-node to the audited v7 commit"
grep -Eq 'uses: actions/setup-node@v[0-9]+' "$composite" \
  && fail "setup-verjson-node still contains a mutable setup-node tag" \
  || pass "setup-verjson-node contains no mutable setup-node tag"

{ grep -qF 'repository: ${{ job.workflow_repository }}' "$release" \
  && grep -qF 'ref: ${{ job.workflow_sha }}' "$release" \
  && grep -qF 'https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#example-usage-of-job-context-workflow-identity' "$release"; } \
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
    (.matchFileNames | index(".github/actions/setup-verjson-node/action.yml")) != null and
    (.matchFileNames | index(".github/workflows/actions-ci.yml")) != null and
    (.matchFileNames | index(".github/workflows/node-cache-integration.yml")) != null and
    (.matchFileNames | index(".github/workflows/node-ci.yml")) != null and
    (.matchFileNames | index(".github/workflows/node-release.yml")) != null)
' "$renovate" >/dev/null \
  && pass "Renovate maintains every Node workflow/setup digest pin" \
  || fail "Renovate digest-pin maintenance does not cover every Node surface"

# node-ci inlines eligibility rather than calling a separately-versioned copy of
# this repository. This removes the manually-maintained self-pin from #162 and
# prevents repo-wide releases from creating a self-update/release loop (#164).
grep -qE '^[[:space:]]*uses: Verjson/\.github/\.github/actions/ci-eligibility@' "$ci" \
  && fail "node-ci still has a remote ci-eligibility self-dependency" \
  || pass "node-ci has no remote ci-eligibility self-dependency"

# Walk the dependency graph that node-ci actually executes. Every remote ref
# must be a full SHA. Any self-reference is resolved with git-show at that SHA
# and recursively scanned, so mutable code cannot hide behind an immutable
# top-level node-ci reference.
declare -A graph_seen=()
graph_error=''
ref_is_immutable() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
resolve_self_source() {
  local ref="$1" path="$2" destination="$3" candidate object_type
  resolved_self_path=''

  # Reusable workflows reference a file directly; composite actions reference
  # their directory, which GitHub resolves to action.yml or action.yaml.
  for candidate in "$path" "$path/action.yml" "$path/action.yaml"; do
    object_type="$(git -C "$root" cat-file -t "$ref:$candidate" 2>/dev/null || true)"
    [ "$object_type" = blob ] || continue
    if git -C "$root" show "$ref:$candidate" >"$destination" 2>/dev/null; then
      resolved_self_path="$candidate"
      return 0
    fi
  done
  return 1
}

walk_uses_graph() {
  local source="$1" identity="$2" use dependency ref nested path nested_identity
  [ -n "${graph_seen[$identity]:-}" ] && return 0
  graph_seen["$identity"]=1

  while IFS= read -r use; do
    dependency="${use%@*}"
    ref="${use##*@}"
    if [ "$dependency" = "$use" ] || ! ref_is_immutable "$ref"; then
      graph_error="$identity has mutable or missing ref: $use"
      return 1
    fi

    case "$dependency" in
      Verjson/.github/*)
        path="${dependency#Verjson/.github/}"
        nested="$(mktemp)"
        if ! resolve_self_source "$ref" "$path" "$nested"; then
          rm -f "$nested"
          graph_error="$identity cannot resolve self-reference $use"
          return 1
        fi
        nested_identity="$ref:$resolved_self_path"
        if ! walk_uses_graph "$nested" "$nested_identity"; then
          rm -f "$nested"
          return 1
        fi
        rm -f "$nested"
        ;;
    esac
  done < <(awk '
    /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/, "", line)
      sub(/[[:space:]#].*$/, "", line)
      print line
    }
  ' "$source")
}

if walk_uses_graph "$ci" "node-ci.yml"; then
  pass "node-ci's complete live dependency graph uses immutable full SHAs"
else
  fail "node-ci dependency graph is not transitively immutable: $graph_error"
fi

# Exercise the graph walker itself, not just its ref predicate. These fixtures
# pin both accepted YAML forms and prove directory-form composite actions resolve
# to their implementation file before recursion.
graph_fixtures="$(mktemp -d)"
trap 'rm -rf "$graph_fixtures"' EXIT
cat >"$graph_fixtures/list-mutable.yml" <<'YAML'
steps:
  - uses: actions/checkout@main
YAML
graph_seen=()
graph_error=''
if walk_uses_graph "$graph_fixtures/list-mutable.yml" "list-mutable.yml"; then
  fail "graph walker accepts a mutable list-form - uses dependency"
elif [[ "$graph_error" == *"actions/checkout@main"* ]]; then
  pass "graph walker rejects mutable list-form - uses dependency"
else
  fail "list-form mutable fixture failed for the wrong reason: $graph_error"
fi

cat >"$graph_fixtures/direct-mutable.yml" <<'YAML'
jobs:
  reusable:
    uses: Verjson/.github/.github/workflows/node-ci.yml@v2
YAML
graph_seen=()
graph_error=''
if walk_uses_graph "$graph_fixtures/direct-mutable.yml" "direct-mutable.yml"; then
  fail "graph walker accepts a mutable direct uses dependency"
elif [[ "$graph_error" == *"node-ci.yml@v2"* ]]; then
  pass "graph walker rejects mutable direct uses dependency"
else
  fail "direct mutable fixture failed for the wrong reason: $graph_error"
fi

self_fixture_ref="$(git -C "$root" rev-parse HEAD)"
cat >"$graph_fixtures/directory-action.yml" <<YAML
steps:
  - uses: Verjson/.github/.github/actions/setup-verjson-node@$self_fixture_ref
YAML
graph_seen=()
graph_error=''
resolved_action="$self_fixture_ref:.github/actions/setup-verjson-node/action.yml"
if walk_uses_graph "$graph_fixtures/directory-action.yml" "directory-action.yml" \
  && [ -n "${graph_seen[$resolved_action]:-}" ]; then
  pass "graph walker resolves directory-form composite action to action.yml"
else
  fail "graph walker did not scan the directory action implementation: $graph_error"
fi

jq -e '
  all(.packageRules[]; .pinDigests != false)
' "$renovate" >/dev/null \
  && pass "Renovate has no exception that permits mutable Node dependencies" \
  || fail "renovate.json still contains a pinDigests:false exception"

audit_setup_line="$(grep -nF "uses: $setup_node" "$actions_ci" | cut -d: -f1)"
audit_line="$(grep -nF 'run: bash scripts/release-tooling-audit.sh' "$actions_ci" | cut -d: -f1)"
{ [ -n "$audit_setup_line" ] && [ -n "$audit_line" ] && [ "$audit_setup_line" -lt "$audit_line" ] \
  && sed -n "${audit_setup_line},$((audit_setup_line + 3))p" "$actions_ci" | grep -qF "node-version: '24'"; } \
  && pass "actions-ci provisions pinned Node 24 before auditing release tooling" \
  || fail "actions-ci does not provision pinned Node 24 before auditing release tooling"

# --- the ONE deliberate @main exception (ADR 0042) ---------------------------
# Everything above exists to force immutable full SHAs. The privileged-merge
# thin caller is the single sanctioned exception, and it is asserted here rather
# than left as a comment so that a future "pin everything" sweep trips this test
# instead of silently breaking merge authority.
#
# Why it is an exception: the canonical privileged-merge workflow already anchors
# trust to Verjson/.github@main AT RUNTIME. A SHA-pinned caller would let a
# repository admin freeze an older gate while the trust anchor moved on — the
# exact divergence the reusable split removes. Pinning here would be less safe,
# not more.
caller_gen="$root/scripts/gen-privileged-merge-caller.sh"
if [ -f "$caller_gen" ]; then
  generated="$(bash "$caller_gen" '["ubuntu-24.04"]' 2>/dev/null)"
  caller_ref="$(printf '%s\n' "$generated" \
    | sed -n 's/^[[:space:]]*uses:[[:space:]]*\(Verjson\/\.github\/\.github\/workflows\/ai-privileged-merge\.yml@.*\)$/\1/p')"

  [ "$caller_ref" = "Verjson/.github/.github/workflows/ai-privileged-merge.yml@main" ] \
    && pass "privileged-merge caller pins @main (sanctioned ADR 0042 exception)" \
    || fail "privileged-merge caller ref changed: '$caller_ref' — if this was pinned to a SHA, read ADR 0042 before 'fixing' it"

  printf '%s\n' "$caller_ref" | grep -qE '@[0-9a-f]{40}$' \
    && fail "privileged-merge caller was SHA-pinned; that lets an admin freeze an older gate (ADR 0042)" \
    || pass "privileged-merge caller is deliberately not SHA-pinned"

  [ -f "$root/docs/decisions/0042-privileged-merge-reusable-split/README.md" ] \
    && pass "the @main exception is backed by a decision record" \
    || fail "ADR 0042 is missing — an unexplained @main is indistinguishable from an unpinned mistake"
else
  fail "scripts/gen-privileged-merge-caller.sh is missing; the caller would be hand-written"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
