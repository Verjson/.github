#!/usr/bin/env bash
# Verjson/.github#173/#174: keep this published workflow package portable
# without allowing Verjson-owned jobs to drift back to GitHub-hosted runners.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflows="$root/.github/workflows"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# A literal job selector in this Verjson-owned repository must never target a
# GitHub-hosted label. Portable fallbacks belong only in organization-aware
# expressions in reusable definitions.
literal_hosted="$(
  grep -HnE '^    runs-on:[[:space:]]+(\[)?ubuntu-(24\.04|latest)([][:space:],]|$)' \
    "$workflows"/*.yml || true
)"
[ -z "$literal_hosted" ] \
  && pass "Verjson-local jobs contain no literal GitHub-hosted runs-on selector" \
  || fail "literal GitHub-hosted selectors found: $literal_hosted"

# Any job-level hosted fallback must prove it is for a non-Verjson caller.
unsafe_portable="$(
  grep -HnE "^    runs-on:.*ubuntu-(24\\.04|latest)" "$workflows"/*.yml \
    | grep -v "github.repository_owner != 'Verjson'" \
    | grep -v "github.repository_owner == 'Verjson'.*|| 'ubuntu-24.04'" \
    || true
)"
[ -z "$unsafe_portable" ] \
  && pass "hosted fallbacks are bounded to callers outside Verjson" \
  || fail "unbounded hosted fallback found: $unsafe_portable"

portable=(
  node-ci.yml
  node-release.yml
  notify-umbrella.yml
  helm-ci.yml
  ui-ci.yml
  pulumi-ci.yml
)
for name in "${portable[@]}"; do
  wf="$workflows/$name"
  if grep -qF "github.repository_owner == 'Verjson'" "$wf" \
      && grep -qF '["self-hosted","isolated","linux","x64"]' "$wf" \
      && grep -qF "'ubuntu-24.04'" "$wf" \
      && grep -qF "default: ''" "$wf"; then
    pass "$name has isolated Verjson, hosted external, and explicit override routing"
  else
    fail "$name lost its portable runner contract"
  fi
done

grep -qF "github.repository_owner != 'Verjson'" "$workflows/actionlint.yml" \
  && grep -qF '["self-hosted","isolated","linux","x64"]' "$workflows/actionlint.yml" \
  && pass "actionlint preserves its bounded external hosted compatibility path" \
  || fail "actionlint runner contract drifted"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
