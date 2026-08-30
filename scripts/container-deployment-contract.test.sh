#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
contract="$tmp/contract"
consumer="$tmp/consumer"
mkdir -p \
  "$contract/.github/workflows" \
  "$contract/contracts/container-deployment-cli" \
  "$contract/scripts" \
  "$contract/docs/decisions/0078-container-release-and-runner-deployment-contract" \
  "$consumer/.github/workflows" \
  "$consumer/scripts"
cp \
  "$root/scripts/gen-container-deployment.sh" \
  "$root/scripts/container_deployment_controller.py" \
  "$root/scripts/container_deployment_preflight.py" \
  "$root/scripts/container_deployment_review_producer.py" \
  "$root/scripts/validate-container-deployment-cli-lock.py" \
  "$contract/scripts/"
cp \
  "$root/.github/workflows/container-deployment-review-producer.yml" \
  "$contract/.github/workflows/"
cp \
  "$root/docs/decisions/0078-container-release-and-runner-deployment-contract/deployment-receipt.schema.json" \
  "$contract/docs/decisions/0078-container-release-and-runner-deployment-contract/"
cp \
  "$root/contracts/container-deployment-cli/package.json" \
  "$root/contracts/container-deployment-cli/package-lock.json" \
  "$root/contracts/container-deployment-cli/.npmrc" \
  "$contract/contracts/container-deployment-cli/"
git -C "$contract" init -q
git -C "$contract" config user.name fixture
git -C "$contract" config user.email fixture@example.invalid
git -C "$contract" add scripts docs
git -C "$contract" add .github
git -C "$contract" commit -qm fixture
ref="$(git -C "$contract" rev-parse HEAD)"
generator="$contract/scripts/gen-container-deployment.sh"

