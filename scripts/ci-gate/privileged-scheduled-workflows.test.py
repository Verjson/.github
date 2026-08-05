#!/usr/bin/env python3
"""Semantic contracts for scheduled workflows that receive ORG_ADMIN_TOKEN."""

from pathlib import Path
import re
import sys

import yaml


ROOT = Path(__file__).resolve().parents[2]
WATCHDOG = ROOT / ".github/workflows/fleet-watchdog.yml"
ADMISSION = ROOT / ".github/workflows/runner-admission-reconcile.yml"
CHECKOUT = re.compile(r"^actions/checkout@[0-9a-f]{40}$")


class ContractError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def require_keys(value: object, expected: set[str], location: str) -> dict:
    require(isinstance(value, dict), f"{location} must be a mapping")
    actual = set(value)
    require(actual == expected, f"{location} keys are {actual}, expected {expected}")
    return value


def workflow_on(document: dict) -> object:
    # PyYAML follows YAML 1.1 and parses an unquoted `on` key as boolean true.
    keys = [key for key in document if key is True or key == "on"]
    require(len(keys) == 1, "workflow must have exactly one on key")
    return document[keys[0]]


def validate_common(document: object, job_name: str) -> tuple[dict, list[dict]]:
    require(isinstance(document, dict), "workflow root must be a mapping")
    root_keys = {"on" if key is True else key for key in document}
    require(
        root_keys == {"name", "on", "permissions", "concurrency", "jobs"},
        f"workflow keys expose an unexpected execution surface: {root_keys}",
    )

    triggers = require_keys(workflow_on(document), {"schedule"}, "on")
    require(isinstance(triggers["schedule"], list), "schedule must be a sequence")

    jobs = require_keys(document["jobs"], {job_name}, "jobs")
    job = jobs[job_name]
    steps = job.get("steps") if isinstance(job, dict) else None
    require(isinstance(steps, list), f"jobs.{job_name}.steps must be a sequence")
    require(all(isinstance(step, dict) for step in steps), "every step must be a mapping")
    require(all(isinstance(step.get("name"), str) for step in steps), "every step must be named")
    return job, steps


def validate_checkout(step: dict, name: str) -> None:
    require_keys(step, {"name", "uses", "with"}, name)
    require(isinstance(step["uses"], str), f"{name}.uses must be a string")
    require(CHECKOUT.fullmatch(step["uses"]) is not None, f"{name}.uses must be a full-SHA checkout pin")
    checkout_with = require_keys(step["with"], {"ref", "persist-credentials"}, f"{name}.with")
    require(checkout_with["ref"] == "${{ github.sha }}", f"{name}.with.ref must equal github.sha")
    require(checkout_with["persist-credentials"] is False, f"{name} must not persist credentials")


def validate_watchdog(document: object) -> None:
    job, steps = validate_common(document, "watchdog")
    require_keys(job, {"runs-on", "timeout-minutes", "steps"}, "jobs.watchdog")
    require(len(steps) == 2, "watchdog must have exactly two steps")
    require(steps[0]["name"] == "Check out the watchdog", "watchdog checkout step name changed")
    validate_checkout(steps[0], "watchdog checkout")

    sweep = require_keys(steps[1], {"name", "env", "run"}, "watchdog sweep")
    require(sweep["name"] == "Sweep the fleet for poll deadlocks", "watchdog sweep step name changed")
    env = require_keys(
        sweep["env"],
        {"GH_TOKEN", "WATCHDOG_ORG", "WATCHDOG_DRY_RUN", "WATCHDOG_MIN_AGE_MINUTES"},
        "watchdog sweep env",
    )
    require(env["GH_TOKEN"] == "${{ secrets.ORG_ADMIN_TOKEN }}", "watchdog token binding changed")
    require(sweep["run"] == "bash scripts/fleet-watchdog.sh", "watchdog command must remain static")


