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
  "$root/scripts/gen-container-deployment.sh" \
  "$root/scripts/container_deployment_controller.py" \
  "$root/scripts/container_deployment_preflight.py" \
  "$contract/scripts/"
cp \
  "$root/docs/decisions/0078-container-release-and-runner-deployment-contract/deployment-receipt.schema.json" \
  "$contract/docs/decisions/0078-container-release-and-runner-deployment-contract/"
git -C "$contract" init -q
git -C "$contract" config user.name fixture
git -C "$contract" config user.email fixture@example.invalid
git -C "$contract" add scripts docs
git -C "$contract" commit -qm fixture
ref="$(git -C "$contract" rev-parse HEAD)"
generator="$contract/scripts/gen-container-deployment.sh"

"$generator" workflow "$ref" >"$consumer/.github/workflows/container-deployment.yml"
"$generator" controller "$ref" >"$consumer/scripts/container_deployment_controller.py"
"$generator" preflight "$ref" >"$consumer/scripts/container_deployment_preflight.py"
"$generator" receipt-schema "$ref" >"$consumer/scripts/deployment-receipt.schema.json"
"$generator" contract-test "$ref" >"$consumer/scripts/container-deployment-contract.test.sh"
cat >"$consumer/container-deployment.json" <<JSON
{
  "schemaVersion": 1,
  "cliCommand": ["npx", "--no-install", "verjson-cloud"],
  "evidenceCommand": ["python3", "scripts/runner-deployment-evidence.py"],
  "probeCommand": ["python3", "scripts/runner-deployment-probe.py"],
  "expectedRelease": {
    "repository": "ghcr.io/verjson/example-release",
    "sourceRepository": "Verjson/example",
    "sourceRef": "refs/heads/main",
    "signerWorkflow": "Verjson/.github/.github/workflows/container-release.yml",
    "contractCommit": "$ref",
    "variant": "runner"
  },
  "fleets": {
    "production": {
      "lane": "gate",
      "project": "existing-fleet",
      "canary": "gha-gate-1",
      "runners": ["gha-gate-1", "gha-gate-2"],
      "minimumAvailable": 1,
      "drainTimeoutSeconds": 600,
      "probeTimeoutSeconds": 300,
      "observationSeconds": 120,
      "runnerGroup": "trusted",
      "requiredLabels": ["gate", "pwsh"],
      "requiredTools": ["pwsh"]
    }
  }
}
JSON
cat >"$consumer/scripts/runner-deployment-evidence.py" <<'PY'
#!/usr/bin/env python3
PY
cat >"$consumer/scripts/runner-deployment-probe.py" <<'PY'
#!/usr/bin/env python3
PY
chmod +x "$consumer/scripts/"*.py "$consumer/scripts/"*.sh
(cd "$consumer" && bash scripts/container-deployment-contract.test.sh)

cp "$consumer/.github/workflows/container-deployment.yml" "$tmp/caller.clean"
sed -i "s/container-deployment.yml@$ref/container-deployment.yml@main/" \
  "$consumer/.github/workflows/container-deployment.yml"
if (cd "$consumer" && bash scripts/container-deployment-contract.test.sh >/dev/null 2>&1); then
  echo "generated contract accepted a mutable reusable-workflow ref" >&2
  exit 1
fi
mv "$tmp/caller.clean" "$consumer/.github/workflows/container-deployment.yml"

workflow="$root/.github/workflows/container-deployment.yml"
grep -q '^    environment: production$' "$workflow"
grep -q 'if: inputs.dry-run' "$workflow"
# The literal GitHub expression is the contract under test.
# shellcheck disable=SC2016
grep -q 'if: \${{ !inputs.dry-run }}' "$workflow"
grep -q 'cancel-in-progress: false' "$workflow"
grep -q 'container_deployment_preflight.py' "$workflow"
grep -q 'Retain pre-mutation admission authority' "$workflow"
# The literal shell variable must never become a path argument.
# shellcheck disable=SC2016
if grep -q -- '--rollback-source "\$ROLLBACK_RECEIPT"' "$workflow"; then
  echo "rollback receipt identity is used as a filesystem path" >&2
  exit 1
fi
grep -q 'verjson-cloud' "$root/scripts/container_deployment_controller.py"
grep -q '"--only"' "$root/scripts/container_deployment_controller.py"
if grep -Eq 'doctl|ssh |droplet|--replicas|--standard|resize|create' "$workflow"; then
  echo "reusable workflow contains fleet mechanics or a spend-increasing operation" >&2
  exit 1
fi
if grep -Eq 'doctl|droplet|--replicas|--standard|resize|create' \
    "$root/scripts/container_deployment_controller.py"; then
  echo "deployment controller contains a spend-increasing operation" >&2
  exit 1
fi

python3 - "$workflow" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    workflow = yaml.safe_load(stream)
trigger = workflow.get("on", workflow.get(True))
assert set(trigger) == {"workflow_call"}
jobs = workflow["jobs"]
assert jobs["deploy"]["environment"] == "production"
assert "environment" not in jobs["dry-run"]
assert workflow["concurrency"]["cancel-in-progress"] is False
assert set(workflow["permissions"]) == {"actions", "attestations", "contents"}
mutation_step = next(
    step for step in jobs["deploy"]["steps"]
    if step.get("name") == "Execute bounded canary and sequential rollout"
)
assert mutation_step["env"] == {
    "CONFIG_PATH": "${{ inputs.config-path }}",
    "GH_TOKEN": "${{ github.token }}",
    "VERJSON_RUNNER_DEPLOY_TOKEN": "${{ secrets.VERJSON_RUNNER_DEPLOY_TOKEN }}",
}
for step in jobs["deploy"]["steps"]:
    if step is not mutation_step:
        assert "VERJSON_RUNNER_DEPLOY_TOKEN" not in str(step)
PY

echo "container deployment generated contract and protected reusable workflow passed"
