#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


path = Path(__file__).with_name("review-verdict.py")
spec = importlib.util.spec_from_file_location("review_verdict", path)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class ReviewVerdictTest(unittest.TestCase):
    def test_canonical_verdict_is_confirmed_without_changes(self):
        verdict = {
            "blocking": False,
            "summary": "No defects found.",
            "review_first": [
                {"location": "scripts/ci-gate/review-verdict.py:42", "why": "Canonical trust boundary."},
            ],
            "findings": [],
            "followups": [],
        }

        confirmed = review.canonicalize_verdict(verdict, sensitive=True)

        self.assertEqual(confirmed, verdict)

    def test_structured_provider_variant_is_normalized_before_confirmation(self):
        verdict = {
            "blocking": False,
            "summary": "No defects found.",
            "review_first": [
                {
                    "file": "scripts/ci-gate/review-verdict.py",
                    "line": "42-48,55",
                    "reason": "Canonical trust boundary.",
                    "confidence": 0.98,
                },
            ],
            "findings": [],
            "followups": [],
        }

        confirmed = review.canonicalize_verdict(verdict, sensitive=True)

        self.assertEqual(
            confirmed["review_first"],
            [{"location": "scripts/ci-gate/review-verdict.py:42", "why": "Canonical trust boundary."}],
        )

    def test_invalid_item_reports_the_exact_path_and_observed_shape(self):
        verdict = {
            "blocking": False,
            "summary": "No defects found.",
            "review_first": [{"location": "app.py:7", "note": "Wrong field."}],
            "findings": [],
            "followups": [],
        }

        with self.assertRaises(review.VerdictError) as raised:
            review.canonicalize_verdict(verdict, sensitive=True)

        self.assertEqual(raised.exception.path, "review_first[0].why")
        self.assertEqual(raised.exception.expected, "non-empty text in why, reason, or rationale")
        self.assertEqual(raised.exception.observed, "object with 2 fields")

    def test_known_structured_variants_project_to_one_strict_canonical_verdict(self):
        verdict = {
            "blocking": True,
            "summary": "One defect found.",
            "review_first": [{"path": "app.py", "line_number": 7, "rationale": "Load-bearing parser."}],
            "findings": [
                {
                    "file": "app.py",
                    "line": 7,
                    "why": "Null is dereferenced.",
                    "impact": "An empty response crashes the worker.",
                    "severity": "high",
                },
            ],
            "followups": [{"location": "app.py:12", "reason": "Simplify the retry path.", "priority": "low"}],
            "confidence": 0.94,
        }

        confirmed = review.canonicalize_verdict(verdict, sensitive=True)

        self.assertEqual(set(confirmed), review.REQUIRED_FIELDS)
        self.assertEqual(
            confirmed["findings"],
            [{"location": "app.py:7", "reason": "Null is dereferenced.", "failure_scenario": "An empty response crashes the worker."}],
        )
        self.assertEqual(confirmed["followups"], [{"location": "app.py:12", "note": "Simplify the retry path."}])

    def test_provider_output_is_locally_confirmed_without_another_model_call(self):
        raw = """```json
{"blocking":false,"summary":"Safe.","review_first":[{"file":"gate.yml","line":"8-10","reason":"Merge boundary."}],"findings":[],"followups":[]}
```"""

        result = review.confirm_output(raw, sensitive=True)

        self.assertTrue(result["usable"])
        self.assertTrue(result["normalized"])
        self.assertEqual(result["verdict"]["review_first"][0]["location"], "gate.yml:8")
        self.assertNotIn("raw", result)

    def test_common_top_level_naming_variants_are_provider_neutral(self):
        verdict = {
            "isBlocking": False,
            "summary": "Safe.",
            "reviewFirst": [{"location": "gate.yml:8", "why": "Merge boundary."}],
            "findings": [],
            "followUps": [],
        }

        confirmed = review.canonicalize_verdict(verdict, sensitive=True)

        self.assertEqual(
            confirmed,
            {
                "blocking": False,
                "summary": "Safe.",
                "review_first": [{"location": "gate.yml:8", "why": "Merge boundary."}],
                "findings": [],
                "followups": [],
            },
        )

    def test_workflow_cli_confirms_or_reports_the_exact_invalid_path(self):
        cases = (
            (
                {"blocking": False, "summary": "Safe.", "review_first": [], "findings": [], "followups": []},
                "false",
                "usable=true",
            ),
            (
                {
                    "blocking": False,
                    "summary": "Safe.",
                    "review_first": [{"location": "gate.yml:8", "note": "Wrong field."}],
                    "findings": [],
                    "followups": [],
                },
                "true",
                'diagnostic={"path":"review_first[0].why"',
            ),
        )
        with tempfile.TemporaryDirectory() as directory:
            for index, (verdict, sensitive, marker) in enumerate(cases):
                output = Path(directory, str(index))
                env = {
                    "VERDICT": json.dumps(verdict),
                    "SENSITIVE": sensitive,
                    "GITHUB_OUTPUT": str(output),
                    "REVIEW_PASS": str(index + 1),
                }
                with self.subTest(index=index), patch.dict(os.environ, env, clear=True):
                    self.assertEqual(review.main(), 0)
                    self.assertIn(marker, output.read_text(encoding="utf-8"))

    def test_ambiguous_or_unsafe_outputs_fail_closed_without_echoing_raw_content(self):
        cases = (
            (
                {"blocking": False, "summary": "Safe.", "review_first": ["app.py:7"], "findings": [], "followups": []},
                True,
                "review_first[0]",
            ),
            (
                {"blocking": True, "summary": "Safe.", "review_first": [], "findings": [], "followups": []},
                False,
                "blocking",
            ),
            (
                {"blocking": False, "summary": "Safe.", "review_first": [], "findings": [], "followups": []},
                True,
                "review_first",
            ),
            (
                {
                    "blocking": False,
                    "isBlocking": True,
                    "summary": "Safe.",
                    "review_first": [],
                    "findings": [],
                    "followups": [],
                },
                False,
                "blocking",
            ),
        )
        for verdict, sensitive, path in cases:
            raw = json.dumps(verdict)
            with self.subTest(path=path):
                result = review.confirm_output(raw, sensitive)
                self.assertFalse(result["usable"])
                self.assertEqual(result["diagnostic"]["path"], path)
                self.assertNotIn(raw, json.dumps(result))

    def test_nested_aliases_must_resolve_to_one_value(self):
        cases = (
            (
                {
                    "blocking": False,
                    "summary": "Safe.",
                    "review_first": [{"file": "gate.yml", "path": "other.yml", "line": 8, "why": "Boundary."}],
                    "findings": [],
                    "followups": [],
                },
                "review_first[0].location",
            ),
            (
                {
                    "blocking": False,
                    "summary": "Safe.",
                    "review_first": [{"location": "gate.yml:8", "why": "Boundary.", "reason": "Different."}],
                    "findings": [],
                    "followups": [],
                },
                "review_first[0].why",
            ),
        )
        for verdict, path in cases:
            with self.subTest(path=path), self.assertRaises(review.VerdictError) as raised:
                review.canonicalize_verdict(verdict, sensitive=True)
            self.assertEqual(raised.exception.path, path)
            self.assertEqual(raised.exception.observed, "conflicting aliases")

    def test_location_normalization_repairs_only_documented_line_lists(self):
        valid = {"file": "gate.yml", "line": "8-10, 15,20-22"}
        invalid = {"location": "gate.yml:8,not-a-line"}

        self.assertEqual(review.normalize_location(valid, "location"), "gate.yml:8")
        with self.assertRaises(review.VerdictError):
            review.normalize_location(invalid, "location")

    def test_unknown_fields_cannot_hide_semantic_content_or_leak_into_diagnostics(self):
        secret_key = "issues-SHOULD-NOT-APPEAR"
        verdict = {
            "blocking": False,
            "summary": "Safe.",
            "review_first": [],
            "findings": [],
            "followups": [],
            secret_key: [{"reason": "hidden defect"}],
        }

        result = review.confirm_output(json.dumps(verdict), sensitive=False)

        self.assertFalse(result["usable"])
        self.assertEqual(result["diagnostic"]["path"], "$")
        self.assertNotIn(secret_key, json.dumps(result))


if __name__ == "__main__":
    unittest.main()
