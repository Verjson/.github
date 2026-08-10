#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
POLICY = Path(os.environ.get("ORG_SECRET_POLICY", ROOT / "config/org-actions-secret-policy.json"))


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


def require_nonempty_string(value, location: str):
    if not isinstance(value, str) or not value.strip():
        raise AuditDataError(f"{location} must be a non-empty string")
    return value


def duplicate_names(values):
    seen = set()
    duplicates = set()
    for value in values:
        if value in seen:
            duplicates.add(value)
        seen.add(value)
    return sorted(duplicates)


def gh_json(path: str):
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", path], capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise RuntimeError(f"GitHub API read failed for {path}")
    documents = load_json(result.stdout, f"GitHub API response for {path}")
    if not isinstance(documents, list) or not documents:
        raise AuditDataError(f"GitHub API returned no data for {path}")
    return documents


def selected_repositories(org: str, name: str) -> list[str]:
    pages = gh_json(f"orgs/{org}/actions/secrets/{name}/repositories")
    names = []
    for index, page_value in enumerate(pages):
        page = require_mapping(page_value, f"selected grants page {index} for {name}")
        repositories = page.get("repositories")
        if not isinstance(repositories, list):
            raise AuditDataError(f"selected grants page {index} for {name}.repositories must be an array")
        for repo_index, repo_value in enumerate(repositories):
            repo = require_mapping(repo_value, f"selected repository {repo_index} for {name}")
            names.append(require_nonempty_string(repo.get("full_name"), f"selected repository {repo_index} for {name}.full_name"))
    duplicates = duplicate_names(names)
    if duplicates:
        raise AuditDataError(f"selected grants for {name} contain duplicate repositories: {duplicates}")
    return sorted(names)


def main() -> int:
    try:
        policy = require_mapping(load_json(POLICY.read_text(encoding="utf-8"), "secret policy"), "secret policy")
        org = require_nonempty_string(policy.get("organization"), "secret policy.organization")
        expected = require_mapping(policy.get("secrets"), "secret policy.secrets")
        for name, rule in expected.items():
            require_nonempty_string(name, "secret policy secret name")
            require_mapping(rule, f"secret policy.secrets.{name}")
        listing = gh_json(f"orgs/{org}/actions/secrets?per_page=100")
        actual = {}
        for page_index, page_value in enumerate(listing):
            page = require_mapping(page_value, f"secret listing page {page_index}")
            secrets = page.get("secrets")
            if not isinstance(secrets, list):
                raise AuditDataError(f"secret listing page {page_index}.secrets must be an array")
            for secret_index, secret_value in enumerate(secrets):
                secret = require_mapping(secret_value, f"secret listing entry {secret_index} on page {page_index}")
                name = require_nonempty_string(secret.get("name"), f"secret listing entry {secret_index} on page {page_index}.name")
                if name in actual:
                    raise AuditDataError(f"secret listing contains duplicate secret {name!r}")
                actual[name] = secret
    except (OSError, AuditDataError, RuntimeError) as error:
        print(f"ERROR: cannot establish secret policy state: {error}", file=sys.stderr)
        return 2

    failures = []
    if set(actual) != set(expected):
        failures.append(
            f"manifest mismatch: unmanifested={sorted(set(actual) - set(expected))} "
            f"absent_live={sorted(set(expected) - set(actual))}"
        )

    for name in sorted(set(actual) & set(expected)):
        rule = expected[name]
        visibility = actual[name].get("visibility")
        target = rule.get("target_visibility")
        consumers = rule.get("consumers")
        reason = rule.get("reason")
        repositories = rule.get("selected_repositories")
        if (
            target not in {"all", "private", "selected"}
            or not isinstance(consumers, list)
            or not consumers
            or not all(isinstance(consumer, str) and consumer.strip() for consumer in consumers)
            or not isinstance(reason, str)
            or not reason.strip()
            or not isinstance(repositories, list)
            or not all(isinstance(repository, str) and repository.strip() for repository in repositories)
        ):
            failures.append(f"{name}: incomplete policy justification")
            continue
        duplicate_repositories = duplicate_names(repositories)
        if duplicate_repositories:
            failures.append(
                f"{name}: policy contains duplicate repositories: {duplicate_repositories}"
            )
            continue
        if target != "selected" and repositories:
            failures.append(f"{name}: non-selected policy must not name repositories")
        if target == "selected" and not repositories:
            failures.append(f"{name}: selected policy has no repositories")
        if visibility != target:
            failures.append(f"{name}: visibility is {visibility!r}, policy requires {target!r}")
            continue
        if target == "selected":
            try:
                granted = selected_repositories(org, name)
            except (AuditDataError, RuntimeError) as error:
                failures.append(f"{name}: {error}")
                continue
            if granted != sorted(repositories):
                failures.append(
                    f"{name}: selected grants differ; actual={granted} expected={sorted(repositories)}"
                )

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1
    print(f"secret-scope-policy=conformant organization={org} secrets={len(expected)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
