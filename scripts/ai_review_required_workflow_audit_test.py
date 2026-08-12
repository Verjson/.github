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
    runs-on: ${{ fromJSON(vars.VERJSON_LANE_TRUSTED || vars.VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]') }}
    steps: []
"""
        # The retired path stays selected until the retarget lands, so the audit
        # must read it too. `pull_request` is what made it schedulable; #642
        # removed it and nothing noticed for four days.
        self.retired_workflow = """\
name: AI review + auto-merge
on:
  pull_request:
  workflow_dispatch:
  workflow_call:
jobs:
  preflight:
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
            "repositories/1269388380/contents/.github/workflows/ai-review-merge.yml?ref=refs/heads/main": [{
                "content": base64.b64encode(self.retired_workflow.encode()).decode(),
            }],
        }
        for repository in repositories:
            full_name = repository["full_name"]
            fixture[f"repos/{full_name}/actions/secrets?per_page=100"] = [{"secrets": []}]
            fixture[f"repos/{full_name}/actions/variables?per_page=100"] = [{"variables": []}]
        return fixture

    def enter_split_state(self):
        """Stub the organization as it looks after the split has been applied."""
        self.arm_id = 4242
        self.fixture[self.ruleset_path] = [{
            "id": self.contract["ruleset_id"], **copy.deepcopy(self.contract["postimage"]),
        }]
        self.fixture["orgs/Verjson/rulesets"][0].append({"id": self.arm_id})
        self.fixture[f"orgs/Verjson/rulesets/{self.arm_id}"] = [{
            "id": self.arm_id, **copy.deepcopy(self.contract["arm_ruleset"]),
        }]

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

    def retired_workflow_source(self, text):
        path = "repositories/1269388380/contents/.github/workflows/ai-review-merge.yml?ref=refs/heads/main"
        self.fixture[path][0]["content"] = base64.b64encode(text.encode()).decode()

    def test_selected_required_workflow_must_declare_a_ruleset_eligible_trigger(self):
        # The live outage: the selected workflow kept only triggers a ruleset
        # cannot fire, so every governed repository lost its required-workflow
        # run and displayed "Workflow configuration invalid" instead.
        self.retired_workflow_source("""\
name: AI review + auto-merge
on:
  workflow_dispatch:
  workflow_call:
jobs:
  preflight:
    runs-on: ubuntu-24.04
    steps: []
""")
        self.assert_audit_error(
            r"ai-review-merge\.yml.*declares only.*workflow_call.*workflow_dispatch",
        )

    def test_merge_group_alone_keeps_the_selected_workflow_schedulable(self):
        self.retired_workflow_source("""\
name: AI review + auto-merge
on:
  merge_group:
jobs:
  preflight:
    runs-on: ubuntu-24.04
    steps: []
""")
        self.assertEqual(AUDIT.audit(self.contract, self.read)["state"], "ready")

    def test_an_unschedulable_selection_outranks_the_fleet_readiness_gap(self):
        # A live outage must not be masked by a rollout precondition. The
        # deterministic-CI gap is why the retarget cannot land yet; the dead
        # selection is why the gate is down right now.
        rows = self.fixture["orgs/Verjson/properties/values?per_page=100"][0]
        for row in rows:
            row["properties"] = []
        self.retired_workflow_source("""\
name: AI review + auto-merge
on:
  workflow_call:
jobs:
  preflight:
    runs-on: ubuntu-24.04
    steps: []
""")
        self.assert_audit_error(r"declares only")

    def test_the_split_selection_is_checked_against_the_replacement(self):
        self.enter_split_state()
        self.workflow_source("""\
name: AI review authorization arm
on:
  workflow_call:
jobs:
  arm:
    continue-on-error: true
    runs-on: ${{ fromJSON(vars.VERJSON_LANE_TRUSTED || vars.VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]') }}
    steps: []
""")
        self.assert_audit_error(r"gate-rearm\.yml.*declares only.*workflow_call")

    def test_the_split_can_be_rendered_while_the_dead_selection_it_repairs_persists(self):
        # The selection being unschedulable is the outage; the split is its
        # remedy. An audit must still refuse, or the finding disappears.
        self.retired_workflow_source("name: x\non:\n  workflow_call:\njobs: {}\n")
        self.assert_audit_error(r"declares only")
        self.assertEqual(
            AUDIT.render_payload(self.contract, "split", self.read),
            self.contract["postimage"],
        )
        self.assertEqual(
            AUDIT.render_payload(self.contract, "arm-ruleset", self.read),
            self.contract["arm_ruleset"],
        )

    def test_the_escape_never_excuses_a_dead_selection_after_the_split(self):
        # Post-split, an unschedulable selection is a fresh regression rather
        # than a state being repaired, so nothing may wave it through.
        self.enter_split_state()
        self.workflow_source("name: x\non:\n  workflow_call:\njobs:\n  arm:\n    steps: []\n")
        with self.assertRaisesRegex(AUDIT.AuditError, r"declares only"):
            AUDIT.audit(self.contract, self.read, allow_unschedulable_selection=True)

    def test_the_escape_does_not_suppress_any_other_precondition(self):
        rows = self.fixture["orgs/Verjson/properties/values?per_page=100"][0]
        beta = next(row for row in rows if row["repository_full_name"] == "Verjson/beta")
        beta["properties"] = [
            {"property_name": "verjson-stack", "value": "helm"},
            {"property_name": "verjson-core-checks", "value": "enforced"},
        ]
        self.retired_workflow_source("name: x\non:\n  workflow_call:\njobs: {}\n")
        with self.assertRaisesRegex(AUDIT.AuditError, "armed default branches without canonical"):
            AUDIT.render_payload(self.contract, "split", self.read)

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
        arm = copy.deepcopy(self.contract["arm_ruleset"])
        self.assertEqual(AUDIT.workflow_path(pre), ".github/workflows/ai-review-merge.yml")
        self.assertEqual(AUDIT.workflow_path(arm), ".github/workflows/gate-rearm.yml")
        # Branch protection is untouched: the postimage is the preimage minus one
        # rule, and every remaining rule still applies to `~ALL`.
        self.assertEqual(
            [rule["type"] for rule in post["rules"]],
            ["deletion", "non_fast_forward", "required_linear_history", "pull_request"],
        )
        self.assertEqual(post["conditions"]["repository_name"], {"exclude": [], "include": ["~ALL"]})
        pre["rules"] = [rule for rule in pre["rules"] if rule["type"] != "workflows"]
        self.assertEqual(pre, post)
        # The arm is scoped by property, never by name, so it governs exactly the
        # repositories that also carry canonical deterministic CI.
        self.assertNotIn("repository_name", arm["conditions"])
        self.assertEqual(arm["conditions"]["repository_property"]["include"], [{
            "name": "verjson-core-checks", "property_values": ["enforced"], "source": "custom",
        }])

    def test_fleet_is_ready_before_the_split_and_recognised_after_it(self):
        report = AUDIT.audit(self.contract, self.read, allow_unschedulable_selection=True)
        self.assertEqual(report["state"], "ready")
        self.assertEqual(report["governed_repositories"], 2)
        self.assertEqual(report["armed_repositories"], 2)
        self.enter_split_state()
        report = AUDIT.audit(self.contract, self.read)
        self.assertEqual(report["state"], "split")
        self.assertEqual(report["current_path"], ".github/workflows/gate-rearm.yml")

    def test_split_state_requires_the_arm_ruleset_to_exist_and_match(self):
        self.fixture[self.ruleset_path] = [{
            "id": self.contract["ruleset_id"], **copy.deepcopy(self.contract["postimage"]),
        }]
        self.assert_audit_error("must have exactly one arm ruleset")
        self.fixture = self.make_fixture()
        self.enter_split_state()
        self.fixture[f"orgs/Verjson/rulesets/{self.arm_id}"][0]["enforcement"] = "evaluate"
        self.assert_audit_error("arm ruleset drifted from its full reviewed image")

    def test_the_arm_ruleset_must_not_exist_before_the_split(self):
        self.fixture["orgs/Verjson/rulesets"][0].append({"id": 4242})
        self.fixture["orgs/Verjson/rulesets/4242"] = [{
            "id": 4242, **copy.deepcopy(self.contract["arm_ruleset"]),
        }]
        self.assert_audit_error("arm ruleset already exists before the split")

    def test_an_armed_repository_without_deterministic_ci_is_rejected(self):
        rows = self.fixture["orgs/Verjson/properties/values?per_page=100"][0]
        beta = next(row for row in rows if row["repository_full_name"] == "Verjson/beta")
        # Armed (property set) but on an undeclared stack: nothing deterministic
        # stands behind the non-vetoing arm. That is the hazard, and it is rejected.
        beta["properties"] = [
            {"property_name": "verjson-stack", "value": "helm"},
            {"property_name": "verjson-core-checks", "value": "enforced"},
        ]
        self.assert_audit_error("armed default branches without canonical deterministic required CI.*Verjson/beta")

    def test_an_unarmed_repository_is_not_required_to_have_deterministic_ci(self):
        # The split's whole purpose: a repository the arm does not govern keeps
        # human review and is not a rollout blocker. Under the ~ALL rule it was.
        rows = self.fixture["orgs/Verjson/properties/values?per_page=100"][0]
        beta = next(row for row in rows if row["repository_full_name"] == "Verjson/beta")
        beta["properties"] = []
        self.enter_split_state()
        report = AUDIT.audit(self.contract, self.read)
        self.assertEqual(report["governed_repositories"], 2)
        self.assertEqual(report["armed_repositories"], 1)

    def test_an_arm_governing_nothing_is_rejected(self):
        for row in self.fixture["orgs/Verjson/properties/values?per_page=100"][0]:
            row["properties"] = []
        self.assert_audit_error("the arm would govern nothing")

    def test_any_collateral_ruleset_drift_rejects_both_rollout_and_rollback(self):
        self.fixture[self.ruleset_path][0]["bypass_actors"][1]["bypass_mode"] = "pull_request"
        self.assert_audit_error("differs from both full reviewed preimage and postimage")
        with self.assertRaisesRegex(AUDIT.AuditError, "differs from both"):
            AUDIT.render_payload(self.contract, "retarget", self.read)

    def test_rendered_payloads_are_verified_and_the_tool_has_no_mutation_path(self):
        self.assertEqual(
            AUDIT.render_payload(self.contract, "split", self.read),
            self.contract["postimage"],
        )
        self.assertEqual(
            AUDIT.render_payload(self.contract, "arm-ruleset", self.read),
            self.contract["arm_ruleset"],
        )
        self.enter_split_state()
        self.assertEqual(
            AUDIT.render_payload(self.contract, "rollback", self.read),
            self.contract["rollback_payload"],
        )
        source = AUDIT_PATH.read_text(encoding="utf-8")
        self.assertNotIn('"--method"', source)
        self.assertNotIn("rulesets/PUT", source)
        self.assertNotIn("rulesets/PATCH", source)

    def test_retired_replacement_and_app_status_cannot_coexist(self):
        second = {"id": 99, **copy.deepcopy(self.contract["arm_ruleset"])}
        self.fixture["orgs/Verjson/rulesets"][0].append({"id": 99})
        self.fixture["orgs/Verjson/rulesets/99"] = [second]
        self.assert_audit_error("arm ruleset already exists before the split")

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

    def test_replacement_requires_supported_trigger_nonveto_and_trusted_lane(self):
        self.workflow_source(self.workflow.replace("pull_request_target", "workflow_dispatch"))
        self.assert_audit_error("lacks pull_request_target")
        self.fixture = self.make_fixture()
        self.workflow_source(self.workflow.replace("    continue-on-error: true\n", ""))
        self.assert_audit_error("can veto ADR 0090")
        self.fixture = self.make_fixture()
        self.workflow_source(self.workflow.replace("VERJSON_LANE_TRUSTED", "VERJSON_LANE_PRIVILEGED"))
        self.assert_audit_error("not routed through the trusted lane")

    def assert_contract_rejected(self, mutate, diagnostic):
        contract = copy.deepcopy(self.contract)
        mutate(contract)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            path.write_text(json.dumps(contract), encoding="utf-8")
            with self.assertRaisesRegex(AUDIT.AuditError, diagnostic):
                AUDIT.read_contract(path)

    def test_the_split_may_not_smuggle_in_any_other_protection_change(self):
        # The postimage is derived, not trusted. A contract that also relaxes
        # enforcement, widens a bypass, or drops another rule while "just moving
        # the workflows rule" is exactly what a reviewer would miss in a 7 KB diff.
        def relax(contract):
            contract["postimage"]["enforcement"] = "evaluate"
        self.assert_contract_rejected(relax, "beyond removing the workflows rule")

        def widen_bypass(contract):
            contract["postimage"]["bypass_actors"].append(
                {"actor_id": 5, "actor_type": "Integration", "bypass_mode": "always"},
            )
        self.assert_contract_rejected(widen_bypass, "beyond removing the workflows rule")

        def drop_protection(contract):
            contract["postimage"]["rules"] = [
                rule for rule in contract["postimage"]["rules"] if rule["type"] != "non_fast_forward"
            ]
        self.assert_contract_rejected(drop_protection, "beyond removing the workflows rule")

        def narrow_scope(contract):
            contract["postimage"]["conditions"]["repository_name"]["include"] = ["verjson-leads"]
        self.assert_contract_rejected(narrow_scope, "beyond removing the workflows rule")

    def test_the_arm_may_not_be_scoped_by_name_or_to_the_wrong_property(self):
        # Scoping the arm by name would re-create the ~ALL hazard the split
        # exists to remove, and silently decouple it from deterministic CI.
        def by_name(contract):
            contract["arm_ruleset"]["conditions"]["repository_name"] = {"exclude": [], "include": ["~ALL"]}
        self.assert_contract_rejected(by_name, "scoped by repository property, not by name")

        def wrong_property(contract):
            contract["arm_ruleset"]["conditions"]["repository_property"]["include"][0]["name"] = "verjson-stack"
        self.assert_contract_rejected(wrong_property, "not scoped to the deterministic-CI property")

        def wrong_value(contract):
            contract["arm_ruleset"]["conditions"]["repository_property"]["include"][0]["property_values"] = ["all"]
        self.assert_contract_rejected(wrong_value, "not scoped to the deterministic-CI property")

        def other_refs(contract):
            contract["arm_ruleset"]["conditions"]["ref_name"]["include"] = ["~ALL"]
        self.assert_contract_rejected(other_refs, "targets different refs")

    def test_the_relocated_rule_must_be_the_same_rule(self):
        def creation_bypass(contract):
            contract["arm_ruleset"]["rules"][0]["parameters"]["do_not_enforce_on_create"] = False
        self.assert_contract_rejected(creation_bypass, "repository-creation bypass drifted")

        def mutable_ref(contract):
            contract["arm_ruleset"]["rules"][0]["parameters"]["workflows"][0]["ref"] = "refs/heads/dev"
        self.assert_contract_rejected(mutable_ref, "not the relocated workflows rule")

        def wrong_source(contract):
            contract["arm_ruleset"]["rules"][0]["parameters"]["workflows"][0]["repository_id"] = 1
        self.assert_contract_rejected(wrong_source, "not the relocated workflows rule")

        def inactive(contract):
            contract["arm_ruleset"]["enforcement"] = "evaluate"
        self.assert_contract_rejected(inactive, "arm ruleset must be active")

        def wider_bypass(contract):
            contract["arm_ruleset"]["bypass_actors"] = []
        self.assert_contract_rejected(wider_bypass, "bypass actors diverge")

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
