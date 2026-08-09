#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
contract="$tmp/contract"
consumer="$tmp/consumer"
mkdir -p "$contract/scripts" "$consumer/.github/workflows" "$consumer/scripts"
cp \
  "$root/scripts/gen-container-candidate.sh" \
  "$root/scripts/gen-container-release.sh" \
  "$root/scripts/container_release_promotion.py" \
  "$root/scripts/container_release_manifest.py" \
  "$root/scripts/container_artifact_extract.py" \
  "$contract/scripts/"
git -C "$contract" init -q
git -C "$contract" config user.name fixture
git -C "$contract" config user.email fixture@example.invalid
git -C "$contract" add scripts
git -C "$contract" commit -qm fixture
ref="$(git -C "$contract" rev-parse HEAD)"

candidate="$contract/scripts/gen-container-candidate.sh"
release="$contract/scripts/gen-container-release.sh"
"$candidate" workflow "$ref" container-candidate.json >"$consumer/.github/workflows/container-candidate.yml"
"$candidate" validator "$ref" container-candidate.json >"$consumer/scripts/container_release_manifest.py"
candidate_validator_digest="$(sha256sum "$consumer/scripts/container_release_manifest.py")"
"$candidate" contract-test "$ref" container-candidate.json >"$consumer/scripts/container-candidate-contract.test.sh"

"$release" workflow "$ref" container-candidate.json >"$consumer/.github/workflows/container-release.yml"
"$release" validator "$ref" container-candidate.json >"$consumer/scripts/container_release_promotion.py"
"$release" manifest-validator "$ref" container-candidate.json >"$consumer/scripts/container_release_manifest.py"
release_validator_digest="$(sha256sum "$consumer/scripts/container_release_manifest.py")"
"$release" artifact-extractor "$ref" container-candidate.json >"$consumer/scripts/container_artifact_extract.py"
"$release" contract-test "$ref" container-candidate.json >"$consumer/scripts/container-release-contract.test.sh"

[ "$candidate_validator_digest" = "$release_validator_digest" ] || {
  echo "candidate and release manifest validators differ" >&2
  exit 1
}
chmod +x "$consumer/scripts/"*.py "$consumer/scripts/"*.sh
(
  cd "$consumer"
  bash scripts/container-candidate-contract.test.sh
  bash scripts/container-release-contract.test.sh
)

echo "container candidate and release generated contracts coexist"
