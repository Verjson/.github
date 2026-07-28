#!/usr/bin/env bash
# Pins the reusable actionlint contract: local triggers stay intact, callers
# select only a governed runner, nested Actions use immutable refs, and the real
# actionlint behavior suite runs before repository linting.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
wf="$root/.github/workflows/actionlint.yml"
contract="$root/.github/workflows/actionlint-reusable-contract.yml"
readme="$root/README.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }
[ -f "$contract" ] || { echo "FAIL - reusable-call contract not found: $contract"; exit 1; }

workflow_call="$(
  awk '
    $0 == "  workflow_call:" { capture = 1 }
    capture && $0 == "permissions:" { exit }
    capture { print }
  ' "$wf"
)"

grep -qE '^  workflow_call:$' <<<"$workflow_call" \
  && pass "workflow_call trigger is present" \
  || fail "workflow_call trigger is missing"

grep -qE '^      github-hosted-runner:$' <<<"$workflow_call" \
  && grep -qE '^        type: boolean$' <<<"$workflow_call" \
  && grep -qE '^        default: false$' <<<"$workflow_call" \
  && pass "runner choice is a default-off boolean" \
  || fail "runner choice is not the governed boolean contract"

expected_runs_on='    runs-on: ${{ (github.repository == '\''Verjson/.github'\'' || inputs.github-hosted-runner) && '\''ubuntu-24.04'\'' || fromJSON('\''["self-hosted","GCP"]'\'') }}'
grep -qxF "$expected_runs_on" "$wf" \
  && pass "runner input maps only to fixed GitHub-hosted or GCP runners" \
  || fail "runs-on does not preserve the bounded runner mapping"

uses_lines="$(grep -E '^[[:space:]]+- uses:' "$wf" || true)"
[ -n "$uses_lines" ] \
  && ! grep -vE '@[0-9a-f]{40}([[:space:]]+#.*)?$' <<<"$uses_lines" >/dev/null \
  && pass "nested Actions are pinned to full commit SHAs" \
  || fail "a nested Action is missing a full-SHA pin"

grep -qF 'ACTIONLINT_VERSION: 1.7.7' "$wf" \
  && grep -qF "ACTIONLINT_SHA256: '023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757'" "$wf" \
  && pass "actionlint version and archive checksum remain pinned" \
  || fail "actionlint version or checksum drifted"

behavior_script="$tmp/behavior.sh"
awk '
  $0 == "      - name: Prove invalid workflows fail actionlint" { seen = 1 }
  seen && $0 == "        run: |" { capture = 1; next }
  capture {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    exit
  }
' "$wf" >"$behavior_script"

grep -qF 'invalid-syntax.yml' "$behavior_script" \
  && grep -qF 'invalid-expression.yml' "$behavior_script" \
  && ! grep -qE '(^|[;&|])[[:space:]]*(bash|sh|source|\.)[[:space:]]+' "$behavior_script" \
  && pass "invalid-workflow fixtures are provider-owned inline code" \
  || fail "behavior fixtures are missing or execute caller-controlled scripts"

cat >"$tmp/actionlint" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$1")" >>"$ACTIONLOG"
case "$(basename "$1")" in
  valid.yml) exit 0 ;;
  invalid-syntax.yml) exit "${PASS_INVALID_SYNTAX:-1}" ;;
  invalid-expression.yml) exit "${PASS_INVALID_EXPRESSION:-1}" ;;
  *) exit 99 ;;
esac
SH
chmod +x "$tmp/actionlint"

run_behavior() {
  export ACTIONLOG="$tmp/action.log"
  : >"$ACTIONLOG"
  (cd "$tmp" && bash "$behavior_script") >"$tmp/behavior.out" 2>&1
}

unset PASS_INVALID_SYNTAX PASS_INVALID_EXPRESSION
run_behavior
rc=$?
[ "$rc" -eq 0 ] || sed 's/^/diag - /' "$tmp/behavior.out"
[ "$rc" -eq 0 ] \
  && grep -qxF 'valid.yml' "$ACTIONLOG" \
  && grep -qxF 'invalid-syntax.yml' "$ACTIONLOG" \
  && grep -qxF 'invalid-expression.yml' "$ACTIONLOG" \
  && pass "inline behavior step exercises all three fixtures" \
  || fail "inline behavior step did not enforce the fixture contract"

PASS_INVALID_SYNTAX=0
export PASS_INVALID_SYNTAX
run_behavior
rc=$?
[ "$rc" -ne 0 ] \
  && pass "accepted malformed syntax fails the behavior step" \
  || fail "behavior step passed when malformed syntax was accepted"
unset PASS_INVALID_SYNTAX

PASS_INVALID_EXPRESSION=0
export PASS_INVALID_EXPRESSION
run_behavior
rc=$?
[ "$rc" -ne 0 ] \
  && pass "accepted invalid expression fails the behavior step" \
  || fail "behavior step passed when an invalid expression was accepted"
unset PASS_INVALID_EXPRESSION

if [ -n "${ACTIONLINT_BIN:-}" ]; then
  cp "$ACTIONLINT_BIN" "$tmp/actionlint"
  chmod +x "$tmp/actionlint"
  run_behavior
  rc=$?
  [ "$rc" -eq 0 ] || sed 's/^/diag - /' "$tmp/behavior.out"
  [ "$rc" -eq 0 ] \
    && pass "real actionlint rejects both inline invalid fixtures" \
    || fail "real actionlint did not enforce the inline fixture contract"
fi

grep -qF 'REQUIRE_SHELLCHECK: ${{ inputs.github-hosted-runner }}' "$wf" \
  && grep -qF 'command -v shellcheck' "$wf" \
  && grep -qF './actionlint -shellcheck=shellcheck -color' "$wf" \
  && pass "GitHub-hosted calls require ShellCheck integration" \
  || fail "hosted actionlint can silently skip ShellCheck"

contract_ref="$(
  sed -nE 's|^[[:space:]]+uses: Verjson/\.github/\.github/workflows/actionlint\.yml@([0-9a-f]{40})$|\1|p' "$contract"
)"
[ -n "$contract_ref" ] \
  && pass "real reusable caller pins the provider by full commit SHA" \
  || fail "reusable caller is missing its immutable provider pin"

grep -qF "      - '.github/workflows/actionlint-reusable-contract.yml'" "$contract" \
  && grep -qF 'github-hosted-runner: true' "$contract" \
  && grep -qF '  contents: read' "$contract" \
  && pass "real caller owns its narrow trigger, runner, and token permission" \
  || fail "real caller contract drifted"

[ -n "$contract_ref" ] && grep -qF "actionlint.yml@$contract_ref" "$readme" \
  && pass "consumer documentation uses the proven immutable contract ref" \
  || fail "consumer documentation does not use the contract fixture SHA"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
