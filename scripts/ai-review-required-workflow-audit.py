#!/usr/bin/env python3
import base64
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


class AuditError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)


def read_contract(path: Path = CONTRACT) -> dict:
    try:
        contract = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError(f"cannot read rollout contract: {error}") from None
    require(isinstance(contract, dict), "rollout contract must be an object")
    require(contract.get("schema_version") == 1, "unsupported rollout contract schema")
    require(
        isinstance(contract.get("organization"), str)
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", contract["organization"]) is not None,
        "contract organization is invalid",
    )
    ruleset = contract.get("ruleset")
    authorization = contract.get("authorization")
    require(isinstance(ruleset, dict), "contract ruleset is missing")
    require(isinstance(authorization, dict), "contract authorization policy is missing")
    for key in (
        "id",
        "name",
        "target",
        "conditions",
        "source_repository",
        "source_repository_id",
        "ref",
        "retired_path",
        "replacement_path",
    ):
        require(ruleset.get(key) not in (None, ""), f"contract ruleset.{key} is missing")
    require(
        ruleset["retired_path"] != ruleset["replacement_path"],
        "retired and replacement workflow paths must differ",
    )
    require(
        isinstance(ruleset["id"], int)
        and not isinstance(ruleset["id"], bool)
        and ruleset["id"] > 0
        and isinstance(ruleset["source_repository_id"], int)
        and not isinstance(ruleset["source_repository_id"], bool)
        and ruleset["source_repository_id"] > 0,
        "ruleset and source repository IDs must be positive integers",
    )
    require(
        ruleset["target"] == "branch" and isinstance(ruleset["conditions"], dict),
        "ruleset target or conditions are invalid",
    )
    for key in ("name", "source_repository", "ref", "retired_path", "replacement_path"):
        require(isinstance(ruleset[key], str), f"ruleset {key} must be a string")
    require(
        re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", ruleset["ref"]) is not None,
        "ruleset ref must be a full branch ref",
    )
    for key in ("retired_path", "replacement_path"):
        require(
            re.fullmatch(r"\.github/workflows/[A-Za-z0-9._-]+\.ya?ml", ruleset[key]) is not None,
            f"ruleset {key} is not a workflow path",
        )
    forbidden_contexts = ruleset.get("forbidden_required_status_contexts")
    require(
        isinstance(forbidden_contexts, list)
        and forbidden_contexts
        and all(isinstance(context, str) and context for context in forbidden_contexts)
        and len(forbidden_contexts) == len(set(forbidden_contexts)),
        "forbidden status contexts must be unique non-empty names",
    )
    require(
        isinstance(authorization.get("private_key_secret"), str)
        and re.fullmatch(r"[A-Z][A-Z0-9_]*", authorization["private_key_secret"]) is not None,
        "private-key secret is invalid",
    )
    variables = authorization.get("variables")
    require(
        isinstance(variables, list)
        and variables
        and all(
            isinstance(name, str) and re.fullmatch(r"[A-Z][A-Z0-9_]*", name) is not None
            for name in variables
        )
        and len(variables) == len(set(variables)),
        "authorization variables must be unique non-empty names",
    )
    permissions = authorization.get("app_permissions")
    require(
        isinstance(permissions, dict)
        and permissions
        and all(isinstance(key, str) and isinstance(value, str) for key, value in permissions.items()),
        "authorization App permissions are missing",
    )
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


def selected_repositories(read, organization: str, kind: str, name: str) -> set[str]:
    path = f"orgs/{organization}/actions/{kind}/{name}/repositories"
    repositories = paginated_items(read, path, "repositories")
    names = [repository.get("full_name") for repository in repositories]
    require(all(isinstance(name, str) and name for name in names), f"invalid repository grant for {name}")
    require(len(names) == len(set(names)), f"duplicate repository grant for {name}")
    return set(names)


def require_scope(
    read,
    organization: str,
    kind: str,
    name: str,
    governed: dict[str, bool],
) -> dict:
    item = single_object(read, f"orgs/{organization}/actions/{kind}/{name}")
    visibility = item.get("visibility")
    if visibility == "all":
        return item
    if visibility == "private":
        missing = sorted(repository for repository, private in governed.items() if not private)
    elif visibility == "selected":
        granted = selected_repositories(read, organization, kind, name)
        missing = sorted(set(governed) - granted)
    else:
        raise AuditError(f"{name} has unsupported visibility {visibility!r}")
    sample = missing[:8]
    suffix = f" (plus {len(missing) - len(sample)} more)" if len(missing) > len(sample) else ""
    require(
        not missing,
        f"{name} cannot reach {len(missing)} governed repositories; sample={sample}{suffix}",
    )
    return item


