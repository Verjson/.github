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
RETRY = ROOT / ".github/workflows/ai-promotion-retry.yml"
APP_TOKEN_ACTION = "actions/create-github-app-token"
IMMUTABLE_ACTION = re.compile(rf"^{re.escape(APP_TOKEN_ACTION)}@[0-9a-f]{{40}}$")
MODEL_ACTION_NAME = "anthropics/claude-code-action"
MODEL_ACTION_SHA = "dcb57747bfceeaa1fa72638cae52295d1d853d4a"
MODEL_ACTION = f"{MODEL_ACTION_NAME}@{MODEL_ACTION_SHA}"
IMMUTABLE_MODEL_ACTION = re.compile(
    rf"^{re.escape(MODEL_ACTION_NAME)}@[0-9a-f]{{40}}$")
TRUSTED_BOTS = {"renovate[bot]", "mend[bot]", "github-actions[bot]"}


def load(path: Path):
    with path.open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def validate_runner_free_external_ci_wait(workflow: dict, job_name: str) -> None:
    job = workflow["jobs"][job_name]
    scripts = "\n".join(step.get("run", "") for step in job.get("steps", []))
    endpoint = re.compile(
        r"commits/[^\s\"']+/(?:check-runs|status)(?:\?per_page=100)?")
    expected_queries = 1 if job_name == "privileged_merge" else 0
    require(len(endpoint.findall(scripts)) == expected_queries,
            f"{job_name} must contain exactly {expected_queries} external-CI endpoint snapshot(s) job-wide")

    # Endpoint spelling is not the trust boundary. Reject syntactically
    # infinite shell loops even when they poll through `gh pr checks`, a
    # variable, or another API spelling. A loop over an infinite condition is
    # allowed only when its own body carries an explicit terminating command;
    # this preserves the bounded fetch retry below while rejecting pure polls.
    infinite_loop = re.compile(
        r"(?:for\s*\(\(\s*;\s*;\s*\)\)|while\s+(?:true|:)|until\s+false)"
        r"\s*;?\s*do\b(?P<body>.*?)\bdone\b", re.I | re.S)
    for loop in infinite_loop.finditer(scripts):
        require(re.search(r"(?m)^\s*(?:break|return|exit)(?:\s|$)", loop.group("body")),
                f"{job_name} contains an unbounded loop with no terminating path")

    # Dynamically composing an external-CI endpoint is outside this contract:
    # the reserved `commits/<head>/(check-runs|status)` text is counted wherever
    # it appears, including variable assignments, and privileged_merge must also
    # retain this exact audited snapshot statement. Splitting the endpoint into
    # runtime fragments would remove that required statement and fail closed.
    allowed_snapshot = ('all_checks="$(gh api --paginate '
                        '"repos/$TARGET_REPO/commits/$EXPECTED_HEAD_SHA/check-runs?per_page=100"')
    if job_name == "privileged_merge":
        require(scripts.count(allowed_snapshot) == 1,
                "privileged_merge must retain its one audited literal CI snapshot")

    for step in job.get("steps", []):
        script = step.get("run", "")
        require(not re.search(r"\bsleep\b|ci-wait|MERGE_PROBE", script, re.I),
                f"{job_name} must not sleep or retain a polling-era CI wait")
        queries = list(endpoint.finditer(script))
        if not queries:
            continue
        prefix = script[:queries[0].start()]
        require(not re.search(r"(?m)^\s*(?:for\b|while\b|until\b)", prefix),
                f"{job_name} must not place its external-CI snapshot after a loop opener")


def authorization_app_token_uses(workflow: dict, job_name: str) -> str:
    steps = workflow["jobs"][job_name]["steps"]
    matches = [step.get("uses", "") for step in steps
               if step.get("name") == "Mint dedicated authorization App token"]
    require(len(matches) == 1,
            f"{job_name} must have exactly one dedicated authorization App token step")
    return matches[0]


