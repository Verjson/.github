#!/usr/bin/env python3
"""Fail a PR that allocates an ADR directory number already spoken for.

`docs/decisions/NNNN-<slug>/` numbers are picked by each PR author as "the
next free number as seen from main". Two PRs open at the same time cannot
see each other's allocation, so both can pick the same number -- observed
live as three concurrent PRs all allocating 0004 (Verjson/.github#983).
`scripts/gen-adr-index.sh` only ever looks at one PR's own tree, so it
faithfully regenerates an index with two 0004s, and git merges the two
differently-named directories without a conflict. The collision lands on
`main` silently.

This check reads live GitHub state instead of the PR's own tree:

  1. The PR's own added (or renamed-into) docs/decisions/NNNN-<slug>/ paths.
  2. The ADR directories that already exist on `main`.
  3. The added docs/decisions/NNNN-<slug>/ paths of every other currently
     open pull request.

...and fails loudly the moment a PR's number collides with (1) a
*different* path already on `main`, or (2) a *different* path newly added
by another open PR. It does not touch the numbering convention itself --
see Verjson/.github#983 for the deferred, larger options.

  scripts/ci-gate/adr-number-collision.py --repo Verjson/.github --pr-number 983

Requires `gh` authenticated against the target repository (GH_TOKEN).
"""
import argparse
import json
import re
import subprocess
import sys

ADR_PATH_RE = re.compile(r"^docs/decisions/([0-9]{4})-([^/]+)/")
ADR_DIR_NAME_RE = re.compile(r"^([0-9]{4})-([^/]+)$")

# GitHub reports a moved-and-content-preserved file as "renamed" rather than
# "added" -- a PR that renumbers its own ADR to dodge a collision still goes
# through this, so it must count as a new allocation too.
NEW_PATH_STATUSES = ("added", "renamed")


class CollisionCheckError(Exception):
    """GitHub state could not be established -- the check fails closed."""


def gh_json(path: str, *, paginate: bool):
    command = ["gh", "api", "--hostname", "github.com", "--method", "GET"]
    if paginate:
        command += ["--paginate", "--slurp"]
    command.append(path)
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise CollisionCheckError(
            f"GitHub API read failed for {path}: {result.stderr.strip()}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise CollisionCheckError(
            f"GitHub API response for {path} is not valid JSON: {error}"
        ) from None
    if not paginate:
        return payload
    if not isinstance(payload, list):
        raise CollisionCheckError(f"GitHub API returned no pages for {path}")
    items = []
    for page in payload:
        if not isinstance(page, list):
            raise CollisionCheckError(f"GitHub API page for {path} is not an array")
        items.extend(page)
    return items


def added_adr_directories(files: list) -> dict[str, str]:
    """number -> docs/decisions/NNNN-slug, from a pull request's changed files."""
    numbers: dict[str, str] = {}
    for entry in files:
        if not isinstance(entry, dict):
            raise CollisionCheckError("a pull request file entry is not an object")
        if entry.get("status") not in NEW_PATH_STATUSES:
            continue
        filename = entry.get("filename")
        if not isinstance(filename, str):
            continue
        match = ADR_PATH_RE.match(filename)
        if not match:
            continue
        number, slug = match.group(1), match.group(2)
        numbers.setdefault(number, f"docs/decisions/{number}-{slug}")
    return numbers


def main_adr_directories(entries: list) -> dict[str, str]:
    """number -> docs/decisions/NNNN-slug, from the live main tree."""
    if not isinstance(entries, list):
        raise CollisionCheckError(
            "GitHub API returned a non-directory listing for docs/decisions on main"
        )
    numbers: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise CollisionCheckError("a docs/decisions entry on main is not an object")
        if entry.get("type") != "dir":
            continue
        name = entry.get("name")
        if not isinstance(name, str):
            continue
        match = ADR_DIR_NAME_RE.match(name)
        if not match:
            continue
        numbers[match.group(1)] = f"docs/decisions/{name}"
    return numbers


def find_collisions(
    pr_numbers: dict[str, str],
    main_numbers: dict[str, str],
    other_open_pr_numbers: dict[str, list[tuple[int, str]]],
) -> list[str]:
    problems = []
    for number, pr_path in sorted(pr_numbers.items()):
        main_path = main_numbers.get(number)
        if main_path == pr_path:
            # Not a new allocation: this PR is editing an ADR that already
            # exists on main under this exact number and path.
            continue
        if main_path is not None:
            problems.append(
                f"ADR number {number}: this PR adds {pr_path}, but {main_path} "
                "already exists on main under the same number. Pick a free number."
            )
            continue
        for other_pr_number, other_path in other_open_pr_numbers.get(number, []):
            if other_path == pr_path:
                continue
            problems.append(
                f"ADR number {number}: this PR adds {pr_path}, which collides "
                f"with {other_path} newly added by open PR #{other_pr_number}. "
                "Coordinate before either merges."
            )
    return problems


def fetch_state(repo: str, pr_number: int):
    pr_files = gh_json(f"repos/{repo}/pulls/{pr_number}/files?per_page=100", paginate=True)
    pr_numbers = added_adr_directories(pr_files)
    if not pr_numbers:
        return pr_numbers, {}, {}

    main_entries = gh_json(f"repos/{repo}/contents/docs/decisions?ref=main", paginate=False)
    main_numbers = main_adr_directories(main_entries)

    open_prs = gh_json(f"repos/{repo}/pulls?state=open&per_page=100", paginate=True)
    other_open_pr_numbers: dict[str, list[tuple[int, str]]] = {}
    for pr in open_prs:
        if not isinstance(pr, dict):
            raise CollisionCheckError("an open pull request entry is not an object")
        number = pr.get("number")
        if not isinstance(number, int) or number == pr_number:
            continue
        other_files = gh_json(f"repos/{repo}/pulls/{number}/files?per_page=100", paginate=True)
        for adr_number, path in added_adr_directories(other_files).items():
            other_open_pr_numbers.setdefault(adr_number, []).append((number, path))

    return pr_numbers, main_numbers, other_open_pr_numbers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="owner/repo")
    parser.add_argument("--pr-number", required=True, type=int)
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", args.repo):
        parser.error("--repo must be 'owner/repo'")
    if args.pr_number < 1:
        parser.error("--pr-number must be a positive integer")

    try:
        pr_numbers, main_numbers, other_open_pr_numbers = fetch_state(args.repo, args.pr_number)
    except CollisionCheckError as error:
        print(f"ERROR: ADR number collision check failed closed: {error}", file=sys.stderr)
        return 2

    if not pr_numbers:
        print("ok - this PR adds no docs/decisions/NNNN-* directories")
        return 0

    problems = find_collisions(pr_numbers, main_numbers, other_open_pr_numbers)
    if problems:
        for problem in problems:
            print(f"ERROR: {problem}", file=sys.stderr)
        return 1

    print(f"ok - no ADR number collisions for {sorted(pr_numbers)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
