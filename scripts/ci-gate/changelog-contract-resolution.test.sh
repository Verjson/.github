#!/usr/bin/env bash
# Tests how a generated changelog caller decides WHICH implementation it runs
# (Verjson/.github#304).
#
# The renderer is sold to adopters as "runs the same code CI validates with".
# Before this, that held only by luck: the cache path is keyed by commit, which
# reads as content-addressed but is not, and nothing verified the bytes. Anything
# able to write that path — another tool, a restored CI cache, an interrupted
# write — was executed as the contract on every subsequent run.
#
# Pinning the digest turns the guarantee into something checked, and that is what
# lets CHANGELOG_CONTRACT_PATH come back: the override selects WHERE the engine
# is read from (vendored copy, offline mirror, warmed cache) and cannot select
# WHAT runs.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
generator="$root/scripts/gen-changelog-caller.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

ref="$(git -C "$root" rev-parse HEAD)"

# The engine as committed at $ref, which is what the generated scripts pin. Read
# from git rather than the worktree: a dirty worktree would otherwise make every
# case here disagree with the digest for reasons that have nothing to do with the
# behaviour under test.
git -C "$root" show "$ref:scripts/changelog.py" >"$tmp/pinned.py" 2>/dev/null \
  || { echo "FAIL - cannot read scripts/changelog.py at $ref"; exit 1; }

"$generator" renderer "$ref" >"$tmp/render-next.sh" 2>"$tmp/gen.err" \
  || { echo "FAIL - generator failed: $(cat "$tmp/gen.err")"; exit 1; }
chmod +x "$tmp/render-next.sh"

digest() { sha256sum <"$1" | cut -d' ' -f1; }

embedded="$(grep -oE 'CONTRACT_SHA256="[0-9a-f]{64}"' "$tmp/render-next.sh" | head -n1 | cut -d'"' -f2)"
[ "$embedded" = "$(digest "$tmp/pinned.py")" ] \
  && pass "the generated renderer pins the digest of the engine at its ref" \
  || fail "embedded digest does not match the engine at $ref (got ${embedded:-none})"

# A captured copy is not the file: $(...) strips trailing newlines, so digesting
# one rejects every honest override. This case is why that bug did not ship.
[ -n "$embedded" ] && [ "$embedded" != "$(printf '%s' "$(cat "$tmp/pinned.py")" | sha256sum | cut -d' ' -f1)" ] \
  && pass "the pinned digest covers the file's trailing newline" \
  || fail "the pinned digest looks computed from a newline-stripped capture"

# One emitter, not two copies: the renderer and the contract test must resolve
# the contract identically or they can execute different implementations, which
# is #304 one level down.
"$generator" contract-test "$ref" >"$tmp/contract-test.sh" 2>/dev/null
for marker in 'contract_is_pinned()' 'CHANGELOG_CONTRACT_PATH' \
  'VERJSON_CHANGELOG_TOOL_CACHE' 'CONTRACT_SHA256='; do
  if grep -qF "$marker" "$tmp/render-next.sh" && grep -qF "$marker" "$tmp/contract-test.sh"; then
    pass "both generated scripts carry $marker"
  else
    fail "$marker is missing from one of the generated scripts"
  fi
done

# --- fixture adopter -------------------------------------------------------
mkdir -p "$tmp/adopter/.github/workflows" "$tmp/adopter/scripts" \
  "$tmp/adopter/NEXT" "$tmp/bin"
cp "$tmp/render-next.sh" "$tmp/adopter/scripts/render-next.sh"
cp "$tmp/contract-test.sh" "$tmp/adopter/scripts/changelog-contract.test.sh"
"$generator" workflow "$ref" >"$tmp/adopter/.github/workflows/changelog.yml"
chmod +x "$tmp/adopter/scripts/changelog-contract.test.sh"
printf -- '---\ndate: 2026-08-02\nissue: 1\ntitle: fixture entry\n---\n\nbody\n' \
  >"$tmp/adopter/NEXT/2026-08-02-issue-1-fixture.md"
cp "$tmp/pinned.py" "$tmp/identical.py"
cp "$tmp/pinned.py" "$tmp/divergent.py"; printf '\n# divergent\n' >>"$tmp/divergent.py"
# An engine that announces itself, so "did the wrong implementation run" is
# observable rather than inferred.
printf 'import sys\nprint("POISONED", file=sys.stderr)\nsys.exit(0)\n' >"$tmp/poison.py"
printf '#!/usr/bin/env bash\nexit 6\n' >"$tmp/bin/curl"; chmod +x "$tmp/bin/curl"

cache_root="$tmp/cache"
cache_dir="$cache_root/$ref"

