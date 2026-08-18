#!/usr/bin/env python3

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from container_deployment_preflight import (
    receipt_digest,
    validate_attempt_revision,
    validate_receipt,
    validate_receipt_chain,
    validate_rollback,
)


DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
MANIFEST_IDENTITY = re.compile(r"(?P<digest>sha256:[0-9a-f]{64})")
MAX_DRAIN_SECONDS = 1_800
MAX_PROBE_SECONDS = 900
MAX_OBSERVATION_SECONDS = 900
MAX_REQUEST_AGE_SECONDS = 3_600
MAX_FLEET_SIZE = 3
JOB_SECONDS = 5_400
SAFETY_MARGIN_SECONDS = 900
UPDATE_COMMAND_OVERHEAD_SECONDS = 120
POST_UPDATE_EVIDENCE_SECONDS = 120
CAPACITY_EVIDENCE_SECONDS = 120
ADMISSION_EVIDENCE_SECONDS = 120
PROBE_COMMAND_OVERHEAD_SECONDS = 30
MAX_ADAPTER_JSON_SECONDS = MAX_PROBE_SECONDS + PROBE_COMMAND_OVERHEAD_SECONDS


class DeploymentError(ValueError):
    pass


class DeploymentInterrupted(DeploymentError):
    pass


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DeploymentError(f"{field} must be an object")
    return value


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise DeploymentError(f"{field} must be a non-empty string")
    return value


def _safe_token(value: Any, field: str, pattern: str) -> str:
    token = _text(value, field)
    if token.startswith("-") or re.fullmatch(pattern, token) is None:
        raise DeploymentError(f"{field} must be a non-option safe token")
    return token


def canonical_digest(value: dict[str, Any]) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def retained_authority_digest(
    plan: dict[str, Any], receipts: list[dict[str, Any]]
) -> str:
    return canonical_digest({"plan": plan, "revisions": receipts})


def _load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DeploymentError(f"cannot read JSON from {path}: {error}") from error
    return _object(value, str(path))


def _write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(encoded, encoding="utf-8")
    temporary.replace(path)


def _command(config: dict[str, Any], field: str) -> list[str]:
    value = config.get(field)
    if (
        not isinstance(value, list)
        or len(value) != 2
        or value[0] != "python3"
        or not isinstance(value[1], str)
        or re.fullmatch(r"scripts/[A-Za-z0-9_.-]+\.py", value[1]) is None
    ):
        raise DeploymentError(f"{field} must be ['python3', 'scripts/<reviewed>.py']")
    return list(value)


def _release(version: Any, manifest_digest: Any, field: str) -> dict[str, str]:
    if not isinstance(version, str) or re.fullmatch(
        r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version
    ) is None:
        raise DeploymentError(f"{field} releaseVersion must be stable SemVer")
    if not isinstance(manifest_digest, str) or DIGEST.fullmatch(manifest_digest) is None:
        raise DeploymentError(f"{field} manifestDigest must be an immutable digest")
    return {"releaseVersion": version, "manifestDigest": manifest_digest}


def _validate_release_evidence(
    expected: dict[str, Any],
    evidence: dict[str, Any],
    identity_match: re.Match[str],
    now: datetime,
) -> tuple[dict[str, str], str]:
    attestation = _object(evidence.get("attestation"), "attestation")
    if attestation.get("verified") is not True:
        raise DeploymentError("release attestation is not verified")
    if attestation.get("repository") != expected.get("sourceRepository"):
        raise DeploymentError("release attestation source repository differs")
    if attestation.get("sourceRef") != expected.get("sourceRef"):
        raise DeploymentError("release attestation source ref differs")
    if attestation.get("signerWorkflow") != expected.get("signerWorkflow"):
        raise DeploymentError("release attestation signer differs")
    if attestation.get("contractCommit") != expected.get("contractCommit"):
        raise DeploymentError("release attestation contract pin differs")
    if attestation.get("subjectDigest") != identity_match.group("digest"):
        raise DeploymentError("release attestation subject digest differs")
    expires_at = _date_time(attestation.get("expiresAt"), "attestation.expiresAt")
    if expires_at <= now:
        raise DeploymentError("release attestation is expired")

    manifest = _object(evidence.get("manifest"), "manifest")
    if canonical_digest(manifest) != identity_match.group("digest"):
        raise DeploymentError("canonical manifest bytes differ from manifest identity")
    source = _object(manifest.get("source"), "manifest.source")
    if source.get("repository") != expected.get("sourceRepository"):
        raise DeploymentError("manifest source repository differs")
    release_evidence = _object(manifest.get("release"), "manifest.release")
    workflow = _object(release_evidence.get("workflow"), "manifest.release.workflow")
    signer_workflow = str(expected.get("signerWorkflow", ""))
    marker = "/.github/workflows/"
    expected_path = (
        ".github/workflows/" + signer_workflow.split(marker, 1)[1]
        if marker in signer_workflow
        else ""
    )
    if workflow.get("path") != expected_path:
        raise DeploymentError("manifest signer workflow differs")
    if workflow.get("contractCommit") != expected.get("contractCommit"):
        raise DeploymentError("manifest release contract pin differs")

    images = manifest.get("images")
    variant = expected.get("variant")
    if not isinstance(images, list) or sum(
        1 for image in images if isinstance(image, dict) and image.get("variant") == variant
    ) != 1:
        raise DeploymentError("manifest must contain exactly one reviewed release variant")
    selected_image = next(
        image for image in images if isinstance(image, dict) and image.get("variant") == variant
    )
    target_digest = selected_image.get("indexDigest")
    if not isinstance(target_digest, str) or DIGEST.fullmatch(target_digest) is None:
        raise DeploymentError("selected release variant has no immutable image digest")
    return (
        _release(
            manifest.get("releaseVersion"),
            identity_match.group("digest"),
            "selectedRelease",
        ),
        target_digest,
    )


def _release_variant_digest(
    manifest_value: Any,
    release: dict[str, Any],
    variant: str,
    field: str,
) -> str:
    manifest = _object(manifest_value, field)
    if canonical_digest(manifest) != release.get("manifestDigest"):
        raise DeploymentError(f"{field} canonical bytes differ from release identity")
    if manifest.get("releaseVersion") != release.get("releaseVersion"):
        raise DeploymentError(f"{field} version differs from release identity")
    images = manifest.get("images")
    if not isinstance(images, list) or sum(
        1 for image in images if isinstance(image, dict) and image.get("variant") == variant
    ) != 1:
        raise DeploymentError(f"{field} must contain exactly one reviewed release variant")
    selected_image = next(
        image for image in images if isinstance(image, dict) and image.get("variant") == variant
    )
    digest = selected_image.get("indexDigest")
    if not isinstance(digest, str) or DIGEST.fullmatch(digest) is None:
        raise DeploymentError(f"{field} release variant has no immutable image digest")
    return digest


