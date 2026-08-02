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
sha="0123456789abcdef0123456789abcdef01234567"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -x "$gen" ] || { echo "FAIL - $gen is not executable"; exit 1; }

workflow="$(bash "$gen" workflow "$sha")"
renderer="$(bash "$gen" renderer "$sha")"

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
grep -qE '[0-9a-f]{64}' "$emitted" \
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
  # build_adopter <dir> [with-release-workflow: yes|no]
  local dir="$1" with_release="${2:-yes}"
  mkdir -p "$dir/NEXT" "$dir/scripts" "$dir/.github/workflows"
  bash "$gen" renderer "$sha" >"$dir/scripts/render-next.sh"
  bash "$gen" workflow "$sha" >"$dir/.github/workflows/changelog.yml"
  cp "$emitted" "$dir/scripts/changelog-contract.test.sh"
  chmod +x "$dir/scripts/render-next.sh" "$dir/scripts/changelog-contract.test.sh"
  if [ "$with_release" = yes ]; then
    cat >"$dir/.github/workflows/release.yml" <<YAML
name: release
on:
  workflow_dispatch:
    inputs:
      version:
        required: true
        type: string
jobs:
  release:
    uses: Verjson/.github/.github/workflows/changelog-release.yml@$sha
    with:
      contract_ref: $sha
      version: \${{ inputs.version }}
YAML
  fi
  cat >"$dir/NEXT/2026-08-01-issue-7-first.md" <<'FRAGMENT'
---
date: 2026-08-01
issue: 7
title: First entry
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

python3 "$contract_src" release --repo-root "$adopter" --version v1.0.0 >/dev/null 2>&1
{ [ -f "$adopter/CHANGELOG/v1.0.0.md" ] && [ -e "$adopter/CHANGELOG.md" ]; } \
  && pass "fixture release really consumed NEXT/ and wrote released history" \
  || fail "fixture release produced no released tree; the next check would be vacuous"

# The regression. Nothing in the hand-copied shape survived this step.
run_adopter "$adopter" \
  && pass "emitted suite still passes AFTER a real release (#309)" \
  || fail "emitted suite breaks on the first release: $(tail -2 "$tmproot/run.out")"

# An adopter with nothing to publish has no release.yml; `agents` and
# `github-runner` are in exactly that shape and must not be forced to invent one.
build_adopter "$tmproot/adopter-norelease" no
run_adopter "$tmproot/adopter-norelease" \
  && pass "emitted suite tolerates an adopter with no release workflow" \
  || fail "emitted suite requires a release workflow: $(tail -2 "$tmproot/run.out")"

# A suite that passes everywhere is worthless. Each case below breaks exactly one
# invariant in a fresh adopter and requires a non-zero exit.
reject_seq=0
expect_rejection() {
  # expect_rejection <label> <mutator-fn>
  local label="$1" mutator="$2" dir
  reject_seq=$((reject_seq + 1))
  dir="$tmproot/reject-$reject_seq"
  build_adopter "$dir"
  "$mutator" "$dir"
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

expect_rejection "a renderer pinned to a different commit" break_pin
expect_rejection "a hand-written renderer that bypasses the contract" handwrite_renderer
expect_rejection "a .releaserc.json that reintroduces release-on-merge" add_releaserc
expect_rejection "a second authored running log in NEXT.md" add_authored_log
expect_rejection "a fragment whose filename is not canonical" uncanonical_fragment
expect_rejection "a non-executable renderer" strip_executable

# Only reachable after a release, so it needs a released fixture.
edited="$tmproot/adopter-edited"
build_adopter "$edited"
python3 "$contract_src" release --repo-root "$edited" --version v1.0.0 >/dev/null 2>&1
printf '\nhand-written addition\n' >>"$edited/CHANGELOG.md"
run_adopter "$edited" \
  && fail "emitted suite accepted a hand-edited CHANGELOG.md" \
  || pass "emitted suite rejects a hand-edited CHANGELOG.md"

[ "$fails" -eq 0 ] || exit 1
echo "All tests passed."
