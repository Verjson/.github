#!/usr/bin/env bash
# Contract tests for scripts/gen-changelog-caller.sh (#286).
#
# The generated pair fails silently when wrong — a renderer and a workflow
# pinned to different commits both keep working while local output stops
# predicting CI — so the agreement between them is asserted here rather than
# left to reviewers.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
gen="$repo_root/scripts/gen-changelog-caller.sh"
# A ref that actually resolves. The generator pins the SHA-256 of the engine at
# the contract commit (#304), so it must be able to read that commit's content —
# a fictional SHA now fails generation by design. The assertions below are about
# interpolation fidelity ("the ref passed is the ref emitted"), which a real SHA
# exercises identically. `unresolvable_sha` keeps the old value for the case that
# asserts the new fail-closed behaviour.
sha="$(git -C "$repo_root" rev-parse HEAD)"
unresolvable_sha="0123456789abcdef0123456789abcdef01234567"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -x "$gen" ] || { echo "FAIL - $gen is not executable"; exit 1; }

workflow="$(bash "$gen" workflow "$sha")"
renderer="$(bash "$gen" renderer "$sha")"
default_release="$(bash "$gen" release-node "$sha")"
custom_release="$(bash "$gen" release-node "$sha" --scope @acme --node-version 22.23.1 --package-dir compat)"
custom_contract="$(bash "$gen" contract-test "$sha" --scope @acme --node-version 22.23.1 --package-dir compat)"
generated_artifacts="$(bash "$gen" generated-artifacts "$sha")"
generated_artifacts_with_adr="$(bash "$gen" generated-artifacts-with-adr-index "$sha")"
renovate_attribution="$(bash "$gen" renovate-attribution "$sha")"
adr_index_generator="$(bash "$gen" adr-index-generator "$sha")"

# 1. The workflow pins its `uses:` and its contract_ref to the same commit.
uses_ref="$(printf '%s\n' "$workflow" | sed -n 's#.*generated-artifacts\.yml@\([0-9a-f]\{40\}\).*#\1#p')"
input_ref="$(printf '%s\n' "$workflow" | sed -n 's/^ *contract_ref: \([0-9a-f]\{40\}\) *$/\1/p')"
[ "$uses_ref" = "$sha" ] && pass "workflow pins uses: to the requested commit" \
  || fail "workflow uses: is '$uses_ref', expected $sha"
[ "$input_ref" = "$sha" ] && pass "workflow passes contract_ref as the same commit" \
  || fail "workflow contract_ref is '$input_ref', expected $sha"
grep -qE '^  generated-artifacts:$' <<<"$workflow" \
  && pass "workflow compatibility mode publishes the canonical required-check prefix" \
  || fail "workflow compatibility mode does not publish generated-artifacts / validate"
grep -qE '^ +changelog: true$' <<<"$workflow" \
  && pass "workflow compatibility mode enables changelog validation" \
  || fail "workflow compatibility mode does not enable changelog validation"

# 2. The renderer pins the same commit the workflow validates with.
script_ref="$(printf '%s\n' "$renderer" | sed -n 's/^CONTRACT_REF="\([0-9a-f]\{40\}\)"$/\1/p')"
[ "$script_ref" = "$uses_ref" ] \
  && pass "renderer and workflow share one contract commit" \
  || fail "renderer pins '$script_ref' but workflow pins '$uses_ref'"

# 3. The renderer is valid bash and renders nothing on its own.
printf '%s\n' "$renderer" | bash -n \
  && pass "generated renderer parses as bash" || fail "generated renderer is not valid bash"

# 4. Least privilege: the workflow requests no write scope.
grep -q 'contents: read' <<<"$workflow" \
  && pass "workflow declares contents: read" || fail "workflow does not declare contents: read"
grep -qE '\bwrite\b' <<<"$workflow" \
  && fail "workflow requests a write permission" || pass "workflow requests no write permission"

# 4a. The shared generated-artifacts caller is generated at the same immutable
# pin. Changelog-only stays the safe default; ADR checking is a separate mode
# because opting in before acquiring the generator is a counted failure.
grep -q "generated-artifacts.yml@$sha" <<<"$generated_artifacts" \
  && pass "generated-artifacts caller pins the requested workflow commit" \
  || fail "generated-artifacts caller does not pin $sha"
grep -qE '^  generated-artifacts:$' <<<"$generated_artifacts" \
  && pass "generated-artifacts caller publishes the canonical required-check prefix" \
  || fail "generated-artifacts caller does not publish generated-artifacts / validate"
grep -qE '^ +changelog: true$' <<<"$generated_artifacts" \
  && grep -qE "^ +contract_ref: $sha$" <<<"$generated_artifacts" \
  && pass "generated-artifacts caller enables changelog validation at the pin" \
  || fail "generated-artifacts caller does not enable pinned changelog validation"
grep -qE '^ +adr-index: true$' <<<"$generated_artifacts" \
  && fail "changelog-only generated-artifacts caller enables ADR checking without its generator" \
  || pass "changelog-only generated-artifacts caller does not opt into ADR checking"
grep -qE '^ +adr-index: true$' <<<"$generated_artifacts_with_adr" \
  && grep -q "generated-artifacts.yml@$sha" <<<"$generated_artifacts_with_adr" \
  && pass "ADR-index caller explicitly enables ADR checking at the pin" \
  || fail "ADR-index caller does not enable ADR checking"
cmp -s <(printf '%s\n' "$adr_index_generator") "$repo_root/scripts/gen-adr-index.sh" \
  && pass "adr-index-generator emits the canonical pinned generator" \
  || fail "adr-index-generator does not emit the pinned gen-adr-index.sh"
printf '%s\n' "$adr_index_generator" | bash -n \
  && pass "generated ADR index generator parses as bash" \
  || fail "generated ADR index generator is not valid bash"

grep -q "renovate-changelog.yml@$sha" <<<"$renovate_attribution" \
  && grep -qE "^ +contract_ref: $sha$" <<<"$renovate_attribution" \
  && pass "Renovate attribution caller binds reusable workflow and helper contract pin" \
  || fail "Renovate attribution caller does not bind its immutable pin"
grep -qE '^  pull_request_target:$' <<<"$renovate_attribution" \
  && grep -qE '^    types: \[opened, reopened, synchronize\]$' <<<"$renovate_attribution" \
  && ! grep -qE '^  (pull_request|push|workflow_dispatch|workflow_run|schedule):' <<<"$renovate_attribution" \
  && pass "Renovate attribution caller is limited to reviewed pull_request_target events" \
  || fail "Renovate attribution caller exposes an unsafe event"
grep -qF "github.event.pull_request.head.repo.full_name == github.repository" <<<"$renovate_attribution" \
  && grep -qF "github.event.pull_request.user.login == 'app/renovate'" <<<"$renovate_attribution" \
  && grep -qF "github.event.pull_request.user.login == 'renovate[bot]'" <<<"$renovate_attribution" \
  && grep -qF "startsWith(github.event.pull_request.head.ref, 'renovate/')" <<<"$renovate_attribution" \
  && pass "Renovate attribution caller rejects forks, other authors, and other branches" \
  || fail "Renovate attribution caller lacks an admission predicate"
grep -qF 'release_app_client_id: ${{ vars.RELEASE_APP_CLIENT_ID }}' <<<"$renovate_attribution" \
  && grep -qF 'release_app_private_key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}' <<<"$renovate_attribution" \
  && grep -qE '^  pull-requests: read$' <<<"$renovate_attribution" \
  && ! grep -qE 'secrets: inherit|ORG_ADMIN_TOKEN|contents: write' <<<"$renovate_attribution" \
  && pass "Renovate attribution caller passes the dedicated App credential and exact read scopes" \
  || fail "Renovate attribution caller broadens credentials or lacks PR-read permission"

# 5. A ref that is not a bare commit is rejected, not quoted and passed through.
# An earlier sibling generator accepted a ref and let YAML be injected through
# it; the guard is asserted, not assumed.
for bad in 'main' "$(printf 'main\n    if: false')" '../../evil' "${sha^^}" "${sha}0" ''; do
  if bash "$gen" workflow "$bad" >/dev/null 2>&1; then
    fail "generator accepted a non-commit ref: '$bad'"
  else
    pass "generator rejects non-commit ref: '${bad//$'\n'/\\n}'"
  fi
done
for mode in generated-artifacts generated-artifacts-with-adr-index renovate-attribution adr-index-generator; do
  if bash "$gen" "$mode" main >/dev/null 2>&1; then
    fail "$mode accepted a mutable ref"
  else
    pass "$mode rejects a mutable ref"
  fi
done

