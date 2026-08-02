#!/usr/bin/env bash
# Contract tests for `scripts/gen-changelog-caller.sh contract-test` (#309, #304).
#
# The contract test was the last hand-copied adoption surface, so consumers
# copied it from whichever repository migrated most recently and inherited that
# repository's assumptions about its own state. Generating it moves the
# release-safe shape here; these assertions are what "release-safe" means.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
gen="$repo_root/scripts/gen-changelog-caller.sh"
sha="0123456789abcdef0123456789abcdef01234567"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -x "$gen" ] || { echo "FAIL - $gen is not executable"; exit 1; }

# 1. The mode exists and emits a script that parses as bash.
if contract_test="$(bash "$gen" contract-test "$sha" 2>/dev/null)"; then
  pass "generator emits a contract test"
else
  fail "generator has no contract-test mode"
  contract_test=""
fi
[ -n "$contract_test" ] && printf '%s\n' "$contract_test" | bash -n 2>/dev/null \
  && pass "generated contract test parses as bash" \
  || fail "generated contract test is empty or not valid bash"

# The new mode interpolates the ref into a shell assignment, so it inherits the
# generator's ref guard — asserted for this mode, not assumed from a sibling.
for bad in 'main' "$(printf 'main"\n rm -rf /\n#')" '../../evil' "${sha^^}" "${sha}0" ''; do
  bash "$gen" contract-test "$bad" >/dev/null 2>&1 \
    && fail "contract-test accepted a non-commit ref: '${bad//$'\n'/\\n}'" \
    || pass "contract-test rejects non-commit ref: '${bad//$'\n'/\\n}'"
done

# One pin across all three artifacts, read out of each emitted file.
test_ref="$(printf '%s\n' "$contract_test" | sed -n 's/^CONTRACT_REF="\([0-9a-f]\{40\}\)"$/\1/p')"
renderer_ref="$(bash "$gen" renderer "$sha" | sed -n 's/^CONTRACT_REF="\([0-9a-f]\{40\}\)"$/\1/p')"
workflow_ref="$(bash "$gen" workflow "$sha" | sed -n 's#.*changelog-validate\.yml@\([0-9a-f]\{40\}\).*#\1#p')"
[ -n "$test_ref" ] && [ "$test_ref" = "$renderer_ref" ] && [ "$test_ref" = "$workflow_ref" ] \
  && pass "contract test, renderer, and workflow pin one commit" \
  || fail "pins disagree: test '$test_ref', renderer '$renderer_ref', workflow '$workflow_ref'"

# 2. Release safety, proved by performing a real release.
#
# This is the assertion that caught #309: the copied test was green on every
# adopter until the first release consumed NEXT/ and generated CHANGELOG.md, and
# permanently red afterwards. A generated test that has never survived a release
# is the same bug again, so the fixture below runs it on both sides of one.
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

# Seeded from this repository's own contract so the fixture needs no network:
# the generated scripts resolve the contract by content address, and a seeded
# cache entry is indistinguishable from a fetched one.
#
# Seeded as a recording shim rather than a plain copy, so what the generated test
# asks the contract to do is observed instead of inferred from its text.
cache_home="$tmproot/cache"
mkdir -p "$cache_home/verjson-changelog/$sha" "$tmproot/home"
export CONTRACT_REAL="$repo_root/scripts/changelog.py"
export CONTRACT_RECORD="$tmproot/contract-record"
: > "$CONTRACT_RECORD"
cat > "$cache_home/verjson-changelog/$sha/changelog.py" <<'SHIM'
#!/usr/bin/env python3
import os
import runpy
import sys

with open(os.environ["CONTRACT_RECORD"], "a", encoding="utf-8") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")
runpy.run_path(os.environ["CONTRACT_REAL"], run_name="__main__")
SHIM

case_root="$tmproot/case"
mkdir -p "$case_root/scripts" "$case_root/NEXT" "$case_root/.github/workflows"
bash "$gen" workflow "$sha" > "$case_root/.github/workflows/changelog.yml"
bash "$gen" renderer "$sha" > "$case_root/scripts/render-next.sh"
printf '%s\n' "$contract_test" > "$case_root/scripts/changelog-contract.test.sh"
chmod +x "$case_root/scripts/render-next.sh" "$case_root/scripts/changelog-contract.test.sh"
cat > "$case_root/NEXT/2026-08-02-issue-309-fixture.md" <<'FRAGMENT'
---
date: 2026-08-02
issue: 309
title: A fixture fragment the generated test must never name
---

