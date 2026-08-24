#!/usr/bin/env python3

import argparse
import base64
import binascii
import json
import os
import re
import urllib.parse
from pathlib import Path
from typing import Any


class DependencyError(ValueError):
    pass


PACKAGE = re.compile(r"^@[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$")
REGISTRY_PACKAGE = re.compile(r"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$")


def validate_integrity(path: str, integrity: Any) -> None:
    if not isinstance(integrity, str) or not integrity.startswith("sha512-"):
        raise DependencyError(f"lock entry {path} lacks sha512 integrity")
    try:
        digest = base64.b64decode(integrity.removeprefix("sha512-"), validate=True)
    except (binascii.Error, ValueError):
        raise DependencyError(f"lock entry {path} lacks sha512 integrity") from None
    if len(digest) != 64:
        raise DependencyError(f"lock entry {path} lacks sha512 integrity")


def validate_approved(approved_names: list[str]) -> set[str]:
    if any(not isinstance(name, str) or not PACKAGE.fullmatch(name) for name in approved_names):
        raise DependencyError("approved packages must be exact lowercase scoped package names")
    approved = set(approved_names)
    if len(approved) != len(approved_names):
        raise DependencyError("approved packages contain duplicates")
    return approved


def validate_url(path: str, name: str, version: str, resolved: str, approved: set[str]) -> bool:
    try:
        parsed = urllib.parse.urlparse(resolved)
        unsafe_url = (
            parsed.scheme != "https"
            or parsed.query
            or parsed.fragment
            or parsed.username is not None
            or parsed.password is not None
            or parsed.port is not None
        )
    except ValueError:
        unsafe_url = True
    if unsafe_url:
        raise DependencyError(f"lock entry {path} has an unsafe resolved URL")
    private = parsed.hostname == "npm.pkg.github.com"
    if private:
        decoded_path = urllib.parse.unquote(parsed.path)
        parts = decoded_path.split("/")
        if (
            len(parts) != 6
            or parts[1] != "download"
            or not parts[2].startswith("@")
            or any(part in ("", ".", "..") for part in parts[1:])
            or resolved != f"https://npm.pkg.github.com{decoded_path}"
            or parts[4] != version
        ):
            raise DependencyError(f"lock entry {path} has an invalid GitHub Packages URL")
        registry_name = f"{parts[2]}/{parts[3]}"
        if registry_name != name or registry_name not in approved:
            raise DependencyError(f"unapproved private package: {registry_name}")
    else:
        unscoped = name.split("/")[-1]
        expected_path = f"/{name}/-/{unscoped}-{version}.tgz"
        if (
            parsed.hostname != "registry.npmjs.org"
            or resolved != f"https://registry.npmjs.org{expected_path}"
            or name in approved
        ):
            raise DependencyError(f"lock entry {path} is outside approved registries")
    return private


def build_npm_plan(lock: dict[str, Any], approved_names: list[str]) -> list[dict[str, Any]]:
    approved = validate_approved(approved_names)
    if lock.get("lockfileVersion") not in (2, 3):
        raise DependencyError("package-lock lockfileVersion must be 2 or 3")

    packages = lock.get("packages")
    if not isinstance(packages, dict):
        raise DependencyError("package-lock packages must be an object")
    found: set[str] = set()
    downloads: dict[tuple[str, str], bool] = {}
    for path, package in packages.items():
        if not isinstance(package, dict):
            raise DependencyError(f"lock entry {path} must be an object")
        if path == "" or package.get("link") is True:
            continue
        install_name = path.rsplit("node_modules/", 1)[-1]
        name = package.get("name", install_name)
        resolved, integrity, version = (
            package.get("resolved"),
            package.get("integrity"),
            package.get("version"),
        )
        if not isinstance(resolved, str):
            raise DependencyError(f"lock entry {path} lacks an exact resolved URL and integrity")
        if (
            not isinstance(version, str)
            or not version
            or "/" in version
            or not isinstance(name, str)
            or not REGISTRY_PACKAGE.fullmatch(name)
        ):
            raise DependencyError(f"lock entry {path} lacks a canonical package identity")
        private = validate_url(path, name, version, resolved, approved)
        if private:
            found.add(name)
        validate_integrity(path, integrity)
        downloads[(resolved, integrity)] = private

    if found != approved:
        difference = ", ".join(sorted(approved ^ found))
        raise DependencyError(f"approved private package set differs from lockfile: {difference}")
    return [
        {"url": url, "integrity": integrity, "private": private}
        for (url, integrity), private in sorted(downloads.items())
    ]


