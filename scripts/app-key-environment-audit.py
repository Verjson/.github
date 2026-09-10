#!/usr/bin/env python3
"""Audit App key storage and main-only admission using metadata, never key values."""

import argparse
import json
import re
import subprocess


ROLES = {
    "release": "RELEASE_APP_PRIVATE_KEY",
    "merge": "MERGE_APP_PRIVATE_KEY",
    "ai-review": "AI_REVIEW_APP_PRIVATE_KEY",
}


def github(path):
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", path],
        check=True, capture_output=True, text=True, timeout=60,
    )
    pages = json.loads(result.stdout)
    if not isinstance(pages, list) or not pages:
        raise ValueError("GitHub returned no metadata pages")
    return pages


def names(pages, field):
    values = []
    for page in pages:
        records = page.get(field)
        if not isinstance(records, list):
            raise ValueError("GitHub metadata collection is unavailable")
        for record in records:
            name = record.get("name")
            if not isinstance(name, str) or not name:
                raise ValueError("GitHub metadata identity is unavailable")
            values.append(name)
    if len(values) != len(set(values)) or any(type(page.get("total_count")) is not int or page["total_count"] != len(values) for page in pages):
        raise ValueError("GitHub metadata pagination is incomplete or inconsistent")
    return set(values)


def audit(repository, api=github):
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is None:
        raise ValueError("repository must be owner/name")
    metadata = api(f"repos/{repository}")[0]
    if metadata.get("default_branch") != "main":
        raise ValueError("repository default branch must be main")
    owner_type = metadata.get("owner", {}).get("type")
    if owner_type not in ("User", "Organization"):
        raise ValueError("repository owner identity is unavailable")
    keys = set(ROLES.values())
    broad_repo = names(api(f"repos/{repository}/actions/secrets?per_page=100"), "secrets") & keys
    broad_org = set()
    if owner_type == "Organization":
        owner = repository.split("/", 1)[0]
        broad_org = names(api(f"orgs/{owner}/actions/secrets?per_page=100"), "secrets") & keys
    missing = []
    for role, key in ROLES.items():
        name = f"{role}-app"
        path = f"repos/{repository}/environments/{name}"
        environment = api(path)[0]
        policy = environment.get("deployment_branch_policy")
        if (environment.get("name") != name
                or type(environment.get("id")) is not int or environment["id"] <= 0
                or not isinstance(policy, dict)
                or set(policy) != {"protected_branches", "custom_branch_policies"}
                or policy["protected_branches"] is not False
                or policy["custom_branch_policies"] is not True):
            raise ValueError(f"{name} must use explicit main-only branch admission")
        pages = api(path + "/deployment-branch-policies?per_page=100")
        if (names(pages, "branch_policies") != {"main"}
                or any(item.get("type") != "branch" for page in pages for item in page["branch_policies"])):
            raise ValueError(f"{name} permits a ref other than the main branch")
        if key not in names(api(path + "/secrets?per_page=100"), "secrets"):
            missing.append(f"{name}/{key}")
    return {
        "repository": repository,
        "compliant": not (broad_repo or broad_org or missing),
        "broadRepositoryKeys": sorted(broad_repo),
        "broadOrganizationKeys": sorted(broad_org),
        "missingEnvironmentKeys": missing,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    try:
        result = audit(args.repo)
    except (ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("App key isolation could not be verified; check metadata access and environment policy")
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0 if result["compliant"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
