#!/usr/bin/env python3
import argparse
import json
import tempfile
import io
import hashlib
import zipfile
import subprocess
import unittest
from pathlib import Path
from unittest import mock

import container_deployment_review_producer as producer


HEAD = "a" * 40
HEAD_TREE = "b" * 40
PRODUCER = "c" * 40
PRODUCER_TREE = "d" * 40
DEPLOYED = "e" * 40


class FakeApi:
    def __init__(self, *, review_state="APPROVED", review_commit=HEAD, duplicate=False, ai_app=900, ai_head=HEAD):
        review = {"id": 71, "state": review_state, "commit_id": review_commit, "user": {"id": 501}}
        self.responses = {
            "repos/Verjson/example": {"id": 42, "default_branch": "main"},
            "repos/Verjson/example/pulls/9": {"number": 9, "head": {"sha": HEAD}, "base": {"ref": "main"}, "merged_at": "2026-08-26T00:00:00Z"},
            f"repos/Verjson/example/commits/{DEPLOYED}/pulls": [{"number": 9, "head": {"sha": HEAD}, "base": {"ref": "main"}, "merged_at": "2026-08-26T00:00:00Z"}],
            f"repos/Verjson/example/git/commits/{HEAD}": {"tree": {"sha": HEAD_TREE}},
            f"repos/Verjson/example/git/commits/{DEPLOYED}": {"tree": {"sha": HEAD_TREE}},
            f"repos/Verjson/.github/git/commits/{PRODUCER}": {"tree": {"sha": PRODUCER_TREE}},
            "repos/Verjson/example/pulls/9/reviews?per_page=100": [review, review] if duplicate else [review],
            "users/dispatcher": {"id": 1}, "users/trigger": {"id": 2},
            "repos/Verjson/example/check-runs/81": {"id": 81, "head_sha": ai_head, "status": "completed", "conclusion": "success", "name": "canonical-ai", "app": {"id": ai_app}},
        }

    def __call__(self, path, method="GET", body=None, accept=None):
        if accept:
            return b"canonical patch"
        return json.dumps(self.responses[path]).encode()


def args(kind="code", **changes):
    values = dict(kind=kind, repository="Verjson/example", pull_request=9, review_id=71,
                  source_check_run_id=81, source_check_name="canonical-ai", source_app_id=900,
                  producer_commit=PRODUCER, producer_workflow_ref=f"Verjson/.github/.github/workflows/container-deployment-review-producer.yml@{PRODUCER}", deployment_commit=DEPLOYED, deployment_ref="refs/heads/main", caller_repository_id=42, publisher_environment=f"runner-deploy-{kind}-review-publisher", environment_policy_digest="sha256:" + "9" * 64, workflow_run_id=1001, workflow_run_attempt=2,
                  actor="dispatcher", triggering_actor="trigger")
    values.update(changes)
    return argparse.Namespace(**values)


