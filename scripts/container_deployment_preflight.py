#!/usr/bin/env python3

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


class PreflightError(ValueError):
    pass


DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")


def _text(evidence: dict[str, Any], field: str) -> str:
    value = evidence.get(field)
    if not isinstance(value, str) or not value:
        raise PreflightError(f"{field} must be a non-empty string")
    return value


def validate_authorization(evidence: dict[str, Any]) -> None:
    default_branch = _text(evidence, "defaultBranch")
    if evidence.get("ref") != f"refs/heads/{default_branch}":
        raise PreflightError("deployment ref is not the exact default branch")
    if evidence.get("environment") != "production":
        raise PreflightError("deployment environment must be production")

    branch_policy = evidence.get("deploymentBranchPolicy")
    if not isinstance(branch_policy, dict):
        raise PreflightError("deploymentBranchPolicy must be an object")
    if branch_policy.get("protectedBranches") is not True:
        raise PreflightError("production must admit protected branches only")
    if branch_policy.get("customBranchPolicies") is not False:
        raise PreflightError("production must not admit custom branch policies")
    if evidence.get("preventSelfReview") is not True:
        raise PreflightError("production must prevent self review")
    if evidence.get("canAdminsBypass") is not False:
        raise PreflightError("production must disable administrator bypass")

    required_reviewers = evidence.get("requiredReviewers")
    if not isinstance(required_reviewers, list) or not required_reviewers:
        raise PreflightError("production must have a required reviewer")
    if any(
        not isinstance(reviewer, dict)
        or reviewer.get("type") not in ("User", "Team")
        or not isinstance(reviewer.get("id"), int)
        or reviewer["id"] < 1
        for reviewer in required_reviewers
    ):
        raise PreflightError("required reviewer evidence is malformed")
    dispatcher = _text(evidence, "dispatcher")
    reviewer = _text(evidence, "reviewer")
    if reviewer == dispatcher:
        raise PreflightError("deployment reviewer must differ from dispatcher")
    if evidence.get("reviewerSatisfiedRequiredRule") is not True:
        raise PreflightError("deployment review did not satisfy a required reviewer rule")


