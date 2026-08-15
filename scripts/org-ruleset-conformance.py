#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
POLICY = Path(
    os.environ.get(
        "ORG_RULESET_POLICY", ROOT / "config/org-ruleset-conformance-policy.json"
    )
)


class AuditDataError(Exception):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AuditDataError(f"duplicate object key {key!r}")
        result[key] = value
    return result


def load_json(text: str, source: str):
    try:
        return json.loads(text, object_pairs_hook=unique_object)
    except (json.JSONDecodeError, AuditDataError) as error:
        raise AuditDataError(f"{source} is not valid JSON: {error}") from None


def require_mapping(value, location: str):
    if not isinstance(value, dict):
        raise AuditDataError(f"{location} must be an object")
    return value


def require_array(value, location: str):
    if not isinstance(value, list):
        raise AuditDataError(f"{location} must be an array")
    return value


def require_string(value, location: str):
    if not isinstance(value, str) or not value.strip():
        raise AuditDataError(f"{location} must be a non-empty string")
    return value


def require_positive_integer(value, location: str):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise AuditDataError(f"{location} must be a positive integer")
    return value


def require_exact_keys(value: dict, expected: set[str], location: str):
    actual = set(value)
    if actual != expected:
        raise AuditDataError(
            f"{location} keys are {sorted(actual)}, expected {sorted(expected)}"
        )


