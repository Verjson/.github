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

if python3 - "$workflow" "$manifest" <<'PY'
import copy
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    document = yaml.safe_load(stream)
manifest_text = open(sys.argv[2], encoding="utf-8").read()
jobs = document["jobs"]
assert set(jobs) == {
    "shell-test-groups",
    "hosted-compatibility-tests",
    "adr-number-collision",
    "shell-tests",
}

groups = jobs["shell-test-groups"]
assert groups["timeout-minutes"] == 18
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
setup_python = next(
    step
    for step in groups["steps"]
    if step.get("name") == "Provision actions CI Python"
)
assert setup_python == {
    "name": "Provision actions CI Python",
    "uses": "actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97",
    "with": {"python-version": "3.12.14"},
}
install_python_dependencies = next(
    step
    for step in groups["steps"]
    if step.get("name") == "Install actions CI Python dependencies"
)
assert install_python_dependencies == {
    "name": "Install actions CI Python dependencies",
    "working-directory": (
        ".actions-ci-source-${{ github.run_id }}-"
        "${{ github.run_attempt }}-${{ matrix.group }}"
    ),
    "run": (
        "python3 -m pip install \\\n"
        "  --disable-pip-version-check \\\n"
        "  --no-input \\\n"
        "  --quiet \\\n"
        "  --no-deps \\\n"
        "  --only-binary=:all: \\\n"
        "  --require-hashes \\\n"
        "  --requirement scripts/actions-ci-python.requirements.txt\n"
    ),
}
assert groups["steps"].index(install_python_dependencies) == (
    groups["steps"].index(setup_python) + 1
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

compatibility_commands = (
    "bash scripts/ci-gate/node-ci-secretless-compatibility.test.sh",
    "scripts/ci-gate/node-ci-secretless-compatibility-absent.test.py",
)

def validate_hosted_compatibility(candidate, candidate_manifest):
    candidate_jobs = candidate["jobs"]
    if "hosted-compatibility-tests" not in candidate_jobs:
        raise AssertionError("missing hosted-compatibility-tests job")
    hosted = candidate_jobs["hosted-compatibility-tests"]
    assert hosted["runs-on"] == "ubuntu-24.04"
    assert hosted["timeout-minutes"] == 8
    assert hosted["steps"][0]["uses"] == (
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    )
    assert hosted["steps"][1] == {
        "name": "Provision actions CI Python",
        "uses": "actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97",
        "with": {"python-version": "3.12.14"},
    }
    execution = next(
        step for step in hosted["steps"]
        if step.get("name") == "Run namespace-bound compatibility contracts"
    )
    assert execution["env"] == {"RUNNER_LABELS": ""}
    assert execution["run"] == "\n".join((*compatibility_commands, ""))
    for command in compatibility_commands:
        assert execution["run"].splitlines().count(command) == 1
        assert not any(
            line.endswith("\t" + command)
            for line in candidate_manifest.splitlines()
        )
    aggregate = candidate_jobs["shell-tests"]
    assert "hosted-compatibility-tests" in aggregate["needs"]
    assert aggregate["steps"][0]["env"]["COMPATIBILITY_RESULT"] == (
        "${{ needs.hosted-compatibility-tests.result }}"
    )
    assert 'if [ "$COMPATIBILITY_RESULT" != "success" ]; then' in (
        aggregate["steps"][0]["run"]
    )

validate_hosted_compatibility(document, manifest_text)

missing_job_mutant = copy.deepcopy(document)
del missing_job_mutant["jobs"]["hosted-compatibility-tests"]
try:
    validate_hosted_compatibility(missing_job_mutant, manifest_text)
except AssertionError as error:
    assert str(error) == "missing hosted-compatibility-tests job"
    print("ok - entire hosted compatibility job removal fails for missing job")
else:
    raise AssertionError("missing hosted compatibility job passed")

for command in compatibility_commands:
    mutant = copy.deepcopy(document)
    execution = next(
        step for step in mutant["jobs"]["hosted-compatibility-tests"]["steps"]
        if step.get("name") == "Run namespace-bound compatibility contracts"
    )
    execution["run"] = execution["run"].replace(command + "\n", "", 1)
    try:
        validate_hosted_compatibility(mutant, manifest_text)
    except (AssertionError, KeyError, StopIteration):
        print(f"ok - hosted compatibility removal fails closed: {command}")
    else:
        raise AssertionError(f"hosted compatibility removal passed: {command}")

    try:
        validate_hosted_compatibility(
            document,
            manifest_text + f"platform\t{command}\n",
        )
    except (AssertionError, KeyError, StopIteration):
        print(f"ok - persistent platform reassignment fails closed: {command}")
    else:
        raise AssertionError(f"persistent platform reassignment passed: {command}")

runner_mutant = copy.deepcopy(document)
runner_mutant["jobs"]["hosted-compatibility-tests"]["runs-on"] = (
    document["jobs"]["shell-test-groups"]["runs-on"]
)
try:
    validate_hosted_compatibility(runner_mutant, manifest_text)
except (AssertionError, KeyError, StopIteration):
    print("ok - hosted compatibility runner drift fails closed")
else:
    raise AssertionError("hosted compatibility runner drift passed")

aggregate_mutant = copy.deepcopy(document)
aggregate_mutant["jobs"]["shell-tests"]["needs"].remove(
    "hosted-compatibility-tests"
)
try:
    validate_hosted_compatibility(aggregate_mutant, manifest_text)
except (AssertionError, KeyError, StopIteration):
    print("ok - hosted compatibility aggregate removal fails closed")
else:
    raise AssertionError("hosted compatibility aggregate removal passed")

required = jobs["shell-tests"]
assert required["needs"] == [
    "shell-test-groups",
    "hosted-compatibility-tests",
    "adr-number-collision",
]
assert required["if"] == "${{ always() }}"
assert required["timeout-minutes"] == 2
assert "strategy" not in required
assert required["steps"][0]["env"] == {
    "GROUP_RESULT": "${{ needs.shell-test-groups.result }}",
    "COMPATIBILITY_RESULT": "${{ needs.hosted-compatibility-tests.result }}",
    "COLLISION_RESULT": "${{ needs.adr-number-collision.result }}",
}
assert required["steps"][0]["run"] == (
    'if [ "$GROUP_RESULT" != "success" ]; then\n'
    '  echo "::error::one or more shell-test groups failed"\n'
    "  exit 1\n"
    "fi\n"
    'if [ "$COMPATIBILITY_RESULT" != "success" ]; then\n'
    '  echo "::error::hosted compatibility contracts failed"\n'
    "  exit 1\n"
    "fi\n"
    '# adr-number-collision only runs on pull_request (needs live PR\n'
    "# state), so 'skipped' -- e.g. on a push to main -- is not a failure.\n"
    'if [ "$COLLISION_RESULT" != "success" ] && [ "$COLLISION_RESULT" != "skipped" ]; then\n'
    '  echo "::error::ADR number collision check failed"\n'
    "  exit 1\n"
    "fi\n"
)

adr_collision = jobs["adr-number-collision"]
assert adr_collision["if"] == "github.event_name == 'pull_request'"
assert groups["runs-on"] == required["runs-on"]
PY
then
  pass "bounded groups, hosted compatibility, and required shell-tests aggregation stay bound"
else
  fail "bounded fan-out, hosted compatibility, or required aggregation is missing"
fi

cat >"$tmp/python-without-pip" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = -m ] && [ "${2-}" = pip ]; then
  exit 1
