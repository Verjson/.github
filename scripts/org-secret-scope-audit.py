#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
POLICY = Path(os.environ.get("ORG_SECRET_POLICY", ROOT / "config/org-actions-secret-policy.json"))


def gh_json(path: str):
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", path], capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise RuntimeError(f"GitHub API read failed for {path}")
    documents = json.loads(result.stdout)
    if not isinstance(documents, list) or not documents:
        raise RuntimeError(f"GitHub API returned no data for {path}")
    return documents


def selected_repositories(org: str, name: str) -> list[str]:
    pages = gh_json(f"orgs/{org}/actions/secrets/{name}/repositories")
    try:
        return sorted(repo["full_name"] for page in pages for repo in page["repositories"])
    except (KeyError, TypeError):
        raise RuntimeError(f"GitHub API returned malformed selected grants for {name}") from None


def main() -> int:
    try:
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        org = policy["organization"]
        expected = policy["secrets"]
        listing = gh_json(f"orgs/{org}/actions/secrets?per_page=100")
        pages = listing
        actual = {secret["name"]: secret for page in pages for secret in page.get("secrets", [])}
    except (OSError, ValueError, KeyError, RuntimeError) as error:
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
            except RuntimeError as error:
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