def pnpm_identity(key: Any) -> tuple[str, str]:
    if not isinstance(key, str) or any(ord(char) < 32 for char in key):
        raise DependencyError("pnpm package key must be a printable string")
    match = re.fullmatch(r"((?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*)@([^()]+)(?:\(.*\))?", key)
    if match is None or match.group(2).startswith("npm:"):
        raise DependencyError(f"invalid or aliased pnpm package key: {key}")
    reference = key[len(match.group(1)) + 1:]
    depth = 0
    for char in reference:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth < 0:
                raise DependencyError(f"unbalanced pnpm peer context: {key}")
    if depth:
        raise DependencyError(f"unbalanced pnpm peer context: {key}")
    return match.group(1), match.group(2)


def build_pnpm_plan(lock: dict[str, Any], approved_names: list[str]) -> list[dict[str, Any]]:
    approved = validate_approved(approved_names)
    if str(lock.get("lockfileVersion")) != "9.0":
        raise DependencyError("pnpm-lock lockfileVersion must be 9.0")
    packages = lock.get("packages")
    if not isinstance(packages, dict):
        raise DependencyError("pnpm-lock packages must be an object")
    found: set[str] = set()
    downloads: dict[tuple[str, str], bool] = {}
    for key, package in packages.items():
        if not isinstance(package, dict):
            raise DependencyError(f"lock entry {key} must be an object")
        name, version = pnpm_identity(key)
        resolution = package.get("resolution")
        if not isinstance(resolution, dict):
            raise DependencyError(f"lock entry {key} lacks a resolution object")
        integrity = resolution.get("integrity")
        validate_integrity(key, integrity)
        resolved = resolution.get("tarball")
        if resolved is None:
            if name in approved:
                raise DependencyError(f"approved private package {name} lacks an exact tarball URL")
            continue
        if not isinstance(resolved, str):
            raise DependencyError(f"lock entry {key} has an invalid tarball URL")
        private = validate_url(key, name, version, resolved, approved)
        if private:
            found.add(name)
        downloads[(resolved, integrity)] = private
    if found != approved:
        difference = ", ".join(sorted(approved ^ found))
        raise DependencyError(f"approved private package set differs from lockfile: {difference}")
    return [{"url": url, "integrity": integrity, "private": private}
            for (url, integrity), private in sorted(downloads.items())]


build_plan = build_npm_plan


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--approved", required=True)
    parser.add_argument("--package-manager", choices=("npm", "pnpm"), required=True)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    try:
        approved = json.loads(args.approved)
        if not isinstance(approved, list):
            raise DependencyError("approved packages must be an array")
        text = args.lock.read_text(encoding="utf-8")
        if args.package_manager == "pnpm":
            if args.manifest is None:
                raise DependencyError("pnpm validation requires package.json")
            manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
            if not isinstance(manifest, dict) or re.fullmatch(
                r"pnpm@[1-9][0-9]*\.[0-9]+\.[0-9]+\+sha512\.[0-9a-f]{128}",
                manifest.get("packageManager", ""),
            ) is None:
                raise DependencyError("pnpm requires an integrity-pinned packageManager field")
            if len(text.encode("utf-8")) > 10 * 1024 * 1024:
                raise DependencyError("pnpm lock exceeds the 10 MiB validation bound")
            try:
                import yaml
            except ImportError:
                raise DependencyError("pnpm validation requires PyYAML") from None
            for token in yaml.scan(text):
                if isinstance(token, (yaml.AliasToken, yaml.AnchorToken, yaml.TagToken)):
                    raise DependencyError("pnpm lock rejects YAML aliases, anchors, and tags")
            class ExactLoader(yaml.SafeLoader):
                pass
            def exact_mapping(loader: Any, node: Any, deep: bool = False) -> dict[Any, Any]:
                result = {}
                for key_node, value_node in node.value:
                    key = loader.construct_object(key_node, deep=deep)
                    if key in result:
                        raise DependencyError(f"duplicate pnpm lock key: {key}")
                    result[key] = loader.construct_object(value_node, deep=deep)
                return result
            ExactLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, exact_mapping)
            try:
                lock = yaml.load(text, Loader=ExactLoader)
            except yaml.YAMLError as error:
                raise DependencyError(f"invalid pnpm lock: {error}") from None
        else:
            lock = json.loads(text)
        if not isinstance(lock, dict):
            raise DependencyError("lockfile must contain an object")
        if args.package_manager == "pnpm":
            build_pnpm_plan(lock, approved)
        else:
            build_npm_plan(lock, approved)
    except (DependencyError, OSError, json.JSONDecodeError) as error:
        print(f"container dependency acquisition rejected: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
