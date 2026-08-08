#!/usr/bin/env python3

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


class PreflightError(ValueError):
    pass


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
    for field in ("attemptId", "action", "selectedRelease", "observedDeployedRelease"):
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


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fail closed on unsafe production deployment authorization"
    )
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    try:
        value = json.loads(args.evidence.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise PreflightError("evidence must be a JSON object")
        validate_authorization(value)
    except (OSError, json.JSONDecodeError, PreflightError) as error:
        print(f"container deployment preflight rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