# 6. An unknown mode fails rather than emitting an empty file.
bash "$gen" bogus "$sha" >/dev/null 2>&1 \
  && fail "generator accepted an unknown mode" || pass "generator rejects an unknown mode"

grep -qF "node-version: \${{ '24' }}" <<<"$default_release" \
  && grep -q "scope: '@verjson'" <<<"$default_release" \
  && pass "release-node keeps the Verjson and Node 24 defaults" \
  || fail "release-node changed its backward-compatible defaults"
grep -qF '# The verification suite runs after package.json has been stamped to the' <<<"$default_release" \
  && grep -qF '# dispatched version. Its expected version must be read dynamically from' <<<"$default_release" \
  && grep -qF '# package.json; never assert a hardcoded version literal.' <<<"$default_release" \
  && pass "release-node warns adopters to derive version expectations from stamped package metadata (#862)" \
  || fail "release-node omits the stamped-version warning from its generated header"
grep -qF 'PACKAGE_VERSION: ${{ steps.release-version.outputs.package-version }}' <<<"$default_release" \
  && grep -qF 'Release verification failed against stamped dispatch version $PACKAGE_VERSION. Check for the hardcoded-version footgun:' <<<"$default_release" \
  && pass "release-node diagnoses the stamped version and hardcoded-version footgun (#862)" \
  || fail "release-node omits the stamped-version verification diagnostic"
grep -qF "node-version: \${{ '22.23.1' }}" <<<"$custom_release" \
  && grep -q "scope: '@acme'" <<<"$custom_release" \
  && pass "release-node emits validated adopter parameters" \
  || fail "release-node ignored custom scope or Node version"

renovate_inert_node_versions="$(printf '%s\n' "$default_release" | grep -cF "node-version: \${{ '24' }}")"
[ "$renovate_inert_node_versions" -eq 2 ] \
  && pass "both generated Node-version fields are Renovate-inert" \
  || fail "release-node emitted $renovate_inert_node_versions of 2 Node-version fields as Renovate-inert expressions"

stamp_command="$(
  printf '%s\n' "$custom_release" | awk '
    /^      - name: Stamp the dispatched package versions$/ { found = 1; next }
    found && /^        run: \|$/ { in_run = 1; next }
    in_run && /^      - name:/ { exit }
    in_run { sub(/^          /, ""); print }
  '
)"
stamp_root="$(mktemp -d)"
printf '{"name":"same-version-fixture","version":"0.1.0"}\n' >"$stamp_root/package.json"
mkdir "$stamp_root/compat"
printf '{"name":"same-version-compat-fixture","version":"0.1.0"}\n' >"$stamp_root/compat/package.json"
if (
  cd "$stamp_root" &&
  PACKAGE_VERSION=0.1.0 eval "$stamp_command" >/dev/null &&
  PACKAGE_VERSION=0.2.0 eval "$stamp_command" >/dev/null &&
  [ "$(node -p "require('./package.json').version")" = "0.2.0" ] &&
  [ "$(node -p "require('./compat/package.json').version")" = "0.2.0" ]
); then
  pass "generated version stamp updates every published package and accepts same-version releases (#557, #579)"
else
  fail "generated version stamp does not update every published package"
fi
rm -rf "$stamp_root"

grep -q 'EXPECTED_RELEASE_NODE_VERSION="22.23.1"' <<<"$custom_contract" \
  && grep -q 'EXPECTED_RELEASE_SCOPE="@acme"' <<<"$custom_contract" \
  && grep -qF "EXPECTED_RELEASE_PACKAGE_DIRS_JSON='[\".\",\"compat\"]'" <<<"$custom_contract" \
  && grep -qF "package-dirs: '[\".\",\"compat\"]'" <<<"$custom_release" \
  && pass "contract-test carries the same release parameters" \
  || fail "contract-test does not bind the selected release parameters"

for bad_args in \
  "--scope Acme" \
  "--scope @Acme" \
  "--scope @acme/other" \
  "--scope @acme --scope @other" \
  "--node-version lts/*" \
  "--node-version 022" \
  "--node-version 22.0.0.1" \
  "--node-version 24 --node-version 22" \
  "--package-dir ../compat" \
  "--package-dir /tmp/compat" \
  "--package-dir -compat" \
  "--package-dir ~compat" \
  "--package-dir compat --package-dir compat" \
  "--package-dir ."; do
  # Intentional word splitting: each fixture is a complete argument sequence.
  # shellcheck disable=SC2086
  if bash "$gen" release-node "$sha" $bad_args >/dev/null 2>&1; then
    fail "release-node accepted invalid or duplicate parameters: $bad_args"
  else
    pass "release-node rejects invalid or duplicate parameters: $bad_args"
  fi
done
bash "$gen" workflow "$sha" --scope @acme >/dev/null 2>&1 \
  && fail "workflow mode accepted release-only parameters" \
  || pass "non-release generator modes reject release-only parameters"

# 7. The emitted renderer fails closed when the contract cannot be fetched, and
# leaves no partial file behind for the next run to exec as if it were the
# contract. Exercised with a stubbed curl so no network is required.
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT
mkdir -p "$tmproot/repo/scripts" "$tmproot/repo/NEXT" "$tmproot/bin" "$tmproot/cache"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$tmproot/bin/curl"
chmod +x "$tmproot/bin/curl"
printf '%s\n' "$renderer" > "$tmproot/repo/scripts/render-next.sh"

set +e
PATH="$tmproot/bin:$PATH" XDG_CACHE_HOME="$tmproot/cache" \
  bash "$tmproot/repo/scripts/render-next.sh" >/dev/null 2>"$tmproot/err"
rc=$?
# Back to the file's own mode, not -e: this suite reports every failure and
# summarizes at the end, so leaving -e on would abort at the first one and skip
# the summary — silently, and increasingly so as assertions are appended below.
set +e

[ "$rc" -ne 0 ] \
  && pass "generated renderer exits non-zero when the contract cannot be fetched" \
  || fail "generated renderer exited 0 despite a failed fetch"
grep -q 'cannot fetch the changelog contract' "$tmproot/err" \
  && pass "generated renderer reports why the fetch failed" \
  || fail "generated renderer gave no fetch-failure diagnostic"
[ -z "$(find "$tmproot/cache" -name '.changelog.*' 2>/dev/null)" ] \
  && pass "generated renderer leaves no partial download behind" \
  || fail "generated renderer left a partial download in the cache"
[ ! -f "$tmproot/cache/verjson-changelog/$sha/changelog.py" ] \
  && pass "generated renderer does not create the contract on failure" \
  || fail "generated renderer created a contract file from a failed fetch"

# 8. The generated contract test must survive the thing it protects.
#
# Three repositories hand-copied a contract test asserting a PRE-RELEASE tree:
# named fragment titles, hashed released entries, "no CHANGELOG.md yet",
# "render-released is empty". `release` consumes NEXT/, writes
# CHANGELOG/<version>.md and generates the root CHANGELOG.md, so every one of
# those is false the moment the contract works as intended. Adopters wire the
# suite into `npm test`, which release workflows run before publishing, so the
# first dispatched release pushed its tag and then died in the publish job:
# orphaned tag, nothing published, main red thereafter (#309).
#
# The load-bearing assertion is therefore not "it emits valid bash" but "it
# exits 0 against an adopter BOTH before and after a real release".

contract_src="$repo_root/scripts/changelog.py"
[ -f "$contract_src" ] || { echo "FAIL - missing $contract_src"; exit 1; }

emitted="$tmproot/contract-test.sh"
if bash "$gen" contract-test "$sha" >"$emitted" 2>"$tmproot/err"; then
  pass "contract-test mode emits a file"
else
  fail "contract-test mode failed: $(cat "$tmproot/err")"
  echo "$fails failed"
  exit 1
fi

contract_validation="$(sed -n '/^  contract-test)/,/^    ;;/p' "$gen")"
if grep -q 'bash -n <"$syntax_input"' <<<"$contract_validation" \
   && ! grep -qE "printf .*\\|[[:space:]]*bash -n" <<<"$contract_validation"; then
  pass "contract-test syntax validation reads a completed file instead of a pipe"
else
  fail "contract-test syntax validation can still race a producer SIGPIPE"
fi

# Captured workflow blocks can be much larger than a pipe buffer. A validator
# such as grep -q or an awk program that exits after its first match may close
# stdin while printf is still writing, making pipefail replace the policy error
# with a producer-side Broken pipe. Feed every captured value by redirection so
# validation status never depends on consumer read-ahead.
emitted_validation="$(sed -n '/^emit_contract_test()/,/^}$/p' "$gen")"
if grep -qE 'printf .*\$\{?(snapshot_job|verify_job|publish_job|first_verify_step|job)' \
    <<<"$emitted_validation"; then
  fail "emitted contract validation still pipes a captured value into an early-exit consumer"
