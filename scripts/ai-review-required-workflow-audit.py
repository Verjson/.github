#!/usr/bin/env python3
import argparse
import base64
import copy
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parent.parent
CONTRACT = Path(
    os.environ.get(
        "AI_REVIEW_RULESET_CONTRACT",
        ROOT / "config/ai-review-required-workflow-rollout.json",
    )
)
RULESET_FIELDS = ("name", "target", "enforcement", "bypass_actors", "conditions", "rules")


class AuditError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)


def workflow_path(payload: dict) -> str:
    workflow_rules = [rule for rule in payload["rules"] if rule.get("type") == "workflows"]
    require(len(workflow_rules) == 1, "ruleset image must contain exactly one workflows rule")
    parameters = workflow_rules[0].get("parameters", {})
    require(parameters.get("do_not_enforce_on_create") is True, "repository-creation bypass drifted")
    workflows = parameters.get("workflows")
    require(isinstance(workflows, list) and len(workflows) == 1, "workflows rule must select one workflow")
    path = workflows[0].get("path")
    require(isinstance(path, str), "required workflow path is invalid")
    return path


def read_contract(path: Path = CONTRACT) -> dict:
    try:
        contract = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError(f"cannot read rollout contract: {error}") from None
    require(isinstance(contract, dict), "rollout contract must be an object")
    require(contract.get("schema_version") == 2, "unsupported rollout contract schema")
    organization = contract.get("organization")
    require(
        isinstance(organization, str)
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", organization) is not None,
        "contract organization is invalid",
    )
    ruleset_id = contract.get("ruleset_id")
    require(
        isinstance(ruleset_id, int) and not isinstance(ruleset_id, bool) and ruleset_id > 0,
        "ruleset ID must be a positive integer",
    )
    for name in ("retired_path", "replacement_path"):
        value = contract.get(name)
        require(
            isinstance(value, str)
            and re.fullmatch(r"\.github/workflows/[A-Za-z0-9._-]+\.ya?ml", value) is not None,
            f"contract {name} is invalid",
        )
    require(contract["retired_path"] != contract["replacement_path"], "workflow paths must differ")

    images = {}
    for name in ("preimage", "postimage", "rollback_payload"):
        image = contract.get(name)
        require(isinstance(image, dict), f"contract {name} is missing")
        require(set(image) == set(RULESET_FIELDS), f"contract {name} is not a complete mutation payload")
        images[name] = image
    require(images["rollback_payload"] == images["preimage"], "rollback payload must equal the verified preimage")
    require(workflow_path(images["preimage"]) == contract["retired_path"], "preimage does not select the retired workflow")
    require(workflow_path(images["postimage"]) == contract["replacement_path"], "postimage does not select the replacement workflow")
    derived = copy.deepcopy(images["preimage"])
    for rule in derived["rules"]:
        if rule.get("type") == "workflows":
            rule["parameters"]["workflows"][0]["path"] = contract["replacement_path"]
    require(derived == images["postimage"], "postimage changes fields beyond the intended workflow path")

    for name in ("forbidden_required_status_contexts", "deterministic_required_status_contexts"):
        values = contract.get(name)
        require(
            isinstance(values, list)
            and values
            and all(isinstance(value, str) and value for value in values)
            and len(values) == len(set(values)),
            f"contract {name} must contain unique non-empty contexts",
        )
    require(
        not set(contract["forbidden_required_status_contexts"])
        & set(contract["deterministic_required_status_contexts"]),
        "forbidden and deterministic contexts overlap",
    )
    for name in ("core_checks_property", "core_checks_value"):
        require(
            isinstance(contract.get(name), str) and contract[name],
            f"contract {name} is invalid",
        )
    deterministic_rulesets = contract.get("deterministic_rulesets")
    require(isinstance(deterministic_rulesets, list) and deterministic_rulesets, "deterministic rulesets are missing")
    ids = []
    stacks = []
    allowed_contexts = set(contract["deterministic_required_status_contexts"])
    for index, declaration in enumerate(deterministic_rulesets):
        require(isinstance(declaration, dict), f"deterministic ruleset {index} is invalid")
        ruleset_id = declaration.get("id")
        stack = declaration.get("stack")
        image = declaration.get("image")
        require(
            isinstance(ruleset_id, int) and not isinstance(ruleset_id, bool) and ruleset_id > 0,
            f"deterministic ruleset {index} ID is invalid",
        )
        require(isinstance(stack, str) and stack, f"deterministic ruleset {index} stack is invalid")
        require(
            isinstance(image, dict) and set(image) == set(RULESET_FIELDS),
            f"deterministic ruleset {index} image is incomplete",
        )
        contexts = {
            check.get("context")
            for rule in image["rules"]
            if rule.get("type") == "required_status_checks"
            for check in rule.get("parameters", {}).get("required_status_checks", [])
        }
        require(contexts and contexts <= allowed_contexts, f"deterministic ruleset {index} contexts are invalid")
        ids.append(ruleset_id)
        stacks.append(stack)
    require(len(ids) == len(set(ids)), "deterministic ruleset IDs must be unique")
    require(len(stacks) == len(set(stacks)), "deterministic stack declarations must be unique")

    authorization = contract.get("authorization")
    require(isinstance(authorization, dict), "authorization contract is missing")
    secret = authorization.get("private_key_secret")
    variables = authorization.get("variables")
    require(secret == "AI_REVIEW_APP_PRIVATE_KEY", "private-key secret is invalid")
    require(
        isinstance(variables, list)
        and variables
        and all(
            isinstance(name, str) and re.fullmatch(r"[A-Z][A-Z0-9_]*", name) is not None
            for name in variables
        )
        and len(variables) == len(set(variables)),
        "authorization variables are invalid",
    )
    require(
        variables == ["AI_REVIEW_APP_ID", "AI_REVIEW_APP_SLUG", "AI_REVIEW_CLIENT_ID"],
        "authorization variable contract drifted",
    )
    permissions = authorization.get("app_permissions")
    require(
        permissions
        == {
            "checks": "write",
            "contents": "read",
            "metadata": "read",
            "pull_requests": "write",
        },
        "authorization App permission contract drifted",
    )
    require(authorization.get("app_events") == [], "authorization App event contract drifted")
    return contract


