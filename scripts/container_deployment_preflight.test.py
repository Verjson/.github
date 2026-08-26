#!/usr/bin/env python3

import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("container_deployment_preflight.py")
SPEC = importlib.util.spec_from_file_location("container_deployment_preflight", MODULE_PATH)
assert SPEC and SPEC.loader
preflight = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = preflight
SPEC.loader.exec_module(preflight)


def evidence():
    head = "a" * 40
    tree = "b" * 40
    repository = "Verjson/verjson-github-runner"
    pull_request = 174
    def gate(kind, principal, digit, app_id):
        return {
            "kind": kind,
            "principalId": principal,
            "appId": app_id,
            "issuer": f"org-{kind}-review",
            "checkRunId": 1000 + app_id,
            "workflowRunId": 2000 + app_id,
            "workflowRunAttempt": 1,
            "workflowPath": f".github/workflows/{kind}-review.yml",
            "workflowRef": f"Verjson/verjson-github-runner/.github/workflows/{kind}-review.yml@refs/heads/main",
            "artifactId": 3000 + app_id,
            "artifactDigest": "sha256:" + digit * 64,
            "evidenceDigest": "sha256:" + "7" * 64,
            "repositoryId": 42,
            "repository": repository,
            "pullRequest": pull_request,
            "headCommit": head,
            "headTree": tree,
            "patchDigest": "sha256:" + "9" * 64,
            "conclusion": "success",
            "completedAt": "2026-08-26T12:00:00Z",
        }
    gates = [
        gate("code", 101, "1", 201),
        gate("security", 102, "2", 202),
        gate("ai", 103, "3", 203),
    ]
    authority = {
        "source": "github-api",
        "repositoryId": 42,
        "defaultBranch": "main",
        "ref": "refs/heads/main",
        "deployedCommit": "e" * 40,
        "deployedTree": tree,
        "environment": "production",
        "deploymentBranchPolicy": {"protectedBranches": True, "customBranchPolicies": False},
        "requiredReviewers": [],
        "preventSelfReview": False,
        "canAdminsBypass": True,
        "repository": repository,
        "pullRequest": pull_request,
        "dispatcher": "release-operator",
        "dispatcherId": 104,
        "triggeringActor": "release-trigger",
        "triggeringActorId": 105,
        "environmentBypassed": False,
        "bypassBasis": "branch-policy-only",
        "workflowRunId": 9001,
        "workflowRunAttempt": 1,
        "reviewedHead": head,
        "reviewedTree": tree,
        "patchDigest": "sha256:" + "9" * 64,
        "reviewGates": gates,
    }
    return {
        "defaultBranch": "main",
        "ref": "refs/heads/main",
        "environment": "production",
        "deploymentBranchPolicy": {
            "protectedBranches": True,
            "customBranchPolicies": False,
        },
        "preventSelfReview": False,
        "canAdminsBypass": True,
        "requiredReviewers": [],
        "dispatcher": "release-operator",
        "environmentBypassed": False,
        "headCommit": head,
        "headTree": tree,
        "repository": repository,
        "pullRequest": pull_request,
        "reviewGates": gates,
        "authorization": authority,
    }


def release(version, digit):
    return {
        "releaseVersion": version,
        "manifestDigest": "sha256:" + digit * 64,
    }


def failed_attempt(outcome="failed"):
    return {
        "revision": 0 if outcome == "admitted" else 1,
        "attemptId": "1001.1",
        "action": "deploy",
        "outcome": outcome,
        "selectedRelease": release("2.0.0", "2"),
        "observedDeployedRelease": release("1.0.0", "1"),
        "previousReceiptDigest": "sha256:" + "0" * 64,
        "runners": [
            {
                "name": "canary",
                "beforeDigest": "sha256:" + "1" * 64,
                "afterDigest": "sha256:" + "2" * 64,
                "probe": "failed",
            }
        ],
    }


def rollback_for(attempt):
    return {
        "action": "rollback",
        "selectedRelease": attempt["observedDeployedRelease"],
        "rollbackOfAttempt": {
            "attemptId": attempt["attemptId"],
            "receiptDigest": preflight.receipt_digest(attempt),
        },
    }


