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
generated_artifacts="$(bash "$gen" generated-artifacts "$sha")"
generated_artifacts_with_adr="$(bash "$gen" generated-artifacts-with-adr-index "$sha")"
adr_index_generator="$(bash "$gen" adr-index-generator "$sha")"

# 1. The workflow pins its `uses:` and its contract_ref to the same commit.
uses_ref="$(printf '%s\n' "$workflow" | sed -n 's#.*changelog-validate\.yml@\([0-9a-f]\{40\}\).*#\1#p')"
input_ref="$(printf '%s\n' "$workflow" | sed -n 's/^ *contract_ref: \([0-9a-f]\{40\}\) *$/\1/p')"
[ "$uses_ref" = "$sha" ] && pass "workflow pins uses: to the requested commit" \
  || fail "workflow uses: is '$uses_ref', expected $sha"
[ "$input_ref" = "$sha" ] && pass "workflow passes contract_ref as the same commit" \
  || fail "workflow contract_ref is '$input_ref', expected $sha"

# 2. The renderer pins the same commit the workflow validates with.
script_ref="$(printf '%s\n' "$renderer" | sed -n 's/^CONTRACT_REF="\([0-9a-f]\{40\}\)"$/\1/p')"
[ "$script_ref" = "$uses_ref" ] \
  && pass "renderer and workflow share one contract commit" \
  || fail "renderer pins '$script_ref' but workflow pins '$uses_ref'"

# 3. The renderer is valid bash and renders nothing on its own.
printf '%s\n' "$renderer" | bash -n \
  && pass "generated renderer parses as bash" || fail "generated renderer is not valid bash"

# 4. Least privilege: the workflow requests no write scope.
printf '%s\n' "$workflow" | grep -q 'contents: read' \
  && pass "workflow declares contents: read" || fail "workflow does not declare contents: read"
printf '%s\n' "$workflow" | grep -qE '\bwrite\b' \
  && fail "workflow requests a write permission" || pass "workflow requests no write permission"

# 4a. The shared generated-artifacts caller is generated at the same immutable
# pin. Changelog-only stays the safe default; ADR checking is a separate mode
# because opting in before acquiring the generator is a counted failure.
printf '%s\n' "$generated_artifacts" \
  | grep -q "generated-artifacts.yml@$sha" \
  && pass "generated-artifacts caller pins the requested workflow commit" \
  || fail "generated-artifacts caller does not pin $sha"
printf '%s\n' "$generated_artifacts" | grep -qE '^ +changelog: true$' \
  && printf '%s\n' "$generated_artifacts" | grep -qE "^ +contract_ref: $sha$" \
  && pass "generated-artifacts caller enables changelog validation at the pin" \
  || fail "generated-artifacts caller does not enable pinned changelog validation"
printf '%s\n' "$generated_artifacts" | grep -qE '^ +adr-index: true$' \
  && fail "changelog-only generated-artifacts caller enables ADR checking without its generator" \
  || pass "changelog-only generated-artifacts caller does not opt into ADR checking"
printf '%s\n' "$generated_artifacts_with_adr" | grep -qE '^ +adr-index: true$' \
  && printf '%s\n' "$generated_artifacts_with_adr" \
    | grep -q "generated-artifacts.yml@$sha" \
  && pass "ADR-index caller explicitly enables ADR checking at the pin" \
  || fail "ADR-index caller does not enable ADR checking"
cmp -s <(printf '%s\n' "$adr_index_generator") "$repo_root/scripts/gen-adr-index.sh" \
  && pass "adr-index-generator emits the canonical pinned generator" \
  || fail "adr-index-generator does not emit the pinned gen-adr-index.sh"
printf '%s\n' "$adr_index_generator" | bash -n \
  && pass "generated ADR index generator parses as bash" \
  || fail "generated ADR index generator is not valid bash"

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
for mode in generated-artifacts generated-artifacts-with-adr-index adr-index-generator; do
  if bash "$gen" "$mode" main >/dev/null 2>&1; then
    fail "$mode accepted a mutable ref"
  else
    pass "$mode rejects a mutable ref"
  fi
done

# 6. An unknown mode fails rather than emitting an empty file.
bash "$gen" bogus "$sha" >/dev/null 2>&1 \
  && fail "generator accepted an unknown mode" || pass "generator rejects an unknown mode"

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
  if [ "$caller" = generated-artifacts-with-adr-index ]; then
    bash "$gen" adr-index-generator "$sha" >"$dir/scripts/gen-adr-index.sh"
    chmod +x "$dir/scripts/gen-adr-index.sh"
  fi
  cp "$emitted" "$dir/scripts/changelog-contract.test.sh"
  chmod +x "$dir/scripts/render-next.sh" "$dir/scripts/changelog-contract.test.sh"
  if [ "$with_release" = yes ]; then
    bash "$gen" release-node "$sha" >"$dir/.github/workflows/release.yml"
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

run_adopter() {
  ( cd "$1" && ./scripts/changelog-contract.test.sh ) >"$tmproot/run.out" 2>&1
}

adopter="$tmproot/adopter"
build_adopter "$adopter"
run_adopter "$adopter" \
  && pass "emitted suite passes against an unreleased adopter" \
  || fail "emitted suite failed before any release: $(tail -2 "$tmproot/run.out")"

