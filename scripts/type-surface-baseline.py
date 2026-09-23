#!/usr/bin/env python3
"""Resolve and verify a protected consumer-owned type-surface declaration."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlparse
from urllib.request import Request, urlopen


SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
PACKAGE = re.compile(r"@[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*\Z")
SCRIPT = re.compile(r"[A-Za-z0-9][A-Za-z0-9:._-]{0,127}\Z")
VERSION = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z"
)
INTEGRITY = re.compile(r"sha512-[A-Za-z0-9+/]{86}==\Z")


class ContractError(Exception):
    """A declaration or evidence failure that must stop the lane."""


class DuplicateJSONKey(ValueError):
    pass


def parse_json(value: bytes | str, label: str) -> object:
    def pairs(items: list[tuple[str, object]]) -> dict:
        result: dict[str, object] = {}
        for key, item in items:
            if key in result:
                raise DuplicateJSONKey(key)
            result[key] = item
        return result

    try:
        return json.loads(value, object_pairs_hook=pairs)
    except DuplicateJSONKey as error:
        raise ContractError(f"{label} contains duplicate JSON field {error}") from None
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError(f"{label} is invalid JSON: {error}") from error


def strict_object(value: bytes | str, label: str) -> dict:
    parsed = parse_json(value, label)
    if not isinstance(parsed, dict):
        raise ContractError(f"{label} must be a JSON object")
    return parsed


def api_json(token: str, path: str) -> dict:
    request = Request(
        f"https://api.github.com/{path.lstrip('/')}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            body = response.read(1024 * 1024 + 1)
    except (HTTPError, URLError, TimeoutError) as error:
        raise ContractError(f"authenticated GitHub API request failed: {error}") from error
    if len(body) > 1024 * 1024:
        raise ContractError("GitHub API response exceeds the 1 MiB bound")
    return strict_object(body, "GitHub API response")


def parse_core(version: str) -> tuple[int, int, int] | None:
    if not VERSION.fullmatch(version):
        return None
    return tuple(int(part) for part in version.split("."))


def satisfies(version: str, range_value: str) -> bool:
    selected = parse_core(version)
    if selected is None:
        return False
    exact = parse_core(range_value)
    if exact is not None:
        return selected == exact
    if range_value.startswith(("^", "~")):
        base = parse_core(range_value[1:])
        if base is None:
            return False
        if range_value.startswith("~"):
            upper = (base[0], base[1] + 1, 0)
        elif base[0] > 0:
            upper = (base[0] + 1, 0, 0)
        elif base[1] > 0:
            upper = (0, base[1] + 1, 0)
        else:
            upper = (0, 0, base[2] + 1)
        return base <= selected < upper
    match = re.fullmatch(
        r">=((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"
        r" <((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))",
        range_value,
    )
    return bool(match and parse_core(match.group(1) or "") <= selected < parse_core(match.group(2) or ""))


def bounded_range(value: str) -> bool:
    return (
        parse_core(value) is not None
        or (value[:1] in ("^", "~") and parse_core(value[1:]) is not None)
        or bool(
            re.fullmatch(
                r">=((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"
                r" <((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))",
                value,
            )
        )
    )


def validate_policy(policy_source: str, package: str, version: str) -> None:
    policy = strict_object(policy_source, "CI_SECRETLESS_PACKAGE_POLICY")
    if set(policy) not in ({"scopes", "packages"}, {"scopes", "packages", "compatibility"}):
        raise ContractError("CI_SECRETLESS_PACKAGE_POLICY has an unsupported shape")
    scopes = policy["scopes"]
    packages = policy["packages"]
    scopes_valid = (
        isinstance(scopes, list)
        and bool(scopes)
        and all(isinstance(item, str) for item in scopes)
        and len(scopes) == len(set(scopes))
        and all(re.fullmatch(r"@[a-z0-9][a-z0-9._-]*", item) for item in scopes)
    )
    packages_valid = (
        isinstance(packages, list)
        and all(isinstance(item, str) for item in packages)
        and len(packages) == len(set(packages))
        and all(PACKAGE.fullmatch(item) for item in packages)
        and all(item.split("/", 1)[0] in scopes for item in packages)
    )
    if not scopes_valid or not packages_valid:
        raise ContractError("CI_SECRETLESS_PACKAGE_POLICY has invalid scopes or packages")
    if package not in packages:
        raise ContractError("declared package is not authorized by CI_SECRETLESS_PACKAGE_POLICY")
    compatibility = policy.get("compatibility", {})
    if not isinstance(compatibility, dict) or package not in compatibility:
        raise ContractError("CI_SECRETLESS_PACKAGE_POLICY has no compatibility authorization for the package")
    ranges = compatibility[package]
    if (
        not isinstance(ranges, list)
        or not ranges
        or len(ranges) != len(set(ranges))
        or any(not isinstance(item, str) or not bounded_range(item) for item in ranges)
    ):
        raise ContractError("CI_SECRETLESS_PACKAGE_POLICY compatibility is invalid")
    if not any(isinstance(item, str) and satisfies(version, item) for item in ranges):
        raise ContractError("declared version is outside CI_SECRETLESS_PACKAGE_POLICY compatibility")


def registry_metadata(package: str, version: str, token: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="verjson-type-surface-") as directory:
        config = Path(directory) / "npmrc"
        config.write_text(
            "registry=https://registry.npmjs.org/\n"
            "@verjson:registry=https://npm.pkg.github.com/\n"
            "//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}\n",
            encoding="utf-8",
        )
        environment = {
            **os.environ,
            "NODE_AUTH_TOKEN": token,
            "NPM_CONFIG_USERCONFIG": str(config),
            "NPM_CONFIG_GLOBALCONFIG": str(Path(directory) / "empty-global-npmrc"),
        }
        view = subprocess.run(
            [
                "npm",
                "view",
                "--json",
                f"{package}@{version}",
                "name",
                "version",
                "dist.integrity",
                "dist.tarball",
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=60,
        )
        if view.returncode:
            raise ContractError("authenticated registry could not resolve the declared package version")
        metadata_value = parse_json(view.stdout, "registry metadata")
        if isinstance(metadata_value, list):
            if len(metadata_value) != 1 or not isinstance(metadata_value[0], dict):
                raise ContractError("registry metadata must identify exactly one artifact")
            metadata = metadata_value[0]
        elif isinstance(metadata_value, dict):
            metadata = metadata_value
        else:
            raise ContractError("registry metadata has an unexpected shape")
        if "dist" in metadata:
            dist = metadata["dist"]
            metadata = {
                "name": metadata.get("name"),
                "version": metadata.get("version"),
                "integrity": dist.get("integrity") if isinstance(dist, dict) else None,
                "tarball": dist.get("tarball") if isinstance(dist, dict) else None,
            }
        else:
            metadata = {
                "name": metadata.get("name"),
                "version": metadata.get("version"),
                "integrity": metadata.get("dist.integrity"),
                "tarball": metadata.get("dist.tarball"),
            }
        if set(metadata) != {"name", "version", "integrity", "tarball"}:
            raise ContractError("registry metadata has an unexpected shape")
        if metadata["name"] != package or metadata["version"] != version:
            raise ContractError("registry metadata changed the declared package identity")
        integrity = metadata["integrity"]
        tarball = metadata["tarball"]
        if not isinstance(integrity, str) or not INTEGRITY.fullmatch(integrity):
            raise ContractError("registry artifact integrity is not a sha512 value")
        parsed = urlparse(tarball) if isinstance(tarball, str) else None
        path = unquote(parsed.path) if parsed is not None else ""
        parts = path.split("/")
        expected_name = f"{parts[2]}/{parts[3]}" if len(parts) == 6 else ""
        if (
            parsed is None
            or parsed.scheme != "https"
            or parsed.netloc != "npm.pkg.github.com"
            or parsed.query
            or parsed.fragment
            or tarball != f"https://npm.pkg.github.com{path}"
            or len(parts) != 6
            or parts[1] != "download"
            or any(part in ("", ".", "..") for part in parts[1:])
            or expected_name != package
            or parts[4] != version
        ):
            raise ContractError("registry artifact is not a GitHub Packages tarball")
        return {"integrity": integrity, "tarball": tarball}


def resolve(arguments: argparse.Namespace) -> dict:
    github_token = os.environ.get("GITHUB_TOKEN", "")
    node_auth_token = os.environ.get("NODE_AUTH_TOKEN", "")
    if os.environ.get("EVENT_NAME") != "pull_request":
        raise ContractError("type-surface verification requires a pull_request event")
    if os.environ.get("EVENT_REPOSITORY") != arguments.repository:
        raise ContractError("workflow repository identity does not match target repository")
    event_base_sha = os.environ.get("EVENT_BASE_SHA", "")
    event_base_ref = os.environ.get("EVENT_BASE_REF", "")
    event_head_sha = os.environ.get("EVENT_HEAD_SHA", "")
    if (
        not SHA.fullmatch(event_base_sha)
        or not SHA.fullmatch(event_head_sha)
        or not re.fullmatch(r"[A-Za-z0-9._/-]+", event_base_ref)
    ):
        raise ContractError("pull_request event identity is incomplete or mutable")
    if not github_token or not node_auth_token:
        raise ContractError("authenticated GitHub and registry credentials are required")
    pull = api_json(github_token, f"repos/{arguments.repository}/pulls/{arguments.pull_request}")
    base = pull.get("base")
    base_repo = base.get("repo") if isinstance(base, dict) else None
    if (
        not isinstance(base, dict)
        or not isinstance(base_repo, dict)
        or base_repo.get("full_name") != arguments.repository
        or base.get("ref") != base_repo.get("default_branch")
    ):
        raise ContractError("pull request base repository is not the target repository")
    base_sha = base.get("sha")
    if not isinstance(base_sha, str) or not SHA.fullmatch(base_sha):
        raise ContractError("pull request base SHA is not an immutable commit")
    if base.get("ref") != event_base_ref or base_sha != event_base_sha:
        raise ContractError("pull_request event base identity changed during resolution")

    encoded_path = quote(arguments.declaration_path, safe="/")
    content = api_json(
        github_token,
        f"repos/{arguments.repository}/contents/{encoded_path}?ref={quote(base_sha, safe='/')}",
    )
    if content.get("type") != "file" or content.get("encoding") != "base64" or content.get("sha") is None:
        raise ContractError("baseline declaration is not a regular API file")
    blob_sha = content["sha"]
    if not isinstance(blob_sha, str) or not SHA.fullmatch(blob_sha):
        raise ContractError("baseline declaration API response has no immutable blob SHA")
    try:
        declaration_bytes = base64.b64decode(content.get("content", ""), validate=True)
    except (ValueError, TypeError):
        raise ContractError("baseline declaration content is not valid base64") from None
    declaration = strict_object(declaration_bytes, "baseline declaration")
    if set(declaration) != {"package", "version", "script"}:
        raise ContractError("baseline declaration requires exactly package, version, and script")
    package = declaration["package"]
    version = declaration["version"]
    script = declaration["script"]
    if not isinstance(package, str) or PACKAGE.fullmatch(package) is None:
        raise ContractError("baseline declaration package is invalid")
    if arguments.expected_package and package != arguments.expected_package:
        raise ContractError("baseline declaration package does not match the protected caller")
    if not isinstance(version, str) or VERSION.fullmatch(version) is None:
        raise ContractError("baseline declaration requires a released semantic version")
    if not isinstance(script, str) or SCRIPT.fullmatch(script) is None:
        raise ContractError("baseline declaration script is invalid")
    if arguments.expected_script and script != arguments.expected_script:
        raise ContractError("baseline declaration script does not match the protected caller")
    validate_policy(arguments.package_policy, package, version)
    registry = registry_metadata(package, version, node_auth_token)
    request = json.dumps(
        {"package": package, "ranges": [version], "script": script},
        separators=(",", ":"),
        sort_keys=True,
    )
    receipt = {
        "schemaVersion": 1,
        "repository": arguments.repository,
        "declarationPath": arguments.declaration_path,
        "pullRequest": arguments.pull_request,
        "baseRef": base["ref"],
        "baseSha": base_sha,
        "headSha": event_head_sha,
        "declarationBlobSha": blob_sha,
        "declarationSha256": hashlib.sha256(declaration_bytes).hexdigest(),
        "package": package,
        "version": version,
        "script": script,
        "request": json.loads(request),
        "artifact": registry,
    }
    return {"request": request, "package": package, "version": version, "script": script, "receipt": receipt}


def write_outputs(values: dict, output_path: str) -> None:
    receipt = json.dumps(values["receipt"], separators=(",", ":"), sort_keys=True)
    outputs = {
        "request": values["request"],
        "package": values["package"],
        "version": values["version"],
        "script": values["script"],
        "receipt": receipt,
    }
    with Path(output_path).open("a", encoding="utf-8") as stream:
        for key, value in outputs.items():
            stream.write(f"{key}<<VERJSON_EOF\n{value}\nVERJSON_EOF\n")


def verify_receipt(arguments: argparse.Namespace) -> None:
    receipt = strict_object(Path(arguments.receipt).read_bytes(), "evidence receipt")
    required = {
        "schemaVersion",
        "repository",
        "declarationPath",
        "pullRequest",
        "baseRef",
        "baseSha",
        "headSha",
        "declarationBlobSha",
        "declarationSha256",
        "package",
        "version",
        "script",
        "request",
        "artifact",
        "typeSurfaceResult",
        "typeSurfaceProvenance",
    }
    if set(receipt) != required or receipt["schemaVersion"] != 1 or receipt["typeSurfaceResult"] != "success":
        raise ContractError("evidence receipt has an unexpected shape")
    if (
        not isinstance(receipt["pullRequest"], int)
        or receipt["pullRequest"] <= 0
        or not isinstance(receipt["baseRef"], str)
        or not re.fullmatch(r"[A-Za-z0-9._/-]+", receipt["baseRef"])
        or not isinstance(receipt["headSha"], str)
        or not SHA.fullmatch(receipt["headSha"])
    ):
        raise ContractError("evidence receipt run identity is invalid")
    if not SHA.fullmatch(receipt["baseSha"]) or not SHA.fullmatch(receipt["declarationBlobSha"]):
        raise ContractError("evidence receipt is not bound to immutable GitHub objects")
    if not SHA256.fullmatch(receipt["declarationSha256"]):
        raise ContractError("evidence receipt declaration digest is invalid")
    request = receipt["request"]
    if request != {"package": receipt["package"], "ranges": [receipt["version"]], "script": receipt["script"]}:
        raise ContractError("evidence receipt request was tampered with")
    artifact = receipt["artifact"]
    if not isinstance(artifact, dict) or set(artifact) != {"integrity", "tarball"}:
        raise ContractError("evidence receipt artifact provenance was tampered with")
    if not INTEGRITY.fullmatch(artifact["integrity"]):
        raise ContractError("evidence receipt artifact integrity is invalid")
    tarball = artifact["tarball"]
    parsed = urlparse(tarball) if isinstance(tarball, str) else None
    path = unquote(parsed.path) if parsed is not None else ""
    parts = path.split("/")
    expected_name = f"{parts[2]}/{parts[3]}" if len(parts) == 6 else ""
    if (
        parsed is None
        or parsed.scheme != "https"
        or parsed.netloc != "npm.pkg.github.com"
        or parsed.query
        or parsed.fragment
        or tarball != f"https://npm.pkg.github.com{path}"
        or len(parts) != 6
        or parts[1] != "download"
        or any(part in ("", ".", "..") for part in parts[1:])
        or expected_name != receipt["package"]
        or parts[4] != receipt["version"]
    ):
        raise ContractError("evidence receipt artifact URL is not bound to package and version")
    provenance = receipt["typeSurfaceProvenance"]
    if not isinstance(provenance, dict) or set(provenance) != {"schemaVersion", "request", "lanes"}:
        raise ContractError("evidence receipt exercised provenance has an unexpected shape")
    if provenance["schemaVersion"] != 1 or provenance["request"] != request:
        raise ContractError("evidence receipt exercised provenance request was tampered with")
    lanes = provenance["lanes"]
    if not isinstance(lanes, list) or len(lanes) != 1 or not isinstance(lanes[0], dict):
        raise ContractError("evidence receipt exercised provenance lane is invalid")
    lane = lanes[0]
    if (
        set(lane) != {"index", "package", "range", "script", "version", "integrity", "tarball", "sha512"}
        or lane["index"] != 0
        or lane["package"] != receipt["package"]
        or lane["range"] != receipt["version"]
        or lane["script"] != receipt["script"]
        or lane["version"] != receipt["version"]
        or lane["integrity"] != artifact["integrity"]
        or lane["tarball"] != artifact["tarball"]
        or not re.fullmatch(r"[0-9a-f]{128}", lane["sha512"])
    ):
        raise ContractError("evidence receipt exercised artifact does not match resolver artifact")
    if base64.b64decode(lane["integrity"].removeprefix("sha512-"), validate=True).hex() != lane["sha512"]:
        raise ContractError("evidence receipt exercised artifact digest is invalid")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("--repository", required=True)
    resolve_parser.add_argument("--pull-request", required=True, type=int)
    resolve_parser.add_argument("--declaration-path", required=True)
    resolve_parser.add_argument("--expected-package", default="")
    resolve_parser.add_argument("--expected-script", default="")
    resolve_parser.add_argument("--package-policy", required=True)
    resolve_parser.add_argument("--github-output", required=True)
    verify_parser = subparsers.add_parser("verify-receipt")
    verify_parser.add_argument("receipt")
    arguments = parser.parse_args()
    try:
        if arguments.command == "resolve":
            write_outputs(resolve(arguments), arguments.github_output)
        else:
            verify_receipt(arguments)
    except ContractError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