def receipt_digest(receipt: dict[str, Any]) -> str:
    encoded = json.dumps(
        receipt, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def validate_attempt_revision(
    revision: dict[str, Any], previous: dict[str, Any]
) -> None:
    for field in (
        "attemptId",
        "action",
        "deploymentContractCommit",
        "environment",
        "manifestIdentity",
        "fleetSelector",
        "canaryRunner",
        "selectedRelease",
        "observedDeployedRelease",
        "rollbackOfAttempt",
        "authorization",
        "observedAt",
        "startedAt",
    ):
        if revision.get(field) != previous.get(field):
            raise PreflightError(f"attempt revision changes immutable {field}")
    if revision.get("previousReceiptDigest") != receipt_digest(previous):
        raise PreflightError("attempt revision does not bind the previous receipt")


def validate_rollback(
    rollback_receipt: dict[str, Any], source_attempt: dict[str, Any]
) -> None:
    if rollback_receipt.get("action") != "rollback":
        raise PreflightError("receipt is not a rollback")
    if source_attempt.get("outcome") not in ("failed", "interrupted"):
        raise PreflightError("rollback source attempt must be failed or interrupted")
    observed = source_attempt.get("observedDeployedRelease")
    if not isinstance(observed, dict):
        raise PreflightError("rollback source attempt has no observed deployed baseline")
    if rollback_receipt.get("selectedRelease") != observed:
        raise PreflightError("rollback selected release differs from attempt baseline")
    source = rollback_receipt.get("rollbackOfAttempt")
    if not isinstance(source, dict):
        raise PreflightError("rollback does not identify its source attempt")
    if source.get("attemptId") != source_attempt.get("attemptId"):
        raise PreflightError("rollback source attempt identity differs")
    if source.get("receiptDigest") != receipt_digest(source_attempt):
        raise PreflightError("rollback source attempt digest differs")


def validate_receipt(receipt: dict[str, Any]) -> None:
    required = {
        "schemaVersion",
        "attemptId",
        "action",
        "deploymentContractCommit",
        "outcome",
        "environment",
        "manifestIdentity",
        "fleetSelector",
        "canaryRunner",
        "selectedRelease",
        "observedDeployedRelease",
        "previousReceiptDigest",
        "rollbackOfAttempt",
        "authorization",
        "runners",
        "finalFleet",
        "failure",
        "observedAt",
        "startedAt",
        "completedAt",
    }
    if set(receipt) != required:
        raise PreflightError("deployment receipt fields differ from schema version 2")
    if receipt.get("schemaVersion") != 2:
        raise PreflightError("deployment receipt schemaVersion must be 2")
    if not isinstance(receipt.get("deploymentContractCommit"), str) or re.fullmatch(
        r"[0-9a-f]{40}", receipt["deploymentContractCommit"]
    ) is None:
        raise PreflightError("deployment receipt contract commit is invalid")
    if receipt.get("environment") != "production":
        raise PreflightError("deployment receipt environment must be production")
    if receipt.get("action") not in ("deploy", "rollback"):
        raise PreflightError("deployment receipt action is invalid")
    outcome = receipt.get("outcome")
    if outcome not in ("admitted", "in_progress", "succeeded", "failed", "interrupted"):
        raise PreflightError("deployment receipt outcome is invalid")
    failure = receipt.get("failure")
    if (outcome in ("failed", "interrupted")) != (
        isinstance(failure, str) and bool(failure)
    ):
        raise PreflightError("deployment receipt failure does not match outcome")

    runners = receipt.get("runners")
    final_fleet = receipt.get("finalFleet")
    if not isinstance(runners, list) or not isinstance(final_fleet, list) or not final_fleet:
        raise PreflightError("deployment receipt fleet evidence is malformed")
    runner_names = [entry.get("name") for entry in runners if isinstance(entry, dict)]
    final_names = [entry.get("name") for entry in final_fleet if isinstance(entry, dict)]
    if len(runner_names) != len(runners) or len(set(runner_names)) != len(runner_names):
        raise PreflightError("deployment receipt repeats a runner transition")
    if len(final_names) != len(final_fleet) or len(set(final_names)) != len(final_names):
        raise PreflightError("deployment receipt final fleet has duplicate runners")
    if not set(runner_names).issubset(set(final_names)):
        raise PreflightError("deployment receipt transition is outside final fleet")
    if runners and runner_names[0] != receipt.get("canaryRunner"):
        raise PreflightError("deployment receipt first transition is not the canary")
    if outcome == "admitted" and (
        runners
        or receipt.get("previousReceiptDigest") is not None
        or receipt.get("completedAt") is not None
    ):
        raise PreflightError("admitted receipt must precede every mutation")
    if outcome != "admitted" and not isinstance(receipt.get("previousReceiptDigest"), str):
        raise PreflightError("receipt revision does not bind previous receipt")
    for entry in runners:
        if entry.get("probe") not in ("passed", "failed"):
            raise PreflightError("runner transition probe outcome is invalid")
        for field in ("beforeDigest", "afterDigest"):
            if (
                not isinstance(entry.get(field), str)
                or DIGEST_PATTERN.fullmatch(entry[field]) is None
            ):
                raise PreflightError(f"runner transition {field} is invalid")
    if outcome == "succeeded":
        if set(runner_names) != set(final_names) or any(
            entry.get("probe") != "passed" for entry in runners
        ):
            raise PreflightError("successful receipt does not verify every fleet runner")
        if any(entry.get("release") != receipt.get("selectedRelease") for entry in final_fleet):
            raise PreflightError("successful receipt final fleet differs from selected release")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fail closed on unsafe production deployment authorization"
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--evidence", type=Path)
    source.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    try:
        path = args.evidence or args.receipt
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise PreflightError("evidence must be a JSON object")
        if args.receipt:
            validate_receipt(value)
        else:
            validate_authorization(value)
    except (OSError, json.JSONDecodeError, PreflightError) as error:
        print(f"container deployment preflight rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
