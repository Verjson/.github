#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
contract="$tmp/contract"
consumer="$tmp/consumer"
mkdir -p \
  "$contract/scripts" \
  "$contract/docs/decisions/0078-container-release-and-runner-deployment-contract" \
  "$consumer/.github/workflows" \
  "$consumer/scripts"
cp \
  "$root/scripts/gen-container-candidate.sh" \
  "$root/scripts/gen-container-release.sh" \
  "$root/scripts/gen-container-deployment.sh" \
  "$root/scripts/container_release_promotion.py" \
  "$root/scripts/container_release_manifest.py" \
  "$root/scripts/container_private_dependencies.py" \
  "$root/scripts/container_artifact_extract.py" \
  "$root/scripts/container_deployment_controller.py" \
  "$root/scripts/container_deployment_preflight.py" \
  "$contract/scripts/"
cp "$root/docs/decisions/0078-container-release-and-runner-deployment-contract/deployment-receipt.schema.json" \
  "$contract/docs/decisions/0078-container-release-and-runner-deployment-contract/"
git -C "$contract" init -q
git -C "$contract" config user.name fixture
git -C "$contract" config user.email fixture@example.invalid
git -C "$contract" add scripts docs
git -C "$contract" commit -qm fixture
ref="$(git -C "$contract" rev-parse HEAD)"

candidate="$contract/scripts/gen-container-candidate.sh"
release="$contract/scripts/gen-container-release.sh"
deployment="$contract/scripts/gen-container-deployment.sh"
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

"$deployment" workflow "$ref" container-deployment.json >"$consumer/.github/workflows/container-deployment.yml"
"$deployment" controller "$ref" >"$consumer/scripts/container_deployment_controller.py"
"$deployment" preflight "$ref" >"$consumer/scripts/container_deployment_preflight.py"
"$deployment" receipt-schema "$ref" >"$consumer/scripts/deployment-receipt.schema.json"
"$deployment" contract-test "$ref" container-deployment.json >"$consumer/scripts/container-deployment-contract.test.sh"
cat >"$consumer/container-deployment.json" <<JSON
{"schemaVersion":1,"cliCommand":["npx","--no-install","verjson-cloud"],"evidenceCommand":["python3","scripts/evidence.py"],"probeCommand":["python3","scripts/probe.py"],"expectedRelease":{"repository":"ghcr.io/verjson/example","sourceRepository":"Verjson/example","sourceRef":"refs/heads/main","signerWorkflow":"Verjson/.github/.github/workflows/container-release.yml","contractCommit":"$ref","variant":"runner"},"fleets":{"production":{"lane":"gate","project":"existing","canary":"gha-gate-1","runners":["gha-gate-1","gha-gate-2"],"minimumAvailable":1,"drainTimeoutSeconds":600,"probeTimeoutSeconds":300,"observationSeconds":120,"runnerGroup":"trusted","requiredLabels":["gate"],"requiredTools":["pwsh"]}}}
JSON
printf '#!/usr/bin/env python3\n' >"$consumer/scripts/evidence.py"
printf '#!/usr/bin/env python3\n' >"$consumer/scripts/probe.py"

[ "$candidate_validator_digest" = "$release_validator_digest" ] || {
  echo "candidate and release manifest validators differ" >&2
  exit 1
}
chmod +x "$consumer/scripts/"*.py "$consumer/scripts/"*.sh
(
  cd "$consumer"
  bash scripts/container-candidate-contract.test.sh
  bash scripts/container-release-contract.test.sh
  bash scripts/container-deployment-contract.test.sh
)

echo "container candidate, release, and deployment generated contracts coexist"
