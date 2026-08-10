import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
AUDIT = ROOT / "scripts/org-secret-scope-audit.py"


class OrgSecretScopeAuditTest(unittest.TestCase):
    def run_audit(self, policy, listing, selected=None, api_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            (temp / "policy.json").write_text(json.dumps(policy), encoding="utf-8")
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
        self.assertIn("malformed selected grants", result.stderr)

    def test_trusted_workflow_runs_live_audit(self):
        workflow = (ROOT / ".github/workflows/org-secret-scope-audit.yml").read_text(encoding="utf-8")
        canonical_route = "fromJSON(vars.VERJSON_LANE_PRIVILEGED || vars.VERJSON_LANE_FALLBACK || '[\"ubuntu-24.04\"]')"

        def assert_canonical_route(text):
            self.assertEqual(text.count(canonical_route), 1)
            self.assertNotIn("VERJSON_RUNNER_PRIVILEGED", text)

        self.assertIn("schedule:", workflow)
        self.assertIn("GH_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}", workflow)
        self.assertIn("python3 scripts/org-secret-scope-audit.py", workflow)
        self.assertIn("persist-credentials: false", workflow)
        assert_canonical_route(workflow)

        stale_route = workflow.replace(
            canonical_route,
            "fromJSON(vars.VERJSON_RUNNER_PRIVILEGED || vars.VERJSON_RUNNER_DEFAULT)",
        )
        with self.assertRaises(AssertionError):
            assert_canonical_route(stale_route)


if __name__ == "__main__":
    unittest.main()