Body.
FRAGMENT
git -C "$case_root" init -q
git -C "$case_root" config user.name Test
git -C "$case_root" config user.email test@example.com
git -C "$case_root" add -A
git -C "$case_root" commit -qm initial

run_generated_test() {
  XDG_CACHE_HOME="$cache_home" HOME="$tmproot/home" \
    bash "$case_root/scripts/changelog-contract.test.sh" >"$tmproot/out" 2>&1
}

if run_generated_test; then
  pass "generated contract test passes before any release"
else
  fail "generated contract test failed on an unreleased repository"
  sed 's/^/       /' "$tmproot/out"
fi

# A test that has never survived a release cannot claim to be release-safe, so
# the generated test must cut one itself against a throwaway fixture. Read from
# the recorded contract invocations, not from the generated text.
grep -q '^release ' "$CONTRACT_RECORD" \
  && pass "generated contract test performs a real release against a fixture" \
  || fail "generated contract test never invoked the contract's release command"
grep -q '^render-released ' "$CONTRACT_RECORD" \
  && pass "generated contract test compares CHANGELOG.md against rendered release history" \
  || fail "generated contract test never invoked render-released"

# Negative control. Everything else here asks the generated test to pass, which
# an empty script also does; this is the assertion that makes those meaningful.
cat > "$case_root/NEXT/2026-08-02-legacy-name.md" <<'FRAGMENT'
# A pre-contract fragment the canonical validator must reject

Body.
FRAGMENT
if run_generated_test; then
  fail "generated contract test accepted a repository that violates the contract"
else
  pass "generated contract test rejects a repository that violates the contract"
fi
rm -f "$case_root/NEXT/2026-08-02-legacy-name.md"

XDG_CACHE_HOME="$cache_home" python3 "$repo_root/scripts/changelog.py" \
  release --repo-root "$case_root" --version v1.0.0 >/dev/null 2>"$tmproot/relerr" || {
  fail "fixture release did not complete: $(cat "$tmproot/relerr")"
}

# The state the copied test asserted the opposite of, pinned so the fixture
# itself cannot quietly stop exercising a post-release repository.
[ -z "$(find "$case_root/NEXT" -name '*.md' ! -name 'README.md' -print -quit)" ] \
  && [ -f "$case_root/CHANGELOG.md" ] \
  && [ -f "$case_root/CHANGELOG/v1.0.0.md" ] \
  && pass "fixture release consumed NEXT/ and generated CHANGELOG.md" \
  || fail "fixture release left the repository in a pre-release state"

if run_generated_test; then
  pass "generated contract test still passes after a real release"
else
  fail "generated contract test went red after a real release (#309)"
  sed 's/^/       /' "$tmproot/out"
fi

# The third state, and the one a hardcoded assertion actually dies in: the
# release consumed the old fragments and the next pull request adds a new one.
# Every adopter reaches it on the first merge after its first release.
cat > "$case_root/NEXT/2026-08-03-issue-311-after-release.md" <<'FRAGMENT'
---
date: 2026-08-03
issue: 311
title: A fragment authored after the first release
---

Body.
FRAGMENT
if run_generated_test; then
  pass "generated contract test passes on a released repository with new fragments"
else
  fail "generated contract test went red once a post-release fragment was added (#309)"
  sed 's/^/       /' "$tmproot/out"
fi
rm -f "$case_root/NEXT/2026-08-03-issue-311-after-release.md"

# 3. Interface parity between the two generated artifacts (#304).
#
# Both are now emitted by one generator, so they must agree by construction. The
# bug being closed is not "the test called the renderer wrongly" — it is that the
# call was silently ignored and the test stayed green, because the path the test
# computed for itself happened to equal the one the renderer computed. Both
# halves are therefore observed by execution, not read off the source.

# 3a. Both scripts resolve the pinned contract at the same cache directory.
mkdir -p "$tmproot/bin"
cat > "$tmproot/bin/curl" <<'STUB'
#!/usr/bin/env bash
target=""
while [ "$#" -gt 0 ]; do
  [ "$1" = "-o" ] && { target="$2"; shift 2; continue; }
  shift
done
printf '%s\n' "$(cd "$(dirname "$target")" && pwd)" >> "$CURL_RECORD"
exit 1
STUB
chmod +x "$tmproot/bin/curl"

