#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/authn-type-surface-ruleset.py"
SPEC = importlib.util.spec_from_file_location("authn_type_surface_ruleset", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SHA = "a" * 40
HEAD = "b" * 40


class AuthnTypeSurfaceRulesetTest(unittest.TestCase):
    def setUp(self):
        self.contract = MODULE.read_contract()

    def test_required_workflow_keeps_acquisition_canonical_and_execution_secretless(self):
        MODULE.validate_workflow()
        workflow = yaml.safe_load(MODULE.WORKFLOW.read_text(encoding="utf-8"))
        job = workflow["jobs"]["type-surface"]
        self.assertEqual(
            "Verjson/.github/.github/workflows/node-ci.yml@"
            "c973a841694a41bf0b9bcd70432f64850cba0850",
            job["uses"],
        )
        self.assertTrue(job["with"]["secretless-pr"])
        self.assertEqual(
            {"NODE_AUTH_TOKEN": "${{ secrets.GITHUB_TOKEN }}"},
            job["secrets"],
        )

    def test_payload_uses_exact_repository_workflow_sha_and_no_bypass(self):
        payload = MODULE.render_payload(self.contract, SHA)
        self.assertEqual([], payload["bypass_actors"])
        self.assertEqual(
            {"repository_ids": [1302124584]},
            payload["conditions"]["repository_id"],
        )
        self.assertNotIn("repository_name", payload["conditions"])
        self.assertNotIn("repository_property", payload["conditions"])
        self.assertEqual(
            [{
                "path": ".github/workflows/authn-type-surface-required.yml",
                "repository_id": 1269388380,
                "ref": "refs/heads/main",
                "sha": SHA,
            }],
            payload["rules"][0]["parameters"]["workflows"],
        )
        self.assertFalse(payload["rules"][0]["parameters"]["do_not_enforce_on_create"])

    def test_pull_request_rewritten_check_name_cannot_satisfy_required_workflow(self):
        spoof = {
            "event": "pull_request",
            "id": 43,
            "created_at": "2026-08-28T15:01:00Z",
            "status": "completed",
            "conclusion": "success",
            "head_sha": HEAD,
            "name": "Authn required type surface",
            "path": ".github/workflows/ci.yml",
            "workflow_url": (
                "https://api.github.com/repos/Verjson/verjson-authn/"
                "actions/workflows/ci.yml"
            ),
        }
        with self.assertRaisesRegex(
            MODULE.ContractError,
            "run path is not the protected required workflow",
        ):
            MODULE.validate_required_run(
                spoof,
                self.contract,
                SHA,
                HEAD,
                minimum_run_id=42,
                not_before=datetime(2026, 8, 28, 15, tzinfo=timezone.utc),
            )

    def test_required_workflow_run_must_have_required_workflow_url_and_exact_head(self):
        run = {
            "event": "pull_request",
            "id": 43,
            "created_at": "2026-08-28T15:01:00Z",
            "status": "completed",
            "conclusion": "success",
            "head_sha": HEAD,
            "path": ".github/workflows/authn-type-surface-required.yml",
            "workflow_url": (
                "https://api.github.com/repos/Verjson/verjson-authn/"
                "actions/required_workflows/42"
            ),
        }
        arguments = {
            "minimum_run_id": 42,
            "not_before": datetime(2026, 8, 28, 15, tzinfo=timezone.utc),
        }
        MODULE.validate_required_run(run, self.contract, SHA, HEAD, **arguments)
        stale = copy.deepcopy(run)
        stale["head_sha"] = "c" * 40
        with self.assertRaisesRegex(MODULE.ContractError, "run is stale"):
                MODULE.validate_required_run(
                    stale, self.contract, SHA, HEAD, **arguments
                )
        local = copy.deepcopy(run)
        local["workflow_url"] = (
            "https://api.github.com/repos/Verjson/verjson-authn/actions/workflows/42"
        )
        with self.assertRaisesRegex(MODULE.ContractError, "was not created"):
                MODULE.validate_required_run(
                    local, self.contract, SHA, HEAD, **arguments
                )
        old_id = copy.deepcopy(run)
        old_id["id"] = 42
        with self.assertRaisesRegex(MODULE.ContractError, "trigger snapshot"):
            MODULE.validate_required_run(
                old_id, self.contract, SHA, HEAD, **arguments
            )
        old_time = copy.deepcopy(run)
        old_time["created_at"] = "2026-08-28T14:59:59Z"
        with self.assertRaisesRegex(MODULE.ContractError, "ruleset activation"):
            MODULE.validate_required_run(
                old_time, self.contract, SHA, HEAD, **arguments
            )

    def test_live_rule_must_match_every_reviewed_field(self):
        expected = MODULE.render_payload(self.contract, SHA)
        live = expected | {"source_type": "Organization", "source": "Verjson", "id": 1}
        MODULE.validate_live_ruleset(live, expected)
        widened = copy.deepcopy(live)
        widened["bypass_actors"] = [{
            "actor_id": None,
            "actor_type": "OrganizationAdmin",
            "bypass_mode": "always",
        }]
        with self.assertRaisesRegex(MODULE.ContractError, "differs"):
            MODULE.validate_live_ruleset(widened, expected)
        with self.assertRaisesRegex(MODULE.ContractError, "missing required fields"):
            MODULE.validate_live_ruleset(
                {"source_type": "Organization", "source": "Verjson"}, expected
            )

    def test_retiring_repository_ruleset_must_match_the_exact_preimage(self):
        expected = self.contract["consumer"]["retired_repository_ruleset"]
        live = expected | {
            "source_type": "Repository",
            "source": "Verjson/verjson-authn",
        }
        MODULE.validate_retired_ruleset(live, expected)
        mutations = []
        for key, value in (
            ("enforcement", "disabled"),
            ("bypass_actors", [{
                "actor_id": None,
                "actor_type": "OrganizationAdmin",
                "bypass_mode": "always",
            }]),
            ("target", "tag"),
        ):
            mutation = copy.deepcopy(live)
            mutation[key] = value
            mutations.append(mutation)
        scope = copy.deepcopy(live)
        scope["conditions"]["ref_name"]["include"] = ["~ALL"]
        mutations.append(scope)
        check = copy.deepcopy(live)
        check["rules"][0]["parameters"]["required_status_checks"][0]["context"] = "spoof"
        mutations.append(check)
        integration = copy.deepcopy(live)
        integration["rules"][0]["parameters"]["required_status_checks"][0]["integration_id"] = 1
        mutations.append(integration)
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with self.assertRaisesRegex(MODULE.ContractError, "preimage drifted"):
                    MODULE.validate_retired_ruleset(mutation, expected)

    def test_activation_rollback_failures_report_only_a_bounded_outcome(self):
        staged = {"enforcement": "disabled"}
        cases = (
            (MODULE.ContractError("secret mutation response"), None, "mutation failed"),
            ({"id": 99}, OSError("secret read response"), "could not be verified"),
        )
        for mutation_result, read_result, outcome in cases:
            with (
                self.subTest(outcome=outcome),
                mock.patch.object(
                    MODULE, "gh_json_input", side_effect=[mutation_result]
                ),
                mock.patch.object(MODULE, "gh_json", side_effect=[read_result]),
            ):
                with self.assertRaisesRegex(MODULE.ContractError, outcome) as raised:
                    MODULE.restore_disabled_after_activation_failure(99, staged)
                self.assertNotIn("secret", str(raised.exception))

    def test_apply_requires_acknowledgement_before_any_mutation(self):
        with (
            mock.patch.object(MODULE, "discover_state", side_effect=[[], []]),
            mock.patch.object(MODULE, "gh_json") as api,
        ):
            with self.assertRaisesRegex(MODULE.ContractError, "acknowledgement"):
                MODULE.main(["apply", "--workflow-sha", SHA])
        api.assert_not_called()

    def test_apply_creates_then_reads_back_the_exact_rule(self):
        expected = MODULE.render_payload(self.contract, SHA)
        live = expected | {
            "id": 99,
            "source_type": "Organization",
            "source": "Verjson",
        }
        staged = copy.deepcopy(live)
        staged["enforcement"] = "disabled"
        with (
            mock.patch.object(MODULE, "discover_state", side_effect=[[], []]),
            mock.patch.object(
                MODULE,
                "gh_json_input",
                side_effect=[{"id": 99}, {"id": 99}],
            ) as mutate,
            mock.patch.object(MODULE, "gh_json", side_effect=[staged, live]),
        ):
            result = MODULE.main([
                "apply",
                "--workflow-sha", SHA,
                "--ack", "APPLY-AUTHN-TYPE-SURFACE-1154",
            ])
        self.assertEqual(0, result)
        self.assertEqual("POST", mutate.call_args_list[0].args[0])
        self.assertEqual("disabled", mutate.call_args_list[0].args[2]["enforcement"])
        self.assertEqual("PUT", mutate.call_args_list[1].args[0])
        self.assertEqual("active", mutate.call_args_list[1].args[2]["enforcement"])

    def test_active_postimage_mismatch_restores_the_rule_disabled(self):
        expected = MODULE.render_payload(self.contract, SHA)
        live = expected | {
            "id": 99,
            "source_type": "Organization",
            "source": "Verjson",
        }
        staged = copy.deepcopy(live)
        staged["enforcement"] = "disabled"
        widened = copy.deepcopy(live)
        widened["conditions"]["repository_id"]["repository_ids"] = [1]
        with (
            mock.patch.object(MODULE, "discover_state", side_effect=[[], []]),
            mock.patch.object(
                MODULE,
                "gh_json_input",
                side_effect=[{"id": 99}, {"id": 99}, {"id": 99}],
            ) as mutate,
            mock.patch.object(
                MODULE, "gh_json", side_effect=[staged, widened, staged]
            ),
        ):
            with self.assertRaisesRegex(
                MODULE.ContractError, "restored and verified disabled"
            ):
                MODULE.main([
                    "apply",
                    "--workflow-sha", SHA,
                    "--ack", "APPLY-AUTHN-TYPE-SURFACE-1154",
                ])
        self.assertEqual("disabled", mutate.call_args_list[2].args[2]["enforcement"])

    def test_post_activation_api_outage_attempts_and_verifies_disabled_rollback(self):
        expected = MODULE.render_payload(self.contract, SHA)
        live = expected | {
            "id": 99,
            "source_type": "Organization",
            "source": "Verjson",
        }
        staged = copy.deepcopy(live)
        staged["enforcement"] = "disabled"
        with (
            mock.patch.object(MODULE, "discover_state", side_effect=[[], []]),
            mock.patch.object(
                MODULE,
                "gh_json_input",
                side_effect=[{"id": 99}, {"id": 99}, {"id": 99}],
            ) as mutate,
            mock.patch.object(
                MODULE,
                "gh_json",
                side_effect=[
                    staged,
                    MODULE.ContractError("simulated post-activation API outage"),
                    staged,
                ],
            ),
        ):
            with self.assertRaisesRegex(
                MODULE.ContractError, "restored and verified disabled"
            ) as raised:
                MODULE.main([
                    "apply",
                    "--workflow-sha", SHA,
                    "--ack", "APPLY-AUTHN-TYPE-SURFACE-1154",
                ])
        self.assertNotIn("simulated", str(raised.exception))
        self.assertEqual("disabled", mutate.call_args_list[2].args[2]["enforcement"])

    def test_duplicate_contract_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            text = MODULE.CONTRACT.read_text(encoding="utf-8")
            path.write_text(text.replace('"schema_version": 1,',
                                         '"schema_version": 1, "schema_version": 1,'),
                            encoding="utf-8")
            with self.assertRaisesRegex(MODULE.ContractError, "duplicate key"):
                MODULE.read_contract(path)


if __name__ == "__main__":
    unittest.main()
