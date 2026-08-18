#!/usr/bin/env python3

import argparse
import base64
import binascii
import json
import re
from pathlib import Path
from urllib.parse import urlsplit


INTEGRITY = re.compile(r"sha512-([A-Za-z0-9+/]{86}==)")
REGISTRIES = {"registry.npmjs.org", "npm.pkg.github.com"}


def validate(path: Path) -> None:
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("deployment CLI lockfile is unreadable") from error
    if lock.get("lockfileVersion") != 3 or not isinstance(lock.get("packages"), dict):
        raise ValueError("deployment CLI lockfile must use npm lockfile version 3")
    packages = lock["packages"]
    if "" not in packages or len(packages) < 2:
        raise ValueError("deployment CLI lockfile has no dependency graph")
    for package_path, package in packages.items():
        if package_path == "":
            continue
        if not isinstance(package, dict):
            raise ValueError(f"lock package {package_path!r} is malformed")
        integrity = package.get("integrity")
        match = INTEGRITY.fullmatch(integrity) if isinstance(integrity, str) else None
        if match is None:
            raise ValueError(f"lock package {package_path!r} lacks exact sha512 integrity")
        try:
            digest = base64.b64decode(match.group(1), validate=True)
        except (ValueError, binascii.Error) as error:
            raise ValueError(f"lock package {package_path!r} has malformed sha512 integrity") from error
        if len(digest) != 64 or base64.b64encode(digest).decode("ascii") != match.group(1):
            raise ValueError(f"lock package {package_path!r} has non-canonical sha512 integrity")
        resolved = package.get("resolved")
        parsed = urlsplit(resolved) if isinstance(resolved, str) else None
        if (
            parsed is None
            or parsed.scheme != "https"
            or parsed.hostname not in REGISTRIES
            or parsed.username is not None
            or parsed.password is not None
            or parsed.port is not None
            or parsed.query
            or parsed.fragment
            or not parsed.path.startswith("/")
        ):
            raise ValueError(f"lock package {package_path!r} uses a non-canonical registry URL")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("lockfile", type=Path)
    arguments = parser.parse_args()
    try:
        validate(arguments.lockfile)
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