def _date_time(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise DeploymentError(f"{field} must be an RFC 3339 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise DeploymentError(f"{field} must be an RFC 3339 timestamp") from error
    if parsed.tzinfo is None:
        raise DeploymentError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _validate_policy(fleet: dict[str, Any]) -> None:
    _safe_token(fleet.get("lane"), "lane", r"[a-z][a-z0-9-]{1,29}")
    _safe_token(fleet.get("project"), "project", r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
    bounds = (
        ("drainTimeoutSeconds", MAX_DRAIN_SECONDS),
        ("probeTimeoutSeconds", MAX_PROBE_SECONDS),
        ("observationSeconds", MAX_OBSERVATION_SECONDS),
    )
    for field, maximum in bounds:
        value = fleet.get(field)
        if not isinstance(value, int) or value < 1 or value > maximum:
            raise DeploymentError(f"{field} must be between 1 and {maximum}")
    for field in ("requiredLabels", "requiredTools"):
        values = fleet.get(field)
        if (
            not isinstance(values, list)
            or not values
            or any(not isinstance(value, str) or not value for value in values)
            or len(set(values)) != len(values)
        ):
            raise DeploymentError(f"{field} must declare unique values")
    _safe_token(
        fleet.get("runnerGroup"),
        "runnerGroup",
        r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,99}",
    )
    runners = fleet.get("runners")
    if not isinstance(runners, list) or len(runners) > MAX_FLEET_SIZE:
        raise DeploymentError(f"fleet may contain at most {MAX_FLEET_SIZE} runners")
    worst_case = MAX_FLEET_SIZE * ADMISSION_EVIDENCE_SECONDS + len(runners) * (
        CAPACITY_EVIDENCE_SECONDS
        + fleet["drainTimeoutSeconds"]
        + UPDATE_COMMAND_OVERHEAD_SECONDS
        + POST_UPDATE_EVIDENCE_SECONDS
        + fleet["probeTimeoutSeconds"]
        + PROBE_COMMAND_OVERHEAD_SECONDS
    ) + fleet["observationSeconds"]
    if worst_case >= JOB_SECONDS - SAFETY_MARGIN_SECONDS:
        raise DeploymentError("reviewed fleet timing leaves less than the required job margin")


def _validate_commands(config: dict[str, Any]) -> None:
    _command(config, "evidenceCommand")
    _command(config, "probeCommand")
    if config.get("cliCommand") != ["verjson-cloud"]:
        raise DeploymentError("cliCommand must select the contract-acquired verjson-cloud executable")


def _deployment_cli() -> str:
    raw_path = os.environ.get("VERJSON_DEPLOYMENT_CLI")
    raw_root = os.environ.get("VERJSON_DEPLOYMENT_CLI_ROOT")
    if not raw_path or not raw_root:
        raise DeploymentError("contract-acquired verjson-cloud executable is unavailable")
    path = Path(raw_path)
    root = Path(raw_root)
    try:
        resolved_path = path.resolve(strict=True)
        resolved_root = root.resolve(strict=True)
        resolved_path.relative_to(resolved_root)
    except (OSError, ValueError) as error:
        raise DeploymentError("deployment CLI escapes its immutable acquisition root") from error
    if not path.is_absolute() or not root.is_absolute() or not os.access(path, os.X_OK):
        raise DeploymentError("contract-acquired verjson-cloud executable is invalid")
    return str(path)


def _validate_inventory(
    fleet: dict[str, Any],
    evidence: dict[str, Any],
    rollback_source: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, str], str]:
    inventory = _object(evidence.get("fleet"), "fleet evidence").get("runners")
    expected_names = fleet.get("runners")
    if not isinstance(inventory, list) or not isinstance(expected_names, list):
        raise DeploymentError("fleet inventory must be an array")
    actual_names = [runner.get("name") for runner in inventory if isinstance(runner, dict)]
    if len(actual_names) != len(inventory) or set(actual_names) != set(expected_names):
        raise DeploymentError("observed fleet inventory differs from reviewed configuration")
    if any(
        runner.get("online") is not True or runner.get("admitted") is not True
        for runner in inventory
    ):
        raise DeploymentError("every runner must be online and admitted before rollout")

    baseline_values = [runner.get("release") for runner in inventory]
    if rollback_source is None:
        if not baseline_values or any(value != baseline_values[0] for value in baseline_values):
            raise DeploymentError("fleet has an unexpected mixed deployed baseline")
        baseline = _object(baseline_values[0], "fleet baseline")
    else:
        recorded_final = rollback_source.get("finalFleet")
        if not isinstance(recorded_final, list):
            raise DeploymentError("rollback source has no recorded final fleet")
        recorded_by_name = {
            runner.get("name"): runner.get("release")
            for runner in recorded_final
            if isinstance(runner, dict)
        }
        if set(recorded_by_name) != set(expected_names) or any(
            runner.get("release") != recorded_by_name.get(runner.get("name"))
            for runner in inventory
        ):
            raise DeploymentError("live fleet differs from rollback source final state")
        baseline = _object(
            rollback_source.get("observedDeployedRelease"),
            "rollback source observed baseline",
        )
    observed = _release(
        baseline.get("releaseVersion"), baseline.get("manifestDigest"), "fleet baseline"
    )
    for runner in inventory:
        runner_release = _object(runner.get("release"), "runner release")
        runner_identity = _text(runner.get("manifestIdentity"), "runner manifestIdentity")
        match = MANIFEST_IDENTITY.fullmatch(runner_identity)
        if match is None or match.group("digest") != runner_release.get("manifestDigest"):
            raise DeploymentError("fleet runner manifest identity is not immutable")
    if rollback_source is None:
        baseline_identity = inventory[0]["manifestIdentity"]
    else:
        baseline_identity = _text(evidence.get("manifestIdentity"), "rollback manifestIdentity")

    minimum_available = fleet.get("minimumAvailable")
    if (
        not isinstance(minimum_available, int)
        or minimum_available < 1
        or len(inventory) - 1 < minimum_available
    ):
        raise DeploymentError("sequential update would violate minimum fleet capacity")
    return inventory, observed, baseline_identity


def build_plan(
    config: dict[str, Any],
    evidence: dict[str, Any],
    fleet_selector: str,
    *,
    now: datetime | None = None,
    action: str = "deploy",
    rollback_source: dict[str, Any] | None = None,
    deployment_contract_ref: str = "0000000000000000000000000000000000000000",
) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    _validate_commands(config)
    if re.fullmatch(r"[0-9a-f]{40}", deployment_contract_ref) is None:
        raise DeploymentError("deployment contract ref must be an immutable commit")
    expected = _object(config.get("expectedRelease"), "expectedRelease")
    _safe_token(
        expected.get("variant"),
        "expectedRelease.variant",
        r"[a-z0-9][a-z0-9._-]{0,63}",
    )
    _safe_token(fleet_selector, "fleet selector", r"[a-z][a-z0-9_-]{1,31}")
    identity = _text(evidence.get("manifestIdentity"), "manifestIdentity")
    identity_match = MANIFEST_IDENTITY.fullmatch(identity)
    if identity_match is None:
        raise DeploymentError("manifestIdentity must be an immutable digest reference")
    selected_release, target_digest = _validate_release_evidence(
        expected, evidence, identity_match, now
    )

    fleets = _object(config.get("fleets"), "fleets")
    fleet = _object(fleets.get(fleet_selector), "fleet selector")
    runners = fleet.get("runners")
    canary = fleet.get("canary")
    if (
        not isinstance(runners, list)
        or not runners
        or any(
            not isinstance(name, str)
            or name.startswith("-")
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name) is None
            for name in runners
        )
        or len(set(runners)) != len(runners)
        or canary not in runners
    ):
        raise DeploymentError("fleet must declare unique runners and one member as canary")
    _validate_policy(fleet)

    requested_at = _date_time(evidence.get("requestedAt"), "requestedAt")
    if requested_at > now or (now - requested_at).total_seconds() > MAX_REQUEST_AGE_SECONDS:
        raise DeploymentError("deployment request is stale")
    if evidence.get("activeDeploymentCount") != 0:
        raise DeploymentError("concurrent deployment is already active")

    _, observed_release, baseline_identity = _validate_inventory(
        fleet, evidence, rollback_source if action == "rollback" else None
    )
    authorization = _object(evidence.get("authorization"), "authorization")
    head_commit = evidence.get("headCommit")
    if not isinstance(head_commit, str) or re.fullmatch(r"[0-9a-f]{40}", head_commit) is None:
        raise DeploymentError("checked-out head commit evidence is invalid")
    run_id = authorization.get("workflowRunId")
    run_attempt = evidence.get("workflowRunAttempt", 1)
    if (
        not isinstance(run_id, int)
        or run_id < 1
        or not isinstance(run_attempt, int)
        or run_attempt < 1
    ):
        raise DeploymentError("workflow run identity is invalid")

    rollback_of = None
    if action == "rollback":
        if rollback_source is None:
            raise DeploymentError("rollback requires a failed or interrupted source attempt")
        candidate = {
            "action": "rollback",
            "selectedRelease": selected_release,
            "rollbackOfAttempt": {
                "attemptId": rollback_source.get("attemptId"),
                "receiptDigest": receipt_digest(rollback_source),
            },
        }
        try:
            validate_rollback(candidate, rollback_source)
        except ValueError as error:
            raise DeploymentError(str(error)) from error
        rollback_of = candidate["rollbackOfAttempt"]
    elif action != "deploy":
        raise DeploymentError("action must be deploy or rollback")

    ordered = [canary, *sorted(name for name in runners if name != canary)]
    return {
        "schemaVersion": 1,
        "fleetSelector": fleet_selector,
        "action": action,
        "attemptId": f"{run_id}.{run_attempt}",
        "deploymentContractCommit": deployment_contract_ref,
        "headCommit": head_commit,
        "manifestIdentity": identity,
        "selectedRelease": selected_release,
        "targetDigest": target_digest,
        "observedDeployedRelease": observed_release,
        "observedManifestIdentity": baseline_identity,
        "rollbackOfAttempt": rollback_of,
        "rolloutMode": "sequential",
        "plannedAt": now.isoformat().replace("+00:00", "Z"),
        "steps": [
            {"runner": runner, "phase": "canary" if index == 0 else "rollout"}
            for index, runner in enumerate(ordered)
        ],
    }