resolved_cache_dir() {
  # $1: script to run; $2: record label. One shared, emptied cache root for both,
  # so the two answers are comparable rather than trivially different.
  local record="$tmproot/curl-record.$2"
  : > "$record"
  rm -rf "$tmproot/empty-cache"
  CURL_RECORD="$record" PATH="$tmproot/bin:$PATH" \
    XDG_CACHE_HOME="$tmproot/empty-cache" HOME="$tmproot/home" \
    bash "$1" >/dev/null 2>&1 || true
  head -n 1 "$record"
}

renderer_cache_dir="$(resolved_cache_dir "$case_root/scripts/render-next.sh" renderer)"
test_cache_dir="$(resolved_cache_dir "$case_root/scripts/changelog-contract.test.sh" test)"
[ -n "$renderer_cache_dir" ] && [ "$renderer_cache_dir" = "$test_cache_dir" ] \
  && pass "renderer and contract test resolve one contract cache directory" \
  || fail "contract cache directories differ: renderer '$renderer_cache_dir' vs test '$test_cache_dir'"

# 3b. What the contract test invokes is what the renderer accepts.
#
# Recorded by substituting a stub renderer that logs its argv and environment and
# then delegates, so the record is what the test actually did rather than what a
# regex thought it did.
mv "$case_root/scripts/render-next.sh" "$case_root/scripts/render-next.real.sh"
cat > "$case_root/scripts/render-next.sh" <<STUB
#!/usr/bin/env bash
CONTRACT_REF="$sha"
{
  printf 'argc=%s\n' "\$#"
  for a in "\$@"; do printf 'arg=%s\n' "\$a"; done
  env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/envname=\1/p'
  printf 'end\n'
} >> "\$RENDERER_RECORD"
exec "\$(dirname "\$0")/render-next.real.sh" "\$@"
STUB
chmod +x "$case_root/scripts/render-next.sh"

# Reinstated so the "unreleased log" block runs and the renderer is invoked.
cat > "$case_root/NEXT/2026-08-02-issue-310-parity.md" <<'FRAGMENT'
---
date: 2026-08-02
issue: 310
title: A fragment that makes the renderer run
---

Body.
FRAGMENT

export RENDERER_RECORD="$tmproot/renderer-record"
: > "$RENDERER_RECORD"
XDG_CACHE_HOME="$cache_home" HOME="$tmproot/home" \
  env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sort -u > "$tmproot/ambient"
XDG_CACHE_HOME="$cache_home" HOME="$tmproot/home" \
  bash "$case_root/scripts/changelog-contract.test.sh" >"$tmproot/out" 2>&1 || true

if grep -q '^argc=' "$tmproot/renderer-record"; then
  pass "the contract test invokes the renderer"
else
  fail "the contract test never invoked the renderer, so parity is untested"
fi

# Anything the test injected that the renderer does not read is silently ignored:
# a green run that exercised a different implementation than it asked for.
grep '^envname=' "$tmproot/renderer-record" | sed 's/^envname=//' | sort -u \
  > "$tmproot/injected-raw"
printf '%s\n' _ PWD OLDPWD SHLVL RENDERER_RECORD >> "$tmproot/ambient"
sort -u -o "$tmproot/ambient" "$tmproot/ambient"
comm -23 "$tmproot/injected-raw" "$tmproot/ambient" > "$tmproot/injected"
unread=""
while read -r name; do
  [ -n "$name" ] || continue
  grep -q "\$$name\|\${$name" "$case_root/scripts/render-next.real.sh" || unread="$unread $name"
done < "$tmproot/injected"
[ -z "$unread" ] \
  && pass "contract test sets no environment the renderer ignores" \
  || fail "contract test sets environment the renderer never reads:$unread"

# Every recorded argv is replayed against the real renderer: exit 2 is its
# "unexpected argument" rejection, so a match means the interfaces agree.
argv_rejected=""
while read -r argc; do
  set --
  n=0
  while [ "$n" -lt "$argc" ]; do set -- "$@" "x$n"; n=$((n + 1)); done
  XDG_CACHE_HOME="$cache_home" HOME="$tmproot/home" \
    bash "$case_root/scripts/render-next.real.sh" "$@" >/dev/null 2>&1
  [ "$?" -eq 2 ] && argv_rejected="$argv_rejected $argc"
done < <(sed -n 's/^argc=//p' "$tmproot/renderer-record" | sort -u)
[ -z "$argv_rejected" ] \
  && pass "the renderer accepts every argument list the contract test passes" \
  || fail "the renderer rejects argument counts the contract test passes:$argv_rejected"

[ "$fails" -eq 0 ] || exit 1
echo "All tests passed."
