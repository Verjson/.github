#!/usr/bin/env python3
"""Contract tests for the head-bound, event-driven AI authorization gate."""

from pathlib import Path
import re
import sys

import yaml


ROOT = Path(__file__).resolve().parents[2]
REVIEW = ROOT / ".github/workflows/ai-review-merge.yml"
REARM = ROOT / ".github/workflows/gate-rearm.yml"
PROMOTE = ROOT / ".github/workflows/ai-privileged-merge.yml"
APP_TOKEN_ACTION = "actions/create-github-app-token"
IMMUTABLE_ACTION = re.compile(rf"^{re.escape(APP_TOKEN_ACTION)}@[0-9a-f]{{40}}$")
MODEL_ACTION = "anthropics/claude-code-action@v1"
TRUSTED_BOTS = {"renovate", "renovate[bot]", "mend[bot]", "github-actions"}


def load(path: Path):
    with path.open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def authorization_app_token_uses(workflow: dict, job_name: str) -> str:
    steps = workflow["jobs"][job_name]["steps"]
    matches = [step.get("uses", "") for step in steps
               if step.get("name") == "Mint dedicated authorization App token"]
    require(len(matches) == 1,
            f"{job_name} must have exactly one dedicated authorization App token step")
    return matches[0]


def validate_authorization_app_token_pins(uses_values: list[str]) -> None:
    require(all(IMMUTABLE_ACTION.fullmatch(uses) for uses in uses_values),
            "trusted authorization sites must use the official App-token action at a full lowercase 40-hex SHA")
    require(len(set(uses_values)) == 1,
            "trusted authorization sites must use the same immutable App-token action pin")


def validate_model_admission(steps: list[dict]) -> None:
    model_indexes = [index for index, step in enumerate(steps)
                     if step.get("uses") == MODEL_ACTION]
    require(len(model_indexes) == 3, "review must retain exactly three bounded model passes")

    validation_indexes = [index for index, step in enumerate(steps)
                          if step.get("name") == "Validate trusted head authorization"]
    require(len(validation_indexes) == 1 and validation_indexes[0] < model_indexes[0],
            "receipt and pending-check validation must precede every model pass")
    validation = steps[validation_indexes[0]].get("run", "")
    verifier = "bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh"
    pending_check = 'check-runs/$AUTHORIZATION_CHECK_ID'
    require(verifier in validation and pending_check in validation and
            validation.index(verifier) < validation.index(pending_check) and
            "in_progress:" in validation and "exit 1" in validation,
            "trusted admission must verify the receipt, then require its exact pending App check")

    allowlists = []
    for index in model_indexes:
        allowed = steps[index].get("with", {}).get("allowed_bots", "")
        require("*" not in allowed, "model bot admission must never contain a wildcard")
        allowlists.append({login.strip() for login in allowed.split(",") if login.strip()})
    require(all(allowed == TRUSTED_BOTS for allowed in allowlists),
            "all model passes must share the exact trusted dispatcher/Renovate/Mend allowlist")


