#!/usr/bin/env python3

import argparse
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
