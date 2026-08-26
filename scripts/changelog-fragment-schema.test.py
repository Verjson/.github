#!/usr/bin/env python3
"""Keep the published fragment schema aligned with the canonical engine."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENGINE_PATH = ROOT / "scripts" / "changelog.py"
SCHEMA_PATH = ROOT / "docs" / "changelog" / "fragment.schema.json"

SPEC = importlib.util.spec_from_file_location("canonical_changelog", ENGINE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load changelog engine from {ENGINE_PATH}")
CHANGELOG = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHANGELOG
SPEC.loader.exec_module(CHANGELOG)


class FragmentSchemaContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        cls.properties = cls.schema["properties"]

    def test_schema_accepts_exactly_the_engine_metadata_keys(self) -> None:
        self.assertEqual(set(CHANGELOG.KNOWN_KEYS), set(self.properties))
        self.assertFalse(self.schema["additionalProperties"])

    def test_release_impact_values_match_the_engine(self) -> None:
        self.assertEqual(
            set(CHANGELOG.RELEASE_IMPACTS), set(self.properties["impact"]["enum"])
        )

    def test_only_universal_fields_are_schema_required(self) -> None:
        # `impact` is required only for fragments added relative to a PR base. Keeping
        # that check in validate_new_fragment_impacts preserves pre-contract archives;
        # a context-free JSON Schema must not reject those immutable fragments.
        self.assertEqual({"date", "title"}, set(self.schema["required"]))
        self.assertNotIn("impact", self.schema["required"])

    def test_component_pattern_matches_the_engine(self) -> None:
        self.assertEqual(
            CHANGELOG.COMPONENT_NAME.pattern, self.properties["component"]["pattern"]
        )

    def test_summary_requires_a_nonempty_string(self) -> None:
        self.assertEqual(
            {"type": "string", "minLength": 1}, self.properties["summary"]
        )


if __name__ == "__main__":
    unittest.main()
