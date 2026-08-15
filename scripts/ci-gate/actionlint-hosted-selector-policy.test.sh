#!/usr/bin/env bash
# Exercises the reusable actionlint boundary that exports #815's metered-family
# policy to Verjson callers without exporting repository-local Linux rules.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/actionlint.yml"
fixtures="$root/scripts/fixtures/hosted-selector-policy"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

if python3 - "$workflow" <<'PY'
import re
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    job = yaml.safe_load(stream)["jobs"]["actionlint"]

steps = {step.get("name"): step for step in job["steps"]}
checkout = steps["Check out centrally versioned actionlint policy"]
assert checkout["if"] == "inputs.config-file == '' || github.repository_owner == 'Verjson'"
assert checkout["with"]["repository"] == "${{ job.workflow_repository }}"
assert checkout["with"]["ref"] == "${{ job.workflow_sha }}"
assert set(checkout["with"]["sparse-checkout"].splitlines()) == {
    ".github/actionlint.yaml",
    "scripts/ci-gate/hosted-selector-policy.py",
}
assert checkout["with"]["persist-credentials"] is False

install = steps["Install hosted-selector policy dependency"]
enforce = steps["Refuse metered hosted selectors in Verjson callers"]
assert install["if"] == "github.repository_owner == 'Verjson'"
assert enforce["if"] == "github.repository_owner == 'Verjson'"
assert "--metered-families-only .github/workflows" in enforce["run"]
assert "--visibility" not in enforce["run"]
assert "python3 -S" in enforce["run"]

environment = job["env"]
assert environment["PYYAML_VERSION"] == "6.0.2"
assert re.fullmatch(r"[0-9a-f]{64}", environment["PYYAML_SHA256"])
assert environment["PYYAML_VERSION"] in environment["PYYAML_SOURCE_URL"]
assert "sha256sum --check --strict" in install["run"]
assert '"pyyaml-${PYYAML_VERSION}/lib/yaml"' in install["run"]
PY
then
  pass "the immutable central policy, narrow mode, dependency pin, and Verjson-only gates are wired"
else
  fail "the reusable actionlint hosted-selector contract is incomplete"
fi

extract_step() {
  local name="$1" destination="$2"
  awk -v wanted="      - name: $name" '
    $0 == wanted { seen = 1 }
    seen && $0 == "        run: |" { capture = 1; next }
    capture {
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      exit
    }
  ' "$workflow" >"$destination"
}

install_script="$tmp/install.sh"
enforce_script="$tmp/enforce.sh"
extract_step "Install hosted-selector policy dependency" "$install_script"
extract_step "Refuse metered hosted selectors in Verjson callers" "$enforce_script"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    output="$2"
    break
  fi
  shift
done
printf '%s' "$DOWNLOAD_CONTENT" >"$output"
SH
cat >"$tmp/bin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    destination="$2"
    break
  fi
  shift
done
printf 'tar\n' >>"$POLICY_ACTIONS"
mkdir -p "$destination/yaml"
printf '# fixture yaml package\n' >"$destination/yaml/__init__.py"
SH
chmod +x "$tmp/bin/curl" "$tmp/bin/tar"

run_install() {
  local checksum="$1" case_dir
  case_dir="$(mktemp -d "$tmp/install.XXXXXX")"
  export PATH="$tmp/bin:$PATH"
  export PYYAML_VERSION=6.0.2
  export PYYAML_SOURCE_URL=https://example.invalid/pyyaml-6.0.2.tar.gz
  export PYYAML_SHA256="$checksum"
  export DOWNLOAD_CONTENT='fixture archive bytes'
  export POLICY_ACTIONS="$case_dir/actions.log"
  : >"$POLICY_ACTIONS"
  (cd "$case_dir" && bash "$install_script") >"$case_dir/out.txt" 2>&1
  INSTALL_RC=$?
  INSTALL_CASE_DIR="$case_dir"
}

good="$(printf '%s' 'fixture archive bytes' | sha256sum | awk '{print $1}')"
run_install "$good"
if [ "$INSTALL_RC" -eq 0 ] \
  && grep -qxF tar "$POLICY_ACTIONS" \
  && [ -f "$INSTALL_CASE_DIR/.verjson-hosted-selector-policy-deps/yaml/__init__.py" ]; then
  pass "a matching dependency checksum permits only the pinned YAML package extraction"
else
  fail "the pinned YAML dependency did not install from a matching archive"
fi

bad="0${good:1}"
[ "${good:0:1}" = 0 ] && bad="1${good:1}"
run_install "$bad"
if [ "$INSTALL_RC" -ne 0 ] && ! grep -qF tar "$POLICY_ACTIONS"; then
  pass "a dependency checksum mismatch fails before archive extraction"
else
  fail "a mismatched YAML dependency reached archive extraction"
fi

source_dir="$tmp/source"
mkdir -p "$source_dir/.verjson-actionlint-policy/scripts/ci-gate" \
  "$source_dir/.github/workflows"
cp "$root/scripts/ci-gate/hosted-selector-policy.py" \
  "$source_dir/.verjson-actionlint-policy/scripts/ci-gate/hosted-selector-policy.py"

(cd "$source_dir" && bash "$enforce_script") >"$tmp/missing-dependency.out" 2>&1
missing_dependency_rc=$?
if [ "$missing_dependency_rc" -ne 0 ]; then
  pass "the enforcement step cannot fall back to an ambient PyYAML installation"
else
  fail "the enforcement step passed without its pinned YAML dependency"
fi

system_yaml="$(python3 -c 'import os, yaml; print(os.path.dirname(yaml.__file__))')"
mkdir -p "$source_dir/.verjson-hosted-selector-policy-deps"
cp -R "$system_yaml" "$source_dir/.verjson-hosted-selector-policy-deps/yaml"

run_policy_fixture() {
  local fixture="$1"
  find "$source_dir/.github/workflows" -type f -delete
  cp "$fixtures/$fixture"/* "$source_dir/.github/workflows/"
  (cd "$source_dir" && bash "$enforce_script") >"$tmp/policy.out" 2>&1
  POLICY_RC=$?
}

run_policy_fixture metered-macos
if [ "$POLICY_RC" -eq 1 ]; then
  pass "the reusable step rejects a caller's literal macOS selector"
else
  fail "the reusable step did not reject a literal macOS selector"
fi

run_policy_fixture metered-windows
if [ "$POLICY_RC" -eq 1 ]; then
  pass "the reusable step rejects a caller's literal Windows selector"
else
  fail "the reusable step did not reject a literal Windows selector"
fi

run_policy_fixture rolling-linux-latest
if [ "$POLICY_RC" -eq 0 ]; then
  pass "the reusable step leaves the deferred consumer ubuntu-latest rule inactive"
else
  fail "the reusable step broadened #815 into consumer Linux policy"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