def validate_authorization_app_token_inputs(workflow: dict, job_name: str) -> None:
    steps = workflow["jobs"][job_name]["steps"]
    token = next(step for step in steps
                 if step.get("name") == "Mint dedicated authorization App token")
    token_index = steps.index(token)
    inputs = token.get("with", {})
    require(inputs.get("client-id") == "${{ vars.AI_REVIEW_CLIENT_ID }}",
            f"{job_name} must mint with the dedicated App client ID")
    require("app-id" not in inputs,
            f"{job_name} token minting must reject the deprecated app-id input")
    env = workflow["jobs"][job_name].get("env", {})
    validation_indexes = [index for index, step in enumerate(steps)
                          if step.get("name") == "Validate authorization App client ID" and
                          '[[ "$APP_CLIENT_ID" =~ ^Iv[A-Za-z0-9.]{8,126}$ ]]' in step.get("run", "") and
                          "AI_REVIEW_CLIENT_ID is unavailable or malformed" in step.get("run", "")]
    require(env.get("APP_CLIENT_ID") == "${{ vars.AI_REVIEW_CLIENT_ID }}" and
            len(validation_indexes) == 1 and validation_indexes[0] < token_index,
            f"{job_name} must fail closed before minting with an absent or malformed client ID")


def validate_authorization_app_token_pins(uses_values: list[str]) -> None:
    require(all(IMMUTABLE_ACTION.fullmatch(uses) for uses in uses_values),
            "trusted authorization sites must use the official App-token action at a full lowercase 40-hex SHA")
    require(len(set(uses_values)) == 1,
            "trusted authorization sites must use the same immutable App-token action pin")


def validate_model_admission(steps: list[dict]) -> None:
    model_uses = [step.get("uses", "") for step in steps
                  if step.get("uses", "").startswith(f"{MODEL_ACTION_NAME}@")]
    require(model_uses and all(IMMUTABLE_MODEL_ACTION.fullmatch(uses)
                               for uses in model_uses),
            "every Claude review action must use a full lowercase 40-hex SHA")
    require(len(set(model_uses)) == 1 and model_uses[0] == MODEL_ACTION,
            "every Claude review pass must share the audited immutable action pin")
    model_indexes = [index for index, step in enumerate(steps)
                     if step.get("uses") == MODEL_ACTION]
    require(len(model_indexes) == 1, "review must retain exactly one automatic paid model pass")

    validation_indexes = [index for index, step in enumerate(steps)
                          if step.get("name") == "Validate trusted head authorization"]
    require(len(validation_indexes) == 1 and validation_indexes[0] < model_indexes[0],
            "receipt and pending-check validation must precede the model pass")
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
            "the model pass must retain exact source bot logins without normalized aliases")