else
  pass "emitted contract validation redirects every captured value without a SIGPIPE producer"
fi

bash -n "$emitted" 2>/dev/null \
  && pass "emitted contract test is valid bash" \
  || fail "emitted contract test does not parse"

for bad in 'main' "$(printf 'main\n  if: false')" '../../evil' "${sha^^}" "${sha}0" ''; do
  if bash "$gen" contract-test "$bad" >/dev/null 2>&1; then
    fail "contract-test mode accepted a non-commit ref: '$bad'"
  else
    pass "contract-test mode rejects a non-commit ref: '${bad//$'\n'/\\n}'"
  fi
done

grep -q "CONTRACT_REF=\"$sha\"" "$emitted" \
  && pass "emitted contract test pins the requested commit" \
  || fail "emitted contract test does not carry the requested pin"

# Each grep below is one of the four shapes that made a hand-copied test a
# release time bomb. None may reappear via the generator.
# The engine digest is exempt, and only it: CONTRACT_SHA256 pins the
# implementation being executed, which no release changes. The shape this guards
# against is an assertion pinned to repository CONTENT — a released entry's hash —
# which every release invalidates (#304, #309).
grep -vE '^(CONTRACT|ADR_INDEX)_SHA256="[0-9a-f]{64}"$' "$emitted" | grep -qE '[0-9a-f]{64}' \
  && fail "emitted test hardcodes a content hash of a released entry" \
  || pass "no hashed released entries (a release adds sections)"
grep -qF '[ ! -e "$root/CHANGELOG.md" ]' "$emitted" \
  && fail "emitted test asserts CHANGELOG.md is absent (a release generates it)" \
  || pass "no assertion that the aggregate changelog is absent"
grep -qF 'render-released --repo-root "$root")" ]' "$emitted" \
  && fail "emitted test asserts released history is empty (a release writes it)" \
  || pass "no assertion that released history is empty"
# A bare `^## ` grep is fine — it matches any heading. What must never reappear
# is a heading grep that *names* something, because the only thing an adopter's
# test could name is a fragment title, and a release deletes it. The generator's
# own Newer/Older fixtures are titles it creates itself, so they are exempt.
stray_titles="$(grep -oE "\^## [A-Za-z][^']*" "$emitted" | grep -vxE '\^## (Newer|Older)\$')"
[ -z "$stray_titles" ] \
  && pass "fragment assertions are derived from the tree, not named inline" \
  || fail "emitted test greps for literal fragment titles: $(tr '\n' ' ' <<<"$stray_titles")"

# Content-addressed by ref, so seeding that cache path with THIS repository's
# changelog.py makes the run hermetic and exercises the contract as it stands in
# this pull request. $sha cannot exist upstream, so a seeding bug fails loudly
# with a 404 rather than quietly passing against whatever is published.
export XDG_CACHE_HOME="$tmproot/adopter-cache"
mkdir -p "$XDG_CACHE_HOME/verjson-changelog/$sha"
cp "$contract_src" "$XDG_CACHE_HOME/verjson-changelog/$sha/changelog.py"

build_adopter() {
  # build_adopter <dir> [with-release-workflow: yes|no|legacy] [caller]
  #
  # `yes` installs the GENERATED release caller, which is what an adopter is now
  # told to commit. `legacy` reproduces the hand-copied verjson-payments shape
  # every migrated repository carried before #463/#464/#465: it verifies nothing
  # before the irreversible snapshot, installs with GITHUB_TOKEN, and lets the
  # two halves of one release route onto two runner pools.
  local dir="$1" with_release="${2:-yes}" caller="${3:-workflow}"
  mkdir -p "$dir/NEXT" "$dir/scripts" "$dir/.github/workflows"
  bash "$gen" renderer "$sha" >"$dir/scripts/render-next.sh"
  bash "$gen" "$caller" "$sha" >"$dir/.github/workflows/changelog.yml"
  bash "$gen" renovate-attribution "$sha" >"$dir/.github/workflows/renovate-changelog.yml"
  if [ "$caller" = generated-artifacts-with-adr-index ]; then
    bash "$gen" adr-index-generator "$sha" >"$dir/scripts/gen-adr-index.sh"
    chmod +x "$dir/scripts/gen-adr-index.sh"
  fi
  cp "$emitted" "$dir/scripts/changelog-contract.test.sh"
  chmod +x "$dir/scripts/render-next.sh" "$dir/scripts/changelog-contract.test.sh"
  if [ "$with_release" = yes ]; then
    bash "$gen" release-node "$sha" >"$dir/.github/workflows/release.yml"
    bash "$gen" release-propose "$sha" --autonomy propose \
      >"$dir/.github/workflows/release-propose.yml"
  elif [ "$with_release" = legacy ]; then
    cat >"$dir/.github/workflows/release.yml" <<YAML
name: release
on:
  workflow_dispatch:
    inputs:
      version:
        required: true
        type: string
jobs:
  snapshot:
    uses: Verjson/.github/.github/workflows/changelog-release.yml@$sha
    with:
      contract_ref: $sha
      version: \${{ inputs.version }}
    secrets:
      push_token: \${{ secrets.ORG_ADMIN_TOKEN }}
  publish:
    needs: snapshot
    runs-on: ubuntu-24.04
    steps:
      - run: npm ci
        env:
          NODE_AUTH_TOKEN: \${{ secrets.GITHUB_TOKEN }}
      - run: npm test
YAML
  fi
  # Quoted, because that is what adopters actually write: YAML requires a quoted
  # scalar wherever a value contains `: `, which is every conventional-commit
  # title. An unquoted fixture let the emitted suite ship a front-matter parser
  # that kept the quotes as literal text and then reported the correctly-written
  # title as missing, so the fixture carries the real spelling.
  cat >"$dir/NEXT/2026-08-01-issue-7-first.md" <<'FRAGMENT'
---
date: 2026-08-01
issue: 7
title: 'fix(caller): first entry'
---

Body.
FRAGMENT
  cat >"$dir/NEXT/2026-07-31-issue-20260731T120000Z-second.md" <<'FRAGMENT'
---
date: 2026-07-31
id: 20260731T120000Z
title: Second entry
---

Body.
FRAGMENT
  git -C "$dir" init -q
  git -C "$dir" config user.name Test
  git -C "$dir" config user.email test@example.com
  git -C "$dir" add -A
  git -C "$dir" commit -qm initial
}

build_split_adopter() {
  local dir="$1"
  build_adopter "$dir" no workflow
  bash "$gen" generated-artifacts-with-adr-index "$sha" \
    >"$dir/.github/workflows/generated-artifacts.yml"
  bash "$gen" adr-index-generator "$sha" >"$dir/scripts/gen-adr-index.sh"
  chmod +x "$dir/scripts/gen-adr-index.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -qm 'add generated artifacts caller'
}

run_adopter() {
  ( cd "$1" && ./scripts/changelog-contract.test.sh ) >"$tmproot/run.out" 2>&1
}

adopter="$tmproot/adopter"
build_adopter "$adopter"
[ -f "$adopter/.github/workflows/release.yml" ] \
  && [ ! -e "$adopter/.github/workflows/changelog-release.yml" ] \
  && pass "generated adopter installs the canonical release caller path" \
  || fail "generated adopter does not use only .github/workflows/release.yml"
grep -q "changelog-release.yml@$sha" "$adopter/.github/workflows/release.yml" \
  && grep -qE "^ +contract_ref: $sha$" "$adopter/.github/workflows/release.yml" \
  && pass "canonical release caller pins uses and contract_ref to the same commit" \
  || fail "canonical release caller does not bind uses and contract_ref to $sha"
grep -q "release-propose.yml@$sha" "$adopter/.github/workflows/release-propose.yml" \
  && grep -qE "^ +contract_ref: $sha$" "$adopter/.github/workflows/release-propose.yml" \
  && pass "canonical release proposer pins uses and contract_ref to the same commit" \
  || fail "canonical release proposer does not bind uses and contract_ref to $sha"
run_adopter "$adopter" \
  && pass "emitted suite passes against an unreleased adopter" \
  || fail "emitted suite failed before any release: $(tail -2 "$tmproot/run.out")"

stale_renovate_caller="$tmproot/adopter-stale-renovate-caller"
cp -a "$adopter" "$stale_renovate_caller"
sed -i "s/renovate-changelog.yml@$sha/renovate-changelog.yml@0000000000000000000000000000000000000000/" \
  "$stale_renovate_caller/.github/workflows/renovate-changelog.yml"
run_adopter "$stale_renovate_caller" \
  && fail "emitted suite accepted a stale Renovate attribution reusable pin" \
  || pass "emitted suite rejects a stale Renovate attribution reusable pin"

