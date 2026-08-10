#!/usr/bin/env python3
"""Reject mutable remote actions across every active workflow and action."""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import re
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCAN_ROOTS = (Path(".github/workflows"), Path(".github/actions"))
REMOTE_ACTION = re.compile(
    r"^(?P<owner>[A-Za-z0-9_.-]+)/(?P<repo>[A-Za-z0-9_.-]+)"
    r"(?P<path>/[^@\s]+)?@(?P<ref>[^@\s]+)$"
)
IMMUTABLE_REF = re.compile(r"[0-9a-f]{40}")
IMMUTABLE_IMAGE = re.compile(r"docker://[^@\s]+@sha256:[0-9a-f]{64}")
# Deliberately empty. Any unavoidable self-reference must be an exact ref with a
# non-empty security rationale; broad owner/repository exceptions are forbidden.
MUTABLE_FIRST_PARTY_ALLOWLIST: dict[str, str] = {}


class ConformanceError(Exception):
    pass


def action_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for relative_root in SCAN_ROOTS:
        directory = root / relative_root
        if directory.is_dir():
            files.extend(path for path in directory.rglob("*.yml") if path.is_file())
            files.extend(path for path in directory.rglob("*.yaml") if path.is_file())
    return sorted(files)


def iter_uses(value: object, location: str = "root"):
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}"
            if key == "uses":
                yield child_location, child
            yield from iter_uses(child, child_location)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from iter_uses(child, f"{location}[{index}]")


def validate_uses(value: object, location: str) -> None:
    if not isinstance(value, str):
        raise ConformanceError(f"{location}: uses must be a string")
    if value.startswith("./"):
        return
    if value.startswith("docker://"):
        if IMMUTABLE_IMAGE.fullmatch(value) is None:
            raise ConformanceError(
                f"{location}: container action {value!r} must use a lowercase sha256 digest"
            )
        return
    match = REMOTE_ACTION.fullmatch(value)
    if match is None:
        raise ConformanceError(f"{location}: malformed remote action reference {value!r}")
    if IMMUTABLE_REF.fullmatch(match.group("ref")) is None:
        rationale = MUTABLE_FIRST_PARTY_ALLOWLIST.get(value)
        if match.group("owner").lower() == "verjson" and rationale:
            return
        raise ConformanceError(
            f"{location}: remote action {value!r} must use a lowercase 40-hex commit SHA"
        )


def validate_document(document: object, source: str) -> int:
    if not isinstance(document, dict):
        raise ConformanceError(f"{source}: YAML root must be a mapping")
    count = 0
    for location, value in iter_uses(document):
        validate_uses(value, f"{source}:{location}")
        count += 1
    return count


def load_document(path: Path) -> object:
    try:
        with path.open(encoding="utf-8") as stream:
            return yaml.safe_load(stream)
    except yaml.YAMLError as error:
        raise ConformanceError(f"{path}: invalid YAML: {error}") from error


def validate_repository(root: Path) -> int:
    files = action_files(root)
    if not files:
        raise ConformanceError("no active workflow or local-action YAML files found")
    return sum(
        validate_document(load_document(path), str(path.relative_to(root)))
        for path in files
    )


def mutation_is_rejected(document: object, replacement: str) -> bool:
    mutant = deepcopy(document)
    for container in _mapping_containers(mutant):
        if "uses" in container and isinstance(container["uses"], str):
            container["uses"] = replacement
            try:
                validate_document(mutant, "mutation")
            except ConformanceError:
                return True
            return False
    raise ConformanceError("mutation fixture contains no uses reference")


def _mapping_containers(value: object):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _mapping_containers(child)
    elif isinstance(value, list):
        for child in value:
            yield from _mapping_containers(child)


def run_mutation_contracts() -> None:
    fixture = yaml.safe_load(
        "jobs:\n  test:\n    steps:\n"
        "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"
    )
    mutations = {
        "checkout major tag": "actions/checkout@v7",
        "third-party branch": "azure/setup-helm@main",
        "first-party branch": "Verjson/.github/.github/actions/setup-verjson-node@main",
        "short commit": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b",
        "mutable container tag": "docker://alpine:latest",
    }
    for description, replacement in mutations.items():
        if not mutation_is_rejected(fixture, replacement):
            raise ConformanceError(f"validator accepted mutation: {description}")


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else ROOT
    try:
        count = validate_repository(root)
        run_mutation_contracts()
    except ConformanceError as error:
        print(f"FAIL - {error}", file=sys.stderr)
        return 1
    print(f"ok - {count} active action references are immutable and mutation contracts reject drift")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
