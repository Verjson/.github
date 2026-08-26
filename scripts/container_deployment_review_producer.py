#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import subprocess
import io
import zipfile
from pathlib import Path
from typing import Any, Callable

Api = Callable[[str, str, dict[str, Any] | None, str | None], bytes]


def github_api(path: str, method: str = "GET", body: dict[str, Any] | None = None, accept: str | None = None) -> bytes:
    command = ["gh", "api", path, "--method", method]
    if body is not None:
        command.extend(("--input", "-"))
    if accept is not None:
        command.extend(("-H", f"Accept: {accept}"))
    return subprocess.run(command, input=None if body is None else json.dumps(body).encode(), check=True, capture_output=True).stdout


def canonical_bytes(value: dict[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def canonical_digest(value: dict[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(canonical_bytes(value).rstrip(b"\n")).hexdigest()


def canonical_policy_bytes(environment: dict[str, Any]) -> bytes:
    projection = {key: environment[key] for key in ("id", "name", "deployment_branch_policy", "protection_rules")}
    return json.dumps(projection, sort_keys=True, separators=(",", ":")).encode()


def environment_policy_digest(environment: dict[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(canonical_policy_bytes(environment)).hexdigest()


def environment_preflight(repository: dict[str, Any], ref: str, kind: str, environment: dict[str, Any], permissions: set[str]) -> dict[str, Any]:
    if "actions:read" not in permissions:
        raise PermissionError("caller token lacks Actions read permission")
    if kind not in ("code", "security", "ai") or ref != f"refs/heads/{repository['default_branch']}":
        raise ValueError("publisher preflight is not on the caller default ref")
    expected_name = f"runner-deploy-{kind}-review-publisher"
    policy = environment.get("deployment_branch_policy")
    rules = environment.get("protection_rules")
    if environment.get("name") != expected_name or not isinstance(policy, dict) or policy.get("protected_branches") is not True or policy.get("custom_branch_policies") is not False or not isinstance(rules, list) or len(rules) != 1 or rules[0].get("type") != "branch_policy":
        raise ValueError("caller publisher environment policy is not canonical")
    return {"repositoryId": repository["id"], "environment": expected_name, "policyDigest": environment_policy_digest(environment)}


def publisher_reconciliation(preflight: dict[str, Any], repository: dict[str, Any], environment: dict[str, Any]) -> bool:
    if preflight.get("repositoryId") != repository.get("id") or preflight.get("environment") != environment.get("name") or preflight.get("policyDigest") != environment_policy_digest(environment):
        raise ValueError("publisher environment changed after preflight")
    return True


def validate_workflow_identity(workflow_ref: str, workflow_sha: str, contract_ref: str) -> tuple[str, str]:
    if re.fullmatch(r"[0-9a-f]{40}", contract_ref) is None or workflow_sha != contract_ref or "@" not in workflow_ref:
        raise ValueError("executing producer workflow identity is malformed")
    workflow_path, selected_ref = workflow_ref.rsplit("@", 1)
    expected_path = "Verjson/.github/.github/workflows/container-deployment-review-producer.yml"
    if workflow_path != expected_path or selected_ref != contract_ref:
        raise ValueError("executing producer workflow is not immutable canonical contract")
    return workflow_path, selected_ref


def validate_serialized_job_context(job_context: dict[str, Any]) -> tuple[str, str, str]:
    repository = job_context.get("workflow_repository")
    workflow_ref = job_context.get("workflow_ref")
    workflow_sha = job_context.get("workflow_sha")
    if repository != "Verjson/.github" or not isinstance(workflow_ref, str) or not isinstance(workflow_sha, str):
        raise ValueError("called workflow job authority is missing")
    validate_workflow_identity(workflow_ref, workflow_sha, workflow_sha)
    return repository, workflow_ref, workflow_sha


def select_merged_pull(pulls: list[dict[str, Any]], pull_request: int, default_branch: str) -> dict[str, Any]:
    candidates = [item for item in pulls if item.get("merged_at") and item.get("base", {}).get("ref") == default_branch]
    if len(candidates) != 1 or candidates[0].get("number") != pull_request:
        raise ValueError("deployed commit must resolve exactly one expected merged pull request")
    return candidates[0]


def build_receipt(args: argparse.Namespace, api: Api = github_api) -> dict[str, Any]:
    validate_workflow_identity(args.producer_workflow_ref, args.producer_commit, args.producer_commit)
    repository = json.loads(api(f"repos/{args.repository}", "GET", None, None))
    expected_environment = f"runner-deploy-{args.kind}-review-publisher"
    if args.caller_repository_id != repository["id"] or args.publisher_environment != expected_environment or re.fullmatch(r"sha256:[0-9a-f]{64}", args.environment_policy_digest) is None:
        raise ValueError("caller-owned publisher environment authority differs target repository")
    pull = json.loads(api(f"repos/{args.repository}/pulls/{args.pull_request}", "GET", None, None))
    if args.deployment_ref != f"refs/heads/{repository['default_branch']}":
        raise ValueError("producer must execute on the caller default branch")
    associated = json.loads(api(f"repos/{args.repository}/commits/{args.deployment_commit}/pulls", "GET", None, None))
    select_merged_pull(associated, args.pull_request, repository["default_branch"])
    reviewed_head = pull["head"]["sha"]
    reviewed_commit = json.loads(api(f"repos/{args.repository}/git/commits/{reviewed_head}", "GET", None, None))
    deployed_commit = json.loads(api(f"repos/{args.repository}/git/commits/{args.deployment_commit}", "GET", None, None))
    if deployed_commit["tree"]["sha"] != reviewed_commit["tree"]["sha"]:
        raise ValueError("deployed default-branch tree differs reviewed pull-request tree")
    producer = json.loads(api(f"repos/Verjson/.github/git/commits/{args.producer_commit}", "GET", None, None))
    patch = api(f"repos/{args.repository}/pulls/{args.pull_request}", "GET", None, "application/vnd.github.v3.diff")
    actor = json.loads(api(f"users/{args.actor}", "GET", None, None))
    triggering_actor = json.loads(api(f"users/{args.triggering_actor}", "GET", None, None))
    review_id = None
    source_check_id = None
    if args.kind in ("code", "security"):
        reviews = json.loads(api(f"repos/{args.repository}/pulls/{args.pull_request}/reviews?per_page=100", "GET", None, None))
        matches = [item for item in reviews if item["id"] == args.review_id]
        if len(matches) != 1:
            raise ValueError("review identity is missing or duplicated")
        review = matches[0]
        if review["state"] != "APPROVED" or review["commit_id"] != reviewed_head:
            raise ValueError("review is not an exact-head approval")
        principal_id = review["user"]["id"]
        review_id = review["id"]
    else:
        check = json.loads(api(f"repos/{args.repository}/check-runs/{args.source_check_run_id}", "GET", None, None))
        if (check["head_sha"] != reviewed_head or check["status"] != "completed" or check["conclusion"] != "success" or check["name"] != args.source_check_name or check["app"]["id"] != args.source_app_id):
            raise ValueError("AI source check is not the pinned exact-head terminal result")
        principal_id = check["app"]["id"]
        source_check_id = check["id"]
    if principal_id in (actor["id"], triggering_actor["id"]):
        raise ValueError("review principal is not independent from dispatcher")
    return {
        "schemaVersion": 2, "kind": args.kind, "repositoryId": repository["id"], "repository": args.repository,
        "pullRequest": args.pull_request, "headCommit": args.deployment_commit, "headTree": deployed_commit["tree"]["sha"],
        "reviewedHead": reviewed_head, "reviewedTree": reviewed_commit["tree"]["sha"],
        "patchDigest": "sha256:" + hashlib.sha256(patch).hexdigest(), "producerCommit": args.producer_commit,
        "producerTree": producer["tree"]["sha"], "producerWorkflowRef": args.producer_workflow_ref, "workflowRunId": args.workflow_run_id,
        "workflowRunAttempt": args.workflow_run_attempt, "principalId": principal_id,
        "reviewId": review_id, "sourceCheckRunId": source_check_id,
        "callerRepositoryId": args.caller_repository_id, "publisherEnvironment": args.publisher_environment,
        "environmentPolicyDigest": args.environment_policy_digest,
    }


def prepare(args: argparse.Namespace) -> None:
    receipt = build_receipt(args)
    args.output.write_bytes(canonical_bytes(receipt))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write(f"head={receipt['headCommit']}\nreceipt-digest={canonical_digest(receipt)}\n")


def build_claim(receipt: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    if args.installation_id != args.expected_installation_id:
        raise ValueError("publisher installation differs immutable reviewed target")
    claim = {key: receipt[key] for key in ("repositoryId", "repository", "pullRequest", "headCommit", "headTree", "reviewedHead", "reviewedTree", "patchDigest", "kind", "producerCommit", "producerTree", "producerWorkflowRef", "callerRepositoryId", "publisherEnvironment", "environmentPolicyDigest")}
    claim.update({"artifactId": args.artifact_id, "artifactDigest": args.artifact_digest,
                  "receiptDigest": canonical_digest(receipt), "workflowRunId": receipt["workflowRunId"],
                  "workflowRunAttempt": receipt["workflowRunAttempt"], "publisherInstallationId": args.installation_id})
    return claim


def verify_bundle(archive: bytes, artifact_digest: str, claim: dict[str, Any]) -> dict[str, Any]:
    if "sha256:" + hashlib.sha256(archive).hexdigest() != artifact_digest or claim.get("artifactDigest") != artifact_digest:
        raise ValueError("downloaded review artifact digest differs")
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            members = [item for item in bundle.infolist() if not item.is_dir()]
            if len(members) != 1 or members[0].filename != "review-receipt.json" or members[0].file_size > 65536:
                raise ValueError("review artifact has ambiguous evidence")
            receipt_bytes = bundle.read(members[0])
        receipt = json.loads(receipt_bytes)
    except (zipfile.BadZipFile, KeyError, json.JSONDecodeError) as error:
        raise ValueError("review artifact is malformed") from error
    if receipt_bytes != canonical_bytes(receipt) or claim.get("receiptDigest") != canonical_digest(receipt):
        raise ValueError("review receipt canonical digest differs")
    for field in ("repositoryId", "repository", "pullRequest", "headCommit", "headTree", "reviewedHead", "reviewedTree", "patchDigest", "kind", "producerCommit", "producerTree", "producerWorkflowRef", "callerRepositoryId", "publisherEnvironment", "environmentPolicyDigest"):
        if claim.get(field) != receipt.get(field):
            raise ValueError("review claim and receipt source differ")
    return receipt


def verify_gate_authority(kind: str, check: dict[str, Any], expected: dict[str, Any], api_get: Callable[[str], bytes]) -> dict[str, Any]:
    if check.get("name") != expected["checkName"] or check.get("app", {}).get("id") != expected["appId"] or check.get("status") != "completed" or check.get("conclusion") != "success":
        raise ValueError("trusted check authority differs")
    try:
        claim = json.loads(check["output"]["summary"])
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError("trusted check claim is malformed") from error
    for field in ("repositoryId", "repository", "pullRequest", "headCommit", "headTree", "reviewedHead", "reviewedTree", "patchDigest", "kind", "callerRepositoryId", "publisherEnvironment", "environmentPolicyDigest"):
        if claim.get(field) != expected[field]:
            raise ValueError("trusted check source differs")
    if claim.get("publisherInstallationId") != expected["installationId"] or claim.get("producerCommit") != expected["contractRef"] or claim.get("producerWorkflowRef") != expected["producerWorkflowRef"]:
        raise ValueError("trusted publisher authority differs")
    workflow = json.loads(api_get(f"repos/{expected['repository']}/actions/runs/{claim['workflowRunId']}"))
    if workflow.get("head_sha") != expected["headCommit"] or workflow.get("path") != expected["workflowPath"] or workflow.get("event") != "workflow_dispatch" or workflow.get("status") != "completed" or workflow.get("conclusion") != "success" or workflow.get("run_attempt") != claim.get("workflowRunAttempt"):
        raise ValueError("trusted workflow authority differs")
    artifacts = json.loads(api_get(f"repos/{expected['repository']}/actions/runs/{claim['workflowRunId']}/artifacts"))["artifacts"]
    artifact = next((item for item in artifacts if item.get("id") == claim.get("artifactId")), None)
    if not artifact or artifact.get("expired") or artifact.get("digest") != claim.get("artifactDigest"):
        raise ValueError("trusted artifact authority differs")
    receipt = verify_bundle(api_get(f"repos/{expected['repository']}/actions/artifacts/{artifact['id']}/zip"), artifact["digest"], claim)
    if kind in ("code", "security"):
        reviews = json.loads(api_get(f"repos/{expected['repository']}/pulls/{expected['pullRequest']}/reviews?per_page=100"))
        review = next((item for item in reviews if item.get("id") == receipt.get("reviewId")), None)
        if not review or review.get("state") != "APPROVED" or review.get("commit_id") != expected["reviewedHead"] or review.get("user", {}).get("id") != receipt.get("principalId"):
            raise ValueError("exact-head review authority differs")
    else:
        source = json.loads(api_get(f"repos/{expected['repository']}/check-runs/{receipt['sourceCheckRunId']}"))
        if source.get("head_sha") != expected["reviewedHead"] or source.get("status") != "completed" or source.get("conclusion") != "success" or source.get("name") != expected["sourceCheckName"] or source.get("app", {}).get("id") != expected["sourceAppId"]:
            raise ValueError("AI source authority differs")
    return receipt


def publish(args: argparse.Namespace) -> None:
    receipt = json.loads(args.receipt.read_bytes())
    claim = build_claim(receipt, args)
    body = {"name": args.check_name, "head_sha": receipt["headCommit"], "status": "completed", "conclusion": "success",
            "output": {"title": args.check_name, "summary": json.dumps(claim, sort_keys=True, separators=(",", ":"))}}
    github_api(f"repos/{args.repository}/check-runs", "POST", body)


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--kind", choices=("code", "security", "ai"), required=True)
    p.add_argument("--repository", required=True); p.add_argument("--pull-request", type=int, required=True)
    p.add_argument("--review-id", type=int); p.add_argument("--source-check-run-id", type=int)
    p.add_argument("--source-check-name"); p.add_argument("--source-app-id", type=int)
    p.add_argument("--producer-commit", required=True); p.add_argument("--producer-workflow-ref", required=True); p.add_argument("--workflow-run-id", type=int, required=True)
    p.add_argument("--deployment-commit", required=True); p.add_argument("--deployment-ref", required=True)
    p.add_argument("--caller-repository-id", type=int, required=True); p.add_argument("--publisher-environment", required=True); p.add_argument("--environment-policy-digest", required=True)
    p.add_argument("--workflow-run-attempt", type=int, required=True); p.add_argument("--actor", required=True)
    p.add_argument("--triggering-actor", required=True); p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("publish")
    p.add_argument("--repository", required=True); p.add_argument("--check-name", required=True)
    p.add_argument("--receipt", type=Path, required=True); p.add_argument("--artifact-id", type=int, required=True)
    p.add_argument("--artifact-digest", required=True); p.add_argument("--installation-id", type=int, required=True)
    p.add_argument("--expected-installation-id", type=int, required=True)
    args = parser.parse_args()
    (prepare if args.command == "prepare" else publish)(args)


if __name__ == "__main__":
    main()
