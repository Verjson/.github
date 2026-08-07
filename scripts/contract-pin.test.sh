#!/usr/bin/env bash
# Contract check: the pin the migration guide tells consumers to generate against
# must exist in this repository and must contain the generator (Verjson/.github#308).
#
# Consumers were told to pin 1486d44…, which predates gen-changelog-caller.sh. So
# `raw.githubusercontent.com/.../<pin>/scripts/gen-changelog-caller.sh` 404s, and
# an adopter wanting a hermetic contract test had to carry a second ref pointing
# somewhere else — which is two pins for one contract, and the drift #304 was
# filed about wearing a different hat.
#
# This is the #287 lesson applied to the pin instead of to a tag: a documented
# literal that nothing checks will eventually name something that does not exist.
#
# Test seam: CONTRACT_PIN_ROOT selects the repository to check.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="${CONTRACT_PIN_ROOT:-$(cd "$here/.." && pwd)}"
guide="$root/docs/changelog/migration.md"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$guide" ] || { echo "FAIL - migration guide not found: $guide"; exit 1; }

# Every 40-hex literal the guide presents as a pin to generate against. Read from
# the guide rather than restated here — a copy is the same drift one level up.
mapfile -t pins < <(grep -oE '^   PIN=[0-9a-f]{40}$' "$guide" | cut -d= -f2 | sort -u)

if [ "${#pins[@]}" -eq 0 ]; then
  fail "the guide names no pin to generate against — either the check or the guide is wrong"
else
  pass "the guide names ${#pins[@]} pin(s) to generate against"
fi

# actions-ci checks out with fetch-depth: 1 (#234, ADR 0045), so the pinned
# commit is normally absent from the local object store. Materialise it the way
# node-workflow-pins.test.sh does rather than assuming full history — assuming it
# is what made the first version of this check pass locally and fail in CI.
fetch_pinned_commit() {
  local ref="$1"
  git -C "$root" cat-file -e "$ref^{commit}" 2>/dev/null && return 0
  git -C "$root" fetch --quiet --no-tags --depth 1 origin "$ref" >/dev/null 2>&1 || return 1
  git -C "$root" cat-file -e "$ref^{commit}" 2>/dev/null
}

for pin in "${pins[@]}"; do
  if ! fetch_pinned_commit "$pin"; then
    fail "documented pin $pin is not a commit this repository can obtain"
    continue
  fi
  pass "documented pin ${pin:0:8} resolves to a commit"

  # The whole point of #308: the generator has to be readable AT the pin, because
  # that is where a consumer's contract test fetches it from.
  if git -C "$root" cat-file -e "$pin:scripts/gen-changelog-caller.sh" 2>/dev/null; then
    pass "documented pin ${pin:0:8} contains gen-changelog-caller.sh"
  else
    fail "documented pin ${pin:0:8} predates gen-changelog-caller.sh — a consumer fetching it there gets a 404 (#308)"
  fi

  # A pin that cannot generate is a pin that cannot be adopted. Cheap to prove,
  # and it catches a generator whose interface moved after the pin was written.
  #
  # `release-node` belongs in this list even though only publishing adopters run
  # it: the guide documents it under the same `$PIN`, so a pin that predates the
  # mode makes a documented command fail. That was the state until the pin moved
  # to the commit that closed #463/#464/#465 — the guide said `release-node` and
  # the pin could not run it, and nothing caught the contradiction (#463).
  for mode in workflow renderer contract-test release-node; do
    if git -C "$root" show "$pin:scripts/gen-changelog-caller.sh" 2>/dev/null \
      | grep -qE "^  $mode\)"; then
      pass "the generator at ${pin:0:8} supports '$mode'"
    else
      fail "the generator at ${pin:0:8} has no '$mode' mode, so the documented command fails"
    fi
  done
done

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
