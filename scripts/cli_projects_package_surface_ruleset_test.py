#!/usr/bin/env python3
import copy
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cli-projects-package-surface-ruleset.py"
SPEC = importlib.util.spec_from_file_location("cli_projects_ruleset", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SHA = "a" * 40
HEAD = "b" * 40


class CliProjectsPackageSurfaceRulesetTest(unittest.TestCase):
    def setUp(self):
        self.contract = MODULE.read_contract()

    def test_workflow_is_exact_repository_hosted_credentialless_boundary(self):
        MODULE.validate_workflow()

    def test_payload_binds_numeric_consumer_and_immutable_protected_workflow(self):
        payload = MODULE.render_payload(self.contract, SHA)
        self.assertEqual([], payload["bypass_actors"])
        self.assertEqual({"repository_ids": [1277452690]}, payload["conditions"]["repository_id"])
        self.assertEqual([{
            "path": ".github/workflows/cli-projects-package-surface-required.yml",
            "repository_id": 1269388380,
            "ref": "refs/heads/main",
            "sha": SHA,
        }], payload["rules"][0]["parameters"]["workflows"])

    def test_contract_rejects_consumer_preimage_or_receipt_scope_drift(self):
        for mutation, message in (
            (("consumer", "repository_ruleset", "id", 1), "preimage drifted"),
            (("rollout", "required_run", "workflow_url_prefix", "https://example.invalid/"),
             "receipt contract drifted"),
        ):
            candidate = copy.deepcopy(self.contract)
            *keys, value = mutation
            target = candidate
            for key in keys[:-1]:
                target = target[key]
            target[keys[-1]] = value
            with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
                json.dump(candidate, stream)
                stream.flush()
                with self.subTest(mutation=mutation), self.assertRaisesRegex(
                    MODULE.ContractError, message
                ):
                    MODULE.read_contract(Path(stream.name))

    def test_pull_request_owned_check_name_cannot_spoof_required_workflow_receipt(self):
        run = {
            "event": "pull_request", "status": "completed", "conclusion": "success",
            "head_sha": HEAD, "id": 2, "created_at": "2026-08-29T12:01:00Z",
            "path": ".github/workflows/ci.yml",
            "workflow_url": "https://api.github.com/repos/Verjson/verjson-cli-projects/actions/workflows/ci.yml",
        }
        with self.assertRaisesRegex(MODULE.ContractError, "path is not protected"):
            MODULE.validate_required_run(
                run, self.contract, SHA, HEAD, 1,
                datetime(2026, 8, 29, 12, tzinfo=timezone.utc),
            )

    def test_repository_activation_changes_only_enforcement_after_fresh_preimage(self):
        before = self.contract["consumer"]["repository_ruleset"] | {
            "source_type": "Repository", "source": "Verjson/verjson-cli-projects",
        }
        after = copy.deepcopy(before)
        after["enforcement"] = "active"
        with (
            mock.patch.object(MODULE, "gh_json", side_effect=[before, after]),
            mock.patch.object(MODULE, "gh_json_input", return_value={}) as put,
        ):
            MODULE.activate_repository_rule(self.contract)
        payload = put.call_args.args[2]
        expected = {key: after[key] for key in MODULE.MUTABLE_FIELDS}
        self.assertEqual(expected, payload)
        changed = {key for key in payload if payload[key] != before[key]}
        self.assertEqual({"enforcement"}, changed)

    def test_repository_activation_fails_closed_on_preimage_drift(self):
        before = self.contract["consumer"]["repository_ruleset"] | {
            "source_type": "Repository", "source": "Verjson/verjson-cli-projects",
        }
        before["rules"] = copy.deepcopy(before["rules"])
        before["rules"][0]["parameters"]["required_status_checks"][0]["context"] = "spoof"
        with (
            mock.patch.object(MODULE, "gh_json", return_value=before),
            mock.patch.object(MODULE, "gh_json_input") as put,
            self.assertRaisesRegex(MODULE.ContractError, "preimage drifted"),
        ):
            MODULE.activate_repository_rule(self.contract)
        put.assert_not_called()

    def test_partial_repository_activation_fails_closed(self):
        before = self.contract["consumer"]["repository_ruleset"] | {
            "source_type": "Repository", "source": "Verjson/verjson-cli-projects",
        }
        mismatch = copy.deepcopy(before)
        mismatch["enforcement"] = "active"
        mismatch["bypass_actors"] = [{"actor_type": "OrganizationAdmin"}]
        with (
            mock.patch.object(
                MODULE, "gh_json", side_effect=[before, mismatch, mismatch, before]
            ),
            mock.patch.object(MODULE, "gh_json_input", return_value={}) as put,
            self.assertRaisesRegex(MODULE.ContractError, "restored and verified evaluate"),
        ):
            MODULE.activate_repository_rule(self.contract)
        self.assertEqual("active", put.call_args_list[0].args[2]["enforcement"])
        self.assertEqual("evaluate", put.call_args_list[1].args[2]["enforcement"])

    def test_applied_repository_put_with_client_failure_rolls_back_evaluate(self):
        before = self.contract["consumer"]["repository_ruleset"] | {
            "source_type": "Repository", "source": "Verjson/verjson-cli-projects",
        }
        active = copy.deepcopy(before)
        active["enforcement"] = "active"
        with (
            mock.patch.object(MODULE, "gh_json", side_effect=[before, active, before]),
            mock.patch.object(
                MODULE, "gh_json_input",
                side_effect=[MODULE.ContractError("client lost response"), {}],
            ) as put,
            self.assertRaisesRegex(MODULE.ContractError, "restored and verified evaluate"),
        ):
            MODULE.activate_repository_rule(self.contract)
        self.assertEqual("active", put.call_args_list[0].args[2]["enforcement"])
        self.assertEqual("evaluate", put.call_args_list[1].args[2]["enforcement"])

    def test_apply_requires_acknowledgement_before_mutation(self):
        with (
            mock.patch.object(MODULE, "discover_state", return_value=[]),
            mock.patch.object(MODULE, "gh_json_input") as mutate,
            self.assertRaisesRegex(MODULE.ContractError, "acknowledgement"),
        ):
            MODULE.main(["apply", "--workflow-sha", SHA])
        mutate.assert_not_called()

    def test_organization_activation_mismatch_restores_disabled(self):
        expected = MODULE.render_payload(self.contract, SHA)
        staged = copy.deepcopy(expected)
        staged["enforcement"] = "disabled"
        live_staged = staged | {"id": 9, "source_type": "Organization", "source": "Verjson"}
        widened = expected | {"id": 9, "source_type": "Organization", "source": "Verjson"}
        widened = copy.deepcopy(widened)
        widened["conditions"]["repository_id"]["repository_ids"] = [1]
        with (
            mock.patch.object(MODULE, "discover_state", side_effect=[[], []]),
            mock.patch.object(MODULE, "gh_json_input", side_effect=[{"id": 9}, {}, {}]) as mutate,
            mock.patch.object(
                MODULE, "gh_json",
                side_effect=[live_staged, widened, widened, live_staged],
            ),
            self.assertRaisesRegex(MODULE.ContractError, "restored and verified disabled"),
        ):
            MODULE.main([
                "apply", "--workflow-sha", SHA,
                "--ack", "APPLY-CLI-PROJECTS-PACKAGE-SURFACE-1177",
            ])
        self.assertEqual("disabled", mutate.call_args_list[2].args[2]["enforcement"])

    def test_applied_organization_put_with_client_failure_rolls_back_disabled(self):
        expected = MODULE.render_payload(self.contract, SHA)
        staged = copy.deepcopy(expected)
        staged["enforcement"] = "disabled"
        live_staged = staged | {"id": 9, "source_type": "Organization", "source": "Verjson"}
        live_active = expected | {"id": 9, "source_type": "Organization", "source": "Verjson"}
        with (
            mock.patch.object(MODULE, "discover_state", side_effect=[[], []]),
            mock.patch.object(
                MODULE, "gh_json_input",
                side_effect=[{"id": 9}, MODULE.ContractError("client lost response"), {}],
            ) as mutate,
            mock.patch.object(
                MODULE, "gh_json",
                side_effect=[live_staged, live_active, live_staged],
            ),
            self.assertRaisesRegex(MODULE.ContractError, "restored and verified disabled"),
        ):
            MODULE.main([
                "apply", "--workflow-sha", SHA,
                "--ack", "APPLY-CLI-PROJECTS-PACKAGE-SURFACE-1177",
            ])
        self.assertEqual("active", mutate.call_args_list[1].args[2]["enforcement"])
        self.assertEqual("disabled", mutate.call_args_list[2].args[2]["enforcement"])

    def test_retry_resumes_exact_interrupted_disabled_creation(self):
        expected = MODULE.render_payload(self.contract, SHA)
        staged = copy.deepcopy(expected)
        staged["enforcement"] = "disabled"
        live_staged = staged | {"id": 9, "source_type": "Organization", "source": "Verjson"}
        live_active = expected | {"id": 9, "source_type": "Organization", "source": "Verjson"}
        with (
            mock.patch.object(MODULE, "discover_state", return_value=[{"id": 9}]),
            mock.patch.object(MODULE, "gh_json", side_effect=[live_staged, live_active]),
            mock.patch.object(MODULE, "gh_json_input", return_value={}) as mutate,
        ):
            result = MODULE.main([
                "apply", "--workflow-sha", SHA,
                "--ack", "APPLY-CLI-PROJECTS-PACKAGE-SURFACE-1177",
            ])
        self.assertEqual(0, result)
        self.assertEqual(1, mutate.call_count)
        self.assertEqual("PUT", mutate.call_args.args[0])
        self.assertEqual("active", mutate.call_args.args[2]["enforcement"])


if __name__ == "__main__":
    unittest.main()
