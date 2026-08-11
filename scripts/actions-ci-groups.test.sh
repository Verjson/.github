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
checkout = next(step for step in groups["steps"] if "uses" in step)
assert checkout["with"]["path"] == (
    ".actions-ci-source-${{ github.run_id }}-"
    "${{ github.run_attempt }}-${{ matrix.group }}"
)
group_step = next(
    step for step in groups["steps"]
    if step.get("name") == "Run ${{ matrix.group }} shell contracts without hiding sibling failures"
)
assert group_step["env"] == {"RUNNER_LABELS": ""}
assert group_step["run"] == (
    'source_root="$GITHUB_WORKSPACE/.actions-ci-source-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.group }}"\n'
    'group_root="$(mktemp -d "$RUNNER_TEMP/actions-ci-${{ matrix.group }}.XXXXXX")"\n'
    'trap \'rm -rf "$source_root" "$group_root"\' EXIT\n'
    'cp -a "$source_root/." "$group_root/"\n'
    'rm -rf "$source_root"\n'
    'cd "$group_root"\n'
    'bash scripts/actions-ci-group.sh "${{ matrix.group }}"\n'
)

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

mkdir -p "$tmp/workspace/.actions-ci-source-42-1-platform/scripts" \
  "$tmp/workspace/.actions-ci-source-42-1-merge-gate/scripts" \
  "$tmp/runner/actions-ci-platform.stale"
printf 'stale\n' > "$tmp/runner/actions-ci-platform.stale/stale-fixture"
for group in platform merge-gate; do
  printf 'original\n' > "$tmp/workspace/.actions-ci-source-42-1-$group/shared-fixture"
done
cat > "$tmp/group-runner" <<'SH'
#!/usr/bin/env bash
[ ! -e stale-fixture ]
printf 'mutated\n' > shared-fixture
pwd > "$ISOLATION_PROBE"
[ -x scripts/actions-ci-group.sh ]
SH
chmod +x "$tmp/group-runner"
cp "$tmp/group-runner" "$tmp/workspace/.actions-ci-source-42-1-platform/scripts/actions-ci-group.sh"
cp "$tmp/group-runner" "$tmp/workspace/.actions-ci-source-42-1-merge-gate/scripts/actions-ci-group.sh"
mkdir -p "$tmp/shared-source/scripts" "$tmp/legacy-copy"
cp "$tmp/group-runner" "$tmp/shared-source/scripts/actions-ci-group.sh"
rm -rf "$tmp/shared-source/scripts"
cp -a "$tmp/shared-source/." "$tmp/legacy-copy/"
if [ ! -e "$tmp/legacy-copy/scripts/actions-ci-group.sh" ]; then
  pass "shared-source cleanup reproduces the missing actions-ci group runner from issue 675"
else
  fail "the issue 675 shared-source failure fixture did not reproduce"
fi
python3 - "$workflow" "$tmp/run-platform.sh" platform <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    document = yaml.safe_load(stream)
step = next(
    step for step in document["jobs"]["shell-test-groups"]["steps"]
    if step.get("name") == "Run ${{ matrix.group }} shell contracts without hiding sibling failures"
)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    stream.write(
        step["run"]
        .replace("${{ github.run_id }}", "42")
        .replace("${{ github.run_attempt }}", "1")
        .replace("${{ matrix.group }}", sys.argv[3])
    )
PY
sed 's/platform/merge-gate/g' \
  "$tmp/run-platform.sh" > "$tmp/run-merge-gate.sh"
if GITHUB_WORKSPACE="$tmp/workspace" RUNNER_TEMP="$tmp/runner" \
  ISOLATION_PROBE="$tmp/probe-one" bash "$tmp/run-platform.sh" &
then platform_pid=$!; else platform_pid=''; fi
if GITHUB_WORKSPACE="$tmp/workspace" RUNNER_TEMP="$tmp/runner" \
  ISOLATION_PROBE="$tmp/probe-two" bash "$tmp/run-merge-gate.sh" &
then merge_gate_pid=$!; else merge_gate_pid=''; fi
if [ -n "$platform_pid" ] && [ -n "$merge_gate_pid" ] \
  && wait "$platform_pid" && wait "$merge_gate_pid" \
  && [ "$(cat "$tmp/probe-one")" != "$(cat "$tmp/probe-two")" ] \
  && [ ! -e "$(cat "$tmp/probe-one")" ] \
  && [ ! -e "$(cat "$tmp/probe-two")" ] \
  && [ ! -e "$tmp/workspace/.actions-ci-source-42-1-platform" ] \
  && [ ! -e "$tmp/workspace/.actions-ci-source-42-1-merge-gate" ] \
  && [ "$(cat "$tmp/runner/actions-ci-platform.stale/stale-fixture")" = stale ]; then
  pass "concurrent matrix groups snapshot unique sources before cleanup and cannot mutate siblings"
else
  fail "matrix groups can lose their runner during setup, collide, retain stale files, or mutate siblings"
fi

if awk -F '\t' '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  NF != 2 { exit 1 }
  $1 !~ /^(platform|merge-gate|changelog-release)$/ { exit 1 }
  seen[$2]++ { exit 1 }
  { groups[$1]++; total++ }
  END {
    exit !(total >= 60 &&
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
  "python3 scripts/ci-gate/event-driven-authorization.test.py" \
  "bash scripts/ci-gate/arm-receipt.test.sh" \
  "bash scripts/ci-gate/gate-hold-disable.test.sh" \
  "bash scripts/ci-gate/native-automerge.test.sh" \
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
