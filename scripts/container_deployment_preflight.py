#!/usr/bin/env python3

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


class PreflightError(ValueError):
    pass


DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
SCHEMA_PATHS = (
    Path(__file__).with_name("deployment-receipt.schema.json"),
    Path(__file__).parent.parent
    / "docs/decisions/0078-container-release-and-runner-deployment-contract"
    / "deployment-receipt.schema.json",
)


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


def _schema() -> dict[str, Any]:
    for path in SCHEMA_PATHS:
        if path.is_file():
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise PreflightError(f"cannot load deployment receipt schema: {error}") from error
            if isinstance(value, dict):
                return value
    raise PreflightError("deployment receipt schema is unavailable")


def _matches_type(value: Any, expected: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "null": value is None,
        "boolean": isinstance(value, bool),
    }.get(expected, False)


def _validate_schema(value: Any, rule: dict[str, Any], root: dict[str, Any], path: str) -> None:
    if "$ref" in rule:
        reference = rule["$ref"]
        if not isinstance(reference, str) or not reference.startswith("#/"):
            raise PreflightError(f"unsupported schema reference at {path}")
        target: Any = root
        for part in reference[2:].split("/"):
            target = target.get(part) if isinstance(target, dict) else None
        if not isinstance(target, dict):
            raise PreflightError(f"unresolved schema reference at {path}")
        _validate_schema(value, target, root, path)
        return
    if "oneOf" in rule:
        matches = 0
        for candidate in rule["oneOf"]:
            try:
                _validate_schema(value, candidate, root, path)
                matches += 1
            except PreflightError:
                pass
        if matches != 1:
            raise PreflightError(f"{path} does not match exactly one allowed shape")
    if "const" in rule and value != rule["const"]:
        raise PreflightError(f"{path} differs from its required value")
    if "enum" in rule and value not in rule["enum"]:
        raise PreflightError(f"{path} is not an allowed value")
    expected = rule.get("type")
    if isinstance(expected, str) and not _matches_type(value, expected):
        raise PreflightError(f"{path} must be {expected}")
    if isinstance(value, dict):
        required = rule.get("required", [])
        if any(field not in value for field in required):
            raise PreflightError(f"{path} is missing required fields")
        properties = rule.get("properties", {})
        if rule.get("additionalProperties") is False and set(value) - set(properties):
            raise PreflightError(f"{path} contains unrecognized fields")
        for field, child in properties.items():
            if field in value:
                _validate_schema(value[field], child, root, f"{path}.{field}")
    if isinstance(value, list):
        if len(value) < rule.get("minItems", 0) or len(value) > rule.get("maxItems", sys.maxsize):
            raise PreflightError(f"{path} has an invalid number of items")
        if isinstance(rule.get("items"), dict):
            for index, item in enumerate(value):
                _validate_schema(item, rule["items"], root, f"{path}[{index}]")
    if isinstance(value, str):
        if len(value) < rule.get("minLength", 0):
            raise PreflightError(f"{path} is too short")
        if "pattern" in rule and re.fullmatch(rule["pattern"], value) is None:
            raise PreflightError(f"{path} has an invalid format")
        if rule.get("format") == "date-time":
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError as error:
                raise PreflightError(f"{path} must be an RFC 3339 timestamp") from error
            if parsed.tzinfo is None:
                raise PreflightError(f"{path} must include a timezone")
    if (
        isinstance(value, int)
        and not isinstance(value, bool)
        and value < rule.get("minimum", value)
    ):
        raise PreflightError(f"{path} is below its minimum")
    for candidate in rule.get("allOf", []):
        condition = candidate.get("if")
        applies = True
        if isinstance(condition, dict):
            try:
                _validate_schema(value, condition, root, path)
            except PreflightError:
                applies = False
        selected = candidate.get("then" if applies else "else")
        if isinstance(selected, dict):
            _validate_schema(value, selected, root, path)


def validate_attempt_revision(
    revision: dict[str, Any], previous: dict[str, Any]
) -> None:
    for field in (
        "attemptId",
        "action",
        "deploymentContractCommit",
        "headCommit",
        "planDigest",
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
    if revision.get("revision") != previous.get("revision", -1) + 1:
        raise PreflightError("attempt revision is not the next append-only revision")


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
    schema = _schema()
    _validate_schema(receipt, schema, schema, "receipt")
    outcome = receipt.get("outcome")
    failure = receipt.get("failure")
    if (outcome in ("failed", "interrupted")) != (
        isinstance(failure, str) and bool(failure)
    ):
        raise PreflightError("deployment receipt failure does not match outcome")
    authorization = receipt["authorization"]
    if authorization["dispatcher"] == authorization["reviewer"]:
        raise PreflightError("deployment receipt authority permits self review")

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
        or receipt.get("revision") != 0
        or receipt.get("previousReceiptDigest") is not None
        or receipt.get("completedAt") is not None
    ):
        raise PreflightError("admitted receipt must precede every mutation")
    if outcome == "in_progress" and receipt.get("completedAt") is not None:
        raise PreflightError("in-progress receipt cannot be complete")
    if outcome in ("succeeded", "failed", "interrupted") and receipt.get("completedAt") is None:
        raise PreflightError("terminal receipt must have a completion timestamp")
    if outcome != "admitted" and not isinstance(receipt.get("previousReceiptDigest"), str):
        raise PreflightError("receipt revision does not bind previous receipt")
    for entry in runners:
        if entry.get("state") == "unknown":
            if (
                entry.get("beforeDigest") is not None
                or entry.get("afterDigest") is not None
                or entry.get("afterRelease") is not None
            ):
                raise PreflightError("unknown runner transition claims an actual release")
        elif (
            entry.get("beforeDigest") is None
            or entry.get("afterDigest") is None
            or entry.get("afterRelease") is None
        ):
            raise PreflightError("verified runner transition omits its actual release")
        if entry.get("probe") == "not_run" and entry.get("completedAt") is not None:
            raise PreflightError("unprobed runner transition cannot be complete")
    final_by_name = {entry["name"]: entry for entry in final_fleet}
    for entry in final_fleet:
        if (entry.get("state") == "unknown") != (entry.get("release") is None):
            raise PreflightError("final fleet state and release disagree")
    for transition in runners:
        final = final_by_name[transition["name"]]
        if transition["state"] == "unknown":
            if final != {"name": transition["name"], "release": None, "state": "unknown"}:
                raise PreflightError("unknown transition is not reflected in final fleet")
        elif final.get("release") != transition.get("afterRelease"):
            raise PreflightError("runner transition and final fleet release disagree")
    if outcome == "succeeded":
        if set(runner_names) != set(final_names) or any(
            entry.get("probe") != "passed" for entry in runners
        ):
            raise PreflightError("successful receipt does not verify every fleet runner")
        if any(
            entry.get("release") != receipt.get("selectedRelease")
            or entry.get("state") != "verified"
            for entry in final_fleet
        ):
            raise PreflightError("successful receipt final fleet differs from selected release")


def validate_receipt_chain(receipts: list[dict[str, Any]]) -> None:
    if not receipts:
        raise PreflightError("receipt chain is empty")
    for index, receipt in enumerate(receipts):
        validate_receipt(receipt)
        if receipt.get("revision") != index:
            raise PreflightError("receipt chain revisions are not contiguous")
        if index:
            validate_attempt_revision(receipt, receipts[index - 1])


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
