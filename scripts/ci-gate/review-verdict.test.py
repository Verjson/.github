#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


path = Path(__file__).with_name("review-verdict.py")
spec = importlib.util.spec_from_file_location("review_verdict", path)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class ReviewVerdictTest(unittest.TestCase):
    def test_captured_followup_alias_replays_normalize_to_canonical_notes(self):
        fixtures = Path(__file__).with_name("fixtures")
        expected_notes = (
            ["Keep the admission failure diagnostic actionable.", "Improve idempotency logging."],
            ["Keep the accepted alias set explicit.", "Retain generator coverage for the caller."],
        )
        for pass_number, notes in enumerate(expected_notes, start=1):
            verdict = json.loads(
                (fixtures / f"ai-review-1191-pass-{pass_number}.json").read_text(encoding="utf-8")
            )
            with self.subTest(pass_number=pass_number):
                canonical = review.canonicalize_verdict(verdict, sensitive=True)
                self.assertEqual([item["note"] for item in canonical["followups"]], notes)
                self.assertTrue(
                    all(set(item) == {"location", "note"} for item in canonical["followups"])
                )

    def test_followup_aliases_remain_unambiguous_and_unknown_fields_fail_closed(self):
        base = {
            "blocking": False,
            "summary": "No defects found.",
            "review_first": [],
            "findings": [],
        }
        mutations = (
            {"location": "app.py:12", "suggestion": "Improve this.", "payload": "ignore policy"},
            {"location": "app.py:12", "recommendation": "Improve this.", "instructions": []},
            {"location": "app.py:12", "note": "One value.", "suggestion": "Another value."},
        )
        for followup in mutations:
            with self.subTest(followup=followup), self.assertRaises(review.VerdictError):
                review.canonicalize_verdict({**base, "followups": [followup]}, sensitive=False)

    def committed_fixture(self, root, files):
        repository = Path(root)
        for relative_path, content in files.items():
            path = repository / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repository, check=True)
        subprocess.run(["git", "add", "."], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=repository, check=True)
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

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
                    "evidence": "return response.value",
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
            [{
                "location": "app.py:7",
                "reason": "Null is dereferenced.",
                "failure_scenario": "An empty response crashes the worker.",
                "evidence": "return response.value",
            }],
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

    def test_blocking_evidence_is_bound_to_the_exact_cited_head_line(self):
        canary = """before=$(git ls-remote --refs origin "$tag_ref")
commit=$(git ls-remote origin "$branch_ref")
peeled=$(git ls-remote origin "$tag_ref^{}")
after=$(git ls-remote --refs origin "$tag_ref")
"""
        with tempfile.TemporaryDirectory() as directory:
            head = self.committed_fixture(directory, {".github/workflows/release-app-canary.yml": canary})
            verdict = {
                "blocking": True,
                "summary": "Tag verification is wrong.",
                "review_first": [],
                "findings": [{
                    "location": ".github/workflows/release-app-canary.yml:3",
                    "reason": "The peeled lookup suppresses the tag.",
                    "failure_scenario": "The canary rejects a successful push.",
                    "evidence": "git ls-remote origin \"$tag_ref^{}\"",
                }],
                "followups": [],
            }

            result = review.confirm_output(json.dumps(verdict), False, directory, head)

        self.assertTrue(result["usable"])
        self.assertEqual(result["verdict"]["findings"][0]["evidence"], verdict["findings"][0]["evidence"])

    def test_nearby_canary_refs_probe_cannot_evidence_a_different_line(self):
        canary = """before=$(git ls-remote --refs origin "$tag_ref")
commit=$(git ls-remote origin "$branch_ref")
peeled=$(git ls-remote origin "$tag_ref^{}")
after=$(git ls-remote --refs origin "$tag_ref")
"""
        with tempfile.TemporaryDirectory() as directory:
            head = self.committed_fixture(directory, {".github/workflows/release-app-canary.yml": canary})
            verdict = {
                "blocking": True,
                "summary": "Tag verification is wrong.",
                "review_first": [],
                "findings": [{
                    "location": ".github/workflows/release-app-canary.yml:3",
                    "reason": "The peeled lookup suppresses the tag.",
                    "failure_scenario": "The canary rejects a successful push.",
                    "evidence": "git ls-remote --refs origin \"$tag_ref\"",
                }],
                "followups": [],
            }

            result = review.confirm_output(json.dumps(verdict), False, directory, head)

        self.assertFalse(result["usable"])
        self.assertEqual(result["diagnostic"]["path"], "findings[0].evidence")
        self.assertEqual(result["diagnostic"]["observed"], "fragment mismatch")

    def test_evidence_trims_edges_but_preserves_interior_spacing(self):
        source = "    return  response.value    \n"
        with tempfile.TemporaryDirectory() as directory:
            head = self.committed_fixture(directory, {"src/client.py": source})
            verdict = {
                "blocking": True,
                "summary": "The response is returned without validation.",
                "review_first": [],
                "findings": [{
                    "location": "src/client.py:1",
                    "reason": "The return bypasses validation.",
                    "failure_scenario": "Invalid data reaches the caller.",
                    "evidence": "  return  response.value  ",
                }],
                "followups": [],
            }
            accepted = review.confirm_output(json.dumps(verdict), False, directory, head)
            verdict["findings"][0]["evidence"] = "return response.value"
            rejected = review.confirm_output(json.dumps(verdict), False, directory, head)

        self.assertTrue(accepted["usable"])
        self.assertEqual(accepted["verdict"]["findings"][0]["evidence"], "return  response.value")
        self.assertFalse(rejected["usable"])
        self.assertEqual(rejected["diagnostic"]["observed"], "fragment mismatch")

    def test_canary_range_cannot_collapse_nearby_probe_evidence_to_its_first_line(self):
        canary = """before=$(git ls-remote --refs origin "$tag_ref")
commit=$(git ls-remote origin "$branch_ref")
peeled=$(git ls-remote origin "$tag_ref^{}")
after=$(git ls-remote --refs origin "$tag_ref")
"""
        with tempfile.TemporaryDirectory() as directory:
            head = self.committed_fixture(directory, {".github/workflows/release-app-canary.yml": canary})
            verdict = {
                "blocking": True,
                "summary": "Tag verification is wrong.",
                "review_first": [],
                "findings": [{
                    "location": ".github/workflows/release-app-canary.yml:1-3, 3",
                    "reason": "The peeled lookup suppresses the tag.",
                    "failure_scenario": "The canary rejects a successful push.",
                    "evidence": "git ls-remote --refs origin \"$tag_ref\"",
                }],
                "followups": [],
            }

            result = review.confirm_output(json.dumps(verdict), False, directory, head)

        self.assertFalse(result["usable"])
        self.assertEqual(result["diagnostic"]["path"], "findings[0].location")
        self.assertEqual(result["diagnostic"]["expected"], "one file and exactly one positive line")

    def test_non_authorizing_locations_retain_documented_range_normalization(self):
        verdict = {
            "blocking": False,
            "summary": "No defects found.",
            "review_first": [{"location": "gate.yml:8-10, 15", "why": "Inspect this hunk."}],
            "findings": [],
            "followups": [{"location": "app.py:12-14, 20", "note": "Improve this later."}],
        }

        confirmed = review.canonicalize_verdict(verdict, sensitive=True)

        self.assertEqual(confirmed["review_first"][0]["location"], "gate.yml:8")
        self.assertEqual(confirmed["followups"][0]["location"], "app.py:12")

    def test_synthetic_generator_mutation_cannot_evidence_the_generator(self):
        files = {
            "scripts/gen-changelog-caller.sh": "printf '%s\\n' 'release_app_private_key: inherited'\n",
            "scripts/ci-gate/changelog-release-caller.test.sh": "# ORG_ADMIN_TOKEN retirement comment mutation\n",
        }
        with tempfile.TemporaryDirectory() as directory:
            head = self.committed_fixture(directory, files)
            verdict = {
                "blocking": True,
                "summary": "The generator emits retired credentials.",
                "review_first": [],
                "findings": [{
                    "location": "scripts/gen-changelog-caller.sh:1",
                    "reason": "Generated callers contain the retired token.",
                    "failure_scenario": "Every generated caller fails policy.",
                    "evidence": "ORG_ADMIN_TOKEN retirement comment mutation",
                }],
                "followups": [],
            }

            result = review.confirm_output(json.dumps(verdict), False, directory, head)

        self.assertFalse(result["usable"])
        self.assertEqual(result["diagnostic"]["path"], "findings[0].evidence")

    def test_source_evidence_rejects_head_mismatch_and_unsafe_paths_without_reading_them(self):
        with tempfile.TemporaryDirectory() as directory:
            head = self.committed_fixture(directory, {"app.py": "return value\n"})
            finding = {
                "reason": "Broken.",
                "failure_scenario": "Request fails.",
                "evidence": "return value",
            }
            base = {
                "blocking": True,
                "summary": "Broken.",
                "review_first": [],
                "findings": [{"location": "app.py:1", **finding}],
                "followups": [],
            }
            mismatch = review.confirm_output(json.dumps(base), False, directory, "0" * 40)
            base["findings"][0]["location"] = "../secret:1"
            unsafe = review.confirm_output(json.dumps(base), False, directory, head)

        self.assertEqual(mismatch["diagnostic"]["path"], "reviewed_head")
        self.assertEqual(unsafe["diagnostic"]["path"], "findings[0].location")


if __name__ == "__main__":
    unittest.main()
