#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence


REPOSITORY = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
OID = re.compile(r"[0-9a-f]{40}")
MAX_GRAPHQL_PAGES = 100
QUERY = """
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    databaseId
    nameWithOwner
    pullRequest(number: $number) {
      number
      state
      headRefOid
      closingIssuesReferences(first: 100, after: $endCursor) {
        nodes {
          id
          number
          state
          url
          repository { databaseId nameWithOwner }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
""".strip()


class VisibilityError(Exception):
    pass


def positive_integer(value: Any) -> bool:
    return type(value) is int and value > 0


def context(environment: Mapping[str, str]) -> dict[str, Any]:
    repository = environment.get("TARGET_REPO", "")
    repository_id = environment.get("GITHUB_REPOSITORY_ID", "")
    number = environment.get("PR_NUMBER", "")
    head = environment.get("EXPECTED_HEAD_SHA", "")
    if not environment.get("GH_TOKEN"):
        raise VisibilityError("read-only caller token is missing")
    if REPOSITORY.fullmatch(repository) is None:
        raise VisibilityError("trusted repository identity is missing or malformed")
    if re.fullmatch(r"[1-9][0-9]*", repository_id) is None:
        raise VisibilityError("stable repository identity is missing or malformed")
    if re.fullmatch(r"[1-9][0-9]*", number) is None:
        raise VisibilityError("pull request number is missing or malformed")
    parsed_repository_id = int(repository_id)
    parsed_number = int(number)
    if not positive_integer(parsed_repository_id):
        raise VisibilityError("stable repository identity is missing or malformed")
    if not positive_integer(parsed_number):
        raise VisibilityError("pull request number is missing or malformed")
    if OID.fullmatch(head) is None:
        raise VisibilityError("expected pull request head is missing or malformed")
    owner, name = repository.split("/", 1)
    return {
        "repository": repository,
        "repository_id": parsed_repository_id,
        "owner": owner,
        "name": name,
        "number": parsed_number,
        "head": head,
    }