def gh_pages(path: str) -> list:
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", path],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise AuditError(f"GitHub API read failed for {path}")
    try:
        pages = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AuditError(f"GitHub API returned invalid JSON for {path}: {error}") from None
    require(isinstance(pages, list) and pages, f"GitHub API returned no data for {path}")
    return pages


def single_object(read, path: str) -> dict:
    pages = read(path)
    require(len(pages) == 1 and isinstance(pages[0], dict), f"unexpected response shape for {path}")
    return pages[0]


def paginated_items(read, path: str, field: str | None = None) -> list[dict]:
    items = []
    for index, page in enumerate(read(path)):
        values = page.get(field) if field and isinstance(page, dict) else page
        require(isinstance(values, list), f"unexpected page {index} shape for {path}")
        require(all(isinstance(value, dict) for value in values), f"invalid item in {path}")
        items.extend(values)
    return items


def normalize_ruleset(live: dict) -> dict:
    require(all(field in live for field in RULESET_FIELDS), "live ruleset omits mutation fields")
    return {field: live[field] for field in RULESET_FIELDS}


def concise_missing(name: str, missing: list[str]) -> None:
    sample = missing[:8]
    suffix = f" (plus {len(missing) - len(sample)} more)" if len(missing) > len(sample) else ""
    require(not missing, f"{name}: missing={len(missing)} sample={sample}{suffix}")


def selected_repositories(read, organization: str, kind: str, name: str) -> set[str]:
    path = f"orgs/{organization}/actions/{kind}/{name}/repositories"
    repositories = paginated_items(read, path, "repositories")
    names = [repository.get("full_name") for repository in repositories]
    require(all(isinstance(value, str) and value for value in names), f"invalid repository grant for {name}")
    require(len(names) == len(set(names)), f"duplicate repository grant for {name}")
    return set(names)


def require_scope(read, organization: str, kind: str, name: str, governed: dict[str, bool]) -> dict:
    item = single_object(read, f"orgs/{organization}/actions/{kind}/{name}")
    visibility = item.get("visibility")
    if visibility == "all":
        return item
    if visibility == "private":
        missing = sorted(repository for repository, private in governed.items() if not private)
    elif visibility == "selected":
        missing = sorted(set(governed) - selected_repositories(read, organization, kind, name))
    else:
        raise AuditError(f"{name} has unsupported visibility {visibility!r}")
    concise_missing(f"{name} cannot reach governed repositories", missing)
    return item


