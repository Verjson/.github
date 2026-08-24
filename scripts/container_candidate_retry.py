#!/usr/bin/env python3

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


class RetryEvidenceError(ValueError):
    pass


DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RetryEvidenceError(f"{field} must be an object")
    return value


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise RetryEvidenceError(f"{field} must be a non-empty string")
    return value


def validate_verified_provenance(
    evidence: Any, *, repository: str, digest: str
) -> str:
    if not isinstance(evidence, list) or len(evidence) != 1:
        raise RetryEvidenceError("exactly one verified provenance attestation is required")
    verified = _object(evidence[0], "verified provenance")
    if set(verified) != {"attestation", "verificationResult"}:
        raise RetryEvidenceError("verified provenance has unexpected fields")
    attestation = _object(verified["attestation"], "verified provenance.attestation")
    result = _object(
        verified["verificationResult"], "verified provenance.verificationResult"
    )
    statement = _object(result.get("statement"), "verified provenance statement")
    if statement.get("predicateType") != "https://slsa.dev/provenance/v1":
        raise RetryEvidenceError("verified provenance predicate differs")
    subjects = statement.get("subject")
    expected_name = repository.removeprefix("ghcr.io/")
    if not isinstance(subjects, list) or len(subjects) != 1:
        raise RetryEvidenceError("verified provenance must name exactly one subject")
    subject = _object(subjects[0], "verified provenance subject")
    subject_digest = _object(subject.get("digest"), "verified provenance subject.digest")
    if set(subject_digest) != {"sha256"} or subject_digest["sha256"] != digest.removeprefix("sha256:"):
        raise RetryEvidenceError("verified provenance subject digest differs")
    if _text(subject.get("name"), "verified provenance subject.name").removeprefix("pkg:docker/") not in {
        repository,
        expected_name,
    }:
        raise RetryEvidenceError("verified provenance subject repository differs")
    bundle = json.dumps(attestation, sort_keys=True, separators=(",", ":")).encode()
    return "verified-bundle-sha256:" + hashlib.sha256(bundle).hexdigest()


def _load(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RetryEvidenceError(f"cannot read {path}: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate exact-SHA container retry provenance"
    )
    parser.add_argument("--verified-provenance", required=True, type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--digest", required=True)
    args = parser.parse_args()
    try:
        if not DIGEST.fullmatch(args.digest):
            raise RetryEvidenceError("digest must be a lowercase sha256 digest")
        identity = validate_verified_provenance(
            _load(args.verified_provenance),
            repository=args.repository,
            digest=args.digest,
        )
    except RetryEvidenceError as error:
        print(f"container retry evidence rejected: {error}", file=sys.stderr)
        return 1
    print(identity)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
