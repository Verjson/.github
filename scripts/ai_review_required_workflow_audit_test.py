import base64
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
AUDIT_PATH = ROOT / "scripts/ai-review-required-workflow-audit.py"
SPEC = importlib.util.spec_from_file_location("ai_review_required_workflow_audit", AUDIT_PATH)
AUDIT = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(AUDIT)


class AiReviewRequiredWorkflowAuditTest(unittest.TestCase):
    def setUp(self):
        self.contract = AUDIT.read_contract()
        self.ruleset_id = self.contract["ruleset"]["id"]
        self.ruleset_path = f"orgs/Verjson/rulesets/{self.ruleset_id}"
        self.workflow = """\
name: AI review authorization arm
on:
  pull_request_target:
  workflow_call:
jobs:
  arm:
    continue-on-error: true
    runs-on: ubuntu-24.04
    steps: []
"""
        self.fixture = self.make_fixture()

    def make_fixture(self):
        ruleset = {
            "id": self.ruleset_id,
            "name": "main-protection",
            "enforcement": "active",
            "target": "branch",
            "conditions": copy.deepcopy(self.contract["ruleset"]["conditions"]),
            "rules": [{
                "type": "workflows",
                "parameters": {"do_not_enforce_on_create": True, "workflows": [{
                    "path": ".github/workflows/ai-review-merge.yml",
                    "ref": "refs/heads/main",
                    "repository_id": 1269388380,
                }]},
            }],
        }
        fixture = {
            self.ruleset_path: [ruleset],
            "orgs/Verjson/rulesets": [[{"id": self.ruleset_id}]],
            "orgs/Verjson/repos?per_page=100&type=all": [[
                {"full_name": "Verjson/alpha", "private": False},
                {"full_name": "Verjson/beta", "private": True},
            ]],
            "orgs/Verjson/actions/secrets/AI_REVIEW_APP_PRIVATE_KEY": [{"visibility": "all"}],
            "orgs/Verjson/actions/variables/AI_REVIEW_APP_ID": [{"visibility": "all", "value": "4528902"}],
            "orgs/Verjson/actions/variables/AI_REVIEW_APP_SLUG": [{"visibility": "all", "value": "verjson-ai-review-authorization"}],
            "orgs/Verjson/actions/variables/AI_REVIEW_CLIENT_ID": [{"visibility": "all", "value": "Iv23liObnM1yEH8j9pJu"}],
            "orgs/Verjson/installations": [{"installations": [{
                "app_id": 4528902,
                "app_slug": "verjson-ai-review-authorization",
                "repository_selection": "all",
                "suspended_at": None,
                "permissions": {
                    "checks": "write",
                    "contents": "read",
                    "pull_requests": "write",
                },
            }]}],
            "repos/Verjson/.github/contents/.github/workflows/gate-rearm.yml?ref=main": [{
                "content": base64.b64encode(self.workflow.encode()).decode(),
            }],
        }
        return fixture

    def read(self, path):
        if path not in self.fixture:
            raise AssertionError(f"unexpected API read: {path}")
        return copy.deepcopy(self.fixture[path])

    def select_scope(self, kind, name, repositories):
        self.fixture[f"orgs/Verjson/actions/{kind}/{name}"][0]["visibility"] = "selected"
        self.fixture[f"orgs/Verjson/actions/{kind}/{name}/repositories"] = [{
            "repositories": [{"full_name": repository} for repository in repositories],
        }]

    def assert_audit_error(self, text):
        with self.assertRaisesRegex(AUDIT.AuditError, text):
            AUDIT.audit(self.contract, self.read)

    def test_full_fleet_coverage_is_ready_for_one_for_one_retarget(self):
        report = AUDIT.audit(self.contract, self.read)
        self.assertEqual(report["state"], "ready")
        self.assertEqual(report["governed_repositories"], 2)
        self.assertEqual(report["current_path"], ".github/workflows/ai-review-merge.yml")

    def test_checked_in_contract_pins_the_sensitive_boundary(self):
        self.assertEqual(self.contract["organization"], "Verjson")
        self.assertEqual(self.contract["ruleset"], {
            "id": 18098028,
            "name": "main-protection",
            "target": "branch",
            "conditions": {
                "ref_name": {"exclude": [], "include": ["~DEFAULT_BRANCH", "refs/heads/develop"]},
                "repository_name": {"exclude": [], "include": ["~ALL"]},
            },
            "source_repository": "Verjson/.github",
            "source_repository_id": 1269388380,
            "ref": "refs/heads/main",
            "retired_path": ".github/workflows/ai-review-merge.yml",
            "replacement_path": ".github/workflows/gate-rearm.yml",
            "forbidden_required_status_contexts": ["gate", "AI review authorization"],
        })
        self.assertEqual(self.contract["authorization"], {
            "private_key_secret": "AI_REVIEW_APP_PRIVATE_KEY",
            "variables": ["AI_REVIEW_APP_ID", "AI_REVIEW_APP_SLUG", "AI_REVIEW_CLIENT_ID"],
            "app_permissions": {"checks": "write", "contents": "read", "pull_requests": "write"},
        })

    def test_exact_selected_coverage_is_accepted(self):
        names = ["Verjson/alpha", "Verjson/beta"]
        self.select_scope("secrets", "AI_REVIEW_APP_PRIVATE_KEY", names)
        for name in self.contract["authorization"]["variables"]:
            self.select_scope("variables", name, names)
        self.assertEqual(AUDIT.audit(self.contract, self.read)["state"], "ready")

    def test_missing_secret_or_variable_scope_fails_before_retarget(self):
        self.select_scope("secrets", "AI_REVIEW_APP_PRIVATE_KEY", ["Verjson/alpha"])
        self.assert_audit_error("AI_REVIEW_APP_PRIVATE_KEY cannot reach 1 governed.*Verjson/beta")

        self.fixture = self.make_fixture()
        self.select_scope("variables", "AI_REVIEW_CLIENT_ID", ["Verjson/beta"])
        self.assert_audit_error("AI_REVIEW_CLIENT_ID cannot reach 1 governed.*Verjson/alpha")

    def test_retired_and_replacement_rules_cannot_coexist(self):
        second = copy.deepcopy(self.fixture[self.ruleset_path][0])
        second["id"] = 99
        second["name"] = "duplicate-arm"
        second["rules"][0]["parameters"]["workflows"][0]["path"] = ".github/workflows/gate-rearm.yml"
        self.fixture["orgs/Verjson/rulesets"][0].append({"id": 99})
        self.fixture["orgs/Verjson/rulesets/99"] = [second]
        self.assert_audit_error("identities are not exclusive")

    def test_app_check_cannot_be_required_alongside_the_arm(self):
        second = {
            "id": 99,
            "rules": [{
                "type": "required_status_checks",
                "parameters": {"required_status_checks": [{"context": "AI review authorization"}]},
            }],
        }
        self.fixture["orgs/Verjson/rulesets"][0].append({"id": 99})
        self.fixture["orgs/Verjson/rulesets/99"] = [second]
        self.assert_audit_error("status is also required")

    def test_replacement_must_be_ruleset_compatible_and_human_nonblocking(self):
        path = "repos/Verjson/.github/contents/.github/workflows/gate-rearm.yml?ref=main"
        self.fixture[path][0]["content"] = base64.b64encode(
            self.workflow.replace("pull_request_target", "workflow_dispatch").encode()
        ).decode()
        self.assert_audit_error("lacks a ruleset-supported")

        self.fixture = self.make_fixture()
        self.fixture[path][0]["content"] = base64.b64encode(
            self.workflow.replace("    continue-on-error: true\n", "").encode()
        ).decode()
        self.assert_audit_error("can veto the ADR 0090 human merge path")

    def test_app_installation_must_cover_all_current_and_future_repositories(self):
        self.fixture["orgs/Verjson/installations"][0]["installations"][0]["repository_selection"] = "selected"
        self.assert_audit_error("does not cover future ~ALL repositories")

        self.fixture = self.make_fixture()
        self.fixture["orgs/Verjson/installations"][0]["installations"][0]["permissions"]["checks"] = "read"
        self.assert_audit_error("permissions drifted")

    def test_post_retarget_state_remains_auditable(self):
        self.fixture[self.ruleset_path][0]["rules"][0]["parameters"]["workflows"][0]["path"] = (
            ".github/workflows/gate-rearm.yml"
        )
        report = AUDIT.audit(self.contract, self.read)
        self.assertEqual(report["state"], "retargeted")

    def test_audit_has_no_live_mutation_path(self):
        source = AUDIT_PATH.read_text(encoding="utf-8")
        self.assertNotIn('"--method"', source)
        self.assertNotIn("rulesets/PUT", source)
        self.assertNotIn("rulesets/PATCH", source)

    def test_malformed_contract_fails_with_a_controlled_diagnostic(self):
        for mutation, diagnostic in (
            (("ruleset", "ref", 42), "ruleset ref must be a string"),
            (("authorization", "variables", [{}]), "authorization variables"),
        ):
            with self.subTest(diagnostic=diagnostic), tempfile.TemporaryDirectory() as directory:
                contract = copy.deepcopy(self.contract)
                section, key, value = mutation
                contract[section][key] = value
                path = Path(directory) / "contract.json"
                path.write_text(json.dumps(contract), encoding="utf-8")
                with self.assertRaisesRegex(AUDIT.AuditError, diagnostic):
                    AUDIT.read_contract(path)


if __name__ == "__main__":
    unittest.main()
