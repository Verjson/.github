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


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
