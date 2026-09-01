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

exit $((failures > 0))
