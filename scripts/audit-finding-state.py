#!/usr/bin/env python3
"""Adjudicate a scheduled audit's findings against a reviewed expectation file."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from datetime import date, datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FINDING_LINE = re.compile(r"^ERROR: (.+)$")
ENTRY_FIELDS = ("fingerprint", "finding", "issue", "reason", "expires")

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
    validated = [validated_entry(entry, audit, index) for index, entry in enumerate(entries)]
    digests = [entry["fingerprint"] for entry in validated]
    if len(digests) != len(set(digests)):
        raise Undetermined(f"audit {audit!r} records the same finding more than once")
    return validated


def validated_entry(entry: object, audit: str, index: int) -> dict:
    where = f"{audit}[{index}]"
    if not isinstance(entry, dict) or set(entry) != set(ENTRY_FIELDS):
        raise Undetermined(f"expectation {where} must declare exactly {sorted(ENTRY_FIELDS)}")
    finding = entry["finding"]
    if not isinstance(finding, str) or not finding:
        raise Undetermined(f"expectation {where} records no finding text")
    digest = entry["fingerprint"]
    if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise Undetermined(f"expectation {where} fingerprint is not a sha256 digest")
    # The recorded text is what a reviewer reads; the digest is what the
    # comparison uses. Requiring them to agree is what stops a waiver from
    # quietly covering a finding other than the one it claims to describe.
    if digest != fingerprint(finding):
        raise Undetermined(f"expectation {where} fingerprint does not describe its recorded finding")
    issue = entry["issue"]
    if not isinstance(issue, int) or isinstance(issue, bool) or issue <= 0:
        raise Undetermined(f"expectation {where} names no tracking issue")
    reason = entry["reason"]
    if not isinstance(reason, str) or not reason:
        raise Undetermined(f"expectation {where} records no reason")
    return {**entry, "expires": parse_expiry(entry["expires"], where)}


def parse_expiry(value: object, where: str) -> date:
    try:
        return date.fromisoformat(value)
    except (TypeError, ValueError):
        raise Undetermined(f"expectation {where} expiry {value!r} is not an ISO date") from None


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
    # Neither shape can be compared, and treating either as "no finding" is the
    # fail-open ADR 0024 rules out: a crashed audit would read as conformance.
    if completed.returncode != 0 and not findings:
        raise Undetermined(
            f"audit exited {completed.returncode} and reported no finding to compare"
        )
    if completed.returncode == 0 and findings:
        raise Undetermined("audit succeeded while reporting findings")
    return findings


def adjudicate(observed: list[str], entries: list[dict], today: date) -> dict:
    # An expired waiver stops keeping its finding quiet. Without that the file
    # accumulates acknowledgements that outlive the work they point at, which is
    # the same "permanently expected red" the comparison exists to end.
    expired = {entry["fingerprint"] for entry in entries if entry["expires"] < today}
    active = {entry["fingerprint"] for entry in entries} - expired
    seen = {fingerprint(finding): finding for finding in observed}
    new = sorted(seen.keys() - active - expired)
    stale = sorted(active - seen.keys())
    return {
        "verdict": "drift" if new or stale or expired else "match",
        "observed": [
            {"fingerprint": digest, "finding": seen[digest]} for digest in sorted(seen)
        ],
        "expected": sorted(active),
        "new": new,
        "stale": stale,
        "expired": sorted(expired),
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
        today = datetime.now(timezone.utc).date()
        state = adjudicate(observe(command), entries, today)
    except Undetermined as error:
        print(f"ERROR: audit-state-undetermined: {error}", file=sys.stderr)
        return UNDETERMINED
    state["audit"] = args.audit
    print(json.dumps(state, sort_keys=True, separators=(",", ":")))
    return DRIFT if state["verdict"] == "drift" else MATCH


if __name__ == "__main__":
    raise SystemExit(main())
