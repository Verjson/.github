#!/usr/bin/env python3
"""The captured private-consumer claim set passes the verifier predicates and every
tampered variant fails on the predicate that names its tampering (#1339, ADR 0211)."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "config/merge-gate-provenance-fixtures.json"
SCRIPT = ROOT / "scripts/merge-gate-provenance-claims.py"
SPEC = importlib.util.spec_from_file_location("provenance_claims", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

EXPECTED_VIOLATION = {
    "consumer_authored_workflow": "job_workflow_ref does not name the canonical required workflow on main",
    "reusable_call_from_consumer": "workflow_ref differs from job_workflow_ref: not an injected required workflow",
    "stale_canonical_sha": "job_workflow_sha is not the ruleset's stored canonical commit",
    "branch_only_ref_without_sha": "job_workflow_sha is not the ruleset's stored canonical commit",
    "foreign_owner_same_name": "repository_owner_id is not the Verjson organization",
    "foreign_issuer": "iss is not the GitHub Actions token issuer",
    "push_event": "event_name is neither pull_request nor pull_request_target",
    "pull_request_target_sub_names_another_ref": "ref is not the pull request base branch",
    "reusable_call_pinned_to_canonical_sha": "job_workflow_ref does not name the canonical required workflow on main",
    "repository_outside_owner": "repository is not owned by repository_owner",
    "unreviewed_runner_environment": "runner_environment is not a reviewed lane",
    "canonical_path_swapped": "job_workflow_ref does not name the canonical required workflow on main",
}


class ProvenanceClaimsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = json.loads(FIXTURES.read_text(encoding="utf-8"))
        cls.expected = cls.fixtures["expected"]
        cls.genuine = cls.fixtures["genuine"]

    def check(self, claims):
        return MODULE.violations(claims, self.expected["canonical_workflow_path"], self.expected["canonical_workflow_sha"])

    def test_fixture_is_the_recorded_capture_not_a_hand_written_shape(self):
        source = self.fixtures["source"]
        self.assertEqual(source["run_id"], int(self.genuine["run_id"]))
        self.assertEqual(source["probe_workflow_commit"], self.genuine["job_workflow_sha"])
        self.assertIn("required_workflows/", source["required_workflow_url"])
        self.assertEqual(self.genuine["repository_visibility"], "private")
        for secret_bearing in ("jti", "exp", "iat", "nbf", "token"):
            self.assertNotIn(secret_bearing, self.genuine)

    def test_genuine_private_consumer_capture_passes_every_predicate(self):
        self.assertEqual([], self.check(self.genuine))

    def test_token_sha_is_the_merge_commit_not_the_pull_request_head(self):
        source = self.fixtures["source"]
        self.assertEqual(self.genuine["sha"], source["merge_commit_sha"])
        self.assertNotEqual(self.genuine["sha"], source["head_sha"])

    def test_pull_request_target_shape_of_the_live_gate_passes_and_is_labelled_provisional(self):
        shape = dict(self.fixtures["genuine_pull_request_target_shape"])
        self.assertIn("NOT a capture", shape.pop("derived_from"))
        self.assertEqual([], self.check(shape))
        self.assertNotEqual([], self.check({**shape, "sub": f"repo:{shape['repository']}:pull_request"}))
        self.assertNotEqual([], self.check({**shape, "ref": "refs/pull/13/merge"}))

    def test_every_tampered_variant_is_enumerated_and_fails_on_its_own_predicate(self):
        tampered = self.fixtures["tampered"]
        self.assertEqual(set(tampered), set(EXPECTED_VIOLATION), "fixture and expectation tables drifted")
        for name, overrides in tampered.items():
            with self.subTest(variant=name):
                claims = {**self.genuine, **overrides}
                self.assertNotEqual(claims, self.genuine, "tampering changed nothing; the case is vacuous")
                found = self.check(claims)
                self.assertIn(EXPECTED_VIOLATION[name], found)

    def test_a_branch_ref_alone_never_binds_the_canonical_commit(self):
        claims = {**self.genuine, "job_workflow_sha": "0" * 40, "workflow_sha": "0" * 40}
        found = self.check(claims)
        self.assertIn("job_workflow_sha is not the ruleset's stored canonical commit", found)
        self.assertNotIn("job_workflow_ref does not name the canonical required workflow on main", found)

    def test_missing_wrong_type_and_empty_claims_are_violations_not_defaults(self):
        for name in ("iss", "job_workflow_ref", "job_workflow_sha", "workflow_ref", "sub", "ref", "event_name", "repository", "repository_owner", "runner_environment"):
            for value in (None, "", 7, ["x"]):
                with self.subTest(claim=name, value=value):
                    claims = {**self.genuine}
                    if value is None:
                        del claims[name]
                    else:
                        claims[name] = value
                    self.assertNotEqual([], self.check(claims))
        self.assertNotEqual([], MODULE.violations("not an object", ".github/workflows/x.yml", "a" * 40))

    def test_verifier_inputs_are_validated_before_any_claim_is_read(self):
        self.assertEqual(["canonical sha must be a 40-hex commit"], MODULE.violations(self.genuine, ".github/workflows/x.yml", "main"))
        for path in ("scripts/x.yml", ".github/workflows/../../evil.yml", ".github/workflows/sub/x.yml", ".github/workflows/x.yaml"):
            with self.subTest(path=path):
                self.assertEqual(
                    ["canonical path must be a workflow file directly under .github/workflows/"],
                    MODULE.violations(self.genuine, path, "a" * 40),
                )

    def test_cli_exit_status_reports_the_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "claims.json"
            path.write_text(json.dumps(self.genuine), encoding="utf-8")
            args = [sys.executable, str(SCRIPT), "verify", "--claims", str(path),
                    "--canonical-path", self.expected["canonical_workflow_path"],
                    "--canonical-sha", self.expected["canonical_workflow_sha"]]
            self.assertEqual(0, subprocess.run(args, capture_output=True, text=True).returncode)
            path.write_text(json.dumps({**self.genuine, **self.fixtures["tampered"]["stale_canonical_sha"]}), encoding="utf-8")
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(1, result.returncode)
            self.assertIn("stored canonical commit", result.stderr)
            path.write_text("{", encoding="utf-8")
            self.assertEqual(2, subprocess.run(args, capture_output=True, text=True).returncode)


if __name__ == "__main__":
    unittest.main()
