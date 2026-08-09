#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="$(git -C "$root" rev-parse HEAD)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for fixture in single multi; do
  consumer="$tmp/$fixture"
  mkdir -p "$consumer/.github/workflows" "$consumer/scripts"
  "$root/scripts/gen-container-candidate.sh" workflow "$ref" container-candidate.json \
    > "$consumer/.github/workflows/container-candidate.yml"
  "$root/scripts/gen-container-candidate.sh" validator "$ref" container-candidate.json \
    > "$consumer/scripts/container_release_manifest.py"
  "$root/scripts/gen-container-candidate.sh" contract-test "$ref" container-candidate.json \
    > "$consumer/scripts/container-candidate-contract.test.sh"
  chmod +x "$consumer/scripts/"*.sh "$consumer/scripts/"*.py
  cp "$root/scripts/fixtures/container-candidate/$fixture.json" "$consumer/container-candidate.json"
  jq -e '.images | length > 0' "$consumer/container-candidate.json" >/dev/null
  bash "$consumer/scripts/container-candidate-contract.test.sh"
done

workflow="$root/.github/workflows/container-candidate.yml"
grep -q "github.event_name == 'pull_request'" "$workflow"
grep -q "github.event_name == 'push'.*github.event.repository.default_branch" "$workflow"
grep -q 'packages: write' "$workflow"
grep -q 'id-token: write' "$workflow"
grep -q 'actions/attest-build-provenance@[0-9a-f]\{40\}' "$workflow"
grep -q 'commit identity already records a different digest' "$workflow"
grep -q 'imagetools create -t "\$commit_tag"' "$workflow"
if grep -q 'GITHUB_WORKFLOW_REF' "$workflow"; then
  echo "called workflows cannot prove their own pin through github.workflow_ref" >&2
  exit 1
fi
if awk '/^  pull-request-build:/{seen=1} /^  publish-base:/{seen=0} seen' "$workflow" | grep -Eq 'packages: write|id-token: write|docker/login-action|push: true'; then
  echo "pull-request build exposes a publication capability" >&2
  exit 1
fi
if grep -Eq 'uses: [^ ]+@(main|master|v[0-9]+)$' "$workflow"; then
  echo "container workflow contains an unpinned action" >&2
  exit 1
fi

before="$(sha256sum "$root/scripts/gen-changelog-caller.sh" "$root/.github/workflows/generated-artifacts.yml")"
"$root/scripts/gen-container-candidate.sh" workflow "$ref" >/dev/null
after="$(sha256sum "$root/scripts/gen-changelog-caller.sh" "$root/.github/workflows/generated-artifacts.yml")"
[ "$before" = "$after" ] || { echo "container generator drifted changelog contract artifacts" >&2; exit 1; }
if "$root/scripts/gen-container-candidate.sh" validator "$(printf 'a%.0s' {1..40})" >/dev/null 2>&1; then
  echo "candidate validator generation resolved a nonexistent pin from local files" >&2
  exit 1
fi

bash "$root/scripts/container-contract-coexistence.test.sh"

echo "container candidate canonical contract passed"
