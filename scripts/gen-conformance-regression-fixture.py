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
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / ".github/workflows/node-ci.yml"
FIXTURE = ROOT / "scripts/ci-gate/conformance/regressions/node-ci-pre-adr-0178.yml"
BODY_START = "name: node-ci (reusable)\n"
DUMP = {"sort_keys": False, "width": 1000}


def render() -> str:
    header = FIXTURE.read_text(encoding="utf-8").split(BODY_START, 1)[0]
    document = yaml.safe_load(CONTRACT.read_text(encoding="utf-8"))
    if document["jobs"].pop("deferred-ci", None) is None:
        raise SystemExit("the contract no longer declares deferred-ci")
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