class ProducerBehaviorTest(unittest.TestCase):
    def publisher_environment(self, kind="code"):
        return {"id": 77, "name": f"runner-deploy-{kind}-review-publisher",
                "deployment_branch_policy": {"protected_branches": True, "custom_branch_policies": False},
                "protection_rules": [{"id": 88, "node_id": "EPR_x", "type": "branch_policy"}]}

    def test_policy_digest_shell_and_python_known_vector_are_byte_identical(self):
        environment = self.publisher_environment()
        shell_bytes = subprocess.run(
            ["jq", "-j", "-cS", "{id,name,deployment_branch_policy,protection_rules}"],
            input=json.dumps(environment).encode(), check=True, capture_output=True,
        ).stdout
        self.assertEqual(producer.canonical_policy_bytes(environment), shell_bytes)
        self.assertEqual("sha256:" + hashlib.sha256(shell_bytes).hexdigest(), producer.environment_policy_digest(environment))

    def test_environment_preflight_requires_actions_read_and_prevents_publisher_reachability(self):
        repository = {"id": 42, "default_branch": "main"}
        publisher = mock.Mock()
        with self.assertRaises(PermissionError):
            evidence = producer.environment_preflight(repository, "refs/heads/main", "code", self.publisher_environment(), {"contents:read"})
            publisher(evidence)
        publisher.assert_not_called()
        evidence = producer.environment_preflight(repository, "refs/heads/main", "code", self.publisher_environment(), {"actions:read", "contents:read"})
        publisher(evidence)
        publisher.assert_called_once()

    def test_environment_preflight_and_toctou_reconciliation_reject_mismatch(self):
        repository = {"id": 42, "default_branch": "main"}
        environment = self.publisher_environment()
        with self.assertRaises(ValueError):
            producer.environment_preflight(repository, "refs/heads/main", "code", self.publisher_environment("security"), {"actions:read"})
        evidence = producer.environment_preflight(repository, "refs/heads/main", "code", environment, {"actions:read"})
        changed = json.loads(json.dumps(environment)); changed["protection_rules"][0]["id"] = 99
        with self.assertRaisesRegex(ValueError, "changed after preflight"):
            producer.publisher_reconciliation(evidence, repository, changed)

    def test_code_receipt_and_claim_bind_complete_source_and_producer(self):
        receipt = producer.build_receipt(args(), FakeApi())
        claim_args = argparse.Namespace(installation_id=301, expected_installation_id=301, artifact_id=91, artifact_digest="sha256:" + "e" * 64)
        claim = producer.build_claim(receipt, claim_args)
        for field in ("repositoryId", "repository", "pullRequest", "headCommit", "headTree", "patchDigest", "kind", "producerCommit", "producerTree", "producerWorkflowRef"):
            self.assertEqual(receipt[field], claim[field])
        self.assertEqual(301, claim["publisherInstallationId"])

    def test_rejects_malformed_stale_and_duplicate_reviews(self):
        for api in (FakeApi(review_state="CHANGES_REQUESTED"), FakeApi(review_commit="f" * 40), FakeApi(duplicate=True)):
            with self.subTest(api=api), self.assertRaises(ValueError):
                producer.build_receipt(args(), api)

    def test_ai_adapter_requires_pinned_exact_head_terminal_app(self):
        receipt = producer.build_receipt(args("ai"), FakeApi())
        self.assertEqual(81, receipt["sourceCheckRunId"])
        for api in (FakeApi(ai_app=901), FakeApi(ai_head="f" * 40)):
            with self.subTest(api=api), self.assertRaises(ValueError):
                producer.build_receipt(args("ai"), api)

    def test_claim_rejects_wrong_publisher_installation(self):
        receipt = producer.build_receipt(args(), FakeApi())
        claim_args = argparse.Namespace(installation_id=999, expected_installation_id=301, artifact_id=91, artifact_digest="sha256:" + "e" * 64)
        with self.assertRaises(ValueError):
            producer.build_claim(receipt, claim_args)

    def test_rejects_hostile_caller_selected_producer_ref(self):
        with self.assertRaisesRegex(ValueError, "immutable canonical contract"):
            producer.build_receipt(args(producer_workflow_ref=f"Verjson/example/.github/workflows/hostile.yml@{PRODUCER}"), FakeApi())
        for workflow_ref, workflow_sha in (
            ("Verjson/.github/.github/workflows/container-deployment-review-producer.yml@refs/heads/main", PRODUCER),
            (f"Verjson/example/.github/workflows/container-deployment-review-producer.yml@{PRODUCER}", PRODUCER),
            (f"Verjson/.github/.github/workflows/container-deployment-review-producer.yml@{PRODUCER}", "0" * 40),
        ):
            with self.subTest(workflow_ref=workflow_ref), self.assertRaises(ValueError):
                producer.validate_workflow_identity(workflow_ref, workflow_sha, PRODUCER)

    def test_serialized_job_authority_ignores_hostile_caller_workflow_fields_and_contract_input(self):
        job_context = {"workflow_repository": "Verjson/.github", "workflow_ref": f"Verjson/.github/.github/workflows/container-deployment-review-producer.yml@{PRODUCER}", "workflow_sha": PRODUCER}
        caller = {"github_workflow_ref": f"Verjson/example/.github/workflows/hostile.yml@{'0' * 40}", "contract_ref": "0" * 40}
        self.assertEqual(("Verjson/.github", job_context["workflow_ref"], PRODUCER), producer.validate_serialized_job_context(job_context))
        self.assertNotIn(caller["contract_ref"], producer.validate_serialized_job_context(job_context))
        for mutation in ({"workflow_repository": "Verjson/example"}, {"workflow_ref": caller["github_workflow_ref"]}, {"workflow_sha": "0" * 40}):
            hostile = dict(job_context, **mutation)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                producer.validate_serialized_job_context(hostile)

    def test_rejects_canonical_repository_environment_substituted_for_caller_environment(self):
        with self.assertRaisesRegex(ValueError, "caller-owned"):
            producer.build_receipt(args(caller_repository_id=999), FakeApi())
        with self.assertRaisesRegex(ValueError, "caller-owned"):
            producer.build_receipt(args(publisher_environment="runner-deploy-code-review-publisher", kind="security"), FakeApi())

    def test_api_reconciliation_accepts_merge_squash_and_rebase_payloads_with_identical_tree(self):
        for topology, merge_sha in (("merge", DEPLOYED), ("squash", DEPLOYED), ("rebase", "f" * 40)):
            api = FakeApi()
            api.responses[f"repos/Verjson/example/commits/{DEPLOYED}/pulls"][0]["merge_commit_sha"] = merge_sha
            with self.subTest(topology=topology):
                receipt = producer.build_receipt(args(), api)
                self.assertEqual(DEPLOYED, receipt["headCommit"])
                self.assertEqual(HEAD, receipt["reviewedHead"])

    def test_api_reconciliation_rejects_zero_multiple_unrelated_and_tree_drift(self):
        zero = FakeApi(); zero.responses[f"repos/Verjson/example/commits/{DEPLOYED}/pulls"] = []
        multiple = FakeApi(); multiple.responses[f"repos/Verjson/example/commits/{DEPLOYED}/pulls"] *= 2
        unrelated = FakeApi(); unrelated.responses[f"repos/Verjson/example/commits/{DEPLOYED}/pulls"][0]["number"] = 10
        drift = FakeApi(); drift.responses[f"repos/Verjson/example/git/commits/{DEPLOYED}"] = {"tree": {"sha": "0" * 40}}
        for name, api in (("zero", zero), ("multiple", multiple), ("unrelated", unrelated), ("drift", drift)):
            with self.subTest(case=name), self.assertRaises(ValueError):
                producer.build_receipt(args(), api)

    def test_changed_receipt_bytes_change_evidence_digest(self):
        receipt = producer.build_receipt(args(), FakeApi())
        changed = dict(receipt, headTree="f" * 40)
        self.assertNotEqual(producer.canonical_digest(receipt), producer.canonical_digest(changed))

    def test_producer_claim_artifact_zip_round_trips_through_verifier(self):
        receipt = producer.build_receipt(args(), FakeApi())
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as bundle:
            bundle.writestr("review-receipt.json", producer.canonical_bytes(receipt))
        archive = buffer.getvalue()
        digest = "sha256:" + hashlib.sha256(archive).hexdigest()
        claim_args = argparse.Namespace(installation_id=301, expected_installation_id=301, artifact_id=91, artifact_digest=digest)
        claim = producer.build_claim(receipt, claim_args)
        self.assertEqual(receipt, producer.verify_bundle(archive, digest, claim))

    def test_verifier_rejects_corrupted_artifact_and_mismatched_check_claim(self):
        receipt = producer.build_receipt(args(), FakeApi())
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as bundle:
            bundle.writestr("review-receipt.json", producer.canonical_bytes(receipt))
        archive = buffer.getvalue()
        digest = "sha256:" + hashlib.sha256(archive).hexdigest()
        claim = producer.build_claim(receipt, argparse.Namespace(installation_id=301, expected_installation_id=301, artifact_id=91, artifact_digest=digest))
        with self.assertRaises(ValueError):
            producer.verify_bundle(archive + b"corrupt", digest, claim)
        hostile = dict(claim, headTree="0" * 40)
        with self.assertRaisesRegex(ValueError, "source differ"):
            producer.verify_bundle(archive, digest, hostile)

    def test_full_mocked_github_check_workflow_artifact_and_review_admission(self):
        receipt = producer.build_receipt(args(), FakeApi())
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as bundle:
            bundle.writestr("review-receipt.json", producer.canonical_bytes(receipt))
        archive = buffer.getvalue()
        digest = "sha256:" + hashlib.sha256(archive).hexdigest()
        claim = producer.build_claim(receipt, argparse.Namespace(installation_id=301, expected_installation_id=301, artifact_id=91, artifact_digest=digest))
        check = {"name": "runner-deploy-code-review", "app": {"id": 201}, "status": "completed", "conclusion": "success", "output": {"summary": json.dumps(claim)}}
        expected = {"checkName": "runner-deploy-code-review", "appId": 201, "installationId": 301, "repositoryId": 42,
            "repository": "Verjson/example", "pullRequest": 9, "headCommit": DEPLOYED, "headTree": HEAD_TREE,
            "reviewedHead": HEAD, "reviewedTree": HEAD_TREE, "patchDigest": receipt["patchDigest"], "kind": "code",
            "callerRepositoryId": 42, "publisherEnvironment": "runner-deploy-code-review-publisher",
            "environmentPolicyDigest": "sha256:" + "9" * 64, "contractRef": PRODUCER,
            "producerWorkflowRef": f"Verjson/.github/.github/workflows/container-deployment-review-producer.yml@{PRODUCER}",
            "workflowPath": ".github/workflows/container-deployment-code-review.yml", "sourceCheckName": "canonical-ai", "sourceAppId": 900}
        responses = {
            "repos/Verjson/example/actions/runs/1001": {"head_sha": DEPLOYED, "path": expected["workflowPath"], "event": "workflow_dispatch", "status": "completed", "conclusion": "success", "run_attempt": 2},
            "repos/Verjson/example/actions/runs/1001/artifacts": {"artifacts": [{"id": 91, "digest": digest, "expired": False}]},
            "repos/Verjson/example/actions/artifacts/91/zip": archive,
            "repos/Verjson/example/pulls/9/reviews?per_page=100": [{"id": 71, "state": "APPROVED", "commit_id": HEAD, "user": {"id": 501}}],
        }
        api = lambda path: responses[path] if isinstance(responses[path], bytes) else json.dumps(responses[path]).encode()
        self.assertEqual(receipt, producer.verify_gate_authority("code", check, expected, api))
        responses["repos/Verjson/example/actions/artifacts/91/zip"] = archive + b"corrupt"
        with self.assertRaises(ValueError):
            producer.verify_gate_authority("code", check, expected, api)

    def test_interrupted_check_publication_fails_closed(self):
        receipt = producer.build_receipt(args(), FakeApi())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "review-receipt.json"
            path.write_bytes(producer.canonical_bytes(receipt))
            publish_args = argparse.Namespace(repository="Verjson/example", check_name="runner-deploy-code-review", receipt=path,
                installation_id=301, expected_installation_id=301, artifact_id=91, artifact_digest="sha256:" + "e" * 64)
            with mock.patch.object(producer, "github_api", side_effect=RuntimeError("interrupted")), self.assertRaises(RuntimeError):
                producer.publish(publish_args)


if __name__ == "__main__":
    unittest.main()