class ContainerDeploymentPreflightTests(unittest.TestCase):
    def assert_rejected(self, candidate, expected):
        with self.assertRaisesRegex(preflight.PreflightError, expected):
            preflight.validate_authorization(candidate)

    def test_accepts_independently_reviewed_protected_default_branch(self):
        candidate = evidence()
        self.assertNotEqual(candidate["authorization"]["deployedCommit"], candidate["authorization"]["reviewedHead"])
        self.assertEqual(candidate["authorization"]["deployedTree"], candidate["authorization"]["reviewedTree"])
        preflight.validate_authorization(candidate)

    def test_receipt_rejects_merge_conflict_tree_not_equal_reviewed_tree(self):
        candidate = evidence()
        candidate["authorization"]["reviewedTree"] = "0" * 40
        self.assert_rejected(candidate, "differs reviewed pull-request tree")

    def test_accepts_merge_squash_and_rebase_commit_ids_only_when_tree_is_identical(self):
        for topology, deployed_commit in (("merge", "1" * 40), ("squash", "2" * 40), ("rebase", "3" * 40)):
            candidate = evidence()
            candidate["authorization"]["deployedCommit"] = deployed_commit
            with self.subTest(topology=topology):
                preflight.validate_authorization(candidate)

    def test_rejects_non_default_branch(self):
        candidate = evidence()
        candidate["authorization"]["ref"] = "refs/heads/release"
        self.assert_rejected(candidate, "exact default branch")

    def test_rejects_custom_branch_admission(self):
        candidate = evidence()
        candidate["authorization"]["deploymentBranchPolicy"]["customBranchPolicies"] = True
        self.assert_rejected(candidate, "custom branch policies")

    def test_rejects_self_review(self):
        candidate = evidence()
        candidate["reviewGates"][0]["principalId"] = candidate["authorization"]["dispatcherId"]
        self.assert_rejected(candidate, "independent")

    def test_rejects_missing_required_reviewer(self):
        candidate = evidence()
        candidate["reviewGates"].pop()
        self.assert_rejected(candidate, "three review gates")

    def test_rejects_malformed_required_reviewer_evidence(self):
        candidate = evidence()
        candidate["reviewGates"][0]["artifactDigest"] = "mutable"
        self.assert_rejected(candidate, "digest is malformed")

    def test_rejects_review_outside_required_rule(self):
        candidate = evidence()
        candidate["reviewGates"][1]["headTree"] = "c" * 40
        self.assert_rejected(candidate, "stale for the exact head/tree")

    def test_rejects_enabled_admin_bypass(self):
        candidate = evidence()
        candidate["authorization"]["environmentBypassed"] = "unknown"
        self.assert_rejected(candidate, "bypass state")

    def test_rejects_disabled_self_review_protection(self):
        candidate = evidence()
        candidate["reviewGates"][1]["principalId"] = candidate["reviewGates"][0]["principalId"]
        self.assert_rejected(candidate, "independent")

    def test_rejects_caller_asserted_review_authority(self):
        candidate = evidence()
        candidate["authorization"]["source"] = "caller"
        self.assert_rejected(candidate, "GitHub API evidence")

    def test_rejects_wrong_trusted_app_identity(self):
        candidate = evidence()
        candidate["reviewGates"][1]["appId"] = candidate["reviewGates"][0]["appId"]
        self.assert_rejected(candidate, "independent")

    def test_rejects_missing_check_run_identity(self):
        candidate = evidence()
        candidate["reviewGates"][0]["checkRunId"] = 0
        self.assert_rejected(candidate, "checkRunId is malformed")

    def test_rejects_replayed_patch_artifact(self):
        candidate = evidence()
        candidate["reviewGates"][2]["patchDigest"] = "sha256:" + "8" * 64
        self.assert_rejected(candidate, "patch differs")

    def test_rejects_malformed_downloaded_evidence_digest(self):
        candidate = evidence()
        candidate["reviewGates"][0]["evidenceDigest"] = "caller-asserted"
        self.assert_rejected(candidate, "evidenceDigest")

    def test_rejects_triggering_actor_as_review_principal(self):
        candidate = evidence()
        candidate["reviewGates"][0]["principalId"] = candidate["authorization"]["triggeringActorId"]
        self.assert_rejected(candidate, "independent")

    def test_rejects_unprovable_admin_bypass(self):
        candidate = evidence()
        candidate["authorization"]["bypassBasis"] = "unknown"
        self.assert_rejected(candidate, "bypass cannot be proven")

    def test_partial_failure_rolls_back_to_attempt_baseline(self):
        attempt = failed_attempt()
        preflight.validate_rollback(rollback_for(attempt), attempt)

    def test_interrupted_attempt_rolls_back_to_persisted_baseline(self):
        admitted = failed_attempt("admitted")
        admitted["runners"] = []
        admitted["previousReceiptDigest"] = None
        interrupted = failed_attempt("interrupted")
        interrupted["runners"] = []
        interrupted["previousReceiptDigest"] = preflight.receipt_digest(admitted)
        preflight.validate_attempt_revision(interrupted, admitted)
        preflight.validate_rollback(rollback_for(interrupted), interrupted)

    def test_rejects_interrupted_revision_that_changes_observed_baseline(self):
        admitted = failed_attempt("admitted")
        admitted["runners"] = []
        admitted["previousReceiptDigest"] = None
        interrupted = failed_attempt("interrupted")
        interrupted["runners"] = []
        interrupted["previousReceiptDigest"] = preflight.receipt_digest(admitted)
        interrupted["observedDeployedRelease"] = release("0.9.0", "9")
        with self.assertRaisesRegex(preflight.PreflightError, "observedDeployedRelease"):
            preflight.validate_attempt_revision(interrupted, admitted)

    def test_rejects_rollback_to_predecessor_of_attempt_baseline(self):
        attempt = failed_attempt()
        rollback = rollback_for(attempt)
        rollback["selectedRelease"] = release("0.9.0", "9")
        with self.assertRaisesRegex(preflight.PreflightError, "differs from attempt baseline"):
            preflight.validate_rollback(rollback, attempt)

    def test_rejects_rollback_with_substituted_attempt_receipt(self):
        attempt = failed_attempt()
        rollback = rollback_for(attempt)
        attempt["runners"][0]["probe"] = "passed"
        with self.assertRaisesRegex(preflight.PreflightError, "attempt digest differs"):
            preflight.validate_rollback(rollback, attempt)


if __name__ == "__main__":
    unittest.main()
