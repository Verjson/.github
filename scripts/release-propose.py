#!/usr/bin/env python3
"""Update one release proposal or dispatch the generated Release workflow."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import quote


PROPOSAL_MARKER = "<!-- verjson-release-proposal:v1 -->"
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
VERSION = re.compile(
    r"^(?:[a-z0-9][a-z0-9._-]*-)?v(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
PREFIX = re.compile(r"^(?:[a-z0-9][a-z0-9._-]*-)?v$")
SELECTOR_DIGEST = re.compile(r"^[0-9a-f]{64}$")
WORKFLOW = re.compile(r"^[A-Za-z0-9_.-]+\.ya?ml$")


class ProposalError(Exception):
    pass


def object_without_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ProposalError(f"GitHub response repeats object key {key!r}")
        result[key] = value
    return result


def decode_json(text: str, source: str) -> object:
    try:
        return json.loads(text, object_pairs_hook=object_without_duplicate_keys)
    except json.JSONDecodeError as error:
        raise ProposalError(f"{source} was not valid JSON: {error}") from None


class GitHubClient:
    def run(self, arguments: list[str], payload: dict[str, object] | None = None) -> str:
        try:
            result = subprocess.run(
                ["gh", *arguments],
                input=json.dumps(payload) if payload is not None else None,
                text=True,
                capture_output=True,
                check=False,
            )
        except OSError as error:
            raise ProposalError("GitHub API client could not start") from error
        if result.returncode:
            raise ProposalError("GitHub API request failed")
        return result.stdout

    def pages(self, path: str) -> list[object]:
        raw = self.run(
            ["api", "--method", "GET", "--paginate", "--slurp", path]
        )
        pages = decode_json(raw, f"GitHub API response for {path}")
        if not isinstance(pages, list) or not pages:
            raise ProposalError(f"GitHub API returned no pages for {path}")
        return pages

    def mutate(self, method: str, path: str, payload: dict[str, object]) -> None:
        self.run(
            ["api", "--method", method, path, "--input", "-"],
            payload,
        )


def proposal_body(
    version: str,
    prefix: str,
    selector_digest: str,
    branch: str,
    head_sha: str,
    preview: str,
) -> str:
    return (
        f"{PROPOSAL_MARKER}\n\n"
        "This issue is maintained by the canonical release proposer. "
        "Re-running it updates this surface instead of opening another issue.\n\n"
        f"Proposed version: `{version}`  \n"
        f"Version namespace: `{prefix}`  \n"
        f"Selection digest: `{selector_digest}`  \n"
        f"Default branch: `{branch}`  \n"
        f"Derived head: `{head_sha}`\n\n"
        "## Released changelog preview\n\n"
        f"{preview.rstrip()}\n"
    )


def open_proposals(client: GitHubClient, repository: str) -> list[dict[str, object]]:
    proposals: list[dict[str, object]] = []
    path = f"repos/{repository}/issues?state=open&per_page=100"
    for page_index, page in enumerate(client.pages(path)):
        if not isinstance(page, list):
            raise ProposalError(f"issue page {page_index} was not an array")
        for issue_index, issue in enumerate(page):
            if not isinstance(issue, dict):
                raise ProposalError(
                    f"issue {issue_index} on page {page_index} was not an object"
                )
            if "pull_request" in issue:
                continue
            body = issue.get("body")
            if isinstance(body, str) and PROPOSAL_MARKER in body:
                author = issue.get("user")
                login = author.get("login") if isinstance(author, dict) else None
                if login != "github-actions[bot]":
                    raise ProposalError(
                        "an open issue carries the release proposal marker but is not owned by github-actions[bot]"
                    )
                proposals.append(issue)
    return proposals


def ensure_proposal(
    client: GitHubClient,
    repository: str,
    version: str,
    prefix: str,
    selector_digest: str,
    branch: str,
    head_sha: str,
    preview: str,
) -> str:
    title = f"Release proposal: {version}"
    body = proposal_body(
        version,
        prefix,
        selector_digest,
        branch,
        head_sha,
        preview,
    )
    proposals = open_proposals(client, repository)
    if len(proposals) > 1:
        numbers = sorted(str(issue.get("number", "?")) for issue in proposals)
        raise ProposalError(
            "multiple open release proposal issues carry the ownership marker: "
            + ", ".join(numbers)
        )
    payload: dict[str, object] = {"title": title, "body": body}
    if not proposals:
        client.mutate("POST", f"repos/{repository}/issues", payload)
        return "created release proposal"

    issue = proposals[0]
    number = issue.get("number")
    if not isinstance(number, int) or number <= 0:
        raise ProposalError("the existing release proposal has no valid issue number")
    if issue.get("title") == title and issue.get("body") == body:
        return f"release proposal #{number} is already current"
    client.mutate("PATCH", f"repos/{repository}/issues/{number}", payload)
    return f"updated release proposal #{number}"


def workflow_runs(
    client: GitHubClient,
    repository: str,
    workflow: str,
) -> list[dict[str, object]]:
    path = (
        f"repos/{repository}/actions/workflows/{workflow}/runs"
        "?event=workflow_dispatch&per_page=100"
    )
    runs: list[dict[str, object]] = []
    for page_index, page in enumerate(client.pages(path)):
        if not isinstance(page, dict) or not isinstance(page.get("workflow_runs"), list):
            raise ProposalError(
                f"workflow-runs page {page_index} has no workflow_runs array"
            )
        for run_index, run in enumerate(page["workflow_runs"]):
            if not isinstance(run, dict):
                raise ProposalError(
                    f"workflow run {run_index} on page {page_index} was not an object"
                )
            runs.append(run)
    return runs


def require_current_head(
    client: GitHubClient, repository: str, branch: str, expected_head: str
) -> None:
    path = f"repos/{repository}/git/ref/heads/{quote(branch, safe='')}"
    pages = client.pages(path)
    if len(pages) != 1 or not isinstance(pages[0], dict):
        raise ProposalError("default-branch ref response was not one object")
    target = pages[0].get("object")
    actual = target.get("sha") if isinstance(target, dict) else None
    if not isinstance(actual, str) or re.fullmatch(r"[0-9a-f]{40}", actual) is None:
        raise ProposalError("default-branch ref response has no valid commit")
    if actual != expected_head:
        raise ProposalError(
            "default branch advanced after proposal checkout; derive again from its new head"
        )


def matching_dispatch(
    runs: list[dict[str, object]], version: str, head_sha: str, selector_digest: str
) -> dict[str, object] | None:
    title = f"Release {version} {selector_digest}"
    return next(
        (
            run
            for run in runs
            if run.get("event") == "workflow_dispatch"
            and run.get("display_title") == title
            and run.get("head_sha") == head_sha
        ),
        None,
    )


def ensure_dispatch(
    client: GitHubClient,
    repository: str,
    workflow: str,
    branch: str,
    head_sha: str,
    version: str,
    prefix: str,
    selector_digest: str,
    fragments: str,
    component: str,
    acknowledgement_attempts: int,
    acknowledgement_delay: float,
) -> str:
    existing = matching_dispatch(
        workflow_runs(client, repository, workflow),
        version,
        head_sha,
        selector_digest,
    )
    if existing is not None:
        return f"release dispatch already exists as run {existing.get('id', '?')}"

    client.mutate(
        "POST",
        f"repos/{repository}/actions/workflows/{workflow}/dispatches",
        {
            "ref": branch,
            "inputs": {
                "version": version,
                "prefix": prefix,
                "expected_head": head_sha,
                "selector_digest": selector_digest,
                "fragments": fragments,
                "component": component,
            },
        },
    )
    for attempt in range(acknowledgement_attempts):
        observed = matching_dispatch(
            workflow_runs(client, repository, workflow),
            version,
            head_sha,
            selector_digest,
        )
        if observed is not None:
            return f"dispatched release as run {observed.get('id', '?')}"
        if attempt + 1 < acknowledgement_attempts:
            time.sleep(acknowledgement_delay)
    raise ProposalError(
        "release dispatch was accepted but no exact-version, exact-head run became visible"
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--mode", choices=("propose", "dispatch"), required=True)
    result.add_argument("--repository", required=True)
    result.add_argument("--workflow", default="release.yml")
    result.add_argument("--branch", required=True)
    result.add_argument("--head-sha", required=True)
    result.add_argument("--version", required=True)
    result.add_argument("--prefix", required=True)
    result.add_argument("--selector-digest", required=True)
    result.add_argument("--fragments", default="")
    result.add_argument("--component", default="")
    result.add_argument("--preview-file", type=Path, required=True)
    result.add_argument("--acknowledgement-attempts", type=int, default=8)
    result.add_argument("--acknowledgement-delay", type=float, default=2.0)
    return result


def main() -> int:
    args = parser().parse_args()
    if REPOSITORY.fullmatch(args.repository) is None:
        raise ProposalError("repository must be an owner/name pair")
    if VERSION.fullmatch(args.version) is None:
        raise ProposalError("version must be an exact supported release tag")
    if PREFIX.fullmatch(args.prefix) is None or not args.version.startswith(args.prefix):
        raise ProposalError("prefix must be canonical and match the exact release tag")
    if SELECTOR_DIGEST.fullmatch(args.selector_digest) is None:
        raise ProposalError("selector digest must be a lowercase SHA-256")
    if WORKFLOW.fullmatch(args.workflow) is None:
        raise ProposalError("workflow must be a repository workflow filename")
    if not re.fullmatch(r"[0-9a-f]{40}", args.head_sha):
        raise ProposalError("head SHA must be a 40-character lowercase commit")
    if not args.branch or any(character.isspace() for character in args.branch):
        raise ProposalError("branch must be a non-empty Git ref name without whitespace")
    if args.acknowledgement_attempts < 1 or args.acknowledgement_delay < 0:
        raise ProposalError("dispatch acknowledgement bounds are invalid")
    try:
        preview = args.preview_file.read_text(encoding="utf-8")
    except OSError as error:
        raise ProposalError(f"cannot read released preview: {error}") from None
    if not preview.strip():
        raise ProposalError("released preview is empty")

    client = GitHubClient()
    require_current_head(client, args.repository, args.branch, args.head_sha)
    if args.mode == "propose":
        outcome = ensure_proposal(
            client,
            args.repository,
            args.version,
            args.prefix,
            args.selector_digest,
            args.branch,
            args.head_sha,
            preview,
        )
    else:
        outcome = ensure_dispatch(
            client,
            args.repository,
            args.workflow,
            args.branch,
            args.head_sha,
            args.version,
            args.prefix,
            args.selector_digest,
            args.fragments,
            args.component,
            args.acknowledgement_attempts,
            args.acknowledgement_delay,
        )
    print(outcome)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProposalError as error:
        print(f"release-propose: {error}", file=sys.stderr)
        raise SystemExit(1)