def _timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def admitted_receipt(
    plan: dict[str, Any],
    config: dict[str, Any],
    evidence: dict[str, Any],
    now: datetime,
) -> dict[str, Any]:
    authorization = _object(evidence.get("authorization"), "authorization")
    required_authorization = {
        field: authorization.get(field)
        for field in (
            "dispatcher",
            "reviewer",
            "workflowRunId",
            "environmentProtectionRuleId",
        )
    }
    return {
        "schemaVersion": 3,
        "revision": 0,
        "attemptId": plan["attemptId"],
        "action": plan["action"],
        "outcome": "admitted",
        "environment": "production",
        "selectedRelease": copy.deepcopy(plan["selectedRelease"]),
        "observedDeployedRelease": copy.deepcopy(plan["observedDeployedRelease"]),
        "previousReceiptDigest": None,
        "rollbackOfAttempt": copy.deepcopy(plan["rollbackOfAttempt"]),
        "deploymentContractCommit": plan["deploymentContractCommit"],
        "headCommit": plan["headCommit"],
        "planDigest": canonical_digest(plan),
        "manifestIdentity": plan["manifestIdentity"],
        "fleetSelector": plan["fleetSelector"],
        "canaryRunner": plan["steps"][0]["runner"],
        "authorization": required_authorization,
        "runners": [],
        "finalFleet": [
            {
                "name": runner["name"],
                "release": copy.deepcopy(runner["release"]),
                "state": "verified",
            }
            for runner in evidence["fleet"]["runners"]
        ],
        "failure": None,
        "observedAt": _timestamp(now),
        "startedAt": _timestamp(now),
        "completedAt": None,
    }


