"""Adversarial contract for terminal merge App-token isolation."""

from __future__ import annotations

import copy
import pathlib

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ai-privileged-merge.yml"
ACTION = "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"
APP_TOKEN = "${{ steps.merge-app-token.outputs.token }}"


def workflow_call(document: dict) -> dict:
    return document.get("on", document.get(True))["workflow_call"]


def named_step(job: dict, name: str) -> dict:
    return next(step for step in job["steps"] if step.get("name") == name)


def validate(document: dict, raw: str) -> list[str]:
    problems: list[str] = []
    call = workflow_call(document)
    inputs = call.get("inputs") or {}
    secrets = call.get("secrets") or {}
    job = document["jobs"]["privileged_merge"]
    steps = job["steps"]
    preflight = named_step(job, "Validate terminal merge App and target repository")
    authorize = named_step(job, "Authorize terminal merge from trusted metadata")
    mint = named_step(job, "Mint exact-repository terminal merge App token")
    merge = named_step(job, "Merge the authorized head")
    confirm = named_step(job, "Confirm merge and consume the arm receipt")

    if not (inputs.get("merge_app_client_id") or {}).get("required"):
        problems.append("merge App client-ID input is not required")
    if secrets != {"MERGE_APP_PRIVATE_KEY": {"required": True}}:
        problems.append("reusable secret contract is not the single merge App key")
    if job.get("permissions") != {
        "actions": "read", "checks": "read", "contents": "read", "pull-requests": "read"
    }:
        problems.append("authorization repository token is not exactly read-only")
    preflight_run = preflight.get("run", "")
    for required in (
        '[[ ! "$MERGE_APP_CLIENT_ID" =~ ^Iv[0-9A-Za-z]{18}$ ]]',
        '"$TARGET_REPO" = "$REPOSITORY_CONTEXT"',
        'owner="${TARGET_REPO%%/*}"',
        'repository="${TARGET_REPO#*/}"',
    ):
        if required not in preflight_run:
            problems.append(f"target/client-ID preflight lacks {required}")
    expected_mint = {
        "client-id": "${{ inputs.merge_app_client_id || vars.MERGE_APP_CLIENT_ID }}",
        "private-key": "${{ secrets.MERGE_APP_PRIVATE_KEY }}",
        "owner": "${{ steps.merge-target.outputs.owner }}",
        "repositories": "${{ steps.merge-target.outputs.repository }}",
        "permission-contents": "write",
        "permission-pull-requests": "write",
    }
    if mint.get("uses") != ACTION or mint.get("with") != expected_mint:
        problems.append("mint is not pinned to exact repository and merge permissions")
    if mint.get("if") != "steps.authorize-merge.outputs.authorized == 'true'":
        problems.append("token can mint before successful authorization")
    if (authorize.get("env") or {}).get("GH_TOKEN") != "${{ github.token }}":
        problems.append("authorization does not use the read-only repository token")
    if (confirm.get("env") or {}).get("GH_TOKEN") != "${{ github.token }}":
        problems.append("confirmation does not return to the read-only repository token")
    if (merge.get("env") or {}) != {"GH_TOKEN": APP_TOKEN}:
        problems.append("terminal token delivery is not isolated to merge")
    merge_run = merge.get("run", "")
    if merge_run.count("gh ") != 1 or "gh pr merge" not in merge_run:
        problems.append("terminal token step performs an operation besides one gh merge")
    if "--admin" not in merge_run or "--squash" not in merge_run or "--match-head-commit" not in merge_run:
        problems.append("terminal merge safety flags drifted")
    token_consumers = [step.get("name") for step in steps if APP_TOKEN in str(step)]
    if token_consumers != ["Merge the authorized head"]:
        problems.append("merge token escaped the terminal operation")
    order = [steps.index(step) for step in (preflight, authorize, mint, merge, confirm)]
    if order != sorted(order) or len(set(order)) != len(order):
        problems.append("preflight/authorization/mint/merge/confirmation ordering drifted")
    if "ORG_ADMIN_TOKEN" in raw:
        problems.append("terminal workflow still depends on ORG_ADMIN_TOKEN")
    return problems


def require_rejected(label: str, document: dict, raw: str) -> None:
    if not validate(document, raw):
        raise AssertionError(f"mutation survived: {label}")
    print(f"ok - rejects {label}")


def main() -> None:
    raw = WORKFLOW.read_text(encoding="utf-8")
    document = yaml.safe_load(raw)
    assert not validate(document, raw), validate(document, raw)
    print("ok - merge App token is exact-repository, non-widenable, and terminal-only")
    job = document["jobs"]["privileged_merge"]

    mutations: list[tuple[str, dict, str]] = []
    mutant = copy.deepcopy(document)
    named_step(mutant["jobs"]["privileged_merge"], "Mint exact-repository terminal merge App token")["with"]["repositories"] = "*"
    mutations.append(("repository wildcard", mutant, raw))
    mutant = copy.deepcopy(document)
    named_step(mutant["jobs"]["privileged_merge"], "Mint exact-repository terminal merge App token")["with"]["owner"] = "${{ inputs.target_owner }}"
    mutations.append(("attacker-controlled installation owner", mutant, raw))
    mutant = copy.deepcopy(document)
    named_step(mutant["jobs"]["privileged_merge"], "Mint exact-repository terminal merge App token")["with"]["permission-actions"] = "write"
    mutations.append(("widened App permission", mutant, raw))
    mutant = copy.deepcopy(document)
    named_step(mutant["jobs"]["privileged_merge"], "Mint exact-repository terminal merge App token")["uses"] = "actions/create-github-app-token@v3"
    mutations.append(("mutable token action", mutant, raw))
    mutant = copy.deepcopy(document)
    mint = named_step(mutant["jobs"]["privileged_merge"], "Mint exact-repository terminal merge App token")
    mint["with"]["app-id"] = mint["with"].pop("client-id")
    mutations.append(("numeric App-ID interface", mutant, raw))
    mutant = copy.deepcopy(document)
    named_step(mutant["jobs"]["privileged_merge"], "Authorize terminal merge from trusted metadata")["env"]["GH_TOKEN"] = APP_TOKEN
    mutations.append(("merge token in authorization", mutant, raw))
    mutant = copy.deepcopy(document)
    named_step(mutant["jobs"]["privileged_merge"], "Merge the authorized head")["run"] += '\ngh api orgs/Verjson\n'
    mutations.append(("second privileged operation", mutant, raw))
    mutant = copy.deepcopy(document)
    named_step(mutant["jobs"]["privileged_merge"], "Mint exact-repository terminal merge App token").pop("if")
    mutations.append(("mint before authorization", mutant, raw))
    mutant = copy.deepcopy(document)
    workflow_call(mutant)["secrets"]["ORG_ADMIN_TOKEN"] = {"required": True}
    mutations.append(("PAT fallback secret", mutant, raw + "\nORG_ADMIN_TOKEN"))
    for mutation in mutations:
        require_rejected(*mutation)


if __name__ == "__main__":
    main()
