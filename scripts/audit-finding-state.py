#!/usr/bin/env python3
"""Adjudicate a scheduled audit's findings against a reviewed expectation file."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FINDING_LINE = re.compile(r"^ERROR: (.+)$")

MATCH = 0
DRIFT = 1
UNDETERMINED = 2


class Undetermined(Exception):
    """The comparison could not be made, so the control fails closed."""


def fingerprint(finding: str) -> str:
    return hashlib.sha256(finding.encode("utf-8")).hexdigest()


def read_expectations(path: Path, audit: str) -> list[dict]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise Undetermined(f"expectation file is unreadable: {error}") from None
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise Undetermined("expectation file has an unsupported schema")
    audits = document.get("audits")
    if not isinstance(audits, dict):
        raise Undetermined("expectation file declares no audits")
    if audit not in audits:
        raise Undetermined(f"audit {audit!r} has no recorded expectation")
    entries = audits[audit]
    if not isinstance(entries, list):
        raise Undetermined(f"audit {audit!r} expectation is not a list")
    return entries


def observe(command: list[str]) -> list[str]:
    try:
        completed = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        raise Undetermined(f"audit command could not be started: {error}") from None
    findings = []
    for line in completed.stderr.splitlines():
        match = FINDING_LINE.match(line)
        if match:
            findings.append(match.group(1))
    sys.stderr.write(completed.stderr)
    return findings


def adjudicate(observed: list[str], entries: list[dict]) -> dict:
    expected = {entry["fingerprint"] for entry in entries}
    seen = {fingerprint(finding): finding for finding in observed}
    new = sorted(seen.keys() - expected)
    return {
        "verdict": "drift" if new else "match",
        "observed": [
            {"fingerprint": digest, "finding": seen[digest]} for digest in sorted(seen)
        ],
        "expected": sorted(expected),
        "new": new,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit", required=True)
    parser.add_argument("--expectations", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    try:
        entries = read_expectations(Path(args.expectations), args.audit)
        state = adjudicate(observe(command), entries)
    except Undetermined as error:
        print(f"ERROR: audit-state-undetermined: {error}", file=sys.stderr)
        return UNDETERMINED
    state["audit"] = args.audit
    print(json.dumps(state, sort_keys=True, separators=(",", ":")))
    return DRIFT if state["verdict"] == "drift" else MATCH


if __name__ == "__main__":
    raise SystemExit(main())
