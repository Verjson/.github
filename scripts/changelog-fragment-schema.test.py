#!/usr/bin/env python3
"""Keep the published fragment schema aligned with the canonical engine."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import unittest

from jsonschema import Draft202012Validator, FormatChecker, ValidationError


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
        cls.validator = Draft202012Validator(
            cls.schema, format_checker=FormatChecker()
        )

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

    def test_schema_accepts_valid_engine_metadata(self) -> None:
        cases = {
            "impact": {"impact": "minor"},
            "summary": {"summary": "Describe the user-visible change"},
            "correctly escaped double-quoted summary": {
                "summary": '"Describe \\"visible\\" change"'
            },
            "correctly escaped single-quoted summary": {
                "summary": "'Describe ''visible'' change'"
            },
            "component": {"component": "release.node_1"},
            "all optional engine fields": {
                "impact": "major",
                "summary": "Describe the user-visible change",
                "component": "release.node_1",
            },
        }

        for name, mutation in cases.items():
            with self.subTest(name=name):
                self.validator.validate(self._fragment(**mutation))
                CHANGELOG.validate_metadata(
                    Path("NEXT/2026-08-26-issue-1091-schema-test.md"),
                    self._engine_fragment(**mutation),
                )

    def test_schema_rejects_values_the_engine_rejects(self) -> None:
        engine_boundary_cases = {
            "whitespace-only summary": {"summary": " \t\n"},
            "ambiguous double-quoted summary": {"summary": '"a" "b"'},
            "ambiguous single-quoted summary": {"summary": "'a' 'b'"},
            "ambiguous double-quoted title": {"title": '"a" "b"'},
            "ambiguous single-quoted title": {"title": "'a' 'b'"},
            "newline-terminated component": {"component": "release.node\n"},
        }
        schema_cases = {
            **engine_boundary_cases,
            "unknown metadata key": {"audience": "operators"},
        }

        for name, mutation in schema_cases.items():
            with self.subTest(name=name):
                with self.assertRaises(ValidationError):
                    self.validator.validate(self._fragment(**mutation))

        for name, mutation in engine_boundary_cases.items():
            with self.subTest(engine_boundary=name):
                with self.assertRaises(CHANGELOG.ChangelogError):
                    CHANGELOG.validate_metadata(
                        Path("NEXT/2026-08-26-issue-1091-schema-test.md"),
                        self._engine_fragment(**mutation),
                    )

    @staticmethod
    def _fragment(**metadata: object) -> dict[str, object]:
        return {
            "date": "2026-08-26",
            "issue": 1091,
            "title": "Align the published schema",
            **metadata,
        }

    @staticmethod
    def _engine_fragment(**metadata: str) -> dict[str, str]:
        return {
            "date": "2026-08-26",
            "issue": "1091",
            "title": "Align the published schema",
            **metadata,
        }


if __name__ == "__main__":
    unittest.main()