def verify_ruleset_state(contract: dict, read, expected: str | None = None) -> tuple[str, dict]:
    path = f"orgs/{contract['organization']}/rulesets/{contract['ruleset_id']}"
    live = normalize_ruleset(single_object(read, path))
    if live == contract["preimage"]:
        state = "ready"
    elif live == contract["postimage"]:
        state = "retargeted"
    else:
        raise AuditError("main-protection differs from both full reviewed preimage and postimage")
    require(expected is None or state == expected, f"ruleset state is {state}, expected {expected}")
    return state, live


def verify_ruleset_exclusivity(contract: dict, read, current_path: str) -> dict[int, dict]:
    organization = contract["organization"]
    recognized = []
    conflicts = []
    candidates = {}
    for summary in paginated_items(read, f"orgs/{organization}/rulesets"):
        candidate = single_object(read, f"orgs/{organization}/rulesets/{summary.get('id')}")
        candidate_id = candidate.get("id")
        require(isinstance(candidate_id, int) and candidate_id not in candidates, "organization ruleset identity is invalid")
        candidates[candidate_id] = candidate
        for rule in candidate.get("rules", []):
            parameters = rule.get("parameters", {})
            if rule.get("type") == "workflows":
                for workflow in parameters.get("workflows", []):
                    if workflow.get("path") in {contract["retired_path"], contract["replacement_path"]}:
                        recognized.append((candidate.get("id"), workflow.get("path")))
            if rule.get("type") == "required_status_checks":
                for check in parameters.get("required_status_checks", []):
                    if check.get("context") in contract["forbidden_required_status_contexts"]:
                        conflicts.append((candidate.get("id"), check.get("context")))
    require(
        recognized == [(contract["ruleset_id"], current_path)],
        f"retired and replacement workflow identities are not exclusive: {recognized}",
    )
    require(not conflicts, f"retired or App authorization status is also required: {conflicts}")
    return candidates


def verify_deterministic_ci(
    contract: dict,
    read,
    repositories: list[dict],
    candidates: dict[int, dict],
) -> None:
    declarations = {}
    for declaration in contract["deterministic_rulesets"]:
        ruleset_id = declaration["id"]
        require(ruleset_id in candidates, f"deterministic ruleset {ruleset_id} is absent")
        require(
            normalize_ruleset(candidates[ruleset_id]) == declaration["image"],
            f"deterministic ruleset {ruleset_id} drifted from its full reviewed image",
        )
        declarations[declaration["stack"]] = declaration
    property_rows = paginated_items(
        read,
        f"orgs/{contract['organization']}/properties/values?per_page=100",
    )
    properties_by_repository = {}
    for row in property_rows:
        full_name = row.get("repository_full_name")
        values = row.get("properties")
        require(
            isinstance(full_name, str)
            and full_name not in properties_by_repository
            and isinstance(values, list),
            "organization property inventory is invalid",
        )
        properties_by_repository[full_name] = {
            item.get("property_name"): item.get("value")
            for item in values
            if isinstance(item, dict)
        }
    missing = []
    for repository in repositories:
        full_name = repository["full_name"]
        values = properties_by_repository.get(full_name, {})
        stack = values.get("verjson-stack")
        if (
            values.get(contract["core_checks_property"]) != contract["core_checks_value"]
            or stack not in declarations
        ):
            missing.append(full_name)
    concise_missing("governed default branches without canonical deterministic required CI", sorted(missing))


def verify_no_repository_shadowing(contract: dict, read, repositories: list[dict]) -> None:
    authorization = contract["authorization"]
    protected_secret = authorization["private_key_secret"]
    protected_variables = set(authorization["variables"])
    shadows = []
    for repository in repositories:
        full_name = repository["full_name"]
        secrets = paginated_items(read, f"repos/{full_name}/actions/secrets?per_page=100", "secrets")
        variables = paginated_items(read, f"repos/{full_name}/actions/variables?per_page=100", "variables")
        if protected_secret in {item.get("name") for item in secrets}:
            shadows.append(f"{full_name}:secret:{protected_secret}")
        for name in sorted(protected_variables & {item.get("name") for item in variables}):
            shadows.append(f"{full_name}:variable:{name}")
    concise_missing("repository-level authorization credential shadowing", shadows)


