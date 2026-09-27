#!/usr/bin/env python3
"""Verifier predicates that bind a signed merge-gate provenance to the canonical
required workflow rather than to the consumer's execution (ADR 0211, #1339).

The claim set is the GitHub Actions OIDC token payload as captured from a real
organization required-workflow run inside a private consumer repository
(config/merge-gate-provenance-fixtures.json). A Sigstore/Fulcio certificate issued
for such a token carries the same values as X.509 extensions, so these predicates
are the certificate policy a future signing rollout must enforce; nothing here
performs signing or verification of signatures.

    python3 scripts/merge-gate-provenance-claims.py verify \
        --claims claims.json --canonical-path .github/workflows/gate-rearm.yml \
        --canonical-sha <ruleset-stored-40-hex-sha>

The live gate (gate-rearm.yml) runs on pull_request_target; the capture that
seeded the fixtures ran on pull_request. Both event shapes are accepted, each
with the exact `sub`/`ref` form GitHub documents for it (ADR 0211).

Exit 0 when every predicate holds, 1 with one line per violated predicate.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

CANONICAL_REPOSITORY = "Verjson/.github"
CANONICAL_OWNER_ID = "279365001"
ISSUER = "https://token.actions.githubusercontent.com"
SHA = re.compile(r"^[0-9a-f]{40}$")
REVIEWED_RUNNER_ENVIRONMENTS = ("github-hosted", "self-hosted")
CANONICAL_PATH = re.compile(r"^\.github/workflows/[A-Za-z0-9._-]+\.yml$")
PULL_MERGE_REF = re.compile(r"^refs/pull/[0-9]+/merge$")
BRANCH_REF = re.compile(r"^refs/heads/[A-Za-z0-9._/-]+$")


class ProvenanceError(Exception):
    pass


def canonical_ref(path: str) -> str:
    return f"{CANONICAL_REPOSITORY}/{path}@refs/heads/main"


def violations(claims: dict, canonical_path: str, canonical_sha: str) -> list[str]:
    """Return every predicate the claim set violates; an empty list is a pass.

    Predicates are evaluated independently so a report names all of them, and
    every value is compared as an exact string: a claim that is missing, empty,
    or of another type is a violation, never a default.
    """
    if not isinstance(claims, dict):
        return ["claims must be a JSON object"]
    if not SHA.fullmatch(canonical_sha or ""):
        return ["canonical sha must be a 40-hex commit"]
    if not CANONICAL_PATH.fullmatch(canonical_path or ""):
        return ["canonical path must be a workflow file directly under .github/workflows/"]
    expected_ref = canonical_ref(canonical_path)

    def claim(name: str) -> str | None:
        value = claims.get(name)
        return value if isinstance(value, str) and value else None

    found = []
    if claim("iss") != ISSUER:
        found.append("iss is not the GitHub Actions token issuer")
    if claim("repository_owner_id") != CANONICAL_OWNER_ID:
        found.append("repository_owner_id is not the Verjson organization")
    if claim("repository_owner") != CANONICAL_REPOSITORY.split("/")[0]:
        found.append("repository_owner is not the Verjson organization")
    # The canonical identity: the injected workflow file and the exact commit the
    # ruleset stores. `job_workflow_ref` alone would accept any commit of main.
    if claim("job_workflow_ref") != expected_ref:
        found.append("job_workflow_ref does not name the canonical required workflow on main")
    if claim("job_workflow_sha") != canonical_sha:
        found.append("job_workflow_sha is not the ruleset's stored canonical commit")
    # A required workflow IS the top-level workflow, so both pairs agree. A
    # reusable call from a consumer-authored caller reports the caller here and
    # is exactly the consumer execution ADR 0077 refused to trust.
    if claim("workflow_ref") != expected_ref:
        found.append("workflow_ref differs from job_workflow_ref: not an injected required workflow")
    if claim("workflow_sha") != canonical_sha:
        found.append("workflow_sha differs from the canonical commit: not an injected required workflow")
    if claim("runner_environment") not in REVIEWED_RUNNER_ENVIRONMENTS:
        found.append("runner_environment is not a reviewed lane")
    repository = claim("repository")
    if not repository or repository.count("/") != 1 or not all(repository.split("/")):
        found.append("repository is malformed")
    elif repository.split("/")[0] != claim("repository_owner"):
        found.append("repository is not owned by repository_owner")
    # Event shape. The gate (gate-rearm.yml) is injected on pull_request_target,
    # whose token binds the BASE branch; the capture that seeded the fixtures ran
    # on pull_request, whose token binds the ephemeral merge ref. Each event has
    # exactly one documented `sub`/`ref` form and nothing else is accepted.
    event = claim("event_name")
    sub = claim("sub")
    ref = claim("ref")
    if event == "pull_request":
        if not PULL_MERGE_REF.fullmatch(ref or ""):
            found.append("ref is not the pull request merge ref")
        if repository and sub != f"repo:{repository}:pull_request":
            found.append("sub does not bind the pull_request event to the reporting repository")
    elif event == "pull_request_target":
        base_ref = claim("base_ref")
        if not base_ref or not BRANCH_REF.fullmatch(ref or "") or ref != f"refs/heads/{base_ref}":
            found.append("ref is not the pull request base branch")
        if repository and ref and sub != f"repo:{repository}:ref:{ref}":
            found.append("sub does not bind the pull_request_target base ref to the reporting repository")
    else:
        found.append("event_name is neither pull_request nor pull_request_target")
    for name in ("run_id", "run_attempt", "sha", "repository_id"):
        if claim(name) is None:
            found.append(f"{name} is absent")
    return found


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="mode", required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--claims", required=True, type=Path)
    verify.add_argument("--canonical-path", required=True)
    verify.add_argument("--canonical-sha", required=True)
    args = parser.parse_args(arguments)
    try:
        claims = json.loads(args.claims.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"provenance: cannot read claims: {error}", file=sys.stderr)
        return 2
    found = violations(claims, args.canonical_path, args.canonical_sha)
    for line in found:
        print(f"provenance: {line}", file=sys.stderr)
    if found:
        return 1
    print("provenance: claims bind the canonical required workflow")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
