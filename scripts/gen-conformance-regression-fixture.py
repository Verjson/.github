#!/usr/bin/env python3
"""Regenerate the pre-ADR-0178 conformance counter-example from the contract.

The fixture is `node-ci.yml` with the `deferred-ci` job removed and nothing
else changed, so it must be regenerated with the contract. Its exact dump
parameters live here rather than in a comment: without them the round-trip has
to be reverse-engineered by bisecting the fold width before the fixture can be
brought current, and
`test_the_counter_example_differs_from_the_contract_only_by_the_deferred_job`
is the check that fails in the meantime.
"""
import copy
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / ".github/workflows/node-ci.yml"
FIXTURE = ROOT / "scripts/ci-gate/conformance/regressions/node-ci-pre-adr-0178.yml"
BODY_START = "name: node-ci (reusable)\n"
DUMP = {"sort_keys": False, "width": 1000}
DEFERRED_JOB_PATH = "jobs.deferred-ci"


def without_deferred_ci(document: object) -> dict:
    if not isinstance(document, dict):
        raise SystemExit(
            f"the contract root must be a mapping; cannot remove {DEFERRED_JOB_PATH}"
        )
    jobs = document.get("jobs")
    if not isinstance(jobs, dict):
        raise SystemExit(
            f"the contract jobs field must be a mapping; cannot remove {DEFERRED_JOB_PATH}"
        )
    deferred_job = jobs.get("deferred-ci")
    if not isinstance(deferred_job, dict):
        if "deferred-ci" not in jobs:
            raise SystemExit(f"the contract no longer declares {DEFERRED_JOB_PATH}")
        raise SystemExit(f"the contract {DEFERRED_JOB_PATH} must be a mapping")

    counter_example = copy.deepcopy(document)
    del counter_example["jobs"]["deferred-ci"]
    return counter_example


def render() -> str:
    # `str.split` returns the whole text when the separator is absent, so an
    # unguarded `[0]` would make the entire fixture the "header" and append a
    # second full dump beneath it. The conformance assertion parses the result
    # and PyYAML takes the last of duplicate keys, so the fixture would double
    # in size on every run while every check kept passing.
    parts = FIXTURE.read_text(encoding="utf-8").split(BODY_START, 1)
    if len(parts) != 2:
        raise SystemExit(
            f"{FIXTURE} does not contain the body marker {BODY_START!r}; "
            "refusing to regenerate a fixture whose header cannot be located"
        )
    header = parts[0]
    document = without_deferred_ci(
        yaml.safe_load(CONTRACT.read_text(encoding="utf-8"))
    )
    return header + yaml.safe_dump(document, **DUMP)


def main() -> int:
    rendered = render()
    if "--check" in sys.argv[1:]:
        if FIXTURE.read_text(encoding="utf-8") == rendered:
            return 0
        print(f"{FIXTURE} is stale; run {Path(__file__).name}", file=sys.stderr)
        return 1
    FIXTURE.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