def audit(contract: dict, read=gh_pages) -> dict:
    organization = contract["organization"]
    ruleset_contract = contract["ruleset"]
    authorization = contract["authorization"]
    ruleset_id = ruleset_contract["id"]
    ruleset = single_object(read, f"orgs/{organization}/rulesets/{ruleset_id}")
    require(ruleset.get("name") == ruleset_contract["name"], "ruleset identity drifted")
    require(ruleset.get("enforcement") == "active", "ruleset is not active")
    require(
        ruleset.get("target") == ruleset_contract["target"]
        and ruleset.get("conditions") == ruleset_contract["conditions"],
        "ruleset target or conditions drifted from the reviewed scope",
    )

    workflow_rules = [rule for rule in ruleset.get("rules", []) if rule.get("type") == "workflows"]
    require(len(workflow_rules) == 1, "main-protection must contain exactly one workflows rule")
    workflows = workflow_rules[0].get("parameters", {}).get("workflows")
    require(isinstance(workflows, list) and len(workflows) == 1, "workflows rule must select exactly one workflow")
    require(
        workflow_rules[0].get("parameters", {}).get("do_not_enforce_on_create") is True,
        "required workflow must preserve repository-creation bypass",
    )
    selected = workflows[0]
    require(
        selected.get("repository_id") == ruleset_contract["source_repository_id"]
        and selected.get("ref") == ruleset_contract["ref"],
        "required workflow source or ref drifted",
    )
    current_path = selected.get("path")
    require(
        current_path in {ruleset_contract["retired_path"], ruleset_contract["replacement_path"]},
        f"unexpected required workflow path {current_path!r}",
    )

    rulesets = paginated_items(read, f"orgs/{organization}/rulesets")
    recognized_paths = []
    conflicting_status_rules = []
    for summary in rulesets:
        candidate = single_object(read, f"orgs/{organization}/rulesets/{summary.get('id')}")
        for rule in candidate.get("rules", []):
            parameters = rule.get("parameters", {})
            if rule.get("type") == "workflows":
                for workflow in parameters.get("workflows", []):
                    if workflow.get("path") in {
                        ruleset_contract["retired_path"],
                        ruleset_contract["replacement_path"],
                    }:
                        recognized_paths.append((candidate.get("id"), workflow.get("path")))
            if rule.get("type") == "required_status_checks":
                for check in parameters.get("required_status_checks", []):
                    if check.get("context") in ruleset_contract["forbidden_required_status_contexts"]:
                        conflicting_status_rules.append(
                            (candidate.get("id"), check.get("context"))
                        )
    require(
        recognized_paths == [(ruleset_id, current_path)],
        f"retired and replacement workflow identities are not exclusive: {recognized_paths}",
    )
    require(
        not conflicting_status_rules,
        f"retired or App authorization status is also required: {conflicting_status_rules}",
    )

    repositories = paginated_items(read, f"orgs/{organization}/repos?per_page=100&type=all")
    governed = {}
    for repository in repositories:
        full_name = repository.get("full_name")
        require(isinstance(full_name, str) and full_name, "organization repository has no full_name")
        require(full_name not in governed, f"duplicate organization repository {full_name}")
        governed[full_name] = bool(repository.get("private"))
    require(governed, "organization has no governed repositories")

    require_scope(
        read,
        organization,
        "secrets",
        authorization["private_key_secret"],
        governed,
    )
    variables = {
        name: require_scope(read, organization, "variables", name, governed)
        for name in authorization["variables"]
    }
    app_id = variables["AI_REVIEW_APP_ID"].get("value")
    app_slug = variables["AI_REVIEW_APP_SLUG"].get("value")
    client_id = variables["AI_REVIEW_CLIENT_ID"].get("value")
    require(isinstance(app_id, str) and app_id.isdigit() and int(app_id) > 0, "AI_REVIEW_APP_ID is invalid")
    require(
        isinstance(app_slug, str) and app_slug and app_slug == app_slug.lower(),
        "AI_REVIEW_APP_SLUG is invalid",
    )
    require(
        isinstance(client_id, str) and client_id.startswith("Iv") and len(client_id) >= 10,
        "AI_REVIEW_CLIENT_ID is invalid",
    )

    installations = paginated_items(read, f"orgs/{organization}/installations", "installations")
    matching = [
        installation
        for installation in installations
        if installation.get("app_id") == int(app_id) and installation.get("app_slug") == app_slug
    ]
    require(len(matching) == 1, "dedicated authorization App installation is missing or ambiguous")
    installation = matching[0]
    require(installation.get("suspended_at") is None, "authorization App installation is suspended")
    require(
        installation.get("repository_selection") == "all",
        "authorization App installation does not cover future ~ALL repositories",
    )
    permissions = installation.get("permissions", {})
    require(
        all(permissions.get(name) == value for name, value in authorization["app_permissions"].items()),
        "authorization App permissions drifted",
    )

    source_path = ruleset_contract["replacement_path"]
    source_ref = ruleset_contract["ref"].removeprefix("refs/heads/")
    source = single_object(
        read,
        f"repos/{ruleset_contract['source_repository']}/contents/{source_path}?ref={source_ref}",
    )
    try:
        workflow = yaml.load(base64.b64decode(source["content"]), Loader=yaml.BaseLoader)
    except (KeyError, ValueError, yaml.YAMLError) as error:
        raise AuditError(f"replacement workflow is unreadable: {error}") from None
    require(isinstance(workflow, dict), "replacement workflow is not a YAML object")
    triggers = workflow.get("on")
    require(
        isinstance(triggers, dict) and "pull_request_target" in triggers,
        "replacement workflow lacks a ruleset-supported pull_request_target trigger",
    )
    arm = workflow.get("jobs", {}).get("arm", {})
    require(
        arm.get("continue-on-error") == "true",
        "replacement arm can veto the ADR 0090 human merge path",
    )

    return {
        "organization": organization,
        "ruleset_id": ruleset_id,
        "current_path": current_path,
        "replacement_path": ruleset_contract["replacement_path"],
        "governed_repositories": len(governed),
        "state": "retargeted" if current_path == ruleset_contract["replacement_path"] else "ready",
    }


def main() -> int:
    try:
        report = audit(read_contract())
    except AuditError as error:
        print(f"ERROR: authorization-arm-rollout-not-ready: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
