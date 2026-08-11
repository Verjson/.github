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
        self.ruleset_path = f"orgs/Verjson/rulesets/{self.contract['ruleset_id']}"
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
        repositories = [
            {"full_name": "Verjson/alpha", "private": False, "default_branch": "main"},
            {"full_name": "Verjson/beta", "private": True, "default_branch": "develop/next"},
        ]
        live_preimage = {"id": self.contract["ruleset_id"], **copy.deepcopy(self.contract["preimage"])}
        node_declaration = next(
            declaration for declaration in self.contract["deterministic_rulesets"]
            if declaration["stack"] == "node"
        )
        actions_declaration = next(
            declaration for declaration in self.contract["deterministic_rulesets"]
            if declaration["stack"] == "actions"
        )
        live_node_ruleset = {"id": node_declaration["id"], **copy.deepcopy(node_declaration["image"])}
        live_actions_ruleset = {
            "id": actions_declaration["id"], **copy.deepcopy(actions_declaration["image"]),
        }
        fixture = {
            self.ruleset_path: [live_preimage],
            "orgs/Verjson/rulesets": [[
                {"id": self.contract["ruleset_id"]},
                {"id": node_declaration["id"]},
                {"id": actions_declaration["id"]},
            ]],
            f"orgs/Verjson/rulesets/{node_declaration['id']}": [live_node_ruleset],
            f"orgs/Verjson/rulesets/{actions_declaration['id']}": [live_actions_ruleset],
            "orgs/Verjson/repos?per_page=100&type=all": [repositories],
            "orgs/Verjson/properties/values?per_page=100": [[
                {
                    "repository_full_name": repository["full_name"],
                    "properties": [
                        {"property_name": "verjson-stack", "value": "node"},
                        {"property_name": "verjson-core-checks", "value": "enforced"},
                    ],
                }
                for repository in repositories
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
                "events": [],
                "permissions": copy.deepcopy(self.contract["authorization"]["app_permissions"]),
            }]}],
            "repositories/1269388380/contents/.github/workflows/gate-rearm.yml?ref=refs/heads/main": [{
                "content": base64.b64encode(self.workflow.encode()).decode(),
            }],
        }
        for repository in repositories:
            full_name = repository["full_name"]
            fixture[f"repos/{full_name}/actions/secrets?per_page=100"] = [{"secrets": []}]
            fixture[f"repos/{full_name}/actions/variables?per_page=100"] = [{"variables": []}]
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

    def workflow_source(self, text):
        path = "repositories/1269388380/contents/.github/workflows/gate-rearm.yml?ref=refs/heads/main"
        self.fixture[path][0]["content"] = base64.b64encode(text.encode()).decode()

    def test_contract_pins_complete_preimage_postimage_and_rollback(self):
        self.assertEqual(self.contract["rollback_payload"], self.contract["preimage"])
        self.assertEqual(
            [rule["type"] for rule in self.contract["preimage"]["rules"]],
            ["deletion", "non_fast_forward", "required_linear_history", "pull_request", "workflows"],
        )
        self.assertEqual(self.contract["preimage"]["bypass_actors"], [
            {"actor_id": None, "actor_type": "OrganizationAdmin", "bypass_mode": "always"},
            {"actor_id": 2740, "actor_type": "Integration", "bypass_mode": "always"},
        ])
        self.assertEqual(self.contract["preimage"]["conditions"], {
            "ref_name": {"exclude": [], "include": ["~DEFAULT_BRANCH", "refs/heads/develop"]},
            "repository_name": {"exclude": [], "include": ["~ALL"]},
        })
        pre = copy.deepcopy(self.contract["preimage"])
        post = copy.deepcopy(self.contract["postimage"])
        self.assertEqual(AUDIT.workflow_path(pre), ".github/workflows/ai-review-merge.yml")
        self.assertEqual(AUDIT.workflow_path(post), ".github/workflows/gate-rearm.yml")
        for rule in pre["rules"]:
            if rule["type"] == "workflows":
                rule["parameters"]["workflows"][0]["path"] = ".github/workflows/gate-rearm.yml"
        self.assertEqual(pre, post)

    def test_full_fleet_is_ready_and_postimage_is_retargeted(self):
        report = AUDIT.audit(self.contract, self.read)
        self.assertEqual(report["state"], "ready")
        self.assertEqual(report["governed_repositories"], 2)
        self.fixture[self.ruleset_path] = [{
            "id": self.contract["ruleset_id"], **copy.deepcopy(self.contract["postimage"]),
        }]
        self.assertEqual(AUDIT.audit(self.contract, self.read)["state"], "retargeted")

    def test_every_default_branch_requires_canonical_deterministic_ci(self):
        rows = self.fixture["orgs/Verjson/properties/values?per_page=100"][0]
        beta = next(row for row in rows if row["repository_full_name"] == "Verjson/beta")
        beta["properties"] = [{"property_name": "verjson-stack", "value": "node"}]
        self.assert_audit_error("without canonical deterministic required CI.*Verjson/beta")
        beta["properties"] = [
            {"property_name": "verjson-stack", "value": "helm"},
            {"property_name": "verjson-core-checks", "value": "enforced"},
        ]
        self.assert_audit_error("without canonical deterministic required CI.*Verjson/beta")

    def test_any_collateral_ruleset_drift_rejects_both_rollout_and_rollback(self):
        self.fixture[self.ruleset_path][0]["bypass_actors"][1]["bypass_mode"] = "pull_request"
        self.assert_audit_error("differs from both full reviewed preimage and postimage")
        with self.assertRaisesRegex(AUDIT.AuditError, "differs from both"):
            AUDIT.render_payload(self.contract, "retarget", self.read)

    def test_rendered_payloads_are_verified_and_the_tool_has_no_mutation_path(self):
        self.assertEqual(
            AUDIT.render_payload(self.contract, "retarget", self.read),
            self.contract["postimage"],
        )
        self.fixture[self.ruleset_path] = [{
            "id": self.contract["ruleset_id"], **copy.deepcopy(self.contract["postimage"]),
        }]
        self.assertEqual(
            AUDIT.render_payload(self.contract, "rollback", self.read),
            self.contract["rollback_payload"],
        )
        source = AUDIT_PATH.read_text(encoding="utf-8")
        self.assertNotIn('"--method"', source)
        self.assertNotIn("rulesets/PUT", source)
        self.assertNotIn("rulesets/PATCH", source)

    def test_retired_replacement_and_app_status_cannot_coexist(self):
        second = {"id": 99, **copy.deepcopy(self.contract["postimage"])}
        self.fixture["orgs/Verjson/rulesets"][0].append({"id": 99})
        self.fixture["orgs/Verjson/rulesets/99"] = [second]
        self.assert_audit_error("identities are not exclusive")

        self.fixture = self.make_fixture()
        self.fixture["orgs/Verjson/rulesets"][0].append({"id": 99})
        self.fixture["orgs/Verjson/rulesets/99"] = [{"id": 99, "rules": [{
            "type": "required_status_checks",
            "parameters": {"required_status_checks": [{"context": "AI review authorization"}]},
        }]}]
        self.assert_audit_error("status is also required")

    def test_repository_level_secret_and_variable_shadowing_are_rejected(self):
        self.fixture["repos/Verjson/alpha/actions/secrets?per_page=100"][0]["secrets"] = [
            {"name": "AI_REVIEW_APP_PRIVATE_KEY"},
        ]
        self.assert_audit_error("credential shadowing.*alpha:secret")
        self.fixture = self.make_fixture()
        self.fixture["repos/Verjson/beta/actions/variables?per_page=100"][0]["variables"] = [
            {"name": "AI_REVIEW_CLIENT_ID"},
        ]
        self.assert_audit_error("credential shadowing.*beta:variable")

    def test_secret_and_variables_must_reach_every_governed_repository(self):
        self.select_scope("secrets", "AI_REVIEW_APP_PRIVATE_KEY", ["Verjson/alpha"])
        self.assert_audit_error("AI_REVIEW_APP_PRIVATE_KEY.*missing=1.*Verjson/beta")
        self.fixture = self.make_fixture()
        self.select_scope("variables", "AI_REVIEW_APP_ID", ["Verjson/beta"])
        self.assert_audit_error("AI_REVIEW_APP_ID.*missing=1.*Verjson/alpha")

    def test_app_permissions_and_events_are_exact(self):
        self.assertEqual(self.contract["authorization"], {
            "private_key_secret": "AI_REVIEW_APP_PRIVATE_KEY",
            "variables": ["AI_REVIEW_APP_ID", "AI_REVIEW_APP_SLUG", "AI_REVIEW_CLIENT_ID"],
            "app_permissions": {
                "checks": "write",
                "contents": "read",
                "metadata": "read",
                "pull_requests": "write",
            },
            "app_events": [],
        })
        installation = self.fixture["orgs/Verjson/installations"][0]["installations"][0]
        installation["permissions"]["issues"] = "read"
        self.assert_audit_error("permission map drifted")
        self.fixture = self.make_fixture()
        self.fixture["orgs/Verjson/installations"][0]["installations"][0]["events"] = ["pull_request"]
        self.assert_audit_error("event subscriptions drifted")

    def test_replacement_requires_supported_trigger_nonveto_and_hosted_capacity(self):
        self.workflow_source(self.workflow.replace("pull_request_target", "workflow_dispatch"))
        self.assert_audit_error("lacks pull_request_target")
        self.fixture = self.make_fixture()
        self.workflow_source(self.workflow.replace("    continue-on-error: true\n", ""))
        self.assert_audit_error("can veto ADR 0090")
        self.fixture = self.make_fixture()
        self.workflow_source(self.workflow.replace("ubuntu-24.04", "self-hosted"))
        self.assert_audit_error("not on provider-hosted capacity")

    def test_malformed_contract_fails_with_controlled_diagnostics(self):
        for section, key, value, diagnostic in (
            (None, "ruleset_id", True, "ruleset ID"),
            ("authorization", "variables", [{}], "authorization variables"),
            ("authorization", "app_permissions", {"checks": "write"}, "permission contract"),
            ("authorization", "app_events", ["pull_request"], "event contract"),
        ):
            with self.subTest(diagnostic=diagnostic), tempfile.TemporaryDirectory() as directory:
                contract = copy.deepcopy(self.contract)
                target = contract if section is None else contract[section]
                target[key] = value
                path = Path(directory) / "contract.json"
                path.write_text(json.dumps(contract), encoding="utf-8")
                with self.assertRaisesRegex(AUDIT.AuditError, diagnostic):
                    AUDIT.read_contract(path)


if __name__ == "__main__":
    unittest.main()
