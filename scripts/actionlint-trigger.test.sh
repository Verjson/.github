#!/usr/bin/env bash
# Pins actionlint.yml's path filters to both inputs that determine lint results:
# workflow source and the custom runner-label config (Verjson/.github#82).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
wf="$(cd "$here/.." && pwd)/.github/workflows/actionlint.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

event_paths() {
  local event="$1"
  local source="${2:-$wf}"
  awk -v header="  $event:" '
    $0 == header { in_event = 1; next }
    in_event && /^  [[:alnum:]_-]+:/ { exit }
    in_event && $0 == "    paths:" { in_paths = 1; next }
    in_paths && /^    [[:alnum:]_-]+:/ { exit }
    in_paths && /^      - / {
      line = substr($0, 9)
      gsub(/^['\''\"]|['\''\"]$/, "", line)
      print line
    }
  ' "$source"
}

for event in pull_request push; do
  paths="$(event_paths "$event")"
  printf '%s\n' "$paths" | grep -qxF '.github/workflows/**' \
    && pass "$event lints workflow changes" \
    || fail "$event does not include workflow changes"
  printf '%s\n' "$paths" | grep -qxF '.github/actionlint.yaml' \
    && pass "$event lints runner-label config changes (#82)" \
    || fail "$event does not include .github/actionlint.yaml (#82)"
done

# Mutation guard: a matching string under another event-level list must not be
# mistaken for a path filter.
cat >"$tmp/branches-only.yml" <<'YAML'
on:
  push:
    branches:
      - '.github/actionlint.yaml'
    paths:
      - '.github/workflows/**'
YAML
mutated="$(event_paths push "$tmp/branches-only.yml")"
printf '%s\n' "$mutated" | grep -qxF '.github/actionlint.yaml' \
  && fail "branches entry was incorrectly read as a path filter" \
  || pass "only the paths mapping can satisfy the trigger guard"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
