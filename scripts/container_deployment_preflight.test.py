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
    return {
        "defaultBranch": "main",
        "ref": "refs/heads/main",
        "environment": "production",
        "deploymentBranchPolicy": {
            "protectedBranches": True,
            "customBranchPolicies": False,
        },
        "preventSelfReview": True,
        "canAdminsBypass": False,
        "requiredReviewers": [{"type": "Team", "id": 42}],
        "dispatcher": "release-operator",
        "reviewer": "release-approver",
        "reviewerSatisfiedRequiredRule": True,
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
        preflight.validate_authorization(evidence())

    def test_rejects_non_default_branch(self):
        candidate = evidence()
        candidate["ref"] = "refs/heads/release"
        self.assert_rejected(candidate, "exact default branch")

    def test_rejects_custom_branch_admission(self):
        candidate = evidence()
        candidate["deploymentBranchPolicy"]["customBranchPolicies"] = True
        self.assert_rejected(candidate, "custom branch policies")

    def test_rejects_self_review(self):
        candidate = evidence()
        candidate["reviewer"] = candidate["dispatcher"]
        self.assert_rejected(candidate, "differ from dispatcher")

    def test_rejects_missing_required_reviewer(self):
        candidate = evidence()
        candidate["requiredReviewers"] = []
        self.assert_rejected(candidate, "required reviewer")

    def test_rejects_malformed_required_reviewer_evidence(self):
        candidate = evidence()
        candidate["requiredReviewers"] = [{"type": "Team", "id": 0}]
        self.assert_rejected(candidate, "evidence is malformed")

    def test_rejects_review_outside_required_rule(self):
        candidate = evidence()
        candidate["reviewerSatisfiedRequiredRule"] = False
        self.assert_rejected(candidate, "required reviewer rule")

    def test_rejects_enabled_admin_bypass(self):
        candidate = evidence()
        candidate["canAdminsBypass"] = True
        self.assert_rejected(candidate, "administrator bypass")

    def test_rejects_disabled_self_review_protection(self):
        candidate = evidence()
        candidate["preventSelfReview"] = False
        self.assert_rejected(candidate, "prevent self review")

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
