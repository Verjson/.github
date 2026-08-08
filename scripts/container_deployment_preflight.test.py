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


if __name__ == "__main__":
    unittest.main()