fi
exec python3 "$@"
SH
chmod +x "$tmp/python-without-pip"

if CHANGELOG_SCHEMA_TEST_PYTHON="$tmp/python-without-pip" \
  bash "$root/scripts/changelog-fragment-schema.test.sh" \
  >"$tmp/schema-without-pip.out" 2>&1; then
  fail "schema validator runner accepted an interpreter without pip"
elif grep -qF 'pip is required; actions-ci must provision it with setup-python' \
  "$tmp/schema-without-pip.out"; then
  pass "schema validator runner fails clearly when setup-python acquisition is absent"
else
  fail "schema validator runner failed without actionable missing-pip evidence"
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

validate_manifest() {
  local candidate="$1"

  awk -F '\t' '
    BEGIN { valid = 1 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 2 { valid = 0; next }
    $1 !~ /^(platform|merge-gate|changelog-release)$/ { valid = 0; next }
    seen[$2]++ { valid = 0 }
    { groups[$1]++; total++ }
    END {
      if (!(total >= 60 &&
        groups["platform"] > 0 &&
        groups["merge-gate"] > 0 &&
        groups["changelog-release"] > 0)) {
        valid = 0
      }
      exit valid ? 0 : 1
    }
  ' "$candidate" || return 1

  while IFS=$'\t' read -r expected_group command; do
    [ "$(awk -F '\t' -v expected_group="$expected_group" -v command="$command" '
      $1 == expected_group && $2 == command { count++ }
      END { print count + 0 }
    ' "$candidate")" -eq 1 ] || return 1
  done <<'LOAD_BEARING_COMMANDS'
merge-gate	python3 scripts/ci-gate/event-driven-authorization.test.py
merge-gate	bash scripts/ci-gate/arm-receipt.test.sh
merge-gate	bash scripts/ci-gate/gate-hold-disable.test.sh
merge-gate	bash scripts/ci-gate/native-automerge.test.sh
merge-gate	bash scripts/ci-gate/privileged-merge-pin.test.sh
changelog-release	bash scripts/ci-gate/changelog-caller-contract.test.sh
platform	bash scripts/runner-selector-health.test.sh
changelog-release	python3 scripts/changelog.py validate --repo-root .
changelog-release	bash scripts/changelog-fragment-schema.test.sh
changelog-release	python3 scripts/v1-readiness-contract.test.py
platform	bash scripts/actions-ci-python-dependencies.test.sh
LOAD_BEARING_COMMANDS
}

if validate_manifest "$manifest"; then
  pass "manifest assigns every command once across three non-empty cohesive groups"
else
  fail "manifest is missing, malformed, duplicated, or incompletely grouped"
fi

for command_id in schema readiness; do
  if [ "$command_id" = schema ]; then
    command='bash scripts/changelog-fragment-schema.test.sh'
  else
    command='python3 scripts/v1-readiness-contract.test.py'
  fi

  for mutation in deletion duplication reassignment; do
    mutant="$tmp/manifest-$command_id-$mutation.tsv"
    case "$mutation" in
      deletion)
        awk -F '\t' -v command="$command" '$2 != command' "$manifest" >"$mutant"
        ;;
      duplication)
        cp "$manifest" "$mutant"
        printf 'changelog-release\t%s\n' "$command" >>"$mutant"
        ;;
      reassignment)
        awk -F '\t' -v command="$command" '
          BEGIN { OFS = "\t" }
          { $1 = ($2 == command ? "platform" : $1); print }
        ' "$manifest" >"$mutant"
        ;;
    esac

    if validate_manifest "$mutant"; then
      fail "$command_id manifest $mutation mutation passed"
    else
      pass "$command_id manifest $mutation mutation fails closed"
    fi
  done
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