overprivileged_renovate_caller="$tmproot/adopter-overprivileged-renovate-caller"
cp -a "$adopter" "$overprivileged_renovate_caller"
sed -i 's/^  contents: read$/  contents: write/' \
  "$overprivileged_renovate_caller/.github/workflows/renovate-changelog.yml"
run_adopter "$overprivileged_renovate_caller" \
  && fail "emitted suite accepted a Contents-write Renovate attribution caller" \
  || pass "emitted suite rejects a Contents-write Renovate attribution caller"

wrong_event_renovate_caller="$tmproot/adopter-wrong-event-renovate-caller"
cp -a "$adopter" "$wrong_event_renovate_caller"
sed -i 's/^  pull_request_target:$/  pull_request:/' \
  "$wrong_event_renovate_caller/.github/workflows/renovate-changelog.yml"
run_adopter "$wrong_event_renovate_caller" \
  && fail "emitted suite accepted an event that cannot write the bot head" \
  || pass "emitted suite rejects a Renovate attribution caller on the wrong event"

stale_proposer="$tmproot/adopter-stale-proposer"
cp -a "$adopter" "$stale_proposer"
sed -i "s/release-propose.yml@$sha/release-propose.yml@0000000000000000000000000000000000000000/" \
  "$stale_proposer/.github/workflows/release-propose.yml"
run_adopter "$stale_proposer" \
  && fail "emitted suite accepted a release proposer on another pin" \
  || pass "emitted suite rejects a release proposer on another pin"

overprivileged_proposer="$tmproot/adopter-overprivileged-proposer"
cp -a "$adopter" "$overprivileged_proposer"
sed -i '/^      issues: write$/a\      actions: write' \
  "$overprivileged_proposer/.github/workflows/release-propose.yml"
run_adopter "$overprivileged_proposer" \
  && fail "emitted suite accepted both issue and dispatch authority in propose mode" \
  || pass "emitted suite rejects mixed release-proposer write authority"

event_selected_proposer="$tmproot/adopter-event-selected-proposer"
cp -a "$adopter" "$event_selected_proposer"
sed -i 's/^      autonomy: propose$/      autonomy: ${{ inputs.autonomy }}/' \
  "$event_selected_proposer/.github/workflows/release-propose.yml"
run_adopter "$event_selected_proposer" \
  && fail "emitted suite accepted event-selected release autonomy" \
  || pass "emitted suite rejects event-selected release autonomy"

custom_adopter="$tmproot/adopter-custom-release"
build_adopter "$custom_adopter"
printf '%s\n' "$custom_release" >"$custom_adopter/.github/workflows/release.yml"
printf '%s\n' "$custom_contract" >"$custom_adopter/scripts/changelog-contract.test.sh"
chmod +x "$custom_adopter/scripts/changelog-contract.test.sh"
run_adopter "$custom_adopter" \
  && pass "custom release caller and contract test accept the same parameters (#520)" \
  || fail "matching custom release parameters were rejected: $(tail -2 "$tmproot/run.out")"
sed -i "s/scope: '@acme'/scope: '@other'/" \
  "$custom_adopter/.github/workflows/release.yml"
run_adopter "$custom_adopter" \
  && fail "custom contract accepted a release scope that drifted after generation" \
  || pass "custom contract rejects release parameter drift (#520)"

omitted_stamp_adopter="$tmproot/adopter-omitted-secondary-stamp"
build_adopter "$omitted_stamp_adopter"
printf '%s\n' "$custom_release" >"$omitted_stamp_adopter/.github/workflows/release.yml"
printf '%s\n' "$custom_contract" >"$omitted_stamp_adopter/scripts/changelog-contract.test.sh"
chmod +x "$omitted_stamp_adopter/scripts/changelog-contract.test.sh"
sed -i 's/package_dirs=(. compat)/package_dirs=(.)/' \
  "$omitted_stamp_adopter/.github/workflows/release.yml"
run_adopter "$omitted_stamp_adopter" \
  && fail "custom contract accepted a verification stamp that omitted a published package" \
  || pass "custom contract rejects a verification stamp that omits a published package (#557)"

generated_adopter="$tmproot/adopter-generated-artifacts"
build_adopter "$generated_adopter" no generated-artifacts
run_adopter "$generated_adopter" \
  && pass "emitted suite accepts the generated-artifacts caller" \
  || fail "emitted suite rejects the generated-artifacts caller: $(tail -2 "$tmproot/run.out")"

retired_adopter="$tmproot/adopter-retired-changelog-caller"
build_adopter "$retired_adopter" no workflow
sed -i \
  -e 's/^  generated-artifacts:$/  changelog:/' \
  -e "s#generated-artifacts.yml@$sha#changelog-validate.yml@$sha#" \
  -e '/^      changelog: true$/d' \
  "$retired_adopter/.github/workflows/changelog.yml"
run_adopter "$retired_adopter" \
  && fail "emitted suite accepts the retired changelog / validate caller" \
  || pass "emitted suite rejects a caller that cannot satisfy the canonical required context (#835)"

cross_job_adopter="$tmproot/adopter-cross-job-changelog-caller"
build_adopter "$cross_job_adopter" no workflow
sed -i 's/^  generated-artifacts:$/  changelog:/' \
  "$cross_job_adopter/.github/workflows/changelog.yml"
cat >>"$cross_job_adopter/.github/workflows/changelog.yml" <<'YAML'
  generated-artifacts:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
YAML
run_adopter "$cross_job_adopter" \
  && fail "emitted suite accepts canonical fields spread across different jobs" \
  || pass "emitted suite binds the canonical caller fields to the generated-artifacts job (#835)"

split_adopter="$tmproot/adopter-split-generated-artifacts"
build_split_adopter "$split_adopter"
run_adopter "$split_adopter" \
  && pass "emitted suite accepts the supported split caller topology (#610)" \
  || fail "emitted suite rejects the split caller topology: $(tail -2 "$tmproot/run.out")"

split_stale_pin="$tmproot/adopter-split-stale-pin"
cp -a "$split_adopter" "$split_stale_pin"
sed -i "s/generated-artifacts.yml@$sha/generated-artifacts.yml@0000000000000000000000000000000000000000/" \
  "$split_stale_pin/.github/workflows/generated-artifacts.yml"
run_adopter "$split_stale_pin" \
  && fail "split topology accepts a stale generated-artifacts uses pin" \
  || pass "split topology rejects a stale generated-artifacts uses pin (#610)"

split_stale_ref="$tmproot/adopter-split-stale-contract-ref"
cp -a "$split_adopter" "$split_stale_ref"
sed -i "s/contract_ref: $sha/contract_ref: 0000000000000000000000000000000000000000/" \
  "$split_stale_ref/.github/workflows/generated-artifacts.yml"
run_adopter "$split_stale_ref" \
  && fail "split topology accepts a stale generated-artifacts contract_ref" \
  || pass "split topology rejects a stale generated-artifacts contract_ref (#610)"

split_shadow_pin="$tmproot/adopter-split-shadow-pin"
cp -a "$split_adopter" "$split_shadow_pin"
sed -i "s/generated-artifacts.yml@$sha/generated-artifacts.yml@0000000000000000000000000000000000000000/" \
  "$split_shadow_pin/.github/workflows/generated-artifacts.yml"
printf '# uses: Verjson/.github/.github/workflows/generated-artifacts.yml@%s\n# contract_ref: %s\n' \
  "$sha" "$sha" >>"$split_shadow_pin/.github/workflows/generated-artifacts.yml"
run_adopter "$split_shadow_pin" \
  && fail "split topology accepts stale fields shadowed by correct comments" \
  || pass "split topology rejects stale fields shadowed by correct comments (#610)"

split_missing_adr="$tmproot/adopter-split-missing-adr"
cp -a "$split_adopter" "$split_missing_adr"
sed -i '/^ *adr-index: true$/d' \
  "$split_missing_adr/.github/workflows/generated-artifacts.yml"
run_adopter "$split_missing_adr" \
  && fail "split topology accepts generated-artifacts without ADR-index validation" \
  || pass "split topology requires ADR-index validation (#610)"

split_wrong_generator="$tmproot/adopter-split-wrong-adr-generator"
cp -a "$split_adopter" "$split_wrong_generator"
printf '\n# drift\n' >>"$split_wrong_generator/scripts/gen-adr-index.sh"
run_adopter "$split_wrong_generator" \
  && fail "split topology accepts the wrong ADR-index generator" \
  || pass "split topology rejects the wrong ADR-index generator (#610)"

