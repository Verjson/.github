#!/usr/bin/env python3
import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import yaml


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

    def test_caller_ref_input_and_credential_mutations_are_rejected(self):
        source = MODULE.WORKFLOW.read_text(encoding="utf-8")
        mutations = (
            source.replace("node-ci.yml@d91d6a7", "node-ci.yml@aaaaaaaa"),
            source.replace("secretless-pr: true", "secretless-pr: false", 1),
            source.replace("NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}", "NODE_AUTH_TOKEN: mutation", 1),
            source.replace("needs: admission", "needs: []", 1),
        )
        for candidate in mutations:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
                stream.write(candidate)
                stream.flush()
                with self.subTest(candidate=candidate[:80]), self.assertRaisesRegex(
                    MODULE.ContractError, "differs from canonical generator output"
                ):
                    MODULE.validate_workflow(Path(stream.name))

    def test_identity_admission_rejects_every_untrusted_identity_mutation(self):
        workflow = yaml.safe_load(MODULE.WORKFLOW.read_text(encoding="utf-8"))
        script = workflow["jobs"]["admission"]["steps"][0]["run"]
        base = {
            "EVENT_NAME": "pull_request",
            "HEAD_REPOSITORY": "Verjson/verjson-cli-projects",
            "HEAD_SHA": "b" * 40,
            "MERGE_SHA": "c" * 40,
            "PR_NUMBER": "114",
            "REF": "refs/pull/114/merge",
            "REPOSITORY": "Verjson/verjson-cli-projects",
        }
        with tempfile.TemporaryDirectory() as directory:
            consumer = subprocess.run(
                [str(MODULE.GENERATOR), "--consumer",
                 "config/cli-projects-required-node-ci.json"],
                cwd=MODULE.ROOT, capture_output=True, check=True,
            ).stdout
            consumer_path = Path(directory) / "consumer.yml"
            consumer_path.write_bytes(consumer)
            base["CONSUMER_WORKFLOW_SHA256"] = hashlib.sha256(consumer).hexdigest()
            fake_gh = Path(directory) / "gh"
            fake_gh.write_text(
                "#!/bin/sh\n"
                "case \"$*\" in\n"
                "  *contents/.github/workflows/ci.yml*) cat \"$CONSUMER_FILE\" ;;\n"
                "  *) printf '114\\tVerjson/verjson-cli-projects\\t%s\\t%s\\n' "
                '"$LIVE_HEAD" "$LIVE_MERGE" ;;\n'
                "esac\n",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)

            def execute(values, live_head=None, live_merge=None):
                environment = {
                    **os.environ,
                    **values,
                    "PATH": f"{directory}:{os.environ['PATH']}",
                    "GH_TOKEN": "bounded-test-token",
                    "LIVE_HEAD": live_head or base["HEAD_SHA"],
                    "LIVE_MERGE": live_merge or base["MERGE_SHA"],
                    "CONSUMER_FILE": str(consumer_path),
                }
                return subprocess.run(
                    ["bash", "-c", script], env=environment,
                    capture_output=True, text=True, check=False,
                ).returncode

            self.assertEqual(0, execute(base))
            mutated = consumer.replace(b"  push:\n", b"  pull_request:\n", 1)
            consumer_path.write_bytes(mutated)
            self.assertNotEqual(0, execute(base))
            consumer_path.write_bytes(consumer + b"\n")
            self.assertNotEqual(0, execute(base))
            consumer_path.write_bytes(consumer)
            mutations = (
                ({**base, "EVENT_NAME": "pull_request_target"}, None, None),
                ({**base, "REPOSITORY": "Verjson/other"}, None, None),
                ({**base, "HEAD_REPOSITORY": "attacker/fork"}, None, None),
                ({**base, "PR_NUMBER": "114;true"}, None, None),
                ({**base, "HEAD_SHA": "not-a-sha"}, None, None),
                ({**base, "MERGE_SHA": "not-a-sha"}, None, None),
                ({**base, "REF": "refs/heads/main"}, None, None),
                (base, "d" * 40, None),
                (base, None, "e" * 40),
            )
            for values, live_head, live_merge in mutations:
                with self.subTest(values=values, live_head=live_head, live_merge=live_merge):
                    self.assertNotEqual(0, execute(values, live_head, live_merge))

    def test_consumer_caller_is_push_only_and_exactly_generated(self):
        result = subprocess.run(
            [str(MODULE.GENERATOR), "--consumer",
             "config/cli-projects-required-node-ci.json"],
            cwd=MODULE.ROOT, capture_output=True, text=True, check=True,
        )
        consumer = yaml.safe_load(result.stdout)
        self.assertEqual({"push": {"branches": ["main"]}}, consumer[True])
        self.assertNotIn("pull_request", result.stdout)
        self.assertNotIn("pull_request_target", result.stdout)

    def test_rollout_rejects_default_branch_consumer_caller_drift(self):
        generated = subprocess.run(
            [str(MODULE.GENERATOR), "--consumer",
             "config/cli-projects-required-node-ci.json"],
            cwd=MODULE.ROOT, capture_output=True, check=True,
        ).stdout
        with mock.patch.object(
            MODULE.subprocess, "run",
            side_effect=[
                subprocess.CompletedProcess([], 0, stdout=generated),
                subprocess.CompletedProcess([], 0, stdout=generated + b"# mutation\n"),
            ],
        ), mock.patch.object(
            MODULE, "gh_json", return_value={"object": {"sha": HEAD}}
        ), self.assertRaisesRegex(
            MODULE.ContractError, "not the reviewed push-only generated image"
        ):
            MODULE.verify_consumer_workflow(self.contract)

    def test_consumer_workflow_read_is_bound_to_unchanged_branch_commit(self):
        generated = subprocess.run(
            [str(MODULE.GENERATOR), "--consumer",
             "config/cli-projects-required-node-ci.json"],
            cwd=MODULE.ROOT, capture_output=True, check=True,
        ).stdout
        with (
            mock.patch.object(
                MODULE.subprocess, "run",
                side_effect=[
                    subprocess.CompletedProcess([], 0, stdout=generated),
                    subprocess.CompletedProcess([], 0, stdout=generated),
                ],
            ),
            mock.patch.object(
                MODULE, "gh_json",
                side_effect=[{"object": {"sha": HEAD}}, {"object": {"sha": "c" * 40}}],
            ),
            self.assertRaisesRegex(MODULE.ContractError, "moved during transaction"),
        ):
            MODULE.verify_consumer_workflow(self.contract)

    def test_generator_rejects_mutable_or_injectable_configuration(self):
        config = json.loads(MODULE.GENERATOR_CONFIG.read_text(encoding="utf-8"))
        mutations = (
            {**config, "node_ci_sha": "main"},
            {**config, "repository": "Verjson/other"},
            {**config, "repository": "Verjson/verjson-cli-projects\npermissions: write"},
            {**config, "approved_internal_packages": ["@verjson/eslint-config\nrun: id"]},
            {**config, "scripts": ["test\nrun: id"]},
        )
        for mutation in mutations:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
                json.dump(mutation, stream)
                stream.flush()
                result = subprocess.run(
                    [str(MODULE.GENERATOR), stream.name], cwd=MODULE.ROOT,
                    capture_output=True, text=True, check=False,
                )
                with self.subTest(mutation=mutation):
                    self.assertEqual(2, result.returncode)

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

    def test_repository_activation_branch_drift_restores_evaluate_after_ambiguous_put(self):
        before = self.contract["consumer"]["repository_ruleset"] | {
            "source_type": "Repository", "source": "Verjson/verjson-cli-projects",
        }
        active = copy.deepcopy(before)
        active["enforcement"] = "active"
        for response in ({}, MODULE.ContractError("client lost response")):
            with (
                mock.patch.object(
                    MODULE, "assert_consumer_branch_sha",
                    side_effect=[None, MODULE.ContractError("branch moved")],
                ),
                mock.patch.object(MODULE, "gh_json", side_effect=[before, active, before]),
                mock.patch.object(
                    MODULE, "gh_json_input", side_effect=[response, {}],
                ) as put,
                self.assertRaisesRegex(MODULE.ContractError, "restored and verified evaluate"),
            ):
                MODULE.activate_repository_rule(self.contract, HEAD)
            self.assertEqual("evaluate", put.call_args_list[1].args[2]["enforcement"])

    def test_apply_requires_acknowledgement_before_mutation(self):
        with (
            mock.patch.object(MODULE, "discover_state", return_value=([], HEAD)),
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
            mock.patch.object(MODULE, "discover_state", side_effect=[([], HEAD), ([], HEAD)]),
            mock.patch.object(MODULE, "assert_consumer_branch_sha"),
            mock.patch.object(MODULE, "gh_json_input", side_effect=[{"id": 9}, {}, {}]) as mutate,
            mock.patch.object(
                MODULE, "gh_json",
                side_effect=[live_staged, widened, widened, live_staged],
            ),
            self.assertRaisesRegex(MODULE.ContractError, "restored and verified disabled"),
        ):
            MODULE.main([
                "apply", "--workflow-sha", SHA,
                "--ack", "ROTATE-CLI-PROJECTS-REQUIRED-WORKFLOW-1187",
            ])
        self.assertEqual("disabled", mutate.call_args_list[2].args[2]["enforcement"])

    def test_apply_rotates_only_the_exact_reviewed_prior_workflow(self):
        expected = MODULE.render_payload(self.contract, SHA)
        previous = MODULE.render_payload(
            self.contract, self.contract["rollout"]["previous_workflow_sha"]
        )
        live_previous = previous | {
            "id": 9, "source_type": "Organization", "source": "Verjson",
        }
        live_expected = expected | {
            "id": 9, "source_type": "Organization", "source": "Verjson",
        }
        with (
            mock.patch.object(MODULE, "discover_state", return_value=([{"id": 9}], HEAD)),
            mock.patch.object(MODULE, "assert_consumer_branch_sha"),
            mock.patch.object(MODULE, "gh_json", side_effect=[live_previous, live_previous, live_expected]),
            mock.patch.object(MODULE, "gh_json_input", return_value={}) as mutate,
        ):
            MODULE.main([
                "apply", "--workflow-sha", SHA,
                "--ack", "ROTATE-CLI-PROJECTS-REQUIRED-WORKFLOW-1187",
            ])
        self.assertEqual(expected, mutate.call_args.args[2])

    def test_apply_rotates_reviewed_prior_workflow_that_appears_during_discovery(self):
        expected = MODULE.render_payload(self.contract, SHA)
        previous = MODULE.render_payload(
            self.contract, self.contract["rollout"]["previous_workflow_sha"]
        )
        live_previous = previous | {
            "id": 9, "source_type": "Organization", "source": "Verjson",
        }
        live_expected = expected | {
            "id": 9, "source_type": "Organization", "source": "Verjson",
        }
        with (
            mock.patch.object(
                MODULE, "discover_state",
                side_effect=[([], HEAD), ([{"id": 9}], HEAD)],
            ),
            mock.patch.object(MODULE, "assert_consumer_branch_sha"),
            mock.patch.object(MODULE, "gh_json", side_effect=[live_previous, live_previous, live_expected]),
            mock.patch.object(MODULE, "gh_json_input", return_value={}) as mutate,
        ):
            MODULE.main([
                "apply", "--workflow-sha", SHA,
                "--ack", "ROTATE-CLI-PROJECTS-REQUIRED-WORKFLOW-1187",
            ])
        self.assertEqual(expected, mutate.call_args.args[2])

    def test_partial_rotation_restores_and_verifies_the_prior_active_workflow(self):
        expected = MODULE.render_payload(self.contract, SHA)
        previous = MODULE.render_payload(
            self.contract, self.contract["rollout"]["previous_workflow_sha"]
        )
        live_previous = previous | {
            "id": 9, "source_type": "Organization", "source": "Verjson",
        }
        partial = copy.deepcopy(expected) | {
            "id": 9, "source_type": "Organization", "source": "Verjson",
        }
        partial["bypass_actors"] = [{"actor_type": "OrganizationAdmin"}]
        with (
            mock.patch.object(MODULE, "gh_json", side_effect=[live_previous, partial, partial, live_previous]),
            mock.patch.object(MODULE, "gh_json_input", return_value={}) as mutate,
            self.assertRaisesRegex(MODULE.ContractError, "prior active workflow restored"),
        ):
            MODULE.rotate_existing_org_rule(9, previous, expected)
        self.assertEqual(expected, mutate.call_args_list[0].args[2])
        self.assertEqual(previous, mutate.call_args_list[1].args[2])

    def test_org_rotation_branch_drift_restores_prior_after_ambiguous_put(self):
        expected = MODULE.render_payload(self.contract, SHA)
        previous = MODULE.render_payload(
            self.contract, self.contract["rollout"]["previous_workflow_sha"]
        )
        live_previous = previous | {
            "id": 9, "source_type": "Organization", "source": "Verjson",
        }
        for response in ({}, MODULE.ContractError("client lost response")):
            with (
                mock.patch.object(
                    MODULE, "assert_consumer_branch_sha",
                    side_effect=[None, MODULE.ContractError("branch moved"),
                                 MODULE.ContractError("branch moved")],
                ),
                mock.patch.object(
                    MODULE, "gh_json",
                    side_effect=[live_previous, live_previous],
                ),
                mock.patch.object(
                    MODULE, "gh_json_input", side_effect=[response, {}],
                ) as mutate,
                self.assertRaisesRegex(MODULE.ContractError, "prior active workflow restored"),
            ):
                MODULE.rotate_existing_org_rule(9, previous, expected, HEAD)
            self.assertEqual(previous, mutate.call_args_list[1].args[2])

    def test_applied_organization_put_with_client_failure_rolls_back_disabled(self):
        expected = MODULE.render_payload(self.contract, SHA)
        staged = copy.deepcopy(expected)
        staged["enforcement"] = "disabled"
        live_staged = staged | {"id": 9, "source_type": "Organization", "source": "Verjson"}
        live_active = expected | {"id": 9, "source_type": "Organization", "source": "Verjson"}
        with (
            mock.patch.object(MODULE, "discover_state", side_effect=[([], HEAD), ([], HEAD)]),
            mock.patch.object(MODULE, "assert_consumer_branch_sha"),
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
                "--ack", "ROTATE-CLI-PROJECTS-REQUIRED-WORKFLOW-1187",
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
            mock.patch.object(MODULE, "discover_state", return_value=([{"id": 9}], HEAD)),
            mock.patch.object(MODULE, "assert_consumer_branch_sha"),
            mock.patch.object(MODULE, "gh_json", side_effect=[live_staged, live_active]),
            mock.patch.object(MODULE, "gh_json_input", return_value={}) as mutate,
        ):
            result = MODULE.main([
                "apply", "--workflow-sha", SHA,
                "--ack", "ROTATE-CLI-PROJECTS-REQUIRED-WORKFLOW-1187",
            ])
        self.assertEqual(0, result)
        self.assertEqual(1, mutate.call_count)
        self.assertEqual("PUT", mutate.call_args.args[0])
        self.assertEqual("active", mutate.call_args.args[2]["enforcement"])


if __name__ == "__main__":
    unittest.main()