def retained_plan(
    config: dict[str, Any],
    evidence: dict[str, Any],
    fleet_selector: str,
    action: str,
    deployment_contract_ref: str,
) -> dict[str, Any] | None:
    plan = evidence.get("retainedPlan")
    retained = evidence.get("retainedRevisions")
    authority = evidence.get("retainedReceiptAuthority")
    if plan is None and retained in (None, []) and authority is None:
        return None
    if not isinstance(plan, dict) or not isinstance(retained, list) or not retained:
        raise DeploymentError("resume evidence omits the exact retained plan or receipt chain")
    try:
        validate_receipt_chain(retained)
    except ValueError as error:
        raise DeploymentError(f"retained receipt chain is invalid: {error}") from error
    latest = retained[-1]
    expected_authority = (
        rf"{re.escape(latest['attemptId'])}/[1-9][0-9]*@"
        + re.escape(retained_authority_digest(plan, retained))
    )
    if not isinstance(authority, str) or re.fullmatch(expected_authority, authority) is None:
        raise DeploymentError("retained receipt authority does not bind the exact chain")
    expected_fields = {
        "attemptId": latest["attemptId"],
        "action": action,
        "deploymentContractCommit": deployment_contract_ref,
        "headCommit": evidence.get("headCommit"),
        "manifestIdentity": evidence.get("manifestIdentity"),
        "fleetSelector": fleet_selector,
        "selectedRelease": latest["selectedRelease"],
        "observedDeployedRelease": latest["observedDeployedRelease"],
    }
    if any(plan.get(field) != value for field, value in expected_fields.items()):
        raise DeploymentError("retained plan differs from current immutable authority")
    if latest.get("planDigest") != canonical_digest(plan):
        raise DeploymentError("retained plan bytes differ from receipt authority")
    fleet = _object(_object(config.get("fleets"), "fleets").get(fleet_selector), "fleet")
    _validate_policy(fleet)
    expected_order = [
        fleet["canary"],
        *sorted(name for name in fleet["runners"] if name != fleet["canary"]),
    ]
    if plan.get("steps") != [
        {"runner": runner, "phase": "canary" if index == 0 else "rollout"}
        for index, runner in enumerate(expected_order)
    ]:
        raise DeploymentError("retained plan runner order differs from reviewed configuration")
    identity = _text(evidence.get("manifestIdentity"), "manifestIdentity")
    identity_match = MANIFEST_IDENTITY.fullmatch(identity)
    if identity_match is None:
        raise DeploymentError("manifestIdentity must be an immutable digest reference")
    expected_release, target_digest = _validate_release_evidence(
        _object(config.get("expectedRelease"), "expectedRelease"),
        evidence,
        identity_match,
        datetime.now(timezone.utc),
    )
    if plan.get("selectedRelease") != expected_release or plan.get("targetDigest") != target_digest:
        raise DeploymentError("retained plan release differs from current attested manifest")
    live_runners = {
        runner.get("name"): runner
        for runner in _object(evidence.get("fleet"), "fleet evidence").get("runners", [])
        if isinstance(runner, dict)
    }
    has_unknown = False
    for runner in latest["finalFleet"]:
        live = live_runners.get(runner.get("name"))
        if not isinstance(live, dict):
            raise DeploymentError("live fleet differs from retained resume state")
        if runner.get("state") == "verified":
            if live.get("release") != runner.get("release"):
                raise DeploymentError("live fleet differs from retained resume state")
            continue
        has_unknown = True
        if live.get("release") not in (
            latest.get("selectedRelease"),
            latest.get("observedDeployedRelease"),
        ) or not isinstance(live.get("deployedDigest"), str) or DIGEST.fullmatch(
            live["deployedDigest"]
        ) is None:
            raise DeploymentError("unknown runner requires exact live reconciliation evidence")
    if latest.get("outcome") not in ("admitted", "in_progress", "interrupted") and not (
        latest.get("outcome") == "failed" and has_unknown
    ):
        raise DeploymentError("retained receipt chain is not resumable")
    return plan


def _next_revision(
    previous: dict[str, Any],
    *,
    outcome: str,
    runners: list[dict[str, Any]],
    completed_at: str | None,
    failure: str | None = None,
) -> dict[str, Any]:
    revision = copy.deepcopy(previous)
    revision["revision"] = previous["revision"] + 1
    revision["outcome"] = outcome
    revision["previousReceiptDigest"] = receipt_digest(previous)
    revision["runners"] = copy.deepcopy(runners)
    revision["completedAt"] = completed_at
    revision["failure"] = failure
    transitions = {runner["name"]: runner for runner in runners}
    for runner in revision["finalFleet"]:
        transition = transitions.get(runner["name"])
        if transition is None:
            continue
        if transition["state"] == "unknown":
            runner["release"] = None
            runner["state"] = "unknown"
        else:
            runner["release"] = copy.deepcopy(transition["afterRelease"])
            runner["state"] = "verified"
    try:
        validate_attempt_revision(revision, previous)
    except ValueError as error:
        raise DeploymentError(str(error)) from error
    return revision


