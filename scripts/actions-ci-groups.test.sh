#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/actions-ci.yml"
runner="$root/scripts/actions-ci-group.sh"
manifest="$root/scripts/actions-ci-groups.tsv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

if python3 - "$workflow" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    document = yaml.safe_load(stream)
jobs = document["jobs"]
assert set(jobs) == {"shell-test-groups", "shell-tests"}

groups = jobs["shell-test-groups"]
assert groups["timeout-minutes"] == 12
assert groups["strategy"] == {
    "fail-fast": False,
    "max-parallel": 3,
    "matrix": {"group": ["platform", "merge-gate", "changelog-release"]},
}
group_step = next(
    step for step in groups["steps"]
    if step.get("name") == "Run ${{ matrix.group }} shell contracts without hiding sibling failures"
)
assert group_step["run"] == 'bash scripts/actions-ci-group.sh "${{ matrix.group }}"'

required = jobs["shell-tests"]
assert required["needs"] == "shell-test-groups"
assert required["if"] == "${{ always() }}"
assert required["timeout-minutes"] == 2
assert "strategy" not in required
assert required["steps"][0]["env"] == {
    "GROUP_RESULT": "${{ needs.shell-test-groups.result }}"
}
assert required["steps"][0]["run"] == (
    'if [ "$GROUP_RESULT" != "success" ]; then\n'
    '  echo "::error::one or more shell-test groups failed"\n'
    "  exit 1\n"
    "fi\n"
)
assert groups["runs-on"] == required["runs-on"]
PY
then
  pass "three bounded groups fan out while unmatrixed shell-tests preserves the required context"
else
  fail "bounded fan-out or required-context aggregation is missing"
fi

if awk -F '\t' '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  NF != 2 { exit 1 }
  $1 !~ /^(platform|merge-gate|changelog-release)$/ { exit 1 }
  seen[$2]++ { exit 1 }
  { groups[$1]++; total++ }
  END {
    exit !(total >= 80 &&
      groups["platform"] > 0 &&
      groups["merge-gate"] > 0 &&
      groups["changelog-release"] > 0)
  }
' "$manifest"; then
  pass "manifest assigns every command once across three non-empty cohesive groups"
else
  fail "manifest is missing, malformed, duplicated, or incompletely grouped"
fi

for command in \
  "bash scripts/ci-gate/dispatch-permission.test.sh" \
  "bash scripts/ci-gate/changelog-caller-contract.test.sh" \
  "bash scripts/runner-selector-health.test.sh" \
  "python3 scripts/changelog.py validate --repo-root ."; do
  if [ "$(awk -F '\t' -v command="$command" '$2 == command { count++ } END { print count + 0 }' "$manifest")" -eq 1 ]; then
    pass "load-bearing command remains assigned: $command"
  else
    fail "load-bearing command is missing or duplicated: $command"
  fi
done

cat >"$tmp/manifest.tsv" <<EOF
platform	printf 'first\n' >>'$tmp/seen'
platform	false
platform	printf 'last\n' >>'$tmp/seen'
EOF

if ACTIONS_CI_GROUP_MANIFEST="$tmp/manifest.tsv" bash "$runner" platform >"$tmp/out" 2>&1; then
  fail "group runner reported green after a member failed"
elif [ "$(cat "$tmp/seen")" = $'first\nlast' ] \
  && grep -q '1 command(s) failed' "$tmp/out"; then
  pass "group runner reports failure after executing every independent command"
else
  fail "group runner stopped early or hid its aggregate failure"
fi

if ACTIONS_CI_GROUP_MANIFEST="$tmp/manifest.tsv" bash "$runner" forged >"$tmp/invalid-out" 2>&1; then
  fail "group runner accepted an undeclared group"
elif grep -q 'unknown actions-ci group' "$tmp/invalid-out"; then
  pass "group runner rejects undeclared matrix values"
else
  fail "invalid group failed without actionable evidence"
fi

if grep -q $'^platform\tbash scripts/actions-ci-groups.test.sh$' "$manifest"; then
  pass "grouping contract runs in actions CI"
else
  fail "grouping contract is not wired into actions CI"
fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
