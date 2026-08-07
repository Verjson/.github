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
readme="$root/docs/changelog/README.md"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

{ [ -f "$guide" ] && [ -f "$readme" ]; } ||
  { echo "FAIL - changelog README or migration guide not found"; exit 1; }

# The README's capability table is the public metadata contract for the
# recommended pin. Read it rather than maintaining a second key list here.
mapfile -t advertised_keys < <(awk '
  /^<!-- contract-pin-metadata:start -->$/ { capture = 1; next }
  /^<!-- contract-pin-metadata:end -->$/   { capture = 0 }
  capture && /^\| `[a-z]+` / {
    key = $2
    gsub(/`/, "", key)
    print key
  }
' "$readme")

if [ "${#advertised_keys[@]}" -eq 0 ]; then
  fail "the README advertises no machine-checkable metadata capabilities"
else
  pass "the README advertises ${#advertised_keys[@]} metadata capabilities"
fi

# Every 40-hex literal the guide presents as a pin to generate against. Read from
# the guide rather than restated here — a copy is the same drift one level up.
mapfile -t pins < <(grep -oE '^   PIN=[0-9a-f]{40}$' "$guide" | cut -d= -f2 | sort -u)
mapfile -t readme_pins < <(
  sed -nE 's/^<!-- recommended-contract-pin: ([0-9a-f]{40}) -->$/\1/p' "$readme" |
    sort -u
)

if [ "${#pins[@]}" -eq 0 ]; then
  fail "the guide names no pin to generate against — either the check or the guide is wrong"
else
  pass "the guide names ${#pins[@]} pin(s) to generate against"
fi

if [ "${#readme_pins[@]}" -ne 1 ]; then
  fail "the README must name exactly one machine-checkable recommended pin"
elif [ "${#pins[@]}" -ne 1 ] || [ "${readme_pins[0]}" != "${pins[0]}" ]; then
  fail "the README capability pin and migration guide PIN disagree"
else
  pass "the README capability table and migration guide share one immutable pin"
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
  for mode in \
    workflow generated-artifacts renderer contract-test release-node \
    adr-index-generator generated-artifacts-with-adr-index; do
    if git -C "$root" show "$pin:scripts/gen-changelog-caller.sh" 2>/dev/null \
      | grep -qE "^  $mode\)"; then
      pass "the generator at ${pin:0:8} supports '$mode'"
    else
      fail "the generator at ${pin:0:8} has no '$mode' mode, so the documented command fails"
    fi
  done

  # Execute the engine AT the recommended pin against fragments that exercise
  # every advertised key. Source inspection alone is insufficient: a parser can
  # name a key and still reject its valid value at the validation boundary.
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/NEXT"
  git -C "$root" show "$pin:scripts/changelog.py" >"$fixture/changelog.py"
  cat >"$fixture/NEXT/2026-08-07-issue-388-issue-form.md" <<'EOF'
---
date: 2026-08-07
issue: 388
title: Exercise issue metadata
summary: Exercise the issue-form capability.
---

Issue-form fixture.
EOF
  cat >"$fixture/NEXT/2026-08-07-issue-20260807T120000Z-id-form.md" <<'EOF'
---
date: 2026-08-07
id: 20260807T120000Z
refs: 388
component: python
title: Exercise reference metadata
summary: Exercise the id-form capability.
---

ID-form fixture.
EOF

  if python3 "$fixture/changelog.py" validate --repo-root "$fixture" \
      >"$fixture/out" 2>"$fixture/err" && [ ! -s "$fixture/err" ]; then
    pass "the engine at ${pin:0:8} accepts fixtures carrying every advertised metadata key"
  else
    fail "the engine at ${pin:0:8} rejects or ignores advertised metadata: $(tr '\n' ' ' <"$fixture/err")"
  fi

  for key in "${advertised_keys[@]}"; do
    if grep -qE "^${key}:" "$fixture"/NEXT/*.md; then
      pass "advertised metadata '$key' is exercised against the pin"
    else
      fail "advertised metadata '$key' has no pin-capability fixture"
    fi
  done
  find "$fixture" -depth -delete
done

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