def validate_admission(document: object) -> None:
    job, steps = validate_common(document, "reconcile")
    require_keys(job, {"runs-on", "timeout-minutes", "steps"}, "jobs.reconcile")
    require(len(steps) == 4, "runner admission must have exactly four steps")
    require(steps[0]["name"] == "Check out the runner admission reconciler", "admission checkout step name changed")
    validate_checkout(steps[0], "admission checkout")

    reconcile = require_keys(steps[1], {"name", "id", "env", "run"}, "admission reconcile")
    require(reconcile["name"] == "Reconcile runner admission against routing policy", "reconcile step name changed")
    require(reconcile["id"] == "reconcile", "reconcile step id changed")
    env = require_keys(
        reconcile["env"],
        {"GH_TOKEN", "ORG", "GENERAL_GROUP_NAME", "UNTRUSTED_GROUP_NAME"},
        "admission reconcile env",
    )
    require(env["GH_TOKEN"] == "${{ secrets.ORG_ADMIN_TOKEN }}", "admission token binding changed")
    # The two group names are pinned to exact expressions, not merely allowed to
    # exist. Widening the key set alone would let this privileged step carry an
    # arbitrary literal, which is the shape #350 is about. Sourcing them from org
    # variables keeps a pool rename a variable flip (#401) while leaving the value
    # under the same org-admin control as the token itself.
    require(
        env["GENERAL_GROUP_NAME"] == "${{ vars.VERJSON_RUNNER_GENERAL_GROUP || 'DigitalOcean' }}",
        "general runner group must come from the org variable with its fallback",
    )
    require(
        env["UNTRUSTED_GROUP_NAME"] == "${{ vars.VERJSON_RUNNER_UNTRUSTED_GROUP }}",
        "untrusted runner group must come from the org variable, with no fallback naming a deleted group",
    )
    require(isinstance(reconcile["run"], str), "admission reconcile command must be a string")
    require(
        'bash scripts/ci-gate/runner-admission-reconcile.sh' in reconcile["run"],
        "admission reconcile command changed",
    )

    expected_followups = [
        ("Open or update the drift issue", "1", {"GH_TOKEN", "REPORT", "MARKER"}),
        ("Close the drift issue once the org is clean again", "0", {"GH_TOKEN", "MARKER"}),
    ]
    for step, (name, code, env_keys) in zip(steps[2:], expected_followups):
        followup = require_keys(step, {"name", "if", "env", "run"}, name)
        require(followup["name"] == name, f"{name} step name changed")
        require(followup["if"] == f"steps.reconcile.outputs.code == '{code}'", f"{name} condition changed")
        followup_env = require_keys(followup["env"], env_keys, f"{name} env")
        require(followup_env["GH_TOKEN"] == "${{ secrets.GITHUB_TOKEN }}", f"{name} gained a privileged token")


def load(text: str) -> object:
    return yaml.safe_load(text)


def expect_valid(label: str, validator, text: str) -> int:
    try:
        validator(load(text))
    except (ContractError, yaml.YAMLError) as error:
        print(f"FAIL - {label}: {error}")
        return 1
    print(f"ok   - {label}")
    return 0


def expect_invalid(label: str, validator, text: str) -> int:
    try:
        document = load(text)
    except yaml.YAMLError as error:
        print(f"FAIL - {label}: mutation is not valid YAML: {error}")
        return 1
    try:
        validator(document)
    except ContractError:
        print(f"ok   - {label}")
        return 0
    print(f"FAIL - {label}: mutation escaped the semantic contract")
    return 1


def mutations(text: str, next_step: str) -> tuple[str, str]:
    bare_dash = text.replace(
        next_step,
        "      -\n        run: echo bare-dash-bypass\n" + next_step,
        1,
    )
    quoted_key = text.replace(
        "          persist-credentials: false",
        '          persist-credentials: false\n        "run": echo quoted-key-bypass',
        1,
    )
    require(bare_dash != text and quoted_key != text, "mutation fixture marker not found")
    return bare_dash, quoted_key


def main() -> int:
    watchdog_text = WATCHDOG.read_text()
    admission_text = ADMISSION.read_text()
    failures = 0
    failures += expect_valid("fleet watchdog is schedule-only and event-SHA-bound", validate_watchdog, watchdog_text)
    failures += expect_valid("runner admission is schedule-only and event-SHA-bound", validate_admission, admission_text)

    cases = [
        ("fleet watchdog", validate_watchdog, watchdog_text, "      - name: Sweep the fleet for poll deadlocks"),
        (
            "runner admission",
            validate_admission,
            admission_text,
            "      - name: Reconcile runner admission against routing policy",
        ),
    ]
    for label, validator, text, marker in cases:
        try:
            bare_dash, quoted_key = mutations(text, marker)
        except ContractError as error:
            print(f"FAIL - {label} mutation setup: {error}")
            failures += 1
            continue
        failures += expect_invalid(f"{label} rejects a bare-dash executable step", validator, bare_dash)
        failures += expect_invalid(f"{label} rejects a quoted executable key", validator, quoted_key)

    if failures:
        print(f"{failures} test(s) failed.")
        return 1
    print("All tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