adr_adopter="$tmproot/adopter-generated-artifacts-adr"
build_adopter "$adr_adopter" no generated-artifacts-with-adr-index
run_adopter "$adr_adopter" \
  && pass "emitted suite accepts ADR checking with the acquired pinned generator" \
  || fail "emitted suite rejects the acquired ADR generator: $(tail -2 "$tmproot/run.out")"
rm -f "$adr_adopter/scripts/gen-adr-index.sh"
if run_adopter "$adr_adopter"; then
  fail "emitted suite accepts adr-index: true without scripts/gen-adr-index.sh"
else
  grep -q 'adr-index: true requires the pinned scripts/gen-adr-index.sh' "$tmproot/run.out" \
    && pass "emitted suite rejects ADR checking without its pinned generator" \
    || fail "missing ADR generator fails without an acquisition remedy: $(tail -2 "$tmproot/run.out")"
fi
bash "$gen" adr-index-generator "$sha" >"$adr_adopter/scripts/gen-adr-index.sh"
chmod +x "$adr_adopter/scripts/gen-adr-index.sh"
printf '\n# local drift\n' >>"$adr_adopter/scripts/gen-adr-index.sh"
if run_adopter "$adr_adopter"; then
  fail "emitted suite accepts a divergent ADR index generator"
else
  grep -q 'is not the generator pinned at' "$tmproot/run.out" \
    && pass "emitted suite rejects a divergent ADR index generator" \
    || fail "divergent ADR generator fails without a regeneration remedy: $(tail -2 "$tmproot/run.out")"
fi

python3 "$contract_src" release --repo-root "$adopter" --version v1.0.0 >/dev/null 2>&1
{ [ -f "$adopter/CHANGELOG/v1.0.0.md" ] && [ -e "$adopter/CHANGELOG.md" ]; } \
  && pass "fixture release really consumed NEXT/ and wrote released history" \
  || fail "fixture release produced no released tree; the next check would be vacuous"

# The regression. Nothing in the hand-copied shape survived this step.
run_adopter "$adopter" \
  && pass "emitted suite still passes AFTER a real release (#309)" \
  || fail "emitted suite breaks on the first release: $(tail -2 "$tmproot/run.out")"

# --------------------------------------------------------------------------
# #399 (duplicate #419): the render guard must tolerate ONLY an emptied NEXT/.
#
# The guard exists because `render-next` exits non-zero once a release has
# consumed NEXT/. Keyed on the exit status alone it reported
# `ok - no unreleased fragments to render` for EVERY renderer failure — an
# unreachable contract fetch, a digest mismatch, a malformed fragment, a missing
# python3, the #398 argv ceiling — and `2>/dev/null` discarded the only sentence
# that said which. A broken adopter announced a clean release.
#
# The two cases below are the same renderer failure distinguished only by whether
# fragments remain, which is why the tree and not the status has to decide.
# --------------------------------------------------------------------------
break_renderer() { # break_renderer <dir>
  # Fail the way a real adopter fails — the renderer exits non-zero with a
  # diagnostic on stderr — rather than by deleting it, which would trip the
  # earlier "is not executable" check and pass for the wrong reason. The
  # gen-changelog-caller.sh marker is kept so the "delegates to the contract"
  # check still passes and this fixture isolates the render guard alone.
  cat >"$1/scripts/render-next.sh" <<BROKEN
#!/usr/bin/env sh
# gen-changelog-caller.sh
# The pin line is required: the emitted suite checks the renderer carries the
# same CONTRACT_REF before it ever renders, so a stub without it dies early and
# the render guard is never reached — which is how this fixture first passed for
# the wrong reason.
CONTRACT_REF="$sha"
echo "render-next: could not fetch the pinned contract (simulated)" >&2
exit 7
BROKEN
  chmod +x "$1/scripts/render-next.sh"
}

# A. Fragments present and the renderer broken: this must FAIL. It is the whole
#    defect — before the fix the suite reported success here.
broken="$tmproot/adopter-broken-renderer"
build_adopter "$broken"
break_renderer "$broken"
if run_adopter "$broken"; then
  fail "#399: a broken renderer with fragments still in NEXT/ reported success"
else
  pass "#399: a broken renderer with fragments present fails the suite"
  # The cause must reach the operator. Swallowing stderr is half the defect: a
  # failure that names nothing sends the adopter to the wrong file.
  grep -q 'could not fetch the pinned contract' "$tmproot/run.out" \
    && pass "#399: the renderer's own stderr is surfaced, not discarded" \
    || fail "#399: the failure hid the renderer's diagnostic: $(tail -3 "$tmproot/run.out")"
  grep -qE 'unreleased fragment\(s\) still in NEXT/' "$tmproot/run.out" \
    && pass "#399: the failure says why this is not the post-release case" \
    || fail "#399: the failure does not distinguish itself from an emptied NEXT/"
fi

# B. The tolerated case, still tolerated. Without this, the fix could satisfy A
#    by failing on every non-zero exit — which would break every adopter the
#    moment they released, the exact regression the guard was added to avoid.
released_broken="$tmproot/adopter-released-broken"
build_adopter "$released_broken"
python3 "$contract_src" release --repo-root "$released_broken" --version v1.0.0 >/dev/null 2>&1
[ -z "$(find "$released_broken/NEXT" -maxdepth 1 -type f -name '*.md' \
    ! -name 'README.md' ! -name '0000-archive.md' 2>/dev/null)" ] \
  && pass "#399 fixture: the release really emptied NEXT/, so case B is not vacuous" \
  || fail "#399 fixture: NEXT/ still holds fragments; case B would prove nothing"
break_renderer "$released_broken"
run_adopter "$released_broken" \
  && pass "#399: an emptied NEXT/ still tolerates a non-zero renderer exit" \
  || fail "#399: the fix broke the post-release case it exists to allow: $(tail -3 "$tmproot/run.out")"

inject_render_failure() { # inject_render_failure <dir> <renderer|download|digest|python>
  local renderer="$1/scripts/render-next.sh"
  case "$2" in
    renderer)
      break_renderer "$1"
      ;;
    download)
      python3 - "$renderer" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
needle = 'root="$(cd "$(dirname "$0")/.." && pwd)"\n'
replacement = needle + '''
XDG_CACHE_HOME="$root/.download-failure-cache"
curl() { echo "simulated contract download failure" >&2; return 22; }
'''
if text.count(needle) != 1:
    raise SystemExit("cannot locate generated renderer root")
open(path, "w", encoding="utf-8").write(text.replace(needle, replacement))
PY
      ;;
    digest)
      sed -i \
        -e 's/^CONTRACT_SHA256="[0-9a-f]\{64\}"$/CONTRACT_SHA256="0000000000000000000000000000000000000000000000000000000000000000"/' \
        -e "/^root=/a XDG_CACHE_HOME=\"\$root/.digest-failure-cache\"" \
        "$renderer"
      ;;
    python)
      sed -i 's/^exec python3 /exec verjson-missing-python3 /' "$renderer"
      ;;
    *)
      return 2
      ;;
  esac
}

for failure in renderer download digest python; do
  failing="$tmproot/adopter-$failure-failure"
  build_adopter "$failing"
  inject_render_failure "$failing" "$failure"
  if run_adopter "$failing"; then
    fail "a $failure failure with renderable NEXT/ fragments reported success"
  else
    pass "a $failure failure with renderable NEXT/ fragments fails closed"
  fi

  emptied="$tmproot/adopter-$failure-empty"
  build_adopter "$emptied"
  python3 "$contract_src" release --repo-root "$emptied" --version v1.0.0 >/dev/null 2>&1
  inject_render_failure "$emptied" "$failure"
  run_adopter "$emptied" \
    && pass "a genuinely emptied NEXT/ remains distinct from a $failure failure" \
    || fail "an emptied NEXT/ is mistaken for a $failure failure: $(tail -3 "$tmproot/run.out")"
done

# An adopter with nothing to publish has no release.yml; `agents` and
# `github-runner` are in exactly that shape and must not be forced to invent one.
build_adopter "$tmproot/adopter-norelease" no
run_adopter "$tmproot/adopter-norelease" \
  && pass "emitted suite tolerates an adopter with no release workflow" \
  || fail "emitted suite requires a release workflow: $(tail -2 "$tmproot/run.out")"

