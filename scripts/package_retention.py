#!/usr/bin/env python3
"""Fail-closed retention for GitHub Packages npm and container versions."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


STABLE_VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
PACKAGE_NAME = re.compile(r"^[a-z0-9][a-z0-9._/-]*$")


class RetentionError(Exception):
    pass


@dataclass(frozen=True)
class Target:
    package_type: str
    name: str
    released_version: str


@dataclass(frozen=True)
class Deletion:
    target: Target
    version_id: int
    reason: str
    labels: tuple[str, ...]


class GitHubPackages:
    def __init__(self, owner: str, token: str, api_url: str) -> None:
        self.owner = owner
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _request(self, method: str, path: str) -> tuple[Any, str | None]:
        request = urllib.request.Request(
            f"{self.api_url}{path}",
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request) as response:
                body = response.read()
                return (json.loads(body) if body else None, response.headers.get("Link"))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise RetentionError(f"GitHub API {method} {path} failed: {error.code}: {detail}") from error

    def versions(self, target: Target) -> list[dict[str, Any]]:
        name = urllib.parse.quote(target.name, safe="")
        path = f"/orgs/{self.owner}/packages/{target.package_type}/{name}/versions?per_page=100"
        versions: list[dict[str, Any]] = []
        while path:
            page, link = self._request("GET", path)
            if not isinstance(page, list):
                raise RetentionError(f"versions response for {target.package_type}/{target.name} is not a list")
            versions.extend(page)
            path = _next_path(link, self.api_url)
        return versions

    def delete(self, deletion: Deletion) -> None:
        name = urllib.parse.quote(deletion.target.name, safe="")
        self._request(
            "DELETE",
            f"/orgs/{self.owner}/packages/{deletion.target.package_type}/{name}/versions/{deletion.version_id}",
        )


def _next_path(link: str | None, api_url: str) -> str:
    if not link:
        return ""
    next_urls = re.findall(r'<([^>]+)>;\s*rel="next"', link)
    if len(next_urls) != 1:
        raise RetentionError("ambiguous GitHub API pagination metadata")
    next_url = next_urls[0]
    if not next_url.startswith(f"{api_url}/"):
        raise RetentionError("pagination escaped the configured GitHub API origin")
    return next_url[len(api_url) :]


def parse_targets(raw: str, owner: str) -> list[Target]:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as error:
        raise RetentionError(f"targets is not valid JSON: {error}") from error
    if not isinstance(data, list) or not data:
        raise RetentionError("targets must be a non-empty JSON array")
    targets: list[Target] = []
    identities: set[tuple[str, str]] = set()
    for item in data:
        if not isinstance(item, dict) or set(item) != {"type", "name", "releasedVersion"}:
            raise RetentionError("each target must contain exactly type, name, and releasedVersion")
        package_type = item["type"]
        name = item["name"]
        released_version = item["releasedVersion"]
        if package_type not in {"npm", "container"}:
            raise RetentionError(f"unsupported package type: {package_type!r}")
        if (
            not isinstance(name, str)
            or not PACKAGE_NAME.fullmatch(name)
            or any(segment in {"", ".", ".."} for segment in name.split("/"))
            or (package_type == "npm" and "/" in name)
        ):
            raise RetentionError(f"invalid package name: {name!r}")
        if package_type == "npm" and name.startswith("@"):
            raise RetentionError("npm REST package names must be unscoped package basenames")
        if not isinstance(released_version, str) or not STABLE_VERSION.fullmatch(released_version):
            raise RetentionError(f"releasedVersion is not stable SemVer: {released_version!r}")
        identity = (package_type, name)
        if identity in identities:
            raise RetentionError(f"duplicate target: {package_type}/{name}")
        identities.add(identity)
        targets.append(Target(package_type, name, released_version))
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", owner):
        raise RetentionError("owner is not a valid GitHub organization login")
    return targets


def _version_tuple(version: str) -> tuple[int, int, int]:
    match = STABLE_VERSION.fullmatch(version)
    if not match:
        raise RetentionError(f"not stable SemVer: {version!r}")
    return tuple(map(int, match.groups()))  # type: ignore[return-value]


def plan_target(target: Target, versions: list[dict[str, Any]], keep: int = 3) -> list[Deletion]:
    if keep != 3:
        raise RetentionError("canonical retention count must remain exactly three")
    stable: dict[str, tuple[int, tuple[str, ...]]] = {}
    untagged: list[tuple[int, tuple[str, ...]]] = []
    seen_ids: set[int] = set()
    for version in versions:
        if not isinstance(version, dict) or not isinstance(version.get("id"), int):
            raise RetentionError(f"{target.package_type}/{target.name} has a version without an integer id")
        version_id = version["id"]
        if version_id in seen_ids:
            raise RetentionError(f"{target.package_type}/{target.name} returned duplicate version id {version_id}")
        seen_ids.add(version_id)
        if target.package_type == "npm":
            name = version.get("name")
            if not isinstance(name, str):
                raise RetentionError(f"npm version {version_id} has no string version name")
            labels = (name,)
        else:
            metadata = version.get("metadata")
            container = metadata.get("container") if isinstance(metadata, dict) else None
            tags = container.get("tags") if isinstance(container, dict) else None
            if not isinstance(tags, list) or any(not isinstance(tag, str) or not tag for tag in tags):
                raise RetentionError(f"container version {version_id} has ambiguous tag metadata")
            if len(tags) != len(set(tags)):
                raise RetentionError(f"container version {version_id} has duplicate tags")
            labels = tuple(tags)
            if not tags:
                untagged.append((version_id, labels))
                continue
            stable_tags = [tag for tag in tags if STABLE_VERSION.fullmatch(tag)]
            if not stable_tags:
                continue
            if len(stable_tags) != 1 or len(tags) != 1:
                raise RetentionError(
                    f"container version {version_id} mixes a numbered release with other tags: {tags}"
                )
            name = stable_tags[0]
        if STABLE_VERSION.fullmatch(name):
            if name in stable:
                raise RetentionError(f"{target.package_type}/{target.name} maps {name} to multiple version ids")
            stable[name] = (version_id, labels)

    if target.released_version not in stable:
        raise RetentionError(
            f"released version {target.released_version} is absent from {target.package_type}/{target.name}"
        )
    retained = set(sorted(stable, key=_version_tuple, reverse=True)[:keep])
    if target.released_version not in retained:
        raise RetentionError(
            f"released version {target.released_version} is not among the newest three; refusing historical cleanup"
        )
    deletions = [
        Deletion(target, version_id, "numbered release older than newest three", labels)
        for name, (version_id, labels) in stable.items()
        if name not in retained
    ]
    if target.package_type == "container":
        deletions.extend(
            Deletion(target, version_id, "untagged container version", labels)
            for version_id, labels in untagged
        )
    return sorted(deletions, key=lambda item: item.version_id)


def build_plan(client: GitHubPackages, targets: list[Target]) -> list[Deletion]:
    inventories = [(target, client.versions(target)) for target in targets]
    return [deletion for target, versions in inventories for deletion in plan_target(target, versions)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--owner", required=True)
    parser.add_argument("--targets", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        raise RetentionError("GH_TOKEN is required")
    targets = parse_targets(args.targets, args.owner)
    client = GitHubPackages(args.owner, token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    deletions = build_plan(client, targets)
    print(json.dumps({"delete": [deletion.__dict__ | {"target": deletion.target.__dict__} for deletion in deletions]}, default=list))
    if not args.apply:
        print("Dry run only; pass --apply to delete the validated inventory.")
        return 0
    for deletion in deletions:
        client.delete(deletion)
        print(
            f"Deleted {deletion.target.package_type}/{deletion.target.name} version id "
            f"{deletion.version_id}: {deletion.reason}."
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RetentionError as error:
        print(f"package-retention: {error}", file=sys.stderr)
        raise SystemExit(1)