def main() -> int:
    review_text = REVIEW.read_text(encoding="utf-8")
    rearm_text = REARM.read_text(encoding="utf-8")
    promote_text = PROMOTE.read_text(encoding="utf-8")
    rearm_generator = (ROOT / "scripts/gen-gate-rearm-caller.sh").read_text(encoding="utf-8")
    promote_generator = (ROOT / "scripts/gen-privileged-merge-caller.sh").read_text(encoding="utf-8")
    verifier_text = (ROOT / "scripts/ci-gate/verify-arm-receipt.sh").read_text(encoding="utf-8")
    review = load(REVIEW)
    rearm = load(REARM)
    promote = load(PROMOTE)

    dispatch_inputs = review[True]["workflow_dispatch"]["inputs"]
    receipt_inputs = {"pr_number", "expected_head_sha", "authorization_check_id",
                      "arm_run_id", "arm_run_attempt"}
    require(receipt_inputs <= dispatch_inputs.keys() and
            all(dispatch_inputs[name].get("required") is True for name in receipt_inputs),
            "workflow_dispatch must require the exact head, App check, and arm-receipt identity")
    gate_steps = review["jobs"]["gate"]["steps"]
    validate_model_admission(gate_steps)

    mutated_steps = [dict(step) for step in gate_steps]
    first_model = next(index for index, step in enumerate(mutated_steps)
                       if step.get("uses") == MODEL_ACTION)
    mutated_steps[first_model] = {
        **mutated_steps[first_model],
        "with": {**mutated_steps[first_model]["with"], "allowed_bots": "*"},
    }
    try:
        validate_model_admission(mutated_steps)
    except AssertionError:
        pass
    else:
        raise AssertionError("wildcard bot mutation escaped model admission contract")

    validation_index = next(index for index, step in enumerate(gate_steps)
                            if step.get("name") == "Validate trusted head authorization")
    missing_verifier_steps = [dict(step) for step in gate_steps]
    missing_verifier_steps[validation_index] = {
        **missing_verifier_steps[validation_index],
        "run": missing_verifier_steps[validation_index]["run"].replace(
            "bash .gate-trust/scripts/ci-gate/verify-arm-receipt.sh", "true"),
    }
    reordered_steps = [dict(step) for step in gate_steps]
    validation_step = reordered_steps.pop(validation_index)
    reordered_steps.insert(first_model + 1, validation_step)
    for mutation, message in (
            (missing_verifier_steps, "missing receipt verifier"),
            (reordered_steps, "post-model receipt validation")):
        try:
            validate_model_admission(mutation)
        except AssertionError:
            continue
        raise AssertionError(f"{message} mutation escaped model admission contract")

    caller_sha = "1" * 40
    callee_sha = "2" * 40
    consumer_call_fixture = {
        "github.workflow_sha": caller_sha,
        "job.workflow_sha": callee_sha,
    }
    resolver_values = []
    for workflow in (review, promote):
        for job in workflow["jobs"].values():
            for step in job.get("steps", []):
                if step.get("name") == "Resolve executing trusted workflow revision":
                    resolver_values.append(step["env"]["EXECUTING_WORKFLOW_SHA"])
    require(resolver_values and all(value == "${{ job.workflow_sha }}" for value in resolver_values),
            "canonical verifier checkout must resolve the reusable callee SHA")
    selected = [consumer_call_fixture[value[4:-3].strip()] for value in resolver_values]
    require(all(value == callee_sha and value != caller_sha for value in selected),
            "consumer-call fixture selected the caller SHA instead of the canonical callee SHA")

    require("pull_request_target" not in review.get(True, {}),
            "model workflow must not run in pull_request_target context")
    require("pull_request" not in review.get(True, {}),
            "model workflow must run only after the trusted arm deduplicates a head")
    require(set(rearm[True]["pull_request_target"]["types"]) >=
            {"opened", "reopened", "synchronize", "ready_for_review", "labeled", "unlabeled"},
            "trusted rearm must cover every head and control transition")
    app_token_uses = [
        authorization_app_token_uses(rearm, "arm"),
        authorization_app_token_uses(review, "complete-authorization"),
    ]
    validate_authorization_app_token_pins(app_token_uses)

    valid_pin = f"{APP_TOKEN_ACTION}@{'a' * 40}"
    invalid_pin_sets = (
        [valid_pin.replace(APP_TOKEN_ACTION, "attacker/create-github-app-token"), valid_pin],
        [f"{APP_TOKEN_ACTION}@v3", f"{APP_TOKEN_ACTION}@v3"],
        [f"{APP_TOKEN_ACTION}@{'a' * 12}", f"{APP_TOKEN_ACTION}@{'a' * 12}"],
        [valid_pin, f"{APP_TOKEN_ACTION}@{'b' * 40}"],
    )
    for invalid_pins in invalid_pin_sets:
        try:
            validate_authorization_app_token_pins(invalid_pins)
        except AssertionError:
            continue
        raise AssertionError(f"mutation escaped App-token pin contract: {invalid_pins}")
    for workflow in (rearm, review, promote):
        require(all(job.get("permissions", {}).get("checks") != "write"
                    for job in workflow["jobs"].values()),
                "shared workflow tokens must never receive Checks write permission")
    completion_steps = review["jobs"]["complete-authorization"]["steps"]
    app_token = next(step for step in completion_steps
                     if step.get("name") == "Mint dedicated authorization App token")
    require(app_token["with"].get("permission-checks") == "write" and
            app_token["with"].get("permission-pull-requests") == "write",
            "dedicated completion App token must request only its required write permissions")
    require('check-runs/$AUTHORIZATION_CHECK_ID' in review_text,
            "review must complete the exact check-run supplied by the trusted arm")
    require('head_sha:$sha' in rearm_text and '--arg sha "$head_sha"' in rearm_text,
            "authorization check must be bound to the exact current PR head")
    require("AI review authorization" in rearm_text and "AI review authorization" in promote_text,
            "arm and promotion must agree on the unambiguous required-check name")
    require("enablePullRequestAutoMerge" in promote_text,
            "trusted continuation must delegate waiting to GitHub native auto-merge")
    require("disablePullRequestAutoMerge" in rearm_text,
            "a hold or draft applied after promotion must revoke native auto-merge")
    require("retention-days: 90" in rearm_text,
            "arm receipts must survive the supported long-lived hold window")
    require(re.search(r"mergeMethod:\s*SQUASH", promote_text) is not None,
            "native auto-merge must preserve squash policy")
    require("(.conclusion | ascii_upcase) == \"SUCCESS\"" in promote_text,
            "only successful authorization may enable auto-merge")
    require(all(marker in verifier_text for marker in
                (".workflow_id == $workflow_id", '.event == "pull_request_target"',
                 '.path == ".github/workflows/gate-rearm.yml"', ".external_id == $external_id",
                 "artifact_digest", "actual_zip_sha")),
            "authorization must be receipt-, digest-, run-, and dedicated-App-bound")
    verifier_invocation = re.compile(
        r"(?m)^(?P<indent>\s*)(?:GH_TOKEN=\"\$ACTIONS_TOKEN\" )?"
        r"(?P<shell>bash )?\.gate-trust/scripts/ci-gate/verify-arm-receipt\.sh$"
    )
    invocations = [
        match for text in (review_text, promote_text)
        for match in verifier_invocation.finditer(text)
    ]
    require(len(invocations) == 3 and all(match.group("shell") == "bash " for match in invocations),
            "every sparse-checked-out arm verifier must be invoked explicitly with bash")
    require("headRefOid" in promote_text and "EXPECTED_HEAD_SHA" in promote_text,
            "promotion must reject a stale head")
    require("headRepositoryOwner" in rearm_text,
            "trusted arm must make an explicit fork policy decision")
    require("authorization_check_id" in review_text and "expected_head_sha" in review_text,
            "review dispatch must carry trusted head/check identities")
    require('--allowedTools "Read,Grep,Glob"' in review_text,
            "secret-backed model review must not execute pull-request code")
    require("AI_REVIEW_APP_PRIVATE_KEY" in rearm_generator and "checks: write" not in rearm_generator and
            all(event in rearm_generator for event in ("opened", "synchronize", "reopened")),
            "generated arm callers must preserve head events and dedicated-App credential boundary")
    require("authorization_check_id" in promote_generator and
            "pull_request_target:" not in promote_generator,
            "generated promotion callers must accept only trusted explicit dispatches")

    forbidden = re.compile(r"\bsleep\b|check-runs\?per_page|MERGE_PROBE|ci-wait", re.I)
    for path, text in ((REVIEW, review_text), (PROMOTE, promote_text)):
        require(not forbidden.search(text), f"{path.name} still contains runner-held waiting")

    for path, data in ((REARM, rearm), (PROMOTE, promote)):
        for job in data["jobs"].values():
            for step in job.get("steps", []):
                uses = step.get("uses", "")
                if uses.startswith("actions/checkout"):
                    require(step.get("with", {}).get("ref") in ("main", "${{ github.event.repository.default_branch }}", "${{ steps.trusted-revision.outputs.sha }}"),
                            f"{path.name} may only checkout trusted base code")

    require("Required check configuration" in promote_text,
            "workflow must carry operator instructions for required-check identity migration")
    print("PASS: event-driven head authorization and native auto-merge contract")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
