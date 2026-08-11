#!/usr/bin/env bash
# Running the hygiene unit tests must not touch the checkout they run from
# (Verjson/.github#340, #393).
#
# The suite builds fixtures as real git repositories, so a fixture path that
# escapes the sandbox does not fail loudly — it lands `git add -A` and
# `git commit` on the HOST repository, sweeping in-progress work into a stray
# commit. That happened three times in one session before it was diagnosed.
#
# This test cannot assert that safety by running the suite in the real checkout:
# on the unfixed code that IS the damage. Instead it stands up a disposable host
# repository from the working tree's tracked files, runs the suite from inside
# it, and asserts the host is byte-for-byte where it started.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
suite="$repo_root/scripts/repo-hygiene.test.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$suite" ] || { echo "FAIL - suite not found: $suite"; exit 1; }

# The real checkout is the thing actually being protected, and an escape by
# ABSOLUTE path never touches $host at all — it would leave every assertion
# about the sandbox green while mutating the tree this test runs from. So pin
# the real checkout directly, before anything else runs.
root_head_before="$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null)"
root_status_before="$(git -C "$repo_root" status --porcelain 2>/dev/null)"
[ -n "$root_head_before" ] \
  || { echo "FAIL - could not read the real checkout's HEAD, so it cannot be pinned"; exit 1; }

# A copy of the WORKING TREE's tracked files, not of HEAD: the suite under test
# is the one being edited, and a HEAD-based sandbox would keep reporting green
# on the committed version of a file the author just changed.
#
# `cp --parents -t` is GNU coreutils only. That is the CI runner and the
# development environment; a BSD/macOS cp fails loudly on the flags rather than
# silently staging a wrong tree, and the guard below turns that into an abort.
host="$tmp/host"
mkdir -p "$host"
( cd "$repo_root" && git ls-files -z | xargs -0 cp --parents -t "$host" ) \
  || { echo "FAIL - could not stage a sandbox copy of the tracked tree"; exit 1; }
# Every setup command is checked. Unchecked and output-suppressed, a failed
# `git commit` here leaves HEAD unborn, and the HEAD assertion below then
# compares "" with "" and reports ok for a run that proved nothing.
{ git init -q "$host" \
    && git -C "$host" config user.name test \
    && git -C "$host" config user.email test@example.com \
    && git -C "$host" add -A \
    && git -C "$host" commit -qm 'sandbox host repository' >/dev/null 2>&1; } \
  || { echo "FAIL - could not build the sandbox host repository"; exit 1; }

before_head="$(git -C "$host" rev-parse --verify HEAD 2>/dev/null)"
[ -n "$before_head" ] \
  && pass "the sandbox host repository has a real commit to compare against" \
  || { fail "the sandbox host repository has no HEAD, so the HEAD assertion would be vacuous"; }
before_status="$(git -C "$host" status --porcelain)"
[ -z "$before_status" ] \
  && pass "the sandbox host repository starts clean" \
  || fail "the sandbox host repository was dirty before the suite ran: $before_status"

# `cd` into the host on purpose: the escape reported in #340 produces a
# RELATIVE fixture path, so the damage lands wherever the suite is run from.
( cd "$host" && bash "$host/scripts/repo-hygiene.test.sh" ) >"$tmp/suite.out" 2>&1
suite_rc=$?

after_status="$(git -C "$host" status --porcelain)"
[ -z "$after_status" ] \
  && pass "running the hygiene suite leaves the host checkout clean" \
  || { fail "the hygiene suite mutated the checkout it ran from"; \
       printf '%s\n' "$after_status" | sed 's/^/diag - /'; }

after_head="$(git -C "$host" rev-parse --verify HEAD 2>/dev/null)"
[ -n "$after_head" ] && [ "$after_head" = "$before_head" ] \
  && pass "running the hygiene suite leaves the host HEAD unchanged" \
  || fail "the hygiene suite committed to the host repository ($before_head -> $after_head)"

# The other half of the property, and the half $host cannot see: nothing the
# suite did reached the checkout this test runs from.
root_head_after="$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null)"
[ "$root_head_after" = "$root_head_before" ] \
  && pass "running the hygiene suite leaves the real checkout's HEAD unchanged" \
  || fail "the hygiene suite committed to the real checkout ($root_head_before -> $root_head_after)"

root_status_after="$(git -C "$repo_root" status --porcelain 2>/dev/null)"
[ "$root_status_after" = "$root_status_before" ] \
  && pass "running the hygiene suite leaves the real checkout's working tree as it found it" \
  || { fail "the hygiene suite changed the real checkout's working tree"; \
       diff <(printf '%s\n' "$root_status_before") <(printf '%s\n' "$root_status_after") \
         | sed 's/^/diag - /'; }

# Cleanliness alone would also be satisfied by a suite that died on its first
# line, so pin that the suite really ran and really passed in the sandbox.
[ "$suite_rc" -eq 0 ] \
  && pass "the hygiene suite passes inside the sandbox" \
  || { fail "the hygiene suite failed in the sandbox (rc=$suite_rc)"; \
       sed 's/^/diag - /' "$tmp/suite.out"; }

# Wired, or it does not run. An unregistered local test is dormant in Actions.
grep -q $'\tbash scripts/ci-gate/repo-hygiene-sandbox.test.sh$' \
  "$repo_root/scripts/actions-ci-groups.tsv" \
  && pass "this suite is wired into actions-ci" \
  || fail "repo-hygiene-sandbox.test.sh is not wired into actions-ci.yml — it would never run"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
