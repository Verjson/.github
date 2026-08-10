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


PACKAGE = re.compile(r"^@verjson/[a-z0-9][a-z0-9._-]*$")
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


def build_plan(lock: dict[str, Any], approved_names: list[str]) -> list[dict[str, Any]]:
    if any(not isinstance(name, str) or not PACKAGE.fullmatch(name) for name in approved_names):
        raise DependencyError("approved packages must be exact @verjson package names")
    approved = set(approved_names)
    if len(approved) != len(approved_names):
        raise DependencyError("approved packages contain duplicates")
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
            found.add(registry_name)
        else:
            package_parts = name.split("/")
            unscoped = package_parts[-1]
            expected_path = f"/{name}/-/{unscoped}-{version}.tgz"
            if (
                parsed.hostname != "registry.npmjs.org"
                or resolved != f"https://registry.npmjs.org{expected_path}"
                or name.startswith("@verjson/")
            ):
                raise DependencyError(f"lock entry {path} is outside approved registries")
        validate_integrity(path, integrity)
        downloads[(resolved, integrity)] = private

    if found != approved:
        difference = ", ".join(sorted(approved ^ found))
        raise DependencyError(f"approved private package set differs from lockfile: {difference}")
    return [
        {"url": url, "integrity": integrity, "private": private}
        for (url, integrity), private in sorted(downloads.items())
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--approved", required=True)
    args = parser.parse_args()
    try:
        approved = json.loads(args.approved)
        if not isinstance(approved, list):
            raise DependencyError("approved packages must be an array")
        lock = json.loads(args.lock.read_text(encoding="utf-8"))
        if not isinstance(lock, dict):
            raise DependencyError("package-lock must contain an object")
        build_plan(lock, approved)
    except (DependencyError, OSError, json.JSONDecodeError) as error:
        print(f"container dependency acquisition rejected: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