def reconcile_unknown_state(
    plan: dict[str, Any],
    previous: dict[str, Any],
    evidence: dict[str, Any],
    config: dict[str, Any],
) -> dict[str, Any]:
    try:
        validate_receipt(previous)
    except ValueError as error:
        raise DeploymentError(f"reconciliation receipt is invalid: {error}") from error
    if previous.get("outcome") not in ("failed", "interrupted"):
        raise DeploymentError("only a failed or interrupted unknown state can be reconciled")
    unknown_names = {
        runner.get("name")
        for runner in previous.get("runners", [])
        if runner.get("state") == "unknown"
    }
    if not unknown_names:
        raise DeploymentError("receipt has no unknown runner state to reconcile")
    for field in (
        "attemptId",
        "action",
        "deploymentContractCommit",
        "headCommit",
        "manifestIdentity",
        "fleetSelector",
        "selectedRelease",
        "observedDeployedRelease",
    ):
        if previous.get(field) != plan.get(field):
            raise DeploymentError(f"reconciliation changes immutable {field}")
    if previous.get("planDigest") != canonical_digest(plan):
        raise DeploymentError("reconciliation changes immutable plan authority")
    expected_release = _object(config.get("expectedRelease"), "expectedRelease")
    variant = _text(expected_release.get("variant"), "expectedRelease.variant")
    if evidence.get("manifestIdentity") != plan.get("manifestIdentity"):
        raise DeploymentError("reconciliation changes selected manifest identity")
    selected_digest = _release_variant_digest(
        evidence.get("manifest"),
        _object(plan.get("selectedRelease"), "selectedRelease"),
        variant,
        "selected release manifest",
    )
    if selected_digest != plan.get("targetDigest"):
        raise DeploymentError("selected release manifest differs from plan image digest")
    live_runners = {
        runner.get("name"): runner
        for runner in _object(evidence.get("fleet"), "fleet evidence").get("runners", [])
        if isinstance(runner, dict)
    }
    final_names = {runner["name"] for runner in previous["finalFleet"]}
    if set(live_runners) != final_names:
        raise DeploymentError("reconciliation live fleet inventory differs")
    for name, live in live_runners.items():
        live_release = _object(live.get("release"), f"live release for {name}")
        normalized_release = _release(
            live_release.get("releaseVersion"),
            live_release.get("manifestDigest"),
            f"live release for {name}",
        )
        if live_release != normalized_release:
            raise DeploymentError(f"live release for {name} has unrecognized fields")
        live_identity = live.get("manifestIdentity")
        identity_match = (
            MANIFEST_IDENTITY.fullmatch(live_identity)
            if isinstance(live_identity, str)
            else None
        )
        if (
            identity_match is None
            or identity_match.group("digest") != live_release["manifestDigest"]
        ):
            raise DeploymentError(f"live manifest identity for {name} is inconsistent")
    transitions = copy.deepcopy(previous["runners"])
    reconciled: list[dict[str, Any]] = []
    for transition in transitions:
        name = transition["name"]
        live = live_runners[name]
        live_release = live.get("release")
        deployed_digest = live.get("deployedDigest")
        if name not in unknown_names:
            recorded = next(
                runner for runner in previous["finalFleet"] if runner["name"] == name
            )
            if recorded.get("state") != "verified" or live_release != recorded.get("release"):
                raise DeploymentError("verified runner changed during reconciliation")
            reconciled.append(transition)
            continue
        if not isinstance(deployed_digest, str) or DIGEST.fullmatch(deployed_digest) is None:
            raise DeploymentError("unknown runner lacks an immutable live image digest")
        if live_release == plan["selectedRelease"]:
            if live.get("manifestIdentity") != plan.get("manifestIdentity"):
                raise DeploymentError("selected live release identity differs from plan")
            if deployed_digest != selected_digest:
                raise DeploymentError("selected live release has the wrong image digest")
            reconciled.append(
                {
                    "name": name,
                    "beforeDigest": None,
                    "afterDigest": deployed_digest,
                    "afterRelease": copy.deepcopy(live_release),
                    "state": "reconciled",
                    "probe": "not_run",
                    "observation": (
                        "pending" if name == previous["canaryRunner"] else "not_required"
                    ),
                    "completedAt": None,
                }
            )
        elif live_release == previous["observedDeployedRelease"]:
            if live.get("manifestIdentity") != plan.get("observedManifestIdentity"):
                raise DeploymentError("baseline live release identity differs from plan")
            baseline_digest = _release_variant_digest(
                live.get("releaseManifest"),
                _object(plan.get("observedDeployedRelease"), "observedDeployedRelease"),
                variant,
                f"baseline release manifest for {name}",
            )
            if deployed_digest != baseline_digest:
                raise DeploymentError("baseline live release has the wrong image digest")
        else:
            raise DeploymentError("unknown runner is neither selected nor baseline release")
    revision = copy.deepcopy(previous)
    revision["revision"] = previous["revision"] + 1
    revision["outcome"] = "in_progress"
    revision["previousReceiptDigest"] = receipt_digest(previous)
    revision["runners"] = reconciled
    revision["finalFleet"] = [
        {
            "name": runner["name"],
            "release": copy.deepcopy(live_runners[runner["name"]]["release"]),
            "state": "verified",
        }
        for runner in previous["finalFleet"]
    ]
    revision["failure"] = None
    revision["completedAt"] = None
    try:
        validate_attempt_revision(revision, previous)
        validate_receipt(revision)
    except ValueError as error:
        raise DeploymentError(f"reconciled receipt is invalid: {error}") from error
    return revision