# An unreleased NEXT/ has no upper bound: fragments are per-change, never
# batched, and only a release consumes them. Crossing 128 KiB of rendered output
# — MAX_ARG_STRLEN, the per-string execve ceiling, not the far larger ARG_MAX —
# killed the emitted suite with a bare "Argument list too long" and exit 126,
# naming neither the changelog nor the fragment count. Nothing could be released
# past it either, because the release path runs this suite (#398).
oversize="$tmproot/adopter-oversize"
build_adopter "$oversize"
filler="$(head -c 20000 </dev/zero | tr '\0' x)"
for day in 01 02 03 04 05 06 07 08; do
  issue=$((100 + 10#$day))
  cat >"$oversize/NEXT/2026-06-$day-issue-$issue-bulk.md" <<FRAGMENT
---
date: 2026-06-$day
issue: $issue
title: Bulk entry $day
---

$filler
FRAGMENT
done
git -C "$oversize" add -A
git -C "$oversize" commit -qm bulk

# Asserted, not assumed: a fixture that quietly renders under the ceiling would
# leave the case below passing for the wrong reason.
rendered_bytes="$( (cd "$oversize" && ./scripts/render-next.sh) | wc -c )"
[ "$rendered_bytes" -gt 131072 ] \
  && pass "oversize fixture renders past MAX_ARG_STRLEN ($rendered_bytes bytes)" \
  || fail "oversize fixture renders only $rendered_bytes bytes; the next check is vacuous"

# Exit 0 alone is not enough. The render block is guarded, and its else branch
# reports "no unreleased fragments" and exits 0 for *any* renderer failure — so a
# ceiling that migrated into the renderer would leave this case green with the
# render assertions never executed. Require the positive line.
{ run_adopter "$oversize" \
  && grep -q 'every unreleased fragment renders with its metadata linkage' "$tmproot/run.out"; } \
  && pass "emitted suite survives a NEXT/ larger than MAX_ARG_STRLEN (#398)" \
  || fail "emitted suite dies on or skips a large unreleased log: $(tail -2 "$tmproot/run.out")"

# A suite that passes everywhere is worthless. Each case below breaks exactly one
# invariant in a fresh adopter and requires a non-zero exit.
reject_seq=0
# Mode as well as content: one of the mutations below only clears the executable
# bit, and a content-only fingerprint reports that as "changed nothing".
fingerprint() {
  ( cd "$1" && find . -type f -printf '%m %p\n' -exec sha256sum {} + | sort )
}

expect_rejection() {
  # expect_rejection <label> <mutator-fn>
  local label="$1" mutator="$2" dir
  reject_seq=$((reject_seq + 1))
  dir="$tmproot/reject-$reject_seq"
  build_adopter "$dir"
  # A mutation that edits nothing is rejected by nothing, and the case still
  # reads green — which is how a guard that cannot fail survives a review. The
  # fixture is fingerprinted before and after so a silently no-op mutator is a
  # failure of this file, not an endorsement of the emitted suite.
  fingerprint "$dir" >"$tmproot/before-$reject_seq"
  "$mutator" "$dir"
  fingerprint "$dir" >"$tmproot/after-$reject_seq"
  if cmp -s "$tmproot/before-$reject_seq" "$tmproot/after-$reject_seq"; then
    fail "mutation for '$label' changed nothing; the case is vacuous"
    return
  fi
  run_adopter "$dir" \
    && fail "emitted suite accepted $label" \
    || pass "emitted suite rejects $label"
}

break_pin() {
  sed -i 's/^CONTRACT_REF=.*/CONTRACT_REF="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"/' \
    "$1/scripts/render-next.sh"
}
handwrite_renderer() {
  printf '#!/usr/bin/env bash\nCONTRACT_REF="%s"\necho hand-rolled\n' "$sha" \
    >"$1/scripts/render-next.sh"
}
add_releaserc() { printf '{"branches":["main"]}\n' >"$1/.releaserc.json"; }
add_authored_log() { printf '# NEXT\n\n## An entry\n\nBody.\n' >"$1/NEXT.md"; }
uncanonical_fragment() {
  printf -- '---\ndate: 2026-08-01\nissue: 9\ntitle: Bad name\n---\n\nBody.\n' \
    >"$1/NEXT/2026-08-01-bad-name.md"
}
strip_executable() { chmod -x "$1/scripts/render-next.sh"; }
# The generated caller supplies only the dedicated App identity material. The
# reusable workflow owns token minting and constrains it to this repository.
drop_release_app_client_id() {
  sed -i '/^      release_app_client_id: /d' "$1/.github/workflows/release.yml"
}
drop_release_app_private_key() {
  sed -i '/^      release_app_private_key: /d' "$1/.github/workflows/release.yml"
}
restore_org_admin_token() {
  sed -i '/^      release_app_private_key: /c\      push_token: ${{ secrets.ORG_ADMIN_TOKEN }}' \
    "$1/.github/workflows/release.yml"
}
wire_github_token() {
  sed -i '/^      release_app_private_key: /c\      push_token: ${{ secrets.GITHUB_TOKEN }}' \
    "$1/.github/workflows/release.yml"
}
grant_snapshot_github_token_write() {
  python3 - "$1/.github/workflows/release.yml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
start = text.index("  snapshot:")
end = text.index("  publish:", start)
snapshot = text[start:end]
needle = "      contents: read\n"
if needle not in snapshot:
    raise SystemExit("snapshot fixture no longer has a read-only GITHUB_TOKEN")
snapshot = snapshot.replace(needle, "      contents: write\n", 1)
open(path, "w", encoding="utf-8").write(text[:start] + snapshot + text[end:])
PY
}

# #463/#464/#465. Each mutation below reproduces one defect the hand-copied
# release caller shipped to every migrated repository, applied to the generated
# caller so the emitted suite is the thing under test rather than the fixture.
drop_snapshot_needs() {
  sed -i '/^    needs: verify$/d' "$1/.github/workflows/release.yml"
}
drop_snapshot_runner() {
  sed -i '/^      runner: /d' "$1/.github/workflows/release.yml"
}
drop_resume_snapshot_checkout() {
  sed -i "/^      - name: Check out the existing snapshot for resumed verification$/,+6d" \
    "$1/.github/workflows/release.yml"
}
install_with_github_token() {
  sed -i 's|NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}|NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}|g' \
    "$1/.github/workflows/release.yml"
}
drop_verify_stamp() {
  python3 - "$1/.github/workflows/release.yml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
start = text.index("      - name: Stamp the dispatched package versions")
end = text.index("      - name:", start + 1)
publish = text.index("  publish:")
if start > publish:
    raise SystemExit("verify stamp fixture matched the publish job")
open(path, "w", encoding="utf-8").write(text[:start] + text[end:])
PY
}
drop_verify_prepare() {
  python3 - "$1/.github/workflows/release.yml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
start = text.index("      - name: Prepare release package metadata")
end = text.index("      - name:", start + 1)
publish = text.index("  publish:")
if start > publish:
    raise SystemExit("verify prepare fixture no longer matches generated output")
open(path, "w", encoding="utf-8").write(text[:start] + text[end:])
PY
}
enable_stamp_lifecycle_scripts() {
  sed -i 's/ --ignore-scripts//g' "$1/.github/workflows/release.yml"
}
reject_same_version_stamp() {
  sed -i 's/ --allow-same-version//g' "$1/.github/workflows/release.yml"
}
drop_verification_suite_token() {
  sed -i '/^      - name: Run the release verification suite$/,+2{/NODE_AUTH_TOKEN:/d;}' \
    "$1/.github/workflows/release.yml"
}
drop_stamped_version_header() {
  sed -i '/^# The verification suite runs after package.json has been stamped to the$/,+3d' \
    "$1/.github/workflows/release.yml"
}
drop_stamped_version_diagnostic() {
  sed -i '/Release verification failed against stamped dispatch version/d' \
    "$1/.github/workflows/release.yml"
}
expose_private_token_to_unrelated_step() {
  python3 - "$1/.github/workflows/release.yml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
start = text.index("      - name: Stamp the dispatched package versions")
end = text.index("      - name:", start + 1)
step = text[start:end]
needle = "          PACKAGE_VERSION: ${{ steps.release-version.outputs.package-version }}\n"
if needle not in step:
    raise SystemExit("stamp step fixture no longer matches generated output")
step = step.replace(
    needle,
    needle + "          NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}\n",
    1,
)
open(path, "w", encoding="utf-8").write(text[:start] + step + text[end:])
PY
}
add_push_trigger() {
  sed -i 's|^on:$|on:\n  push:\n    branches: [main]|' "$1/.github/workflows/release.yml"
}
unpin_release_ref() {
  sed -i "s|changelog-release.yml@$sha|changelog-release.yml@main|" \
    "$1/.github/workflows/release.yml"
}
drift_release_contract_ref() {
  sed -i "s|contract_ref: $sha|contract_ref: 0000000000000000000000000000000000000000|" \
    "$1/.github/workflows/release.yml"
}
expose_node_version_to_renovate() {
  sed -i "0,/node-version:/s/node-version:.*/node-version: '24'/" \
    "$1/.github/workflows/release.yml"
}
strip_release_provenance() {
  sed -i '/gen-changelog-caller.sh release-node/d' "$1/.github/workflows/release.yml"
}
# The trigger surface, written the ways a line-oriented guard cannot see. Flow
# style never matches a `^on:$` anchor, and workflow_call/release/workflow_run
# are absent from any blocklist that was written by listing what came to mind.
add_flow_style_push_trigger() {
  # Line-oriented on purpose. A regex over the whole file (`(?s)`) swallows
  # everything after `on:` and produces a mutant that is rejected for having no
  # release call at all — a case that looks like it passes and proves nothing.
  python3 - "$1/.github/workflows/release.yml" <<'PY'
import sys

path = sys.argv[1]
lines = open(path).read().splitlines(True)
out = []
index = 0
while index < len(lines):
    line = lines[index]
    if line.rstrip() == "on:":
        out.append(
            "on: {workflow_dispatch: {inputs: {version: {required: true,"
            " type: string}}}, push: {branches: [main]}}\n"
        )
        index += 1
        while index < len(lines) and (
            not lines[index].strip() or lines[index][:1] in " \t"
        ):
            index += 1
        continue
    out.append(line)
    index += 1
open(path, "w").write("".join(out))
PY
}
add_workflow_call_trigger() {
  sed -i 's|^on:$|on:\n  workflow_call:|' "$1/.github/workflows/release.yml"
}
add_release_trigger() {
  sed -i 's|^on:$|on:\n  release:\n    types: [published]|' "$1/.github/workflows/release.yml"
}
# The same credential, inherited rather than written on the install step, which
# is where a step-scoped guard stops looking.
install_token_from_job_env() {
  python3 - "$1/.github/workflows/release.yml" <<'PY'
import sys
path = sys.argv[1]
out = []
for line in open(path):
    if "NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}" in line:
        continue
    out.append(line)
    if line.startswith("  verify:"):
        out.append("    env:\n      NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n")
open(path, "w").write("".join(out))
PY
}
# Keying the checks on one filename let any other name collect none of them.
rename_release_caller() {
  mv "$1/.github/workflows/release.yml" "$1/.github/workflows/publish-package.yml"
  rm "$1/.github/workflows/release-propose.yml"
  sed -i '/^    needs: verify$/d' "$1/.github/workflows/publish-package.yml"
}

expect_rejection "a renderer pinned to a different commit" break_pin
expect_rejection "a hand-written renderer that bypasses the contract" handwrite_renderer
expect_rejection "a .releaserc.json that reintroduces release-on-merge" add_releaserc
expect_rejection "a second authored running log in NEXT.md" add_authored_log
expect_rejection "a fragment whose filename is not canonical" uncanonical_fragment
expect_rejection "a non-executable renderer" strip_executable
expect_rejection "a release caller without RELEASE_APP_CLIENT_ID" drop_release_app_client_id
expect_rejection "a release caller without RELEASE_APP_PRIVATE_KEY" drop_release_app_private_key
expect_rejection "a release caller restoring ORG_ADMIN_TOKEN" restore_org_admin_token
expect_rejection "a release caller wiring GITHUB_TOKEN" wire_github_token

# Rejected for the stated reason, not incidentally. expect_rejection only asserts
# a non-zero exit, so without this the guard could rot while its case stays green.
# It reads the LAST run, so it has to sit immediately after the credential cases.
grep -qE 'dedicated release App credential|RELEASE_APP_PRIVATE_KEY' "$tmproot/run.out" \
  && pass "the broad-token rejection names the dedicated release App remedy" \
  || fail "the last credential case failed for some other reason: $(tail -2 "$tmproot/run.out")"

expect_rejection "a snapshot caller granting GITHUB_TOKEN contents-write (#784)" grant_snapshot_github_token_write
expect_rejection "a snapshot job that verifies nothing first (#463, #464)" drop_snapshot_needs
expect_rejection "a snapshot job with no explicit runner (#465)" drop_snapshot_runner
expect_rejection "a resumed release that verifies the later dispatch tree instead of its tagged snapshot (#591)" drop_resume_snapshot_checkout
expect_rejection "an npm ci installing with GITHUB_TOKEN (#465)" install_with_github_token
expect_rejection "a verification job without package metadata preparation (#550)" drop_verify_prepare
expect_rejection "a verification suite with no dispatched version stamp (#519)" drop_verify_stamp
expect_rejection "version stamps that can run package lifecycle scripts (#519)" enable_stamp_lifecycle_scripts
expect_rejection "a first release whose scaffold version already matches the dispatch (#579)" reject_same_version_stamp
expect_rejection "a release verification suite without private-package auth (#569)" drop_verification_suite_token
expect_rejection "a generated release caller without the stamped-version header warning (#862)" drop_stamped_version_header
expect_rejection "a generated release caller without the stamped-version failure diagnostic (#862)" drop_stamped_version_diagnostic
expect_rejection "an unrelated release step exposed to private-package auth (#569)" expose_private_token_to_unrelated_step
expect_rejection "a release caller reachable by a push to main" add_push_trigger
expect_rejection "a release caller on a mutable reusable ref" unpin_release_ref
expect_rejection "a release caller whose contract_ref drifts from its uses pin" drift_release_contract_ref
expect_rejection "a release caller whose Node version became Renovate-visible" expose_node_version_to_renovate
expect_rejection "a hand-written release caller with no generator provenance" strip_release_provenance
expect_rejection "a push: trigger hidden in a flow-style on:" add_flow_style_push_trigger
expect_rejection "a release caller exposed as a reusable workflow_call" add_workflow_call_trigger
expect_rejection "a release caller fired by a release: event" add_release_trigger
expect_rejection "an install credential inherited from a job-level env:" install_token_from_job_env
expect_rejection "a release caller under any other filename (#463, #464)" rename_release_caller

# ...and the renamed caller must be rejected for its real defect, not merely for
# no longer being called release.yml. A checker that only notices the name would
# pass the identical file back under its old one.
grep -q 'publish-package.yml' "$tmproot/run.out" \
  && pass "the renamed release caller is checked under the name it actually has" \
  || fail "the renamed caller's rejection never names it: $(tail -2 "$tmproot/run.out")"

# The shape ~21 repositories carry today. If the emitted suite accepted it,
# regenerating would change nothing an adopter could observe.
legacy_release="$tmproot/adopter-legacy-release"
build_adopter "$legacy_release" legacy
run_adopter "$legacy_release" \
  && fail "emitted suite accepted the hand-copied verjson-payments release shape" \
  || pass "emitted suite rejects the hand-copied verjson-payments release shape"
grep -q 'gen-changelog-caller.sh release-node' "$tmproot/run.out" \
  && pass "the legacy release shape is rejected with the command that fixes it" \
  || fail "the legacy release rejection names no remedy: $(tail -2 "$tmproot/run.out")"

# The counterpart. docs/changelog/README.md tells adopters to write exactly this
# comment next to a correct wiring, so a guard matching the raw line would break
# the build of everyone who followed the documentation.
commented="$tmproot/adopter-commented"
build_adopter "$commented"
sed -i 's|^      release_app_private_key:|      # ORG_ADMIN_TOKEN and push_token are retired by ADR 0099.\n      release_app_private_key:|' \
  "$commented/.github/workflows/release.yml"
run_adopter "$commented" \
  && pass "emitted suite ignores retired-token names in comments" \
  || fail "emitted suite treated a comment as credential wiring: $(tail -2 "$tmproot/run.out")"

# A quoted title is the correct spelling, not a tolerated one, so the emitted
# suite has to read it the way the engine does. Both quote styles, because the
# unquoting rule branches on which quote opened the scalar and a parser can be
# right about one of them.
quoted="$tmproot/adopter-quoted"
build_adopter "$quoted"
cat >"$quoted/NEXT/2026-08-02-issue-8-quoted.md" <<'FRAGMENT'
---
date: 2026-08-02
issue: 8
title: "feat(caller): a double-quoted title"
---

The lead paragraph, which is what a release note carries.

## Why

The argument beneath it, which a release note does not.
FRAGMENT
git -C "$quoted" add -A >/dev/null 2>&1
git -C "$quoted" -c user.email=t@t -c user.name=t commit -qm quoted >/dev/null 2>&1
run_adopter "$quoted" \
  && pass "emitted suite accepts the quoted titles YAML requires of conventional commits" \
  || fail "emitted suite rejected a quoted title: $(tail -2 "$tmproot/run.out")"

commit_fixture() {
  # commit_fixture <dir> <message>
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm "$2" >/dev/null 2>&1
}

# `refs:` is in KNOWN_KEYS and exists so several entries can link an issue while
# only one owns it (#316). The renderer appends `; refs #n` after the back-link,
# but the emitted assertion anchored `_$` directly after the issue number, so the
# one combination the contract validates and renders correctly was rejected by
# the generated test — which adopters wire into `npm test` and may not edit (#461).
refs_adopter="$tmproot/adopter-refs"
build_adopter "$refs_adopter"
cat >"$refs_adopter/NEXT/2026-08-03-issue-5-refs.md" <<'FRAGMENT'
---
date: 2026-08-03
issue: 5
refs: 16
title: 'fix(caller): an entry that links a second issue'
---

Body.
FRAGMENT
commit_fixture "$refs_adopter" refs
run_adopter "$refs_adopter" \
  && pass "emitted suite accepts an issue-form fragment carrying refs (#461)" \
  || fail "emitted suite rejected a refs: fragment: $(tail -2 "$tmproot/run.out")"
refs_released="$tmproot/adopter-refs-released"
cp -a "$refs_adopter" "$refs_released"
python3 "$contract_src" release --repo-root "$refs_released" --version v1.0.0 >/dev/null 2>&1
run_adopter "$refs_released" \
  && pass "emitted suite still accepts refs metadata after the exact release path" \
  || fail "emitted suite rejects refs metadata after release: $(tail -2 "$tmproot/run.out")"

# Two refs, because one leaves the repeated group in the pattern unproven.
multi_refs="$tmproot/adopter-refs-multi"
build_adopter "$multi_refs"
cat >"$multi_refs/NEXT/2026-08-04-issue-6-multi-refs.md" <<'FRAGMENT'
---
date: 2026-08-04
issue: 6
refs: 16, 22
title: 'fix(caller): an entry that links two other issues'
---

Body.
FRAGMENT
commit_fixture "$multi_refs" multi-refs
run_adopter "$multi_refs" \
  && pass "emitted suite accepts a fragment refs-ing several issues (#461)" \
  || fail "emitted suite rejected a multi-ref fragment: $(tail -2 "$tmproot/run.out")"

# Widening the pattern to accept `refs` is only safe if it can still fail. Nothing
# an adopter writes can produce a back-link that disagrees with its own fragment —
# the engine derives both — so the mutation is applied to the rendered OUTPUT: the
# generated renderer keeps its pin and its delegation, and only what it prints is
# corrupted. Without this, every case above would pass against `.*`.
corrupt_render() {
  # corrupt_render <dir> <sed-script>
  RENDERER="$1/scripts/render-next.sh" MUTATION="$2" python3 - <<'PY'
import os
import shlex

path = os.environ["RENDERER"]
tail = 'exec python3 "$contract" "${args[@]}"\n'
text = open(path, encoding="utf-8").read()
if not text.endswith(tail):
    raise SystemExit("generated renderer no longer ends with the render exec")
piped = tail.rstrip("\n") + " | sed " + shlex.quote(os.environ["MUTATION"]) + "\n"
open(path, "w", encoding="utf-8").write(text[: -len(tail)] + piped)
PY
}

expect_backlink_rejection() {
  # expect_backlink_rejection <label> <sed-script>
  local label="$1" dir
  reject_seq=$((reject_seq + 1))
  dir="$tmproot/backlink-$reject_seq"
  build_adopter "$dir"
  cp "$refs_adopter/NEXT/2026-08-03-issue-5-refs.md" "$dir/NEXT/"
  commit_fixture "$dir" backlink
  corrupt_render "$dir" "$2"
  if run_adopter "$dir"; then
    fail "emitted suite accepted $label"
  elif grep -q 'back-link missing from the rendered log' "$tmproot/run.out"; then
    pass "emitted suite rejects $label"
  else
    fail "$label failed for another reason: $(tail -2 "$tmproot/run.out")"
  fi
}

expect_backlink_rejection "a rendered back-link naming the wrong issue" 's/issue #5;/issue #55;/'
expect_backlink_rejection "a rendered back-link carrying the wrong date" 's/^_Date: 2026-08-03;/_Date: 2026-08-13;/'
expect_backlink_rejection "text appended after the back-link's closing underscore" 's/refs #16_$/refs #16_ and more/'
expect_backlink_rejection "an unrecognised suffix in place of refs" 's/; refs #16_/; notes #16_/'
expect_backlink_rejection "a declared refs linkage the render dropped" 's/; refs #16_/_/'

# A validator may reject the first malformed back-link while rendered output is
# still much larger than a pipe buffer. The generated suite must report that
# policy diagnostic, never a producer-side Broken pipe made fatal by pipefail.
large_backlink="$tmproot/backlink-large"
build_adopter "$large_backlink"
cp "$refs_adopter/NEXT/2026-08-03-issue-5-refs.md" "$large_backlink/NEXT/"
python3 - "$large_backlink/NEXT/2026-08-03-issue-5-refs.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8") + ("rendered padding\n" * 32768), encoding="utf-8")
PY
commit_fixture "$large_backlink" large-backlink
corrupt_render "$large_backlink" 's/issue #5;/issue #55;/'
for attempt in 1 2 3 4 5; do
  if run_adopter "$large_backlink"; then
    fail "large rendered back-link mutation was accepted on attempt $attempt"
  elif grep -q 'back-link missing from the rendered log' "$tmproot/run.out" \
       && ! grep -qi 'broken pipe' "$tmproot/run.out"; then
    pass "large rendered rejection reports the intended diagnostic on attempt $attempt"
  else
    fail "large rendered rejection raced into another failure on attempt $attempt: $(tail -2 "$tmproot/run.out")"
  fi
