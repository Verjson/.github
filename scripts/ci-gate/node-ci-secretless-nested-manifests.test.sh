#!/usr/bin/env bash
# Verjson/.github#1229 — secretless acquisition must cover nested manifests.
#
# The credentialless execution job never receives a package-read credential, so
# every private dependency it installs has to arrive through the credentialed
# acquisition job's bounded, digest-verified transfer. Before this contract the
# acquisition, packaging, and install paths all hardcoded the root lockfile, so
# a consumer with a nested manifest (an example directory with its own
# package.json/package-lock.json) had no credentialless way to obtain its
# private dependencies at all.
#
# The load-bearing invariant these tests protect is per-manifest authorization:
# a manifest is validated against its OWN approvedPackages only, so no manifest
# can smuggle in a package that was authorized for a different one.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/node-ci.yml"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }

python3 - "$workflow" <<'PY' \
  && pass "the nested-manifest input is declared and wired into every acquisition stage" \
  || fail "the nested-manifest input contract is absent or unwired"
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
inputs = doc[True]["workflow_call"]["inputs"]
jobs = doc["jobs"]

declared = inputs["secretless-nested-manifests"]
assert declared["type"] == "string"
assert declared["default"] == ""
assert declared["required"] is False
description = declared["description"]
for phrase in ("path", "approvedPackages", "scriptPlan", "never inherits"):
    assert phrase in description, phrase

acquire = jobs["acquire-secretless-dependencies"]["steps"]
build = jobs["build-test"]["steps"]
wiring = "${{ inputs.secretless-nested-manifests }}"

validate = next(step for step in acquire
                if step.get("name") == "Validate approved internal dependency lock")
package = next(step for step in acquire
               if step.get("name") == "Package bounded credential-free npm cache")
install = next(step for step in build
               if step.get("name") == "Install from verified secretless npm cache")
plan = next(step for step in build
            if step.get("name") == "Run exact credentialless consumer script plan")

for step in (validate, package, install, plan):
    assert step["env"]["NESTED_MANIFESTS"] == wiring, step["name"]

# A caller may declare nested script plans without a root plan, so the plan step
# can no longer be gated on the root plan alone.
assert "inputs.secretless-nested-manifests != ''" in plan["if"]
assert "inputs.secretless-ci-script-plan != ''" in plan["if"]

# The credentialless job still receives no package-read credential.
for credential in ("GH_TOKEN", "GITHUB_TOKEN", "NODE_AUTH_TOKEN", "NPM_TOKEN"):
    assert install["env"][credential] == ""
assert "secrets." not in str(install.get("env", {}))
assert "secrets." not in str(plan.get("env", {}))
PY

validator="$tmp/validate.sh"
awk '
  /- name: Validate approved internal dependency lock/ { found = 1; next }
  found && /python3 - <<'"'"'PY'"'"'/ { copying = 1; next }
  copying && /^          PY$/ { exit }
  copying { sub(/^          /, ""); print }
' "$workflow" > "$validator"

run_validator() {
  local fixture="$1" approved="$2" nested="$3"
  local scopes="${4:-@verjson}" policy="${5:-}" package_manager="${6:-npm}"
  rm -f "$fixture/private-cache-entries"
  (cd "$fixture" && APPROVED_INTERNAL_PACKAGES="$approved" \
    APPROVED_INTERNAL_SCOPES="$scopes" NESTED_MANIFESTS="$nested" \
    PACKAGE_MANAGER="$package_manager" \
    PRIVATE_CACHE_ENTRIES="$fixture/private-cache-entries" \
    TRUSTED_PACKAGE_POLICY="$policy" python3 "$validator")
}

blob() { printf 'content of %s\n' "$1"; }
integrity_of() { blob "$1" | openssl dgst -sha512 -binary | base64 -w0; }
digest_of() { blob "$1" | sha512sum | cut -d' ' -f1; }

root_integrity="sha512-$(integrity_of root-lib)"
nested_integrity="sha512-$(integrity_of nested-lib)"
root_url='https://npm.pkg.github.com/download/@verjson/root-lib/1.0.0/aaa'
nested_url='https://npm.pkg.github.com/download/@verjson/nested-lib/2.0.0/bbb'

write_lock() {
  # write_lock <path> [<name> <url> <integrity>]...
  local target="$1"; shift
  local dir; dir="$(dirname "$target")"
  mkdir -p "$dir"
  printf '%s\n' '{"name":"fixture","version":"1.0.0","scripts":{"verify":"true"}}' \
    > "$dir/package.json"
  local body='{"lockfileVersion":3,"packages":{"":{}'
  while [ "$#" -gt 0 ]; do
    body="$body,\"node_modules/$1\":{\"name\":\"$1\",\"resolved\":\"$2\",\"integrity\":\"$3\"}"
    shift 3
  done
  printf '%s\n' "$body}}" > "$target"
}

nested_plan='[{"path":"examples/nested","approvedPackages":["@verjson/nested-lib"],"scriptPlan":["verify"]}]'

paired="$tmp/paired"
write_lock "$paired/package-lock.json" '@verjson/root-lib' "$root_url" "$root_integrity"
write_lock "$paired/examples/nested/package-lock.json" \
  '@verjson/nested-lib' "$nested_url" "$nested_integrity"

if run_validator "$paired" '@verjson/root-lib' "$nested_plan" >/dev/null 2>&1 \
    && [ "$(wc -l < "$paired/private-cache-entries")" -eq 2 ] \
    && grep -qF "$root_url	$(digest_of root-lib)" "$paired/private-cache-entries" \
    && grep -qF "$nested_url	$(digest_of nested-lib)" "$paired/private-cache-entries"; then
  pass "a nested manifest's private downloads join the root manifest's verified acquisition set"
else
  fail "a nested manifest's private downloads were not acquired alongside the root manifest's"
fi

# The adversarial control: the root manifest approves @verjson/root-lib, so a
# nested manifest that pulls it must still be rejected — approval is scoped to
# the manifest that declared it, never to the workflow call as a whole.
smuggle="$tmp/smuggle"
write_lock "$smuggle/package-lock.json" '@verjson/root-lib' "$root_url" "$root_integrity"
write_lock "$smuggle/examples/nested/package-lock.json" \
  '@verjson/nested-lib' "$nested_url" "$nested_integrity" \
  '@verjson/root-lib' "$root_url" "$root_integrity"

if run_validator "$smuggle" '@verjson/root-lib' "$nested_plan" >/dev/null 2>&1; then
  fail "a nested manifest inherited another manifest's approved package"
else
  pass "a package approved only for the root manifest is rejected inside a nested manifest"
fi

# The mirror control: the root manifest must not inherit a nested approval.
reverse="$tmp/reverse"
write_lock "$reverse/package-lock.json" \
  '@verjson/root-lib' "$root_url" "$root_integrity" \
  '@verjson/nested-lib' "$nested_url" "$nested_integrity"
write_lock "$reverse/examples/nested/package-lock.json" \
  '@verjson/nested-lib' "$nested_url" "$nested_integrity"

if run_validator "$reverse" '@verjson/root-lib' "$nested_plan" >/dev/null 2>&1; then
  fail "the root manifest inherited a nested manifest's approved package"
else
  pass "a package approved only for a nested manifest is rejected inside the root manifest"
fi

exit $((failures > 0))