def main() -> int:
    review_text = REVIEW.read_text(encoding="utf-8")
    rearm_text = REARM.read_text(encoding="utf-8")
    promote_text = PROMOTE.read_text(encoding="utf-8")
    retry_text = RETRY.read_text(encoding="utf-8")
    rearm_generator = (ROOT / "scripts/gen-gate-rearm-caller.sh").read_text(encoding="utf-8")
    promote_generator = (ROOT / "scripts/gen-privileged-merge-caller.sh").read_text(encoding="utf-8")
    verifier_text = (ROOT / "scripts/ci-gate/verify-arm-receipt.sh").read_text(encoding="utf-8")
    review = load(REVIEW)
    rearm = load(REARM)
    promote = load(PROMOTE)
    retry = load(RETRY)

    dispatch_inputs = review[True]["workflow_dispatch"]["inputs"]
    receipt_inputs = {"pr_number", "expected_head_sha", "authorization_check_id",
                      "arm_run_id", "arm_run_attempt"}
    require(receipt_inputs <= dispatch_inputs.keys() and
            all(dispatch_inputs[name].get("required") is True for name in receipt_inputs),
            "workflow_dispatch must require the exact head, App check, and arm-receipt identity")
    gate_steps = review["jobs"]["gate"]["steps"]
    validate_runner_free_external_ci_wait(review, "gate")
    validate_runner_free_external_ci_wait(promote, "privileged_merge")
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

    for invalid_uses in (f"{MODEL_ACTION_NAME}@v1",
                         f"{MODEL_ACTION_NAME}@{'a' * 40}"):
        mutated_pin_steps = [dict(step) for step in gate_steps]
        mutated_pin_steps[first_model] = {
            **mutated_pin_steps[first_model], "uses": invalid_uses,
        }
        try:
            validate_model_admission(mutated_pin_steps)
        except AssertionError:
            continue
        raise AssertionError(f"mutable or divergent Claude action pin escaped: {invalid_uses}")

    normalized_alias_steps = [dict(step) for step in gate_steps]
    normalized_alias_steps[first_model] = {
        **normalized_alias_steps[first_model],
        "with": {
            **normalized_alias_steps[first_model]["with"],
            "allowed_bots": "renovate,mend,github-actions",
        },
    }
    try:
        validate_model_admission(normalized_alias_steps)
    except AssertionError:
        pass
    else:
        raise AssertionError("normalized aliases escaped the source-login bot contract")

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
    validate_authorization_app_token_inputs(rearm, "arm")
    validate_authorization_app_token_inputs(review, "complete-authorization")

    for workflow, job_name in ((rearm, "arm"), (review, "complete-authorization")):
        mutated = yaml.safe_load(yaml.safe_dump(workflow))
        token = next(step for step in mutated["jobs"][job_name]["steps"]
                     if step.get("name") == "Mint dedicated authorization App token")
        token["with"]["app-id"] = token["with"].pop("client-id")
        try:
            validate_authorization_app_token_inputs(mutated, job_name)
        except AssertionError:
            continue
        raise AssertionError(f"{job_name} legacy app-id mutation escaped token-input contract")

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
            app_token["with"].get("permission-contents") == "read" and
            app_token["with"].get("permission-pull-requests") == "write",
            "dedicated completion App token must request the exact approval permission envelope")
    require('check-runs/$AUTHORIZATION_CHECK_ID' in review_text,
            "review must complete the exact check-run supplied by the trusted arm")
    require('head_sha:$sha' in rearm_text and '--arg sha "$head_sha"' in rearm_text,
            "authorization check must be bound to the exact current PR head")
    require("APP_ID: ${{ vars.AI_REVIEW_APP_ID }}" in rearm_text and
            "EXPECTED_APP_ID: ${{ vars.AI_REVIEW_APP_ID }}" in review_text and
            ".app.id" in rearm_text and ".app.id" in verifier_text,
            "numeric App ID must remain the receipt and check-run identity boundary")
    require("AI review authorization" in rearm_text and "AI review authorization" in promote_text,
            "arm and promotion must agree on the unambiguous required-check name")
    require("gh pr merge" in promote_text and "--admin --squash" in promote_text and
            '--match-head-commit "$EXPECTED_HEAD_SHA"' in promote_text,
            "trusted continuation must terminally merge only the exact authorized head")
    require("retention-days: 90" in rearm_text,
            "arm receipts must survive the supported long-lived hold window")
    require("REQUIRED_CHECK_POLICY" in promote_text and "vars.AI_REVIEW_REQUIRED_CHECKS" not in promote_text and
            "check-runs?per_page=100" in promote_text and "sort_by(.id) | last" in promote_text and
            ".workflow_id == $workflow_id" in promote_text and
            "actions/runs/$ci_run_id/jobs?per_page=100" in promote_text and
            ".check_suite.id" in promote_text and ".check_suite_id" in promote_text and
            ".check_run_url == $url" in promote_text and
            "head_workflow_blob" in promote_text and "trusted_workflow_blob" in promote_text,
            "terminal promotion must enforce latest-run App/workflow/revision-bound required CI")
    require("(.conclusion | ascii_upcase) == \"SUCCESS\"" in promote_text,
            "only successful authorization may permit terminal promotion")
    require(all(marker in verifier_text for marker in
                ('[ "$(<"$tmp/arm-workflow-id")" = "$arm_workflow_id" ]',
                 'actions/required_workflows/$arm_workflow_id',
                 'workflow_api arm-rules', '--paginate',
                 '.source_type == "Organization"', '.source == "Verjson"',
                 '.repository_id == 1269388380', '.ref == "refs/heads/main"',
                 '.event == "pull_request_target"',
                 '.path == ".github/workflows/gate-rearm.yml"', ".external_id == $external_id",
                 "artifact_digest", "actual_zip_sha")),
            "authorization must bind local or organization-required arm provenance, receipt digest, run, and dedicated App")
    verifier_invocation = re.compile(
        r"(?m)^(?P<indent>\s*)(?:GH_TOKEN=\"\$ACTIONS_TOKEN\" )?"
        r"(?P<shell>bash )?\.gate-trust/scripts/ci-gate/verify-arm-receipt\.sh"
        r"(?: \|\| receipt_ok=false)?$"
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

    forbidden = re.compile(r"\bsleep\b|MERGE_PROBE|ci-wait", re.I)
    for path, text in ((REVIEW, review_text), (PROMOTE, promote_text), (RETRY, retry_text)):
        require(not forbidden.search(text), f"{path.name} still contains runner-held waiting")
    require(promote_text.count("check-runs?per_page=100") == 1,
            "promotion must read required checks once rather than poll")

    mutated_review = yaml.safe_load(yaml.safe_dump(review))
    mutated_review["jobs"]["gate"]["steps"].append(
        {"run": "for attempt in $(seq 1 20); do gh api commits/head/check-runs?per_page=100; sleep 30; done"})
    mutated_promote = yaml.safe_load(yaml.safe_dump(promote))
    mutated_promote["jobs"]["privileged_merge"]["steps"].append(
        {"run": "until gh api commits/head/status?per_page=100; do sleep 30; done"})
    mutated_infinite = yaml.safe_load(yaml.safe_dump(review))
    mutated_infinite["jobs"]["gate"]["steps"].append(
        {"run": "for ((;;)); do gh api commits/head/check-runs; done"})
    mutated_second_step = yaml.safe_load(yaml.safe_dump(promote))
    mutated_second_step["jobs"]["privileged_merge"]["steps"].append(
        {"run": "gh api commits/head/check-runs"})
    mutated_multiline = yaml.safe_load(yaml.safe_dump(promote))
    promotion_script = mutated_multiline["jobs"]["privileged_merge"]["steps"][-1]["run"]
    mutated_multiline["jobs"]["privileged_merge"]["steps"][-1]["run"] = (
        "while\n  true\ndo\n" + promotion_script + "\ndone")
    mutated_indirect = yaml.safe_load(yaml.safe_dump(promote))
    mutated_indirect["jobs"]["privileged_merge"]["steps"].append(
        {"run": 'prefix="repos/$TARGET_REPO/com"\n'
                'suffix="mits/head/check-runs"\nendpoint="$prefix$suffix"\n'
                'while true; do gh api "$endpoint"; done'})
    mutated_pr_checks = yaml.safe_load(yaml.safe_dump(review))
    mutated_pr_checks["jobs"]["gate"]["steps"].append(
        {"run": "while true; do gh pr checks 7; done"})
    mutated_until_false = yaml.safe_load(yaml.safe_dump(review))
    mutated_until_false["jobs"]["gate"]["steps"].append(
        {"run": "until\nfalse\ndo\ngh pr checks 7\ndone"})
    for workflow, job_name in ((mutated_review, "gate"),
                               (mutated_promote, "privileged_merge"),
                               (mutated_infinite, "gate"),
                               (mutated_second_step, "privileged_merge"),
                               (mutated_multiline, "privileged_merge"),
                               (mutated_indirect, "privileged_merge"),
                               (mutated_pr_checks, "gate"),
                               (mutated_until_false, "gate")):
        try:
            validate_runner_free_external_ci_wait(workflow, job_name)
        except AssertionError:
            continue
        raise AssertionError(f"{job_name} polling-loop mutation escaped the structural contract")

    require(set(retry[True]) == {"workflow_run", "workflow_call"} and
            retry[True]["workflow_run"]["types"] == ["completed"],
            "CI retry must be callable by generated consumers and directly reachable only from completed deterministic workflows")
    require("ai-review-merge.yml" not in retry_text and MODEL_ACTION not in retry_text and
            "ai-privileged-merge.yml" in retry_text,
            "CI completion path must be structurally unable to invoke paid review")
    require("AI review authorization" in retry_text and "EXPECTED_APP_ID" in retry_text and
            "EXPECTED_APP_SLUG" in retry_text and "HEAD_SHA" in retry_text,
            "CI completion retry must rediscover exact-head dedicated-App evidence")
    require("--retry" in promote_generator and "ai-promotion-retry.yml" in promote_generator and
            "workflow_run:" in promote_generator and RETRY.name in promote_generator,
            "privileged caller generator must also emit the consumer CI-completion bridge")

    for path, data in ((REARM, rearm), (PROMOTE, promote)):
        for job in data["jobs"].values():
            for step in job.get("steps", []):
                uses = step.get("uses", "")
                if uses.startswith("actions/checkout"):
                    require(step.get("with", {}).get("ref") in ("main", "${{ github.event.repository.default_branch }}", "${{ steps.trusted-revision.outputs.sha }}"),
                            f"{path.name} may only checkout trusted base code")

    require("Required check configuration" in promote_text,
            "workflow must carry operator instructions for required-check identity migration")
    print("PASS: event-driven head authorization and terminal promotion contract")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