done

# The released form is what an author is asked to read before merge, and under
# ADR 0059 it is the form that can never be corrected afterwards. A renderer that
# cannot produce it leaves only "skip the review" or "edit a generated artifact",
# and the contract forbids the second (#443).
released_out="$tmproot/as-released.out"
if (cd "$quoted" && ./scripts/render-next.sh --as-released) >"$released_out" 2>&1; then
  pass "the generated renderer accepts --as-released"
else
  fail "the generated renderer rejected --as-released: $(head -1 "$released_out")"
fi

# Distinguishes pass-through from a flag that is merely tolerated and dropped:
# the released form omits everything after the lead paragraph.
if grep -q '^## feat(caller): a double-quoted title$' "$released_out" \
  && grep -q '^The lead paragraph, which is what a release note carries\.$' "$released_out" \
  && ! grep -q '^## Why$' "$released_out"; then
  pass "--as-released renders the release note, not the whole diary"
else
  fail "--as-released did not change the output; the flag is being swallowed"
fi

cat >"$quoted/NEXT/2026-08-07-issue-390-python-stream.md" <<'FRAGMENT'
---
date: 2026-08-07
issue: 390
component: python
title: Python stream
---

Python-only release note.
FRAGMENT
commit_fixture "$quoted" component
component_out="$tmproot/component.out"
if (cd "$quoted" && ./scripts/render-next.sh --component python) \
    >"$component_out" 2>&1 \
    && grep -q '^## Python stream$' "$component_out" \
    && ! grep -q '^## feat(caller): a double-quoted title$' "$component_out"; then
  pass "the generated renderer selects exactly one explicit component stream"