def gh_json_pages(path: str):
    result = subprocess.run(
        [
            "gh",
            "api",
            "--hostname",
            "github.com",
            "--method",
            "GET",
            "--paginate",
            "--slurp",
            path,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(f"GitHub API read failed for {path}")
    pages = load_json(result.stdout, f"GitHub API response for {path}")
    if not isinstance(pages, list) or not pages:
        raise AuditDataError(f"GitHub API returned no pages for {path}")
    return pages


def read_policy():
    document = require_mapping(
        load_json(POLICY.read_text(encoding="utf-8"), "ruleset policy"),
        "ruleset policy",
    )
    require_exact_keys(
        document,
        {"organization", "release_authorization_bypass"},
        "ruleset policy",
    )
    organization = require_string(document["organization"], "ruleset policy.organization")
    actor = require_mapping(
        document["release_authorization_bypass"],
        "ruleset policy.release_authorization_bypass",
    )
    require_exact_keys(
        actor,
        {"actor_type", "actor_id", "bypass_mode"},
        "ruleset policy.release_authorization_bypass",
    )
    expected = {
        "actor_type": require_string(
            actor["actor_type"],
            "ruleset policy.release_authorization_bypass.actor_type",
        ),
        "actor_id": require_positive_integer(
            actor["actor_id"],
            "ruleset policy.release_authorization_bypass.actor_id",
        ),
        "bypass_mode": require_string(
            actor["bypass_mode"],
            "ruleset policy.release_authorization_bypass.bypass_mode",
        ),
    }
    if expected["actor_type"] != "Integration" or expected["bypass_mode"] != "always":
        raise AuditDataError(
            "release authorization policy must require an always-bypass Integration"
        )
    return organization, expected


def list_ruleset_ids(organization: str):
    pages = gh_json_pages(f"orgs/{organization}/rulesets?per_page=100")
    ruleset_ids = []
    seen = set()
    for page_index, page_value in enumerate(pages):
        page = require_array(page_value, f"ruleset listing page {page_index}")
        for entry_index, entry_value in enumerate(page):
            entry = require_mapping(
                entry_value,
                f"ruleset listing entry {entry_index} on page {page_index}",
            )
            ruleset_id = require_positive_integer(
                entry.get("id"),
                f"ruleset listing entry {entry_index} on page {page_index}.id",
            )
            if ruleset_id in seen:
                raise AuditDataError(f"ruleset listing contains duplicate ruleset id {ruleset_id}")
            seen.add(ruleset_id)
            ruleset_ids.append(ruleset_id)
    if not ruleset_ids:
        raise AuditDataError("ruleset listing contained no rulesets")
    return ruleset_ids


def validate_string_array(value, location: str):
    values = require_array(value, location)
    for index, item in enumerate(values):
        require_string(item, f"{location}[{index}]")
    return values


def read_ruleset(organization: str, ruleset_id: int):
    documents = gh_json_pages(f"orgs/{organization}/rulesets/{ruleset_id}")
    if len(documents) != 1:
        raise AuditDataError(
            f"ruleset {ruleset_id} detail returned {len(documents)} documents"
        )
    ruleset = require_mapping(documents[0], f"ruleset {ruleset_id}")
    detail_id = require_positive_integer(ruleset.get("id"), f"ruleset {ruleset_id}.id")
    if detail_id != ruleset_id:
        raise AuditDataError(
            f"ruleset detail id {detail_id} does not match requested id {ruleset_id}"
        )
    require_string(ruleset.get("name"), f"ruleset {ruleset_id}.name")
    source_type = require_string(
        ruleset.get("source_type"), f"ruleset {ruleset_id}.source_type"
    )
    if source_type != "Organization":
        raise AuditDataError(
            f"ruleset {ruleset_id}.source_type must be 'Organization'"
        )
    require_string(ruleset.get("target"), f"ruleset {ruleset_id}.target")
    enforcement = require_string(
        ruleset.get("enforcement"), f"ruleset {ruleset_id}.enforcement"
    )
    if enforcement not in {"active", "evaluate", "disabled"}:
        raise AuditDataError(f"ruleset {ruleset_id}.enforcement is unrecognized")

    conditions = require_mapping(
        ruleset.get("conditions"), f"ruleset {ruleset_id}.conditions"
    )
    ref_name = require_mapping(
        conditions.get("ref_name"), f"ruleset {ruleset_id}.conditions.ref_name"
    )
    validate_string_array(
        ref_name.get("include"), f"ruleset {ruleset_id}.conditions.ref_name.include"
    )
    validate_string_array(
        ref_name.get("exclude"), f"ruleset {ruleset_id}.conditions.ref_name.exclude"
    )

    actors = require_array(
        ruleset.get("bypass_actors"), f"ruleset {ruleset_id}.bypass_actors"
    )
    for actor_index, actor_value in enumerate(actors):
        actor = require_mapping(
            actor_value, f"ruleset {ruleset_id} bypass actor {actor_index}"
        )
        require_string(
            actor.get("actor_type"),
            f"ruleset {ruleset_id} bypass actor {actor_index}.actor_type",
        )
        actor_id = actor.get("actor_id")
        if actor_id is not None:
            require_positive_integer(
                actor_id, f"ruleset {ruleset_id} bypass actor {actor_index}.actor_id"
            )
        require_string(
            actor.get("bypass_mode"),
            f"ruleset {ruleset_id} bypass actor {actor_index}.bypass_mode",
        )

    rules = require_array(ruleset.get("rules"), f"ruleset {ruleset_id}.rules")
    for rule_index, rule_value in enumerate(rules):
        rule = require_mapping(rule_value, f"ruleset {ruleset_id} rule {rule_index}")
        require_string(rule.get("type"), f"ruleset {ruleset_id} rule {rule_index}.type")
    return ruleset


def targets_default_branch(ruleset: dict):
    return (
        ruleset["target"] == "branch"
        and "~DEFAULT_BRANCH" in ruleset["conditions"]["ref_name"]["include"]
    )


def has_expected_actor(ruleset: dict, expected: dict):
    return any(
        actor.get("actor_type") == expected["actor_type"]
        and actor.get("actor_id") == expected["actor_id"]
        and actor.get("bypass_mode") == expected["bypass_mode"]
        for actor in ruleset["bypass_actors"]
    )


def main() -> int:
    try:
        organization, expected_actor = read_policy()
        ruleset_ids = list_ruleset_ids(organization)
        rulesets = [read_ruleset(organization, ruleset_id) for ruleset_id in ruleset_ids]
    except (OSError, AuditDataError, RuntimeError) as error:
        print(f"ERROR: cannot establish organization ruleset state: {error}", file=sys.stderr)
        return 2

    default_branch_rulesets = [
        ruleset for ruleset in rulesets if targets_default_branch(ruleset)
    ]
    failures = [
        ruleset
        for ruleset in default_branch_rulesets
        if not has_expected_actor(ruleset, expected_actor)
    ]
    if failures:
        for ruleset in failures:
            print(
                f"ERROR: {ruleset['name']} ({ruleset['id']}): "
                "required release authorization bypass is absent",
                file=sys.stderr,
            )
        return 1

    print(
        f"ruleset-policy=conformant organization={organization} "
        f"rulesets={len(rulesets)} default_branch_rulesets={len(default_branch_rulesets)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