render() { # render [env assignments...] -> "rc=<n>"; output in $tmp/out.txt
  ( cd "$tmp/adopter" && env "$@" VERJSON_CHANGELOG_TOOL_CACHE="$cache_root" \
      ./scripts/render-next.sh >"$tmp/out.txt" 2>&1; echo "rc=$?" )
}
poison_cache() { mkdir -p "$cache_dir"; cp "$tmp/poison.py" "$cache_dir/changelog.py"; }
ran_poison() { grep -q POISONED "$tmp/out.txt"; }

rm -rf "$cache_root"
[ "$(render CHANGELOG_CONTRACT_PATH="$tmp/identical.py")" = "rc=0" ] \
  && pass "an override holding the pinned bytes is accepted (#304's vendored copy)" \
  || fail "a byte-identical override was rejected: $(tail -1 "$tmp/out.txt")"

rc="$(render CHANGELOG_CONTRACT_PATH="$tmp/divergent.py")"
{ [ "$rc" != "rc=0" ] && grep -q "is not the contract pinned at" "$tmp/out.txt"; } \
  && pass "an override that diverges from the pin is refused" \
  || fail "a divergent override was accepted or refused for the wrong reason ($rc)"

rc="$(render CHANGELOG_CONTRACT_PATH="$tmp/absent.py")"
{ [ "$rc" != "rc=0" ] && grep -q "does not exist" "$tmp/out.txt"; } \
  && pass "an override naming a missing file is refused" \
  || fail "a missing override target was accepted or refused for the wrong reason ($rc)"

rm -rf "$cache_root"
mkdir -p "$cache_dir"
cp "$tmp/pinned.py" "$cache_dir/changelog.py"
rc="$(render PATH="$tmp/bin:$PATH")"
{ [ "$rc" = "rc=0" ] && ! ran_poison; } \
  && pass "a verified runner-preloaded cache works with egress blocked" \
  || fail "an offline verified cache hit was rejected ($rc)"

if ( cd "$tmp/adopter" \
  && env VERJSON_CHANGELOG_TOOL_CACHE="$cache_root" PATH="$tmp/bin:$PATH" \
    ./scripts/changelog-contract.test.sh >/dev/null ); then
  pass "the generated contract and disposable release suite use the offline cache"
else
  fail "the generated contract/release suite could not use the offline cache"
fi

# The hole that existed independently of the override: a cache entry at the right
# path with the wrong bytes. Without a network to repair from, this must FAIL —
# falling back to the resident copy is the fail-open.
rm -rf "$cache_root"; poison_cache
rc="$(render PATH="$tmp/bin:$PATH")"
{ [ "$rc" != "rc=0" ] && ! ran_poison \
  && grep -q "VERJSON_CHANGELOG_TOOL_CACHE=$cache_root" "$tmp/out.txt" \
  && grep -q "$cache_dir/changelog.py" "$tmp/out.txt"; } \
  && pass "a poisoned cache entry is never executed, even with no way to refetch" \
  || fail "a poisoned offline cache did not fail with an actionable repair path ($rc)"

# Given a source to repair from, the same poisoned entry is replaced rather than
# merely refused. The source is a stub serving the pinned bytes, not the live
# network: fetching raw.githubusercontent at HEAD only works when HEAD happens to
# be published, so a rebase, a fork, or an offline runner would fail this case for
# a reason that has nothing to do with the behaviour under test.
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done\ncat %q >"$out"\n' \
  "$tmp/pinned.py" >"$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
rm -rf "$cache_root"
rc="$(render PATH="$tmp/bin:$PATH")"
{ [ "$rc" = "rc=0" ] && [ "$(digest "$cache_dir/changelog.py")" = "$embedded" ]; } \
  && pass "a cache miss falls back to the pinned upstream contract" \
  || fail "a cache miss did not populate the verified cache ($rc)"

rm -rf "$cache_root"; poison_cache
rc="$(render PATH="$tmp/bin:$PATH")"
{ [ "$rc" = "rc=0" ] && ! ran_poison && [ -f "$cache_dir/changelog.py" ] \
  && [ "$(digest "$cache_dir/changelog.py")" = "$embedded" ]; } \
  && pass "a poisoned cache entry is replaced by the pinned contract" \
  || fail "a poisoned cache entry was not repaired ($rc)"

# A fetch that returns the wrong bytes must not be published into the cache, or
# the next run inherits it.
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done\ncat %q >"$out"\n' \
  "$tmp/poison.py" >"$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
rm -rf "$cache_root"
rc="$(render PATH="$tmp/bin:$PATH")"
{ [ "$rc" != "rc=0" ] && ! ran_poison && [ ! -f "$cache_dir/changelog.py" ]; } \
  && pass "a fetch that does not match the pin is refused and not cached" \
  || fail "a mismatched fetch was executed or left in the cache ($rc)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
