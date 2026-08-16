#!/usr/bin/env bash
# Generate one immutable container-candidate adopter artifact.
set -euo pipefail

mode="${1-}"
ref="${2-}"
config_path="${3-container-candidate.json}"
root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "usage: $(basename "$0") {workflow|validator|contract-test} <40-hex-contract-ref> [config-path]" >&2
  exit 2
}

[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$config_path" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*\.json$ ]] || {
  echo "config-path must be a repository-relative JSON path" >&2
  exit 2
}

case "$mode" in
  workflow)
    acquisition_sha256="$(git -C "$root" show "$ref:scripts/container_private_dependencies.py" | sha256sum | cut -d' ' -f1)"
    cat <<YAML
# GENERATED FILE — do not edit by hand.
# Contract: $ref
# Regenerate with:
#   scripts/gen-container-candidate.sh workflow $ref $config_path > .github/workflows/container-candidate.yml
name: immutable container candidate

on:
  push:
    branches: [main]
  pull_request:

permissions:
  actions: read
  attestations: write
  contents: read
  packages: write
  id-token: write

jobs:
  candidate:
    uses: Verjson/.github/.github/workflows/container-candidate.yml@$ref
    with:
      config-path: $config_path
      contract-ref: $ref
      acquisition-sha256: $acquisition_sha256
    secrets:
      NODE_AUTH_TOKEN: \${{ secrets.NODE_AUTH_TOKEN }}
YAML
    ;;
  validator)
    cat <<HEADER
#!/usr/bin/env python3
# GENERATED FILE — do not edit by hand.
# Contract: $ref
# Source: Verjson/.github/scripts/container_release_manifest.py@$ref
HEADER
    git -C "$root" show "$ref:scripts/container_release_manifest.py" \
      | sed '1{/^#!\/usr\/bin\/env python3$/d;}'
    ;;
  contract-test)
    acquisition_sha256="$(git -C "$root" show "$ref:scripts/container_private_dependencies.py" | sha256sum | cut -d' ' -f1)"
    workflow="$("$0" workflow "$ref" "$config_path")"
    workflow_digest="$(printf '%s\n' "$workflow" | sha256sum | cut -d' ' -f1)"
    validator="$("$0" validator "$ref" "$config_path")"
    validator_digest="$(printf '%s\n' "$validator" | sha256sum | cut -d' ' -f1)"
    cat <<TEST
#!/usr/bin/env bash
# GENERATED FILE — do not edit by hand.
# Contract: $ref
set -euo pipefail
root="\$(cd "\$(dirname "\$0")/.." && pwd)"
caller="\$root/.github/workflows/container-candidate.yml"
validator="\$root/scripts/container_release_manifest.py"
fail() { echo "container candidate contract: \$*" >&2; exit 1; }
[ -f "\$caller" ] || fail "generated caller is missing"
[ -f "\$validator" ] || fail "generated validator is missing"
grep -qx '# Contract: $ref' "\$caller" || fail "caller contract pin differs"
grep -qx '# Contract: $ref' "\$validator" || fail "validator contract pin differs"
grep -q 'uses: Verjson/.github/.github/workflows/container-candidate.yml@$ref' "\$caller" || fail "caller does not use the pinned reusable workflow"
grep -q 'contract-ref: $ref' "\$caller" || fail "caller does not pass the shared pin"
grep -q 'acquisition-sha256: $acquisition_sha256' "\$caller" || fail "caller does not pin the acquisition implementation digest"
grep -q '^  actions: read$' "\$caller" || fail "caller cannot satisfy reusable Actions reads"
grep -q '^  attestations: write$' "\$caller" || fail "caller cannot publish signed attestations"
grep -q '^  contents: read$' "\$caller" || fail "caller cannot read its source"
grep -q '^  packages: write$' "\$caller" || fail "caller cannot publish candidate images and signed SBOMs"
grep -q '^  id-token: write$' "\$caller" || fail "caller cannot mint attestation identity"
[ "\$(sha256sum "\$caller" | cut -d' ' -f1)" = "$workflow_digest" ] || fail "generated caller was edited"
[ "\$(sha256sum "\$validator" | cut -d' ' -f1)" = "$validator_digest" ] || fail "generated validator was edited"
grep -q '^  pull_request:' "\$caller" || fail "pull requests must exercise the build-only path"
if grep -Eq 'secrets: inherit|registry-namespace:|environment:' "\$caller"; then
  fail "caller may not inherit credentials or inject registry namespaces or environments"
fi
grep -qF 'NODE_AUTH_TOKEN: \${{ secrets.NODE_AUTH_TOKEN }}' "\$caller" \
  || fail "caller does not pass only the private-package acquisition token"
python3 "\$validator" --help >/dev/null
echo "container candidate generated contract passed"
TEST
    ;;
  *) usage ;;
esac