def execute_plan(
    plan: dict[str, Any],
    config: dict[str, Any],
    evidence: dict[str, Any],
    adapter: Any,
    persist: Any,
    *,
    dry_run: bool = False,
    previous_receipt: dict[str, Any] | None = None,
    max_hosts: int | None = None,
    clock: Any | None = None,
) -> dict[str, Any]:
    if dry_run:
        return plan
    if clock is None:
        clock = type("SystemClock", (), {"now": staticmethod(lambda: datetime.now(timezone.utc))})()

    if previous_receipt is None:
        current = admitted_receipt(plan, config, evidence, clock.now())
        persist(copy.deepcopy(current))
    else:
        current = copy.deepcopy(previous_receipt)
        try:
            validate_receipt(current)
        except ValueError as error:
            raise DeploymentError(f"resume receipt is invalid: {error}") from error
        if current.get("outcome") not in ("admitted", "in_progress", "interrupted"):
            raise DeploymentError("resume receipt is not resumable")
        for field in (
            "attemptId",
            "action",
            "deploymentContractCommit",
            "headCommit",
            "manifestIdentity",
            "fleetSelector",
            "selectedRelease",
            "observedDeployedRelease",
        ):
            expected = plan[field]
            if current.get(field) != expected:
                raise DeploymentError(f"resume changes immutable {field}")
        if current.get("planDigest") != canonical_digest(plan):
            raise DeploymentError("resume changes immutable plan authority")
        live_by_name = {
            runner.get("name"): runner.get("release")
            for runner in _object(evidence.get("fleet"), "fleet evidence").get("runners", [])
            if isinstance(runner, dict)
        }
        for runner in current["finalFleet"]:
            if (
                runner["state"] != "verified"
                or live_by_name.get(runner["name"]) != runner["release"]
            ):
                raise DeploymentError("live fleet differs from retained resume state")

    fleet = config["fleets"][plan["fleetSelector"]]
    completed = copy.deepcopy(current.get("runners", []))
    completed_names = {
        runner.get("name")
        for runner in completed
        if runner.get("probe") == "passed"
        and runner.get("state") in ("updated", "restored", "reconciled")
        and runner.get("afterRelease") == current.get("selectedRelease")
        and runner.get("observation") in ("not_required", "passed")
    }
    target_variant = config["expectedRelease"]["variant"]
    advanced = 0
    for step in plan["steps"]:
        runner = step["runner"]
        if runner in completed_names:
            continue
        if max_hosts is not None and advanced >= max_hosts:
            break
        observation_pending = next(
            (
                transition
                for transition in completed
                if transition.get("name") == runner
                and transition.get("probe") == "passed"
                and transition.get("observation") == "pending"
            ),
            None,
        )
        if observation_pending is not None:
            try:
                adapter.observe(fleet["observationSeconds"])
            except (OSError, RuntimeError) as error:
                failed = _next_revision(
                    current,
                    outcome="interrupted",
                    runners=completed,
                    completed_at=_timestamp(clock.now()),
                    failure=f"canary observation interrupted: {error}",
                )
                persist(copy.deepcopy(failed))
                return failed
            observation_pending["observation"] = "passed"
            observation_pending["completedAt"] = _timestamp(clock.now())
            current = _next_revision(
                current,
                outcome="in_progress",
                runners=completed,
                completed_at=None,
            )
            persist(copy.deepcopy(current))
            advanced += 1
            continue
        pending = next(
            (
                transition
                for transition in completed
                if transition.get("name") == runner
                and transition.get("probe") == "not_run"
                and transition.get("state") in ("updated", "restored", "reconciled")
                and transition.get("afterRelease") == plan["selectedRelease"]
            ),
            None,
        )
        if pending is None:
            try:
                if adapter.available_capacity() - 1 < fleet["minimumAvailable"]:
                    raise DeploymentError("live spare capacity would fall below policy floor")
            except (DeploymentError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                failed = _next_revision(
                    current,
                    outcome="failed",
                    runners=completed,
                    completed_at=_timestamp(clock.now()),
                    failure=str(error),
                )
                persist(copy.deepcopy(failed))
                return failed
            try:
                result = adapter.update_runner(
                    runner,
                    plan["manifestIdentity"],
                    target_variant,
                    fleet["drainTimeoutSeconds"],
                )
                _validate_runner_result(result, runner, plan, fleet)
            except DeploymentInterrupted as error:
                completed.append({
                    "name": runner,
                    "beforeDigest": None,
                    "afterDigest": None,
                    "afterRelease": None,
                    "state": "unknown",
                    "probe": "not_run",
                    "observation": "not_required",
                    "completedAt": None,
                })
                interrupted = _next_revision(
                    current,
                    outcome="interrupted",
                    runners=completed,
                    completed_at=_timestamp(clock.now()),
                    failure=str(error),
                )
                persist(copy.deepcopy(interrupted))
                return interrupted
            except (DeploymentError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                completed.append({
                    "name": runner,
                    "beforeDigest": None,
                    "afterDigest": None,
                    "afterRelease": None,
                    "state": "unknown",
                    "probe": "not_run",
                    "observation": "not_required",
                    "completedAt": None,
                })
                failed = _next_revision(
                    current,
                    outcome="failed",
                    runners=completed,
                    completed_at=_timestamp(clock.now()),
                    failure=str(error),
                )
                persist(copy.deepcopy(failed))
                return failed
            entry = {
                "name": runner,
                "beforeDigest": result["beforeDigest"],
                "afterDigest": result["afterDigest"],
                "afterRelease": copy.deepcopy(plan["selectedRelease"]),
                "state": "restored" if plan["action"] == "rollback" else "updated",
                "probe": "not_run",
                "observation": "pending" if step["phase"] == "canary" else "not_required",
                "completedAt": None,
            }
            completed.append(entry)
            current = _next_revision(
                current,
                outcome="in_progress",
                runners=completed,
                completed_at=None,
            )
            persist(copy.deepcopy(current))
        else:
            entry = pending
        try:
            probe_result = adapter.probe_runner(runner, fleet["probeTimeoutSeconds"])
            probe = _validate_probe(probe_result, runner)
        except (DeploymentError, OSError, RuntimeError, subprocess.SubprocessError) as error:
            probe = "timeout"
            probe_failure = str(error)
        else:
            probe_failure = f"representative probe {probe}"
        entry["probe"] = probe
        if probe != "passed":
            entry["observation"] = "not_required"
            entry["completedAt"] = _timestamp(clock.now())
            failed = _next_revision(
                current,
                outcome="failed",
                runners=completed,
                completed_at=_timestamp(clock.now()),
                failure=probe_failure,
            )
            persist(copy.deepcopy(failed))
            return failed

        if step["phase"] != "canary":
            entry["completedAt"] = _timestamp(clock.now())
        current = _next_revision(
            current,
            outcome="in_progress",
            runners=completed,
            completed_at=None,
        )
        persist(copy.deepcopy(current))
        if step["phase"] == "canary":
            try:
                adapter.observe(fleet["observationSeconds"])
            except (OSError, RuntimeError) as error:
                failed = _next_revision(
                    current,
                    outcome="interrupted",
                    runners=completed,
                    completed_at=_timestamp(clock.now()),
                    failure=f"canary observation interrupted: {error}",
                )
                persist(copy.deepcopy(failed))
                return failed
            entry["observation"] = "passed"
            entry["completedAt"] = _timestamp(clock.now())
            current = _next_revision(
                current,
                outcome="in_progress",
                runners=completed,
                completed_at=None,
            )
            persist(copy.deepcopy(current))
        advanced += 1

    remaining = {
        step["runner"] for step in plan["steps"]
    } - {
        runner["name"]
        for runner in completed
        if runner.get("probe") == "passed"
        and runner.get("observation") in ("not_required", "passed")
    }
    if remaining:
        return current
    succeeded = _next_revision(
        current,
        outcome="succeeded",
        runners=completed,
        completed_at=_timestamp(clock.now()),
    )
    persist(copy.deepcopy(succeeded))
    return succeeded


def _validate_runner_result(
    result: Any, runner: str, plan: dict[str, Any], fleet: dict[str, Any]
) -> None:
    value = _object(result, f"runner update result for {runner}")
    checks = (
        (value.get("drained") is True, "bounded drain did not succeed"),
        (value.get("online") is True, "runner is not online"),
        (value.get("admitted") is True, "runner is not admitted"),
        (value.get("healthy") is True, "runner runtime health failed"),
        (value.get("transactionLocked") is False, "runner has a transaction lock"),
        (
            value.get("runnerGroup") == fleet.get("runnerGroup"),
            "runner group differs from reviewed configuration",
        ),
        (
            set(fleet.get("requiredLabels", [])).issubset(set(value.get("labels", []))),
            "runner labels are incomplete",
        ),
        (
            set(fleet.get("requiredTools", [])).issubset(set(value.get("tools", []))),
            "runner tools are incomplete",
        ),
        (
            value.get("manifestIdentity") == plan.get("manifestIdentity"),
            "runner manifest identity differs",
        ),
        (value.get("afterDigest") == plan.get("targetDigest"), "runner digest differs"),
        (
            isinstance(value.get("availableCapacity"), int)
            and value["availableCapacity"] >= fleet.get("minimumAvailable", 0),
            "post-update available capacity is below policy floor",
        ),
    )
    for accepted, message in checks:
        if not accepted:
            raise DeploymentError(message)
    if (
        not isinstance(value.get("beforeDigest"), str)
        or DIGEST.fullmatch(value["beforeDigest"]) is None
    ):
        raise DeploymentError("runner before digest is invalid")


def _validate_probe(result: Any, runner: str) -> str:
    value = _object(result, "representative probe result")
    if value.get("routedRunner") != runner:
        raise DeploymentError("representative probe routing differs from selected runner")
    outcome = value.get("outcome")
    if outcome not in ("passed", "failed"):
        raise DeploymentError("representative probe timed out or has invalid outcome")
    return outcome


class ProcessAdapter:
    def __init__(self, config: dict[str, Any], fleet: dict[str, Any]):
        self.config = config
        self.fleet = fleet

    @staticmethod
    def _invoke(
        command: list[str],
        env: dict[str, str] | None = None,
        *,
        timeout_seconds: int = 2_000,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout_seconds,
        )

    @classmethod
    def _run(
        cls,
        command: list[str],
        env: dict[str, str] | None = None,
        *,
        timeout_seconds: int = POST_UPDATE_EVIDENCE_SECONDS,
    ) -> dict[str, Any]:
        if (
            not isinstance(timeout_seconds, int)
            or isinstance(timeout_seconds, bool)
            or timeout_seconds < 1
            or timeout_seconds > MAX_ADAPTER_JSON_SECONDS
        ):
            raise DeploymentError(
                f"adapter timeout must be between 1 and {MAX_ADAPTER_JSON_SECONDS} seconds"
            )
        completed = cls._invoke(
            command,
            env,
            timeout_seconds=timeout_seconds,
        )
        try:
            value = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise DeploymentError("adapter command did not emit one JSON object") from error
        return _object(value, "adapter command output")

    def update_runner(
        self, runner: str, manifest_identity: str, variant: str, timeout_seconds: int
    ) -> dict[str, Any]:
        deploy_token = os.environ.get("VERJSON_RUNNER_DEPLOY_TOKEN")
        if not deploy_token:
            raise DeploymentError("VERJSON_RUNNER_DEPLOY_TOKEN is unavailable")
        environment = os.environ.copy()
        environment["DIGITALOCEAN_ACCESS_TOKEN"] = deploy_token
        command = [
            _deployment_cli(),
            "runner",
            "update",
            self.fleet["lane"],
            "--cloud",
            "digitalocean",
            "--project",
            self.fleet["project"],
            "--runner-mode",
            "persistent",
            "--release-manifest",
            manifest_identity,
            "--release-variant",
            variant,
            "--only",
            runner,
        ]
        try:
            self._invoke(command, environment, timeout_seconds=timeout_seconds + 120)
        except subprocess.SubprocessError as error:
            raise DeploymentInterrupted(
                f"runner update did not return verified terminal evidence for {runner}"
            ) from error
        return self._run(
            [
                *_command(self.config, "evidenceCommand"),
                "--runner",
                runner,
                "--manifest-identity",
                manifest_identity,
                "--fleet",
                self.fleet["lane"],
                "--post-update",
            ],
            timeout_seconds=POST_UPDATE_EVIDENCE_SECONDS,
        )

    def available_capacity(self) -> int:
        result = self._run(
            [
                *_command(self.config, "evidenceCommand"),
                "--fleet",
                self.fleet["lane"],
                "--capacity-only",
            ],
            timeout_seconds=CAPACITY_EVIDENCE_SECONDS,
        )
        capacity = result.get("availableCapacity")
        if not isinstance(capacity, int) or capacity < 0:
            raise DeploymentError("capacity evidence is malformed")
        return capacity

    def probe_runner(self, runner: str, timeout_seconds: int) -> dict[str, Any]:
        probe_environment = os.environ.copy()
        probe_environment.pop("VERJSON_RUNNER_DEPLOY_TOKEN", None)
        probe_environment.pop("DIGITALOCEAN_ACCESS_TOKEN", None)
        return self._run(
            [
                *_command(self.config, "probeCommand"),
                "--runner",
                runner,
                "--timeout-seconds",
                str(timeout_seconds),
            ],
            probe_environment,
            timeout_seconds=timeout_seconds + 30,
        )

    @staticmethod
    def observe(seconds: int) -> None:
        time.sleep(seconds)


def _persist_directory(receipt_dir: Path, start_index: int = 0):
    index = start_index

    def persist(receipt: dict[str, Any]) -> None:
        nonlocal index
        validate_receipt(receipt)
        destination = receipt_dir / f"revision-{index:04d}.json"
        if destination.exists():
            raise DeploymentError(f"refusing to overwrite retained receipt {destination}")
        _write(destination, receipt)
        index += 1

    return persist


def _restore_receipts(
    evidence: dict[str, Any], plan: dict[str, Any], receipt_dir: Path
) -> dict[str, Any] | None:
    retained = evidence.get("retainedRevisions", [])
    authority = evidence.get("retainedReceiptAuthority")
    if retained == [] and authority is None:
        return None
    if not isinstance(retained, list) or not retained or not all(
        isinstance(receipt, dict) for receipt in retained
    ):
        raise DeploymentError("retained receipt revisions are malformed")
    try:
        validate_receipt_chain(retained)
    except ValueError as error:
        raise DeploymentError(f"retained receipt chain is invalid: {error}") from error
    latest = retained[-1]
    expected_authority = (
        rf"{re.escape(latest['attemptId'])}/[1-9][0-9]*@"
        + re.escape(retained_authority_digest(plan, retained))
    )
    if not isinstance(authority, str) or re.fullmatch(expected_authority, authority) is None:
        raise DeploymentError("retained receipt authority does not bind the exact chain")
    expected = {
        "attemptId": plan["attemptId"],
        "headCommit": plan["headCommit"],
        "manifestIdentity": plan["manifestIdentity"],
        "planDigest": canonical_digest(plan),
    }
    if any(latest.get(field) != value for field, value in expected.items()):
        raise DeploymentError("retained receipt authority differs from this exact plan")
    for receipt in retained:
        destination = receipt_dir / f"revision-{receipt['revision']:04d}.json"
        if destination.exists():
            if _load(destination) != receipt:
                raise DeploymentError("local receipt revision differs from retained authority")
        else:
            _write(destination, receipt)
    return latest


def _collect_evidence(
    config: dict[str, Any],
    manifest_identity: str,
    fleet_selector: str,
    rollback_receipt: str = "",
) -> dict[str, Any]:
    if MANIFEST_IDENTITY.fullmatch(manifest_identity) is None:
        raise DeploymentError("manifest identity must be an immutable digest reference")
    _safe_token(fleet_selector, "fleet selector", r"[a-z][a-z0-9_-]{1,31}")
    command = [
        *_command(config, "evidenceCommand"),
        "--manifest-identity",
        manifest_identity,
        "--fleet",
        fleet_selector,
    ]
    if rollback_receipt:
        if DIGEST.fullmatch(rollback_receipt) is None:
            raise DeploymentError("rollback receipt identity must be a canonical digest")
        command.extend(("--rollback-receipt", rollback_receipt))
    evidence = ProcessAdapter._run(
        command, timeout_seconds=ADMISSION_EVIDENCE_SECONDS
    )
    github_sha = os.environ.get("GITHUB_SHA")
    if github_sha and evidence.get("headCommit") != github_sha:
        raise DeploymentError("evidence checked-out head differs from workflow authority")
    authorization = evidence.get("authorization")
    github_run_id = os.environ.get("GITHUB_RUN_ID")
    github_run_attempt = os.environ.get("GITHUB_RUN_ATTEMPT")
    if github_run_id and (
        not isinstance(authorization, dict)
        or authorization.get("workflowRunId") != int(github_run_id)
    ):
        raise DeploymentError("evidence workflow run differs from workflow authority")
    if github_run_attempt and evidence.get("workflowRunAttempt") != int(github_run_attempt):
        raise DeploymentError("evidence workflow attempt differs from workflow authority")
    observed_identity = evidence.get("manifestIdentity")
    if observed_identity not in (None, manifest_identity):
        raise DeploymentError("evidence command substituted manifest identity")
    evidence["manifestIdentity"] = manifest_identity
    if rollback_receipt:
        source = _object(evidence.get("rollbackSource"), "rollbackSource")
        validate_receipt(source)
        if receipt_digest(source) != rollback_receipt:
            raise DeploymentError("retrieved rollback receipt differs from requested digest")
        evidence["rollbackReceiptIdentity"] = rollback_receipt
    return evidence


def main() -> int:
    parser = argparse.ArgumentParser(description="Protected sequential runner deployment")
    subparsers = parser.add_subparsers(dest="command", required=True)

    collect = subparsers.add_parser("collect-evidence")
    collect.add_argument("--config", required=True, type=Path)
    collect.add_argument("--manifest-identity", required=True)
    collect.add_argument("--fleet", required=True)
    collect.add_argument("--rollback-receipt", default="")
    collect.add_argument("--output", required=True, type=Path)

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--config", required=True, type=Path)
    plan_parser.add_argument("--evidence", required=True, type=Path)
    plan_parser.add_argument("--fleet", required=True)
    plan_parser.add_argument("--action", choices=("deploy", "rollback"), required=True)
    plan_parser.add_argument("--contract-ref", required=True)
    plan_parser.add_argument("--rollback-source", type=Path)
    plan_parser.add_argument("--output", required=True, type=Path)

    admit = subparsers.add_parser("admit")
    reconcile = subparsers.add_parser("reconcile")
    for target in (admit, reconcile):
        target.add_argument("--plan", required=True, type=Path)
        target.add_argument("--config", required=True, type=Path)
        target.add_argument("--evidence", required=True, type=Path)
        target.add_argument("--receipt-dir", required=True, type=Path)

    execute = subparsers.add_parser("execute")
    execute.add_argument("--plan", required=True, type=Path)
    execute.add_argument("--config", required=True, type=Path)
    execute.add_argument("--evidence", required=True, type=Path)
    execute.add_argument("--receipt-dir", required=True, type=Path)

    args = parser.parse_args()
    try:
        if args.command == "collect-evidence":
            config = _load(args.config)
            _validate_commands(config)
            _write(
                args.output,
                _collect_evidence(
                    config,
                    args.manifest_identity,
                    args.fleet,
                    args.rollback_receipt,
                ),
            )
        elif args.command == "plan":
            config = _load(args.config)
            evidence = _load(args.evidence)
            resume_plan = retained_plan(
                config,
                evidence,
                args.fleet,
                args.action,
                args.contract_ref,
            )
            rollback_source = (
                _load(args.rollback_source)
                if args.rollback_source
                else evidence.get("rollbackSource")
            )
            _write(
                args.output,
                resume_plan
                or build_plan(
                    config,
                    evidence,
                    args.fleet,
                    action=args.action,
                    rollback_source=rollback_source,
                    deployment_contract_ref=args.contract_ref,
                ),
            )
        elif args.command == "admit":
            plan = _load(args.plan)
            config = _load(args.config)
            evidence = _load(args.evidence)
            receipt = _restore_receipts(evidence, plan, args.receipt_dir)
            if receipt is None:
                receipt = admitted_receipt(plan, config, evidence, datetime.now(timezone.utc))
                _persist_directory(args.receipt_dir)(receipt)
        elif args.command == "reconcile":
            plan = _load(args.plan)
            config = _load(args.config)
            evidence = _load(args.evidence)
            existing = sorted(args.receipt_dir.glob("revision-*.json"))
            receipts = [_load(path) for path in existing]
            try:
                validate_receipt_chain(receipts)
            except ValueError as error:
                raise DeploymentError(f"local receipt chain is invalid: {error}") from error
            latest = receipts[-1]
            if any(
                runner.get("state") == "unknown"
                for runner in latest.get("runners", [])
            ):
                reconciled = reconcile_unknown_state(plan, latest, evidence, config)
                _persist_directory(args.receipt_dir, len(existing))(reconciled)
            elif latest.get("outcome") in ("failed", "succeeded"):
                raise DeploymentError(
                    "terminal receipt has no unknown state to reconcile; use protected rollback"
                )
        else:
            plan = _load(args.plan)
            config = _load(args.config)
            evidence = _load(args.evidence)
            fleet = config["fleets"][plan["fleetSelector"]]
            existing = sorted(args.receipt_dir.glob("revision-*.json"))
            receipts = [_load(path) for path in existing]
            if any(
                path.name != f"revision-{receipt.get('revision', -1):04d}.json"
                for path, receipt in zip(existing, receipts)
            ):
                raise DeploymentError("local receipt filename differs from its revision")
            try:
                validate_receipt_chain(receipts)
            except ValueError as error:
                raise DeploymentError(f"local receipt chain is invalid: {error}") from error
            final_receipt = receipts[-1]
            if final_receipt.get("outcome") != "succeeded":
                final_receipt = execute_plan(
                    plan,
                    config,
                    evidence,
                    ProcessAdapter(config, fleet),
                    _persist_directory(args.receipt_dir, len(existing)),
                    previous_receipt=final_receipt,
                    max_hosts=1,
                )
            if final_receipt.get("outcome") not in ("in_progress", "succeeded"):
                raise DeploymentError(
                    f"deployment stopped with outcome {final_receipt.get('outcome')}"
                )
    except (DeploymentError, OSError, subprocess.SubprocessError) as error:
        print(f"container deployment rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