generated_adopter="$tmproot/adopter-generated-artifacts"
build_adopter "$generated_adopter" no generated-artifacts
run_adopter "$generated_adopter" \
  && pass "emitted suite accepts the generated-artifacts caller" \
  || fail "emitted suite rejects the generated-artifacts caller: $(tail -2 "$tmproot/run.out")"

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
# The release push lands on the default branch, which `main-protection` forbids
# for GITHUB_TOKEN. That rejection happens on a real remote, so no fixture can
# reproduce it — the emitted suite has to reject the wiring statically (#389).
# Every spelling below is the same credential, so a guard that catches only the
# first one reports green on a release that cannot run.
wire_push_token() {
  # wire_push_token <dir> <value>
  local escaped
  escaped="$(printf '%s' "$2" | sed 's/[&/\]/\\&/g')"
  sed -i "s/\${{ secrets.ORG_ADMIN_TOKEN }}/$escaped/" \
    "$1/.github/workflows/release.yml"
}
wire_unprivileged_push_token() { wire_push_token "$1" '${{ secrets.GITHUB_TOKEN }}'; }
wire_quoted_push_token() { wire_push_token "$1" '"${{ secrets.GITHUB_TOKEN }}"'; }
wire_alias_push_token() { wire_push_token "$1" '${{ github.token }}'; }
wire_lowercase_push_token() { wire_push_token "$1" '${{ secrets.github_token }}'; }
wire_folded_push_token() {
  # Inserted on the line after the key, which is where YAML puts a folded
  # scalar's value — not appended at EOF, which in the generated caller lands
  # inside a later job and so would exercise nothing.
  wire_push_token "$1" '>-'
  sed -i 's|^      push_token: >-$|      push_token: >-\n        ${{ secrets.GITHUB_TOKEN }}|' \
    "$1/.github/workflows/release.yml"
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
install_with_github_token() {
  sed -i 's|NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}|NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}|g' \
    "$1/.github/workflows/release.yml"
}
move_publish_stamp_after_build() {
  python3 - "$1/.github/workflows/release.yml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
stamp = """      - name: Stamp the dispatched package version
        env:
          VERSION: ${{ inputs.version }}
        run: npm version "${VERSION#v}" --no-git-tag-version --ignore-scripts
"""
build = "      - run: npm run build --if-present\n"
publish = text.index("  publish:")
before, job = text[:publish], text[publish:]
if stamp not in job or build not in job:
    raise SystemExit("publish stamp/build fixture no longer matches generated output")
job = job.replace(stamp, "", 1).replace(build, build + stamp, 1)
open(path, "w", encoding="utf-8").write(before + job)
PY
}
add_push_trigger() {
  sed -i 's|^on:$|on:\n  push:\n    branches: [main]|' "$1/.github/workflows/release.yml"
}
unpin_release_ref() {
  sed -i "s|changelog-release.yml@$sha|changelog-release.yml@main|" \
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
  sed -i '/^    needs: verify$/d' "$1/.github/workflows/publish-package.yml"
}

expect_rejection "a renderer pinned to a different commit" break_pin
expect_rejection "a hand-written renderer that bypasses the contract" handwrite_renderer
expect_rejection "a .releaserc.json that reintroduces release-on-merge" add_releaserc
expect_rejection "a second authored running log in NEXT.md" add_authored_log
expect_rejection "a fragment whose filename is not canonical" uncanonical_fragment
expect_rejection "a non-executable renderer" strip_executable
expect_rejection "a release caller wiring GITHUB_TOKEN as push_token" wire_unprivileged_push_token
expect_rejection "a quoted GITHUB_TOKEN push_token" wire_quoted_push_token
expect_rejection "the github.token alias as push_token" wire_alias_push_token
expect_rejection "a lower-case secrets.github_token push_token" wire_lowercase_push_token
expect_rejection "a folded GITHUB_TOKEN push_token on the next line" wire_folded_push_token

# Rejected for the stated reason, not incidentally. expect_rejection only asserts
# a non-zero exit, so without this the guard could rot while its case stays green.
# It reads the LAST run, so it has to sit immediately after the push_token cases.
grep -q 'push_token' "$tmproot/run.out" \
  && pass "the push_token rejection names push_token as the cause" \
  || fail "the last push_token case failed for some other reason: $(tail -2 "$tmproot/run.out")"

expect_rejection "a snapshot job that verifies nothing first (#463, #464)" drop_snapshot_needs
expect_rejection "a snapshot job with no explicit runner (#465)" drop_snapshot_runner
expect_rejection "an npm ci installing with GITHUB_TOKEN (#465)" install_with_github_token
expect_rejection "a publish build that runs before the dispatched version stamp (#519)" move_publish_stamp_after_build
expect_rejection "a release caller reachable by a push to main" add_push_trigger
expect_rejection "a release caller on a mutable reusable ref" unpin_release_ref
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
sed -i 's|^      push_token:|      # NOT GITHUB_TOKEN — see Verjson/.github ADR 0052.\n      push_token:|' \
  "$commented/.github/workflows/release.yml"
run_adopter "$commented" \
  && pass "emitted suite accepts a correct wiring carrying a GITHUB_TOKEN warning comment" \
  || fail "emitted suite rejected a documented comment: $(tail -2 "$tmproot/run.out")"

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
tail = 'exec python3 "$contract" render-next --repo-root "$root"\n'
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

# Still a renderer, not a front end to a pinned engine: anything else is refused
# so a caller cannot reach subcommands the contract does not sanction.
if (cd "$quoted" && ./scripts/render-next.sh release --version v9.9.9) >/dev/null 2>&1; then
  fail "the generated renderer forwarded an unsanctioned argument"
else
  pass "the generated renderer still refuses arguments other than --as-released"
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
