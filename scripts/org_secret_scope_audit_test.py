import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
AUDIT = ROOT / "scripts/org-secret-scope-audit.py"


class OrgSecretScopeAuditTest(unittest.TestCase):
    def run_audit(self, policy, listing, selected=None, api_failure=False, raw_policy=None):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            (temp / "policy.json").write_text(
                raw_policy if raw_policy is not None else json.dumps(policy), encoding="utf-8"
            )
            gh = temp / "gh"
            gh.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "if os.environ.get('API_FAILURE') == '1': sys.exit(1)\n"
                "path = sys.argv[-1]\n"
                "if path.endswith('/repositories'): print(os.environ['SELECTED'])\n"
                "else: print(os.environ['LISTING'])\n",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            env = os.environ | {
                "PATH": f"{temp}:{os.environ['PATH']}",
                "ORG_SECRET_POLICY": str(temp / "policy.json"),
                "LISTING": json.dumps(listing if isinstance(listing, list) else [listing]),
                "SELECTED": json.dumps(selected if isinstance(selected, list) else [selected or {"repositories": []}]),
                "API_FAILURE": "1" if api_failure else "0",
            }
            return subprocess.run(["python3", str(AUDIT)], env=env, capture_output=True, text=True)

    def test_exact_all_and_selected_policy_conforms(self):
        policy = {"organization": "Verjson", "secrets": {
            "FLEET": {"target_visibility": "all", "selected_repositories": [], "consumers": ["fleet"], "reason": "required"},
            "SCOPED": {"target_visibility": "selected", "selected_repositories": ["Verjson/.github"], "consumers": ["policy"], "reason": "only consumer"},
        }}
        listing = {"secrets": [{"name": "FLEET", "visibility": "all"}, {"name": "SCOPED", "visibility": "selected"}]}
        result = self.run_audit(policy, listing, {"repositories": [{"full_name": "Verjson/.github"}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("secrets=2", result.stdout)

    def test_unmanifested_secret_fails_closed(self):
        policy = {"organization": "Verjson", "secrets": {}}
        result = self.run_audit(policy, {"secrets": [{"name": "NEW_SECRET", "visibility": "all"}]})
        self.assertEqual(result.returncode, 1)
        self.assertIn("unmanifested=['NEW_SECRET']", result.stderr)

    def test_visibility_or_selected_grant_drift_fails(self):
        policy = {"organization": "Verjson", "secrets": {
            "SCOPED": {"target_visibility": "selected", "selected_repositories": ["Verjson/.github"], "consumers": ["policy"], "reason": "only consumer"},
        }}
        listing = {"secrets": [{"name": "SCOPED", "visibility": "selected"}]}
        result = self.run_audit(policy, listing, {"repositories": [{"full_name": "Verjson/other"}]})
        self.assertEqual(result.returncode, 1)
        self.assertIn("selected grants differ", result.stderr)

    def test_api_failure_cannot_report_conformance(self):
        result = self.run_audit({"organization": "Verjson", "secrets": {}}, {}, api_failure=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot establish secret policy state", result.stderr)

    def test_paginated_selected_grants_are_combined(self):
        policy = {"organization": "Verjson", "secrets": {
            "SCOPED": {"target_visibility": "selected", "selected_repositories": ["Verjson/a", "Verjson/b"], "consumers": ["two repos"], "reason": "exact"},
        }}
        listing = [{"secrets": [{"name": "SCOPED", "visibility": "selected"}]}]
        selected = [{"repositories": [{"full_name": "Verjson/b"}]}, {"repositories": [{"full_name": "Verjson/a"}]}]
        result = self.run_audit(policy, listing, selected)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_policy_and_selected_response_fail_with_diagnostics(self):
        malformed_policy = {"organization": "Verjson", "secrets": {
            "BAD": {"target_visibility": "selected", "selected_repositories": 42, "consumers": "not-a-list", "reason": 7},
        }}
        listing = {"secrets": [{"name": "BAD", "visibility": "selected"}]}
        result = self.run_audit(malformed_policy, listing)
        self.assertEqual(result.returncode, 1)
        self.assertIn("incomplete policy justification", result.stderr)

        valid_policy = {"organization": "Verjson", "secrets": {
            "BAD": {"target_visibility": "selected", "selected_repositories": ["Verjson/.github"], "consumers": ["policy"], "reason": "exact"},
        }}
        result = self.run_audit(valid_policy, listing, [{"wrong": []}])
        self.assertEqual(result.returncode, 1)
        self.assertIn("selected grants page 0 for BAD.repositories must be an array", result.stderr)

    def test_invalid_boundary_shapes_fail_without_tracebacks(self):
        cases = [
            ([], {"secrets": []}, "secret policy must be an object"),
            ({"organization": "Verjson", "secrets": []}, {"secrets": []}, "secret policy.secrets must be an object"),
            ({"organization": "Verjson", "secrets": {}}, "BAD", "secret listing page 0 must be an object"),
            ({"organization": "Verjson", "secrets": {}}, {"secrets": {}}, "secret listing page 0.secrets must be an array"),
            ({"organization": "Verjson", "secrets": {}}, {"secrets": ["BAD"]}, "secret listing entry 0 on page 0 must be an object"),
        ]
        for policy, listing, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic):
                result = self.run_audit(policy, listing)
                self.assertEqual(result.returncode, 2)
                self.assertIn(diagnostic, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_duplicate_live_secrets_and_selected_repositories_fail_closed(self):
        policy = {"organization": "Verjson", "secrets": {"SCOPED": {
            "target_visibility": "selected", "selected_repositories": ["Verjson/.github"],
            "consumers": ["policy"], "reason": "exact",
        }}}
        duplicate_secrets = {"secrets": [
            {"name": "SCOPED", "visibility": "selected"},
            {"name": "SCOPED", "visibility": "selected"},
        ]}
        result = self.run_audit(policy, duplicate_secrets)
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate secret 'SCOPED'", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

        result = self.run_audit(
            {}, {}, raw_policy='{"organization":"Verjson","secrets":{"S":{},"S":{}}}'
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate object key 'S'", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

        listing = {"secrets": [{"name": "SCOPED", "visibility": "selected"}]}
        selected = {"repositories": [
            {"full_name": "Verjson/.github"}, {"full_name": "Verjson/.github"},
        ]}
        duplicate_policy_repositories = {"organization": "Verjson", "secrets": {"SCOPED": {
            "target_visibility": "selected",
            "selected_repositories": ["Verjson/.github", "Verjson/.github"],
            "consumers": ["policy"], "reason": "exact",
        }}}
        result = self.run_audit(duplicate_policy_repositories, listing, selected)
        self.assertEqual(result.returncode, 1)
        self.assertIn("policy contains duplicate repositories", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

        result = self.run_audit(policy, listing, selected)
        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate repositories", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

if __name__ == "__main__":
    unittest.main()