def verify_authorization(contract: dict, read, governed: dict[str, bool]) -> None:
    organization = contract["organization"]
    authorization = contract["authorization"]
    require_scope(read, organization, "secrets", authorization["private_key_secret"], governed)
    variables = {
        name: require_scope(read, organization, "variables", name, governed)
        for name in authorization["variables"]
    }
    app_id = variables["AI_REVIEW_APP_ID"].get("value")
    app_slug = variables["AI_REVIEW_APP_SLUG"].get("value")
    client_id = variables["AI_REVIEW_CLIENT_ID"].get("value")
    require(isinstance(app_id, str) and app_id.isdigit() and int(app_id) > 0, "AI_REVIEW_APP_ID is invalid")
    require(isinstance(app_slug, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]*", app_slug), "AI_REVIEW_APP_SLUG is invalid")
    require(isinstance(client_id, str) and re.fullmatch(r"Iv[A-Za-z0-9.]{8,126}", client_id), "AI_REVIEW_CLIENT_ID is invalid")
    installations = paginated_items(read, f"orgs/{organization}/installations", "installations")
    matching = [
        installation
        for installation in installations
        if installation.get("app_id") == int(app_id) and installation.get("app_slug") == app_slug
    ]
    require(len(matching) == 1, "dedicated authorization App installation is missing or ambiguous")
    installation = matching[0]
    require(installation.get("suspended_at") is None, "authorization App installation is suspended")
    require(installation.get("repository_selection") == "all", "authorization App installation is not ~ALL")
    require(installation.get("permissions") == authorization["app_permissions"], "authorization App permission map drifted")
    require(installation.get("events") == authorization["app_events"], "authorization App event subscriptions drifted")


def verify_replacement_workflow(contract: dict, read) -> None:
    workflow_rule = next(rule for rule in contract["postimage"]["rules"] if rule["type"] == "workflows")
    selected = workflow_rule["parameters"]["workflows"][0]
    source = single_object(
        read,
        f"repositories/{selected['repository_id']}/contents/{selected['path']}?ref={selected['ref']}",
    )
    try:
        workflow = yaml.load(base64.b64decode(source["content"]), Loader=yaml.BaseLoader)
    except (KeyError, ValueError, yaml.YAMLError) as error:
        raise AuditError(f"replacement workflow is unreadable: {error}") from None
    require(isinstance(workflow, dict), "replacement workflow is not a YAML object")
    triggers = workflow.get("on")
    require(isinstance(triggers, dict) and "pull_request_target" in triggers, "replacement lacks pull_request_target")
    arm = workflow.get("jobs", {}).get("arm", {})
    require(arm.get("continue-on-error") == "true", "replacement can veto ADR 0090 human merges")
    require(arm.get("runs-on") == "ubuntu-24.04", "required arm is not on provider-hosted capacity")


def audit(contract: dict, read=gh_pages) -> dict:
    state, live = verify_ruleset_state(contract, read)
    current_path = workflow_path(live)
    candidates = verify_ruleset_exclusivity(contract, read, current_path)
    repositories = paginated_items(
        read,
        f"orgs/{contract['organization']}/repos?per_page=100&type=all",
    )
    require(repositories, "organization has no governed repositories")
    governed = {}
    for repository in repositories:
        full_name = repository.get("full_name")
        require(isinstance(full_name, str) and full_name, "organization repository has no full_name")
        require(full_name not in governed, f"duplicate organization repository {full_name}")
        governed[full_name] = bool(repository.get("private"))
    verify_deterministic_ci(contract, read, repositories, candidates)
    verify_no_repository_shadowing(contract, read, repositories)
    verify_authorization(contract, read, governed)
    verify_replacement_workflow(contract, read)
    return {
        "organization": contract["organization"],
        "ruleset_id": contract["ruleset_id"],
        "current_path": current_path,
        "replacement_path": contract["replacement_path"],
        "governed_repositories": len(governed),
        "state": state,
    }


def render_payload(contract: dict, mode: str, read=gh_pages) -> dict:
    if mode == "retarget":
        require(audit(contract, read)["state"] == "ready", "retarget payload requires ready preflight")
        return contract["postimage"]
    verify_ruleset_state(contract, read, "retargeted")
    return contract["rollback_payload"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit the AI authorization-arm ruleset rollout")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--render-retarget-payload", action="store_true")
    modes.add_argument("--render-rollback-payload", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        contract = read_contract()
        if args.render_retarget_payload:
            result = render_payload(contract, "retarget")
        elif args.render_rollback_payload:
            result = render_payload(contract, "rollback")
        else:
            result = audit(contract)
    except AuditError as error:
        print(f"ERROR: authorization-arm-rollout-not-ready: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