"$generator" workflow "$ref" >"$consumer/.github/workflows/container-deployment.yml"
"$generator" code-review-workflow "$ref" >"$consumer/.github/workflows/container-deployment-code-review.yml"
"$generator" security-review-workflow "$ref" >"$consumer/.github/workflows/container-deployment-security-review.yml"
"$generator" ai-review-workflow "$ref" >"$consumer/.github/workflows/container-deployment-ai-review.yml"
"$generator" review-producer-workflow "$ref" >"$consumer/.github/workflows/container-deployment-review-producer.yml"
"$generator" review-producer "$ref" >"$consumer/scripts/container_deployment_review_producer.py"
"$generator" controller "$ref" >"$consumer/scripts/container_deployment_controller.py"
"$generator" preflight "$ref" >"$consumer/scripts/container_deployment_preflight.py"
"$generator" receipt-schema "$ref" >"$consumer/scripts/deployment-receipt.schema.json"
"$generator" contract-test "$ref" >"$consumer/scripts/container-deployment-contract.test.sh"
cat >"$consumer/container-deployment.json" <<JSON
{
  "schemaVersion": 1,
  "reviewAuthority": {
    "code": {"appId": 201, "installationId": 301, "checkName": "runner-deploy-code-review", "workflowPath": ".github/workflows/container-deployment-code-review.yml"},
    "security": {"appId": 202, "installationId": 302, "checkName": "runner-deploy-security-review", "workflowPath": ".github/workflows/container-deployment-security-review.yml"},
    "ai": {"appId": 203, "installationId": 303, "sourceAppId": 403, "sourceCheckName": "canonical-ai-review", "checkName": "runner-deploy-ai-review", "workflowPath": ".github/workflows/container-deployment-ai-review.yml"}
  },
  "cliCommand": ["verjson-cloud"],
  "evidenceCommand": ["python3", "scripts/runner-deployment-evidence.py"],
  "probeCommand": ["python3", "scripts/runner-deployment-probe.py"],
  "expectedRelease": {
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
test "$(jq -r '.packages["node_modules/@verjson/cli-cloud"].version' \
  "$root/contracts/container-deployment-cli/package-lock.json")" = '0.29.0'
test "$(jq -r '.packages["node_modules/@verjson/cli-cloud"].integrity' \
  "$root/contracts/container-deployment-cli/package-lock.json")" = \
  'sha512-hS4jMPzfYHNYDmNP7yDrnvTg8Z6W/NY4CDOZXZvadtDaFALkRtPceWVaI1ggG1lrlDcDpaWQJRUfqrV9vjI82g=='
python3 "$root/scripts/validate-container-deployment-cli-lock.py" \
  "$root/contracts/container-deployment-cli/package-lock.json"
python3 - "$root/contracts/container-deployment-cli/package-lock.json" "$tmp" <<'PY'
import copy
import json
from pathlib import Path
import sys

source = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
destination = Path(sys.argv[2])
package_name = next(name for name in source["packages"] if name)
mutations = {
    "missing-integrity": ("integrity", None),
    "wrong-integrity": ("integrity", "sha256-" + "A" * 44),
    "file-url": ("resolved", "file:///tmp/package.tgz"),
    "git-url": ("resolved", "git+https://github.com/example/package.git"),
    "plain-http": ("resolved", "http://registry.npmjs.org/package/-/package.tgz"),
    "foreign-host": ("resolved", "https://packages.example.invalid/package.tgz"),
}
for name, (field, value) in mutations.items():
    candidate = copy.deepcopy(source)
    if value is None:
        candidate["packages"][package_name].pop(field, None)
    else:
        candidate["packages"][package_name][field] = value
    (destination / f"lock-{name}.json").write_text(
        json.dumps(candidate), encoding="utf-8"
    )
PY
for hostile_lock in "$tmp"/lock-*.json; do
  if python3 "$root/scripts/validate-container-deployment-cli-lock.py" \
      "$hostile_lock" >/dev/null 2>&1; then
    echo "deployment CLI lock validator accepted $(basename "$hostile_lock")" >&2
    exit 1
  fi
done
grep -q 'npm ci --ignore-scripts --no-audit --no-fund' "$workflow"
grep -q 'NPM_CONFIG_CACHE:.*npm-cache-' "$workflow"
grep -q 'validate-container-deployment-cli-lock.py' "$workflow"
grep -q 'repos/Verjson/.github/tarball/\$CONTRACT_REF' "$workflow"
grep -q 'test -x "\$cli_bin/verjson-cloud"' "$workflow"
grep -q 'VERJSON_DEPLOYMENT_CLI_ROOT=' "$workflow"
grep -q 'Retain admitted or reconciled authority' "$workflow"
grep -q 'container_deployment_controller.py reconcile' "$workflow"
test "$(grep -c -- '--authorization github-authorization.json' "$workflow")" = 3
for authority_variable in \
  RUNNER_DEPLOY_CODE_REVIEW_APP_ID RUNNER_DEPLOY_CODE_REVIEW_CHECK RUNNER_DEPLOY_CODE_REVIEW_WORKFLOW \
  RUNNER_DEPLOY_SECURITY_REVIEW_APP_ID RUNNER_DEPLOY_SECURITY_REVIEW_CHECK RUNNER_DEPLOY_SECURITY_REVIEW_WORKFLOW \
  RUNNER_DEPLOY_AI_REVIEW_APP_ID RUNNER_DEPLOY_AI_REVIEW_CHECK RUNNER_DEPLOY_AI_REVIEW_WORKFLOW; do
  ! grep -q "$authority_variable" "$workflow"
done
grep -q 'actions/artifacts/{artifact' "$workflow"
grep -q 'review-receipt.json' "$workflow"
! grep -qF '.github/workflows/adversarial-code-review.yml' "$workflow"
! grep -qF '.github/workflows/adversarial-security-review.yml' "$workflow"
grep -qF '"sha256:" + hashlib.sha256(archive).hexdigest()' "$workflow"
grep -qF 'pulls/{pull[' "$workflow"
# The literal shell variable must never become a path argument.
# shellcheck disable=SC2016
if grep -q -- '--rollback-source "\$ROLLBACK_RECEIPT"' "$workflow"; then
  echo "rollback receipt identity is used as a filesystem path" >&2
  exit 1
fi
grep -q 'verjson-cloud' "$root/scripts/container_deployment_controller.py"
grep -q '"--only"' "$root/scripts/container_deployment_controller.py"
if grep -vF 'actions/create-github-app-token@' "$workflow" \
  | grep -Eq 'doctl|ssh |droplet|--replicas|--standard|resize|create'; then
  echo "reusable workflow contains fleet mechanics or a spend-increasing operation" >&2
  exit 1
fi
if grep -Eq 'doctl|droplet|--replicas|--standard|resize|create' \
    "$root/scripts/container_deployment_controller.py"; then
  echo "deployment controller contains a spend-increasing operation" >&2
  exit 1
fi

python3 - "$workflow" "$consumer" "$ref" <<'PY'
import os
from pathlib import Path
import subprocess
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
assert set(workflow["permissions"]) == {
    "actions", "attestations", "checks", "contents", "packages", "pull-requests"
}
for job_name in ("dry-run", "deploy"):
    steps = jobs[job_name]["steps"]
    setup = [step for step in steps if step.get("uses", "").startswith("actions/setup-node@")]
    assert len(setup) == 1
    assert setup[0]["uses"] == "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020"
    assert setup[0]["with"]["node-version"] == "24.19.0"
    binding = [step for step in steps if step.get("name") == "Verify caller binds this immutable contract"]
    assert len(binding) == 1
    acquisition = [step for step in steps if step.get("name") == "Acquire immutable deployment CLI"]
    assert len(acquisition) == 1
    assert "NPM_CONFIG_CACHE" in acquisition[0]["env"]
    cleanup = [step for step in steps if step.get("name") == "Remove deployment acquisition state"]
    assert len(cleanup) == 1
    assert cleanup[0]["if"] == "${{ always() }}"
    assert "deployment-contract.tar.gz" in cleanup[0]["run"]
    assert "deployment-contract" in cleanup[0]["run"]
    assert "NPM_CONFIG_CACHE" in cleanup[0]["run"]

consumer = Path(sys.argv[2])
contract = sys.argv[3]
binding_script = next(
    step["run"] for step in jobs["dry-run"]["steps"]
    if step.get("name") == "Verify caller binds this immutable contract"
)
environment = os.environ | {
    "CONTRACT_REF": contract,
    "GITHUB_REPOSITORY": "fixture/consumer",
    "GITHUB_WORKSPACE": str(consumer),
    "WORKFLOW_REF": "fixture/consumer/.github/workflows/container-deployment.yml@refs/heads/main",
}
subprocess.run(["bash", "-c", binding_script], check=True, env=environment, cwd=consumer)
caller = consumer / ".github/workflows/container-deployment.yml"
original = caller.read_text(encoding="utf-8")
caller.write_text(original.replace(f"contract-ref: {contract}", "contract-ref: " + "0" * 40), encoding="utf-8")
rejected = subprocess.run(
    ["bash", "-c", binding_script], env=environment, cwd=consumer,
    capture_output=True, text=True,
)
assert rejected.returncode != 0
caller.write_text(original, encoding="utf-8")
mutation_steps = [
    step for step in jobs["deploy"]["steps"]
    if step.get("name", "").startswith("Advance ")
]
assert len(mutation_steps) == 3
expected_mutation_env = {
    "CONFIG_PATH": "${{ inputs.config-path }}",
        "GH_RUNNER_CONTROL_TOKEN": "${{ steps.runner-app-token.outputs.token }}",
        "DIGITALOCEAN_RUNNER_FLEET_TOKEN": "${{ secrets.DIGITALOCEAN_RUNNER_FLEET_TOKEN }}",
}
assert all(step["env"] == expected_mutation_env for step in mutation_steps)
mint = next(step for step in jobs["deploy"]["steps"] if step.get("id") == "runner-app-token")
assert mint["uses"] == "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"
assert mint["with"] == {
    "client-id": "${{ vars.GH_RUNNER_REGISTRATION_APP_CLIENT_ID }}",
    "private-key": "${{ secrets.GH_RUNNER_REGISTRATION_APP_PRIVATE_KEY }}",
    "owner": "${{ github.repository_owner }}",
    "repositories": "${{ github.event.repository.name }}",
    "permission-organization-self-hosted-runners": "write",
}
verify_installation = next(
    step for step in jobs["deploy"]["steps"]
    if step.get("name") == "Verify runner App installation identity"
)
assert "outputs.installation-id" in str(verify_installation)
assert "GH_RUNNER_REGISTRATION_APP_INSTALLATION_ID" in str(verify_installation)
dry_uploads = [
    step for step in jobs["dry-run"]["steps"]
    if step.get("uses", "").startswith("actions/upload-artifact@")
]
assert len(dry_uploads) == 1
assert dry_uploads[0]["with"]["path"] == "deployment-plan.json"
for step in jobs["deploy"]["steps"]:
    if step not in mutation_steps:
        assert "DIGITALOCEAN_RUNNER_FLEET_TOKEN" not in str(step)
        assert "GH_RUNNER_CONTROL_TOKEN" not in str(step)
PY

echo "container deployment generated contract and protected reusable workflow passed"