else
  fail "the generated renderer does not isolate an explicit component stream"
fi

# Still a renderer, not a front end to a pinned engine: anything else is refused
# so a caller cannot reach subcommands the contract does not sanction.
if (cd "$quoted" && ./scripts/render-next.sh release --version v9.9.9) >/dev/null 2>&1; then
  fail "the generated renderer forwarded an unsanctioned argument"
else
  pass "the generated renderer still refuses arguments outside its render flags"
fi

# Only reachable after a release, so it needs a released fixture.
edited="$tmproot/adopter-edited"
build_adopter "$edited"
python3 "$contract_src" release --repo-root "$edited" --version v1.0.0 >/dev/null 2>&1
printf '\nhand-written addition\n' >>"$edited/CHANGELOG.md"
run_adopter "$edited" \
  && fail "emitted suite accepted a hand-edited CHANGELOG.md" \
  || pass "emitted suite rejects a hand-edited CHANGELOG.md"

# Generation is fail-closed on an unresolvable ref: emitting a caller whose engine
# cannot be verified would hand adopters a contract that only looks pinned.
gen_err="$(mktemp)"
if "$gen" renderer "$unresolvable_sha" >/dev/null 2>"$gen_err"; then
  fail "generator emitted a caller for a ref whose engine it could not read"
elif grep -q "cannot resolve" "$gen_err"; then
  pass "generating for an unresolvable ref fails closed with a stated cause"
else
  fail "generation failed for an unstated reason: $(cat "$gen_err")"
fi
rm -f "$gen_err"

[ "$fails" -eq 0 ] || exit 1
echo "All tests passed."
