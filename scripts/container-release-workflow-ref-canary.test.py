#!/usr/bin/env python3
import copy
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/container-release-workflow-ref-canary.yml"
CONTRACT = "6462e0cc72f4d96baa4f8ff8a862db4af0f93db7"
PERMISSIONS = {
    "actions": "read",
    "attestations": "write",
    "contents": "read",
    "id-token": "write",
    "packages": "write",
}


def valid(document: dict, source: str) -> bool:
    trigger = document.get(True, document.get("on"))
    jobs = document.get("jobs", {})
    if trigger != {"workflow_dispatch": None} or list(jobs) != ["probe"]:
        return False
    if document.get("permissions") != PERMISSIONS:
        return False
    probe = jobs["probe"]
    expected_target = (
        "Verjson/.github/.github/workflows/container-release.yml@" + CONTRACT
    )
    expected_inputs = {
        "version": "0.0.0-workflow-identity-canary",
        "candidate-manifest": "intentionally-invalid-after-workflow-ref-guard",
        "config-path": "container-candidate.json",
        "contract-ref": CONTRACT,
        "release_app_client_id": "${{ vars.RELEASE_APP_CLIENT_ID }}",
    }
    expected_secrets = {
        "release_app_private_key": "${{ secrets.RELEASE_APP_PRIVATE_KEY }}"
    }
    return (
        set(probe) == {"uses", "with", "secrets"}
        and probe.get("uses") == expected_target
        and probe.get("with") == expected_inputs
        and probe.get("secrets") == expected_secrets
        and "ORG_ADMIN_TOKEN" not in source
        and "secrets: inherit" not in source
    )


raw = WORKFLOW.read_text(encoding="utf-8")
workflow = yaml.safe_load(raw)
assert valid(workflow, raw)

mutants = []
mutable = copy.deepcopy(workflow)
mutable["jobs"]["probe"]["uses"] = (
    "Verjson/.github/.github/workflows/container-release.yml@main"
)
mutants.append(mutable)
widened = copy.deepcopy(workflow)
trigger_key = True if True in widened else "on"
widened[trigger_key] = {
    "workflow_dispatch": {"inputs": {"candidate-manifest": {"required": True}}}
}
mutants.append(widened)
candidate = copy.deepcopy(workflow)
candidate["jobs"]["probe"]["with"]["candidate-manifest"] = (
    "1@sha256:" + "0" * 64
)
mutants.append(candidate)
mismatched = copy.deepcopy(workflow)
mismatched["jobs"]["probe"]["with"]["contract-ref"] = "0" * 40
mutants.append(mismatched)
inherited = copy.deepcopy(workflow)
inherited["jobs"]["probe"]["secrets"] = "inherit"
mutants.append(inherited)

assert all(not valid(mutant, yaml.safe_dump(mutant)) for mutant in mutants)
print("container release workflow-ref canary contract passed")
