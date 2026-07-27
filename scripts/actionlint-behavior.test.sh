#!/usr/bin/env bash
# Exercises the pinned actionlint binary against isolated fixtures. The called
# job must reject both malformed YAML and valid YAML with an invalid expression.
set -uo pipefail

actionlint="${1:-./actionlint}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$actionlint" ] || {
  echo "FAIL - actionlint binary not found: $actionlint"
  exit 1
}
actionlint="$(cd "$(dirname "$actionlint")" && pwd)/$(basename "$actionlint")"

cat >"$tmp/valid.yml" <<'YAML'
name: valid
on: push
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - run: echo valid
YAML

cat >"$tmp/invalid-syntax.yml" <<'YAML'
name: invalid syntax
on: push
jobs:
  test:
    runs-on: [ubuntu-24.04
YAML

cat >"$tmp/invalid-expression.yml" <<'YAML'
name: invalid expression
on: push
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - if: ${{ github.property_that_does_not_exist }}
        run: echo unreachable
YAML

"$actionlint" "$tmp/valid.yml" >"$tmp/valid.out" 2>&1 \
  && pass "valid workflow passes" \
  || fail "valid workflow was rejected"

if "$actionlint" "$tmp/invalid-syntax.yml" >"$tmp/invalid-syntax.out" 2>&1; then
  fail "malformed workflow syntax passed"
else
  pass "malformed workflow syntax fails"
fi

if "$actionlint" "$tmp/invalid-expression.yml" >"$tmp/invalid-expression.out" 2>&1; then
  fail "invalid workflow expression passed"
else
  pass "invalid workflow expression fails"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