def fetch_graphql_pages(command: Sequence[str]) -> list[dict[str, Any]]:
    pages: list[dict[str, Any]] = []
    seen_cursors: set[str] = set()
    cursor: str | None = None
    for _ in range(MAX_GRAPHQL_PAGES):
        page_command = list(command)
        if cursor is not None:
            page_command.extend(("-f", f"endCursor={cursor}"))
        result = subprocess.run(page_command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise VisibilityError("GitHub GraphQL request failed")
        try:
            page = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise VisibilityError("GitHub GraphQL response was not JSON") from error
        if not isinstance(page, dict):
            raise VisibilityError("GitHub GraphQL response page was malformed")
        if "errors" in page:
            errors = page["errors"]
            if not isinstance(errors, list):
                raise VisibilityError("GitHub GraphQL response errors field was malformed")
            if errors:
                raise VisibilityError("GitHub GraphQL response reported errors")
        pages.append(page)
        try:
            page_info = page["data"]["repository"]["pullRequest"][
                "closingIssuesReferences"
            ]["pageInfo"]
        except (KeyError, TypeError) as error:
            raise VisibilityError("GitHub GraphQL response omitted closing issue data") from error
        if not isinstance(page_info, dict):
            raise VisibilityError("GitHub GraphQL closing issue pageInfo was malformed")
        if "hasNextPage" not in page_info or "endCursor" not in page_info:
            raise VisibilityError("GitHub GraphQL closing issue pageInfo was malformed")
        has_next = page_info["hasNextPage"]
        end_cursor = page_info["endCursor"]
        if not isinstance(has_next, bool) or (
            end_cursor is not None and (not isinstance(end_cursor, str) or not end_cursor)
        ):
            raise VisibilityError("GitHub GraphQL closing issue pageInfo was malformed")
        if not has_next:
            return pages
        if end_cursor is None:
            raise VisibilityError("GitHub GraphQL pagination omitted its next-page cursor")
        if end_cursor in seen_cursors:
            raise VisibilityError("GitHub GraphQL pagination cursor did not progress")
        seen_cursors.add(end_cursor)
        cursor = end_cursor
    raise VisibilityError("GitHub GraphQL response exceeded the page limit")


def fetch_snapshot(expected: Mapping[str, Any], expected_state: str) -> list[dict[str, Any]]:
    command = [
        "gh",
        "api",
        "graphql",
        "-f",
        f"query={QUERY}",
        "-F",
        f"owner={expected['owner']}",
        "-F",
        f"name={expected['name']}",
        "-F",
        f"number={expected['number']}",
    ]
    pages = fetch_graphql_pages(command)

    references: dict[str, dict[str, Any]] = {}
    seen_cursors: set[str] = set()
    for page_index, page in enumerate(pages):
        try:
            repository = page["data"]["repository"]
            pull_request = repository["pullRequest"]
            resolved = pull_request["closingIssuesReferences"]
            nodes = resolved["nodes"]
            page_info = resolved["pageInfo"]
        except (KeyError, TypeError) as error:
            raise VisibilityError("GitHub GraphQL response omitted closing issue data") from error
        if not isinstance(pull_request, dict):
            raise VisibilityError("GitHub GraphQL pull request page was malformed")
        if (
            not isinstance(repository, dict)
            or not positive_integer(repository.get("databaseId"))
            or repository.get("databaseId") != expected["repository_id"]
            or repository.get("nameWithOwner") != expected["repository"]
        ):
            raise VisibilityError("target repository stable identity changed during closing issue read")
        if (
            not positive_integer(pull_request.get("number"))
            or pull_request.get("number") != expected["number"]
            or pull_request.get("state") != expected_state
            or pull_request.get("headRefOid") != expected["head"]
        ):
            raise VisibilityError("pull request state or exact head changed during closing issue read")
        if not isinstance(nodes, list) or not isinstance(page_info, dict):
            raise VisibilityError("GitHub GraphQL closing issue page was malformed")
        if "hasNextPage" not in page_info or "endCursor" not in page_info:
            raise VisibilityError("GitHub GraphQL closing issue pageInfo was malformed")
        has_next = page_info["hasNextPage"]
        end_cursor = page_info.get("endCursor")
        if not isinstance(has_next, bool) or (
            end_cursor is not None and (not isinstance(end_cursor, str) or not end_cursor)
        ):
            raise VisibilityError("GitHub GraphQL closing issue pageInfo was malformed")
        if has_next and end_cursor is None:
            raise VisibilityError("GitHub GraphQL pagination omitted its next-page cursor")
        if not nodes and end_cursor is not None:
            raise VisibilityError("GitHub GraphQL empty page returned an unexpected cursor")
        if not has_next and end_cursor is None and (nodes or page_index > 0):
            raise VisibilityError("GitHub GraphQL final page omitted its pagination cursor")
        if isinstance(end_cursor, str) and end_cursor in seen_cursors:
            raise VisibilityError("GitHub GraphQL pagination cursor did not progress")
        if isinstance(end_cursor, str):
            seen_cursors.add(end_cursor)
        if page_index < len(pages) - 1 and not has_next:
            raise VisibilityError("GitHub GraphQL pagination returned an unexpected extra page")
        if page_index == len(pages) - 1 and has_next:
            raise VisibilityError("GitHub GraphQL pagination did not return the complete issue set")
        for node in nodes:
            normalized = normalize_reference(
                node,
                expected["repository"],
                expected["repository_id"],
            )
            existing = references.get(normalized["id"])
            if existing is not None:
                raise VisibilityError("GitHub returned a duplicate stable closing issue identity")
            references[normalized["id"]] = normalized
    normalized_references = list(references.values())
    require_unique_issue_locators(normalized_references, "GitHub response")
    return sorted(
        normalized_references,
        key=lambda reference: (reference["repository"], reference["number"]),
    )


def normalize_reference(
    node: Any,
    expected_repository: str,
    expected_repository_id: int,
) -> dict[str, Any]:
    if not isinstance(node, dict) or not isinstance(node.get("repository"), dict):
        raise VisibilityError("GitHub returned a malformed closing issue reference")
    identity = node.get("id")
    repository = node["repository"].get("nameWithOwner")
    repository_id = node["repository"].get("databaseId")
    number = node.get("number")
    state = node.get("state")
    url = node.get("url")
    if not isinstance(identity, str) or not identity:
        raise VisibilityError("GitHub returned a closing issue without a stable identity")
    if not isinstance(repository, str) or REPOSITORY.fullmatch(repository) is None:
        raise VisibilityError("GitHub returned a malformed closing issue repository")
    if (
        repository != expected_repository
        or not positive_integer(repository_id)
        or repository_id != expected_repository_id
    ):
        raise VisibilityError(
            "GitHub returned a closing issue outside the exact caller repository identity"
        )
    if not positive_integer(number):
        raise VisibilityError("GitHub returned a malformed closing issue number")
    if state not in {"OPEN", "CLOSED"}:
        raise VisibilityError("GitHub returned an unknown closing issue state")
    expected_url = f"https://github.com/{repository}/issues/{number}"
    if url != expected_url:
        raise VisibilityError("GitHub returned a closing issue with an unexpected URL")
    return {
        "id": identity,
        "repository": repository,
        "repositoryId": repository_id,
        "number": number,
        "url": url,
        "state": state,
    }


def require_unique_issue_locators(
    references: Sequence[Mapping[str, Any]], source: str
) -> None:
    locators = [
        (reference["repositoryId"], reference["number"])
        for reference in references
    ]
    if len(locators) != len(set(locators)):
        raise VisibilityError(f"{source} contains duplicate closing issue locators")


def write_receipt(path: Path, expected: Mapping[str, Any], references: list[dict[str, Any]]) -> None:
    receipt = {
        "schema": "verjson-closing-issue-capture/v2",
        "repository": expected["repository"],
        "repositoryId": expected["repository_id"],
        "pullRequest": expected["number"],
        "headSha": expected["head"],
        "references": [
            {
                "id": reference["id"],
                "repository": reference["repository"],
                "repositoryId": reference["repositoryId"],
                "number": reference["number"],
                "url": reference["url"],
                "stateBeforeMerge": reference["state"],
            }
            for reference in references
        ],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def read_receipt(path: Path, expected: Mapping[str, Any]) -> list[dict[str, Any]]:
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VisibilityError("pre-merge closing issue capture is missing or malformed") from error
    if not isinstance(receipt, dict) or set(receipt) != {
        "schema",
        "repository",
        "repositoryId",
        "pullRequest",
        "headSha",
        "references",
    }:
        raise VisibilityError("pre-merge closing issue capture has an unknown shape")
    if (
        receipt["schema"] != "verjson-closing-issue-capture/v2"
        or receipt["repository"] != expected["repository"]
        or not positive_integer(receipt["repositoryId"])
        or receipt["repositoryId"] != expected["repository_id"]
        or not positive_integer(receipt["pullRequest"])
        or receipt["pullRequest"] != expected["number"]
        or receipt["headSha"] != expected["head"]
        or not isinstance(receipt["references"], list)
    ):
        raise VisibilityError("pre-merge closing issue capture does not bind this exact pull request")
    references = []
    for raw in receipt["references"]:
        if not isinstance(raw, dict) or set(raw) != {
            "id",
            "repository",
            "repositoryId",
            "number",
            "url",
            "stateBeforeMerge",
        }:
            raise VisibilityError("pre-merge closing issue reference has an unknown shape")
        references.append(
            normalize_reference(
                {
                    "id": raw["id"],
                    "repository": {
                        "databaseId": raw["repositoryId"],
                        "nameWithOwner": raw["repository"],
                    },
                    "number": raw["number"],
                    "url": raw["url"],
                    "state": raw["stateBeforeMerge"],
                },
                expected["repository"],
                expected["repository_id"],
            )
        )
    identities = [reference["id"] for reference in references]
    if len(identities) != len(set(identities)):
        raise VisibilityError("pre-merge closing issue capture contains duplicate identities")
    require_unique_issue_locators(references, "pre-merge closing issue capture")
    return sorted(
        references,
        key=lambda reference: (reference["repository"], reference["number"]),
    )


def reference_identity(reference: Mapping[str, Any]) -> tuple[str, str, int, int, str]:
    return (
        str(reference["id"]),
        str(reference["repository"]),
        int(reference["repositoryId"]),
        int(reference["number"]),
        str(reference["url"]),
    )


def append_summary(path: Path, lines: Sequence[str]) -> None:
    with path.open("a", encoding="utf-8") as summary:
        summary.write("\n".join(lines) + "\n")


def capture(output: Path, expected: Mapping[str, Any]) -> int:
    references = fetch_snapshot(expected, "OPEN")
    write_receipt(output, expected, references)
    print(
        f"Captured {len(references)} caller-token-visible, same-repository "
        "GitHub-resolved closing issue reference(s)."
    )
    return 0


def report(input_path: Path, summary_path: Path, expected: Mapping[str, Any]) -> int:
    before = read_receipt(input_path, expected)
    after = fetch_snapshot(expected, "MERGED")
    if [reference_identity(reference) for reference in before] != [
        reference_identity(reference) for reference in after
    ]:
        append_summary(
            summary_path,
            [
                "## Closing issue outcome",
                "",
                "The caller-token-visible, same-repository GitHub-resolved closing issue set changed across the terminal merge; the outcome is indeterminate.",
            ],
        )
        raise VisibilityError("resolved closing issue set changed across terminal merge")

    lines = [
        "## Closing issue outcome",
        "",
        "`merge-authorization` intentionally lacks `issues: write`; this check uses read-only caller authority and never mutates issues.",
        "",
        "The repository-scoped caller token covers only GitHub-resolved issues in the exact caller repository. Private cross-repository references are outside this fallback's authority and require normal PM reconciliation.",
        "",
    ]
    if not after:
        lines.append(
            "No caller-token-visible, same-repository GitHub-resolved closing issue references were present on the merged pull request."
        )
    for reference in after:
        label = f"{reference['repository']}#{reference['number']}"
        if reference["state"] == "CLOSED":
            lines.append(f"- ✅ [{label}]({reference['url']}) is closed.")
            continue
        reason = (
            "merge-authorization intentionally lacks issues:write; "
            "the read-only fallback reports this outcome and does not mutate issues"
        )
        print(
            "::warning title=Closing issue remains open::"
            f"{reference['url']} remains open after merge; {reason}."
        )
        lines.append(f"- ⚠️ [{label}]({reference['url']}) remains open; {reason}.")
    append_summary(summary_path, lines)
    return 0


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser()
    subcommands = argument_parser.add_subparsers(dest="command", required=True)
    capture_parser = subcommands.add_parser("capture")
    capture_parser.add_argument("--output", type=Path, required=True)
    report_parser = subcommands.add_parser("report")
    report_parser.add_argument("--input", type=Path, required=True)
    return argument_parser


def main(argv: Sequence[str] | None = None, environment: Mapping[str, str] = os.environ) -> int:
    arguments = parser().parse_args(argv)
    try:
        expected = context(environment)
        if arguments.command == "capture":
            return capture(arguments.output, expected)
        summary = environment.get("GITHUB_STEP_SUMMARY", "")
        if not summary:
            raise VisibilityError("GITHUB_STEP_SUMMARY is missing")
        return report(arguments.input, Path(summary), expected)
    except VisibilityError as error:
        if arguments.command == "capture":
            print(
                "::error title=Closing issue capture failed::"
                f"{error}; terminal merge was withheld because closing references could not be captured safely."
            )
            return 1
        summary = environment.get("GITHUB_STEP_SUMMARY", "")
        if summary and "resolved closing issue set changed" not in str(error):
            append_summary(
                Path(summary),
                [
                    "## Closing issue outcome",
                    "",
                    "The merge completed, but closing issue outcomes could not be read. The run fails visibly instead of treating missing evidence as success.",
                ],
            )
        print(f"::error title=Closing issue outcome unavailable::{error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
