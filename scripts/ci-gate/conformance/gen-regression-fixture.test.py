#!/usr/bin/env python3
"""Unit tests for scripts/gen-conformance-regression-fixture.py."""

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "scripts/gen-conformance-regression-fixture.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("gen_regression_fixture", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RenderRefusesAnUnlocatableHeader(unittest.TestCase):
    def setUp(self):
        self.generator = load_generator()

    def test_a_fixture_without_the_body_marker_is_refused(self):
        # Arrange: a fixture whose marker the generator cannot find. `str.split`
        # returns the whole text for an absent separator, so an unguarded `[0]`
        # would treat the entire fixture as the header and append a second dump
        # beneath it — doubling the file on every run while the conformance
        # assertion kept passing, because PyYAML takes the last duplicate key.
        self.generator.BODY_START = "name: a marker this fixture does not carry\n"

        # Act / Assert
        with self.assertRaises(SystemExit) as refusal:
            self.generator.render()

        self.assertIn("does not contain the body marker", str(refusal.exception))

    def test_the_real_fixture_still_renders(self):
        # Arrange / Act: the marker is present in the committed fixture, so the
        # guard must not make the ordinary path refuse.
        rendered = self.generator.render()

        # Assert
        self.assertTrue(rendered.startswith(self.generator.FIXTURE.read_text(
            encoding="utf-8").split(self.generator.BODY_START, 1)[0]))
        self.assertIn(self.generator.BODY_START, rendered)

    def test_only_the_top_level_deferred_job_is_removed(self):
        # Arrange: same-named decoys make a broad search or wrong-field mutation
        # look successful unless the exact jobs.deferred-ci path is proved.
        document = {
            "deferred-ci": {"decoy": "root"},
            "jobs": {
                "build-test": {"deferred-ci": {"decoy": "nested"}},
                "deferred-ci": {"if": "expected-condition"},
            },
        }

        # Act
        counter_example = self.generator.without_deferred_ci(document)

        # Assert: source is not mutated, the intended member alone is absent,
        # and both wrong-field decoys survive byte-for-byte as values.
        self.assertIn("deferred-ci", document["jobs"])
        self.assertNotIn("deferred-ci", counter_example["jobs"])
        self.assertEqual({"decoy": "root"}, counter_example["deferred-ci"])
        self.assertEqual(
            {"decoy": "nested"},
            counter_example["jobs"]["build-test"]["deferred-ci"],
        )

    def test_wrong_field_decoys_do_not_hide_a_missing_deferred_job(self):
        # Arrange: the intended path is absent while plausible wrong locations
        # still contain a same-named mapping.
        document = {
            "deferred-ci": {"decoy": "root"},
            "jobs": {"build-test": {"deferred-ci": {"decoy": "nested"}}},
        }

        # Act / Assert
        with self.assertRaises(SystemExit) as refusal:
            self.generator.without_deferred_ci(document)
        self.assertEqual(
            "the contract no longer declares jobs.deferred-ci",
            str(refusal.exception),
        )

    def test_contract_shape_errors_name_the_exact_failed_boundary(self):
        cases = (
            ([], "the contract root must be a mapping"),
            ({}, "the contract jobs field must be a mapping"),
            ({"jobs": []}, "the contract jobs field must be a mapping"),
            ({"jobs": {"deferred-ci": None}}, "jobs.deferred-ci must be a mapping"),
        )
        for document, expected in cases:
            with self.subTest(document=document):
                with self.assertRaises(SystemExit) as refusal:
                    self.generator.without_deferred_ci(document)
                self.assertIn(expected, str(refusal.exception))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
