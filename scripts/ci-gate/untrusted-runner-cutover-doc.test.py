#!/usr/bin/env python3
import collections
import pathlib
import re
import unittest


EXPECTED_ORDER = [
    "CI_RUNNER_UNTRUSTED",
    "VERJSON_LANE_UNTRUSTED",
    "VERJSON_RUNNER_UNTRUSTED",
    "CI_RUNNER_ISOLATED",
    "VERJSON_RUNNER_ISOLATED",
    "CI_LANE_UNTRUSTED",
]
CANONICAL = "CI_LANE_UNTRUSTED"
ADR = (
    pathlib.Path(__file__).resolve().parents[2]
    / "docs/decisions/0147-route-untrusted-ci-to-ephemeral-hosted-runners/README.md"
)


def extract_cutover_order(document: str) -> list[str]:
    migration = document.split("## Migration and canary", 1)
    if len(migration) != 2:
        raise ValueError("migration section missing")
    migration_body = migration[1].split("## Rollback", 1)[0]
    blocks = re.findall(r"```text\n([^`]+?)\n\s*```", migration_body)
    if len(blocks) != 1:
        raise ValueError("migration must contain exactly one text order block")
    return [line.strip() for line in blocks[0].splitlines() if line.strip()]


def validate_cutover_order(order: list[str]) -> None:
    if collections.Counter(order) != collections.Counter(EXPECTED_ORDER):
        raise ValueError("all six aliases must appear exactly once")
    if order[-1] != CANONICAL:
        raise ValueError("canonical CI_LANE_UNTRUSTED must be last")
    if order != EXPECTED_ORDER:
        raise ValueError("legacy alias order changed")


class CutoverDocumentationContract(unittest.TestCase):
    def test_documented_order_updates_every_legacy_alias_before_canonical(self):
        order = extract_cutover_order(ADR.read_text(encoding="utf-8"))

        validate_cutover_order(order)

        self.assertEqual(order, EXPECTED_ORDER)

    def test_canonical_first_mutation_fails_for_last_position(self):
        mutation = [CANONICAL, *EXPECTED_ORDER[:-1]]

        with self.assertRaisesRegex(ValueError, "must be last"):
            validate_cutover_order(mutation)

    def test_duplicate_alias_mutation_fails_for_exactly_once(self):
        mutation = [*EXPECTED_ORDER[:-1], EXPECTED_ORDER[0], CANONICAL]

        with self.assertRaisesRegex(ValueError, "exactly once"):
            validate_cutover_order(mutation)

    def test_missing_alias_mutation_fails_for_exactly_once(self):
        mutation = EXPECTED_ORDER[1:]

        with self.assertRaisesRegex(ValueError, "exactly once"):
            validate_cutover_order(mutation)


if __name__ == "__main__":
    unittest.main()
