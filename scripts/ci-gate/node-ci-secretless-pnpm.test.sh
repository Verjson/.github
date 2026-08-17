#!/usr/bin/env bash
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/node-ci.yml"
failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
validator="$(mktemp)"
trap 'rm -f "$validator"; rm -rf "$fixture"' EXIT
awk '/- name: Validate approved internal dependency lock/ { found = 1; next }
  found && /python3 - <<'"'"'PY'"'"'/ { copying = 1; next }
  copying && /^          PY$/ { exit }
  copying { sub(/^          /, ""); print }' "$workflow" > "$validator"
fixture="$(mktemp -d)"
integrity="sha512-$(printf 'private pnpm package\n' | openssl dgst -sha512 -binary | base64 -w0)"
pin="$(printf '0%.0s' {1..128})"
write_fixture() {
  local dir="$1" package="$2" tarball="$3" locked_integrity="$4"
  mkdir -p "$dir"
  printf '{"name":"fixture","packageManager":"pnpm@11.20.0+sha512.%s"}\n' "$pin" > "$dir/package.json"
  printf "lockfileVersion: '9.0'\npackages:\n  '%s@1.2.3':\n    resolution:\n      integrity: %s\n      tarball: %s\n" \
    "$package" "$locked_integrity" "$tarball" > "$dir/pnpm-lock.yaml"
}
run_validator() {
  local dir="$1" approved="$2" entries="$1/private-entries"
  rm -f "$entries"
  (cd "$dir" && PACKAGE_MANAGER=pnpm APPROVED_INTERNAL_PACKAGES="$approved" \
    APPROVED_INTERNAL_SCOPES='@verjson' PRIVATE_CACHE_ENTRIES="$entries" \
    TRUSTED_PACKAGE_POLICY='' python3 "$validator")
}
valid="$fixture/valid"
write_fixture "$valid" '@verjson/contracts' 'https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/abc' "$integrity"
if run_validator "$valid" '@verjson/contracts' && grep -qF 'https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/abc' "$valid/private-entries"; then
  pass "pnpm lock admits one exact allowlisted private package"
else fail "pnpm lock rejected an exact allowlisted private package"; fi
missing="$fixture/missing-integrity"
write_fixture "$missing" '@verjson/contracts' 'https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/abc' ''
if run_validator "$missing" '@verjson/contracts' >/dev/null 2>&1; then fail "pnpm lock admitted missing integrity"; else pass "pnpm lock rejects missing private-package integrity"; fi
unapproved="$fixture/unapproved"
write_fixture "$unapproved" '@verjson/other' 'https://npm.pkg.github.com/download/@verjson/other/1.2.3/abc' "$integrity"
if run_validator "$unapproved" '@verjson/contracts' >/dev/null 2>&1; then fail "pnpm lock admitted an unapproved package"; else pass "pnpm lock rejects an unapproved private package"; fi
sed -i 's/pnpm@11.20.0+sha512\.[0-9a-f]*/pnpm@11.20.0/' "$valid/package.json"
if run_validator "$valid" '@verjson/contracts' >/dev/null 2>&1; then fail "pnpm admitted an unpinned Corepack version"; else pass "pnpm rejects package-manager pin drift"; fi
duplicate="$fixture/duplicate"
write_fixture "$duplicate" '@verjson/contracts' 'https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/abc' "$integrity"
printf "  '@verjson/contracts@1.2.3':\n    resolution: {integrity: %s, tarball: https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/abc}\n" "$integrity" >> "$duplicate/pnpm-lock.yaml"
if run_validator "$duplicate" '@verjson/contracts' >/dev/null 2>&1; then fail "pnpm lock admitted duplicate YAML keys"; else pass "pnpm lock rejects duplicate-key ambiguity"; fi
python3 - "$workflow" <<'PY' \
  && pass "pnpm execution remains credentialless, frozen, bounded, and cleaned" \
  || fail "pnpm execution weakened the secretless handoff"
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
inputs = doc[True]["workflow_call"]["inputs"]
assert inputs["package-manager"]["default"] == "npm"
steps = doc["jobs"]["build-test"]["steps"]
install = next(step for step in steps if step.get("name") == "Install from verified secretless npm cache")
for credential in ("GH_TOKEN", "GITHUB_TOKEN", "NODE_AUTH_TOKEN", "NPM_TOKEN"):
    assert install["env"][credential] == ""
script = install["run"]
assert 'corepack pnpm store add --store-dir "$PNPM_STORE_DIR" "$package_blob"' in script
assert "corepack pnpm install --frozen-lockfile --ignore-scripts --prefer-offline" in script
assert 'rm -rf "$SECRETLESS_CACHE_DIR" "$PNPM_STORE_DIR" "$TRANSFER_DIR"' in script
boundary = next(step for step in doc["jobs"]["acquire-secretless-dependencies"]["steps"] if step.get("name") == "Enforce the secretless event boundary")
assert "same-repository pull request" in boundary["run"]
PY
exit "$failures"
