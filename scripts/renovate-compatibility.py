#!/usr/bin/env python3
"""Fail-closed decision engine for Renovate compatibility observations."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


def load(path: str) -> object:
    with Path(path).open(encoding="utf-8") as stream:
        return json.load(stream)


def hold_entries(value: object) -> list[object]:
    if isinstance(value, dict):
        value = value.get("holds")
    if not isinstance(value, list):
        raise ValueError("hold registry must contain a holds array")
    return value


def normalized_signature(value: str) -> str:
    value = re.sub(r"\b[0-9a-f]{7,40}\b", "<sha>", value.lower())
    value = re.sub(r"(?:/[^\s:]+)+", "<path>", value)
    value = re.sub(r"\b\d+(?:\.\d+)+\b", "<version>", value)
    value = re.sub(r"\s+", " ", value).strip()
    return hashlib.sha256(value.encode()).hexdigest()


OBSERVATION_FIELDS = {
    "repository", "pullRequest", "ecosystem", "package", "targetMajor",
    "stackProfile", "baseGreen", "majorUpdate", "relevantCheckFailed",
    "retryCompleted", "firstFailure", "retryFailure",
}
REPOSITORY = re.compile(r"^Verjson/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?$")
PACKAGE = {
    "npm": re.compile(r"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$"),
    "github-actions": re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"),
    "docker": re.compile(r"^(?:[a-z0-9.-]+(?::[0-9]{1,5})?/)?[a-z0-9._-]+(?:/[a-z0-9._-]+)*$"),
}
PROFILE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def valid_observation(observation: object) -> bool:
    if not isinstance(observation, dict) or set(observation) != OBSERVATION_FIELDS:
        return False
    ecosystem = observation["ecosystem"]
    package = observation["package"]
    pull_request = observation["pullRequest"]
    target_major = observation["targetMajor"]
    if not isinstance(ecosystem, str) or ecosystem not in PACKAGE:
        return False
    if not isinstance(package, str) or not PACKAGE[ecosystem].fullmatch(package):
        return False
    if not isinstance(observation["repository"], str) or not REPOSITORY.fullmatch(observation["repository"]):
        return False
    if not isinstance(observation["stackProfile"], str) or not PROFILE.fullmatch(observation["stackProfile"]):
        return False
    if isinstance(pull_request, bool) or not isinstance(pull_request, int) or not 1 <= pull_request <= 2_147_483_647:
        return False
    if isinstance(target_major, bool) or not isinstance(target_major, int) or not 1 <= target_major <= 10_000:
        return False
    if any(type(observation[key]) is not bool for key in (
        "baseGreen", "majorUpdate", "relevantCheckFailed", "retryCompleted"
    )):
        return False
    return all(
        isinstance(observation[key], str) and 0 < len(observation[key].strip()) <= 65_536
        for key in ("firstFailure", "retryFailure")
    )


def fingerprint(observation: dict[str, object]) -> str:
    if not valid_observation(observation):
        raise ValueError("invalid compatibility observation")
    identity = (
        str(observation["ecosystem"]),
        str(observation["package"]),
        int(observation["targetMajor"]),
        str(observation["stackProfile"]),
        normalized_signature(str(observation["firstFailure"])),
    )
    return "/".join(map(str, identity))


def eligible(observation: dict[str, object]) -> bool:
    if not valid_observation(observation):
        return False
    return all(
        observation[key] is True
        for key in ("baseGreen", "majorUpdate", "relevantCheckFailed", "retryCompleted")
    ) and normalized_signature(str(observation["firstFailure"])) == normalized_signature(
        str(observation["retryFailure"])
    )


def reconcile(observations: list[object], holds: list[object]) -> dict[str, object]:
    known = {
        "/".join((str(h["ecosystem"]), str(h["package"]), str(h["targetMajor"]),
                  str(h["stackProfile"]), str(h["failureFingerprint"])))
        for item in holds if isinstance(item, dict) for h in (item,)
    }
    seen: set[str] = set()
    results: list[dict[str, object]] = []
    for item in observations:
        if not valid_observation(item):
            results.append({"disposition": "reject", "reason": "invalid-observation"})
            continue
        if not eligible(item):
            results.append({"disposition": "reject", "reason": "insufficient-repeatable-evidence"})
            continue
        key = fingerprint(item)
        disposition = "known" if key in known or key in seen else "report"
        seen.add(key)
        results.append({
            "disposition": disposition,
            "fingerprint": key,
            "repository": item["repository"],
            "pullRequest": item["pullRequest"],
            "aiClassificationRequired": disposition == "report",
        })
    return {"mode": "observe-only", "results": results}


def versions(value: str) -> tuple[int, ...]:
    match = re.match(r"^(\d+(?:\.\d+)*)", value)
    if not match:
        raise ValueError(f"invalid version: {value}")
    return tuple(int(part) for part in match.group(1).split("."))


def discover(holds: list[object], registry: dict[str, object]) -> dict[str, object]:
    candidates = []
    for item in holds:
        if not isinstance(item, dict) or item.get("status", "held") != "held":
            continue
        package = str(item["package"])
        available = registry.get(package, [])
        if not isinstance(available, list):
            continue
        newer = sorted(
            (str(version) for version in available if versions(str(version)) > versions(str(item["testedThroughVersion"]))),
            key=versions,
        )
        if newer:
            candidates.append({
                "holdId": item["id"], "package": package, "candidate": newer[-1],
                "stackProfile": item["stackProfile"],
                "repositories": item["representativeRepositories"],
            })
    return {"candidates": candidates}


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("reconcile")
    rec.add_argument("--observations", required=True)
    rec.add_argument("--holds", required=True)
    can = sub.add_parser("discover")
    can.add_argument("--holds", required=True)
    can.add_argument("--registry-versions", required=True)
    args = parser.parse_args()
    if args.command == "reconcile":
        observations = load(args.observations)
        if not isinstance(observations, list):
            raise ValueError("observations must be an array")
        output = reconcile(observations, hold_entries(load(args.holds)))
    else:
        registry = load(args.registry_versions)
        if not isinstance(registry, dict):
            raise ValueError("registry versions must be an object")
        output = discover(hold_entries(load(args.holds)), registry)
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
