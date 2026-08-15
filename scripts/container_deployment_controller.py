#!/usr/bin/env python3

import argparse
import copy
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
    validate_rollback,
)


DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
MANIFEST_IDENTITY = re.compile(
    r"(?P<repository>ghcr\.io/[a-z0-9_.-]+/[a-z0-9_.-]+)@(?P<digest>sha256:[0-9a-f]{64})"
)
MAX_DRAIN_SECONDS = 1_800
MAX_PROBE_SECONDS = 900
MAX_OBSERVATION_SECONDS = 900
MAX_REQUEST_AGE_SECONDS = 3_600


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
    _text(fleet.get("runnerGroup"), "runnerGroup")


def _validate_commands(config: dict[str, Any]) -> None:
    _command(config, "evidenceCommand")
    _command(config, "probeCommand")
    if config.get("cliCommand") != ["npx", "--no-install", "verjson-cloud"]:
        raise DeploymentError(
            "cliCommand must use the reviewed local verjson-cloud executable without install"
        )


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
    identity = _text(evidence.get("manifestIdentity"), "manifestIdentity")
    identity_match = MANIFEST_IDENTITY.fullmatch(identity)
    if identity_match is None:
        raise DeploymentError("manifestIdentity must be an immutable digest reference")
    if identity_match.group("repository") != expected.get("repository"):
        raise DeploymentError("manifestIdentity repository differs from reviewed configuration")
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
        or any(not isinstance(name, str) or not name for name in runners)
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
        "schemaVersion": 2,
        "attemptId": plan["attemptId"],
        "action": plan["action"],
        "outcome": "admitted",
        "environment": "production",
        "selectedRelease": copy.deepcopy(plan["selectedRelease"]),
        "observedDeployedRelease": copy.deepcopy(plan["observedDeployedRelease"]),
        "previousReceiptDigest": None,
        "rollbackOfAttempt": copy.deepcopy(plan["rollbackOfAttempt"]),
        "deploymentContractCommit": plan["deploymentContractCommit"],
        "manifestIdentity": plan["manifestIdentity"],
        "fleetSelector": plan["fleetSelector"],
        "canaryRunner": plan["steps"][0]["runner"],
        "authorization": required_authorization,
        "runners": [],
        "finalFleet": [
            {"name": runner["name"], "release": copy.deepcopy(runner["release"])}
            for runner in evidence["fleet"]["runners"]
        ],
        "failure": None,
        "observedAt": _timestamp(now),
        "startedAt": _timestamp(now),
        "completedAt": None,
    }


def _next_revision(
    previous: dict[str, Any],
    *,
    outcome: str,
    runners: list[dict[str, Any]],
    completed_at: str | None,
    failure: str | None = None,
) -> dict[str, Any]:
    revision = copy.deepcopy(previous)
    revision["outcome"] = outcome
    revision["previousReceiptDigest"] = receipt_digest(previous)
    revision["runners"] = copy.deepcopy(runners)
    revision["completedAt"] = completed_at
    revision["failure"] = failure
    passed_names = {runner["name"] for runner in runners if runner["probe"] == "passed"}
    for runner in revision["finalFleet"]:
        if runner["name"] in passed_names:
            runner["release"] = copy.deepcopy(revision["selectedRelease"])
    try:
        validate_attempt_revision(revision, previous)
    except ValueError as error:
        raise DeploymentError(str(error)) from error
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
        for field in (
            "attemptId",
            "action",
            "deploymentContractCommit",
            "manifestIdentity",
            "fleetSelector",
            "selectedRelease",
            "observedDeployedRelease",
        ):
            expected = (
                plan[field]
                if field != "attemptId"
                else previous_receipt.get("attemptId")
            )
            if current.get(field) != expected:
                raise DeploymentError(f"resume changes immutable {field}")

    fleet = config["fleets"][plan["fleetSelector"]]
    completed = list(current.get("runners", []))
    completed_names = {
        runner.get("name")
        for runner in completed
        if runner.get("probe") == "passed"
    }
    target_variant = config["expectedRelease"]["variant"]
    for step in plan["steps"]:
        runner = step["runner"]
        if runner in completed_names:
            continue
        try:
            if adapter.available_capacity() - 1 < fleet["minimumAvailable"]:
                raise DeploymentError("live spare capacity would fall below policy floor")
            result = adapter.update_runner(
                runner,
                plan["manifestIdentity"],
                target_variant,
                fleet["drainTimeoutSeconds"],
            )
            _validate_runner_result(result, runner, plan, fleet)
            probe_result = adapter.probe_runner(runner, fleet["probeTimeoutSeconds"])
            probe = _validate_probe(probe_result, runner)
        except DeploymentInterrupted as error:
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
            "probe": probe,
            "completedAt": _timestamp(clock.now()),
        }
        completed.append(entry)
        if probe != "passed":
            failed = _next_revision(
                current,
                outcome="failed",
                runners=completed,
                completed_at=_timestamp(clock.now()),
                failure="representative probe failed",
            )
            persist(copy.deepcopy(failed))
            return failed

        current = _next_revision(
            current,
            outcome="in_progress",
            runners=completed,
            completed_at=None,
        )
        persist(copy.deepcopy(current))
        if step["phase"] == "canary":
            adapter.observe(fleet["observationSeconds"])

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
        timeout_seconds: int = 2_000,
    ) -> dict[str, Any]:
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
            *self.config["cliCommand"],
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
            timeout_seconds=timeout_seconds,
        )

    def available_capacity(self) -> int:
        result = self._run(
            [
                *_command(self.config, "evidenceCommand"),
                "--fleet",
                self.fleet["lane"],
                "--capacity-only",
            ]
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


def _collect_evidence(
    config: dict[str, Any],
    manifest_identity: str,
    fleet_selector: str,
    rollback_receipt: str = "",
) -> dict[str, Any]:
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
    evidence = ProcessAdapter._run(command)
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
    for target in (admit,):
        target.add_argument("--plan", required=True, type=Path)
        target.add_argument("--config", required=True, type=Path)
        target.add_argument("--evidence", required=True, type=Path)
        target.add_argument("--receipt-dir", required=True, type=Path)

    execute = subparsers.add_parser("execute")
    execute.add_argument("--plan", required=True, type=Path)
    execute.add_argument("--config", required=True, type=Path)
    execute.add_argument("--evidence", required=True, type=Path)
    execute.add_argument("--receipt-dir", required=True, type=Path)
    execute.add_argument("--resume", required=True, type=Path)

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
            rollback_source = (
                _load(args.rollback_source)
                if args.rollback_source
                else evidence.get("rollbackSource")
            )
            _write(
                args.output,
                build_plan(
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
            receipt = admitted_receipt(plan, config, evidence, datetime.now(timezone.utc))
            _persist_directory(args.receipt_dir)(receipt)
        else:
            plan = _load(args.plan)
            config = _load(args.config)
            evidence = _load(args.evidence)
            previous = _load(args.resume)
            fleet = config["fleets"][plan["fleetSelector"]]
            existing = sorted(args.receipt_dir.glob("revision-*.json"))
            final_receipt = execute_plan(
                plan,
                config,
                evidence,
                ProcessAdapter(config, fleet),
                _persist_directory(args.receipt_dir, len(existing)),
                previous_receipt=previous,
            )
            if final_receipt.get("outcome") != "succeeded":
                raise DeploymentError(
                    f"deployment stopped with outcome {final_receipt.get('outcome')}"
                )
    except (DeploymentError, OSError, subprocess.SubprocessError) as error:
        print(f"container deployment rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
