#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/invocations"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

cat >"$tmp/probe" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$PORTABILITY_TEST_LOG"
SH
chmod +x "$tmp/probe"

run_target() {
  : >"$log"
  PORTABILITY_TEST_LOG="$log" make -s -C "$root" "$1" \
    ACTIONLINT="$tmp/probe actionlint" \
    BASH="$tmp/probe bash"
}

run_target lint
if grep -qxF 'actionlint -config-file .github/actionlint.yaml -shellcheck=shellcheck -color' "$log"; then
  pass "lint delegates to the repository actionlint policy"
else
  fail "lint did not preserve the actionlint command"
fi

run_target test
if grep -qxF 'bash scripts/repo-hygiene.test.sh' "$log"; then
  pass "test delegates to the documented behavioral smoke test"
else
  fail "test did not preserve the documented test command"
fi

run_target render
if grep -qxF 'bash scripts/render-next.sh' "$log"; then
  pass "render delegates to the canonical NEXT renderer"
else
  fail "render did not preserve the canonical renderer command"
fi

run_target adr-index
if grep -qxF 'bash scripts/gen-adr-index.sh --check' "$log"; then
  pass "adr-index checks the generated index without rewriting it"
else
  fail "adr-index did not preserve the generated-index check"
fi

actions_ci="$root/.github/workflows/actions-ci.yml"
if grep -qF 'run: make adr-index' "$actions_ci"; then
  pass "actions-ci consumes the portable ADR-index target"
else
  fail "actions-ci bypasses the portable ADR-index target"
fi
if grep -qF 'run: make render >/dev/null' "$actions_ci"; then
  pass "actions-ci consumes the portable render target"
else
  fail "actions-ci bypasses the portable render target"
fi

for control_plane in ai-review-merge.yml ai-privileged-merge.yml; do
  if grep -qE '^[[:space:]]+run: make([[:space:]]|$)' "$root/.github/workflows/$control_plane"; then
    fail "$control_plane was pulled into the portability layer"
  else
    pass "$control_plane remains outside the portability layer"
  fi
done

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi

echo "$fails test(s) failed."
exit 1
