#!/usr/bin/env python3

import hashlib
import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/container-candidate-publish.yml"
CANARY = ROOT / ".github/workflows/container-candidate-reusable-contract.yml"


class RetryWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.safe_load(cls.text)

    def test_retry_verifier_is_a_required_digest_bound_contract_input(self):
        retry_input = self.workflow[True]["workflow_call"]["inputs"]["retry-sha256"]
        self.assertEqual(
            retry_input,
            {
                "description": "SHA-256 of the canonical exact-SHA retry verifier",
                "required": True,
                "type": "string",
            },
        )
        self.assertEqual(self.text.count('printf \'%s  %s\\n\' "$RETRY_SHA256" "$retry" | sha256sum --check --strict'), 2)
        prepare = next(
            step
            for step in self.workflow["jobs"]["prepare"]["steps"]
            if step.get("id") == "config"
        )
        self.assertEqual(prepare["env"]["RETRY_SHA256"], "${{ inputs.retry-sha256 }}")
        self.assertIn(
            '[[ "$RETRY_SHA256" =~ ^[0-9a-f]{64}$ ]]', prepare["run"]
        )
        helper_digest = hashlib.sha256(
            (ROOT / "scripts/container_candidate_retry.py").read_bytes()
        ).hexdigest()
        canary = yaml.safe_load(CANARY.read_text(encoding="utf-8"))
        self.assertEqual(
            canary["jobs"]["publish"]["with"]["retry-sha256"], helper_digest
        )

    def test_every_builder_verifies_before_reuse_and_skips_only_the_build_and_new_attestation(self):
        for job_name in ("publish-base", "publish-derived"):
            steps = self.workflow["jobs"][job_name]["steps"]
            retry = next(step for step in steps if step.get("id") == "retry")
            build = next(step for step in steps if step.get("id") == "build")
            provenance = next(step for step in steps if step.get("id") == "provenance")
            fresh_record = next(
                step
                for step in steps
                if "commit identity already records a different digest"
                in step.get("run", "")
            )
            self.assertLess(steps.index(retry), steps.index(build))
            self.assertIn("steps.retry.outputs.reused != 'true'", build["if"])
            self.assertIn("steps.retry.outputs.reused != 'true'", provenance["if"])
            self.assertIn(
                "steps.retry.outputs.reused != 'true'", fresh_record["if"]
            )
            command = retry["run"]
            for required in (
                'commit_tag="$REPOSITORY:sha-$GITHUB_SHA"',
                '--repo "$GITHUB_REPOSITORY"',
                "--signer-workflow Verjson/.github/.github/workflows/container-candidate-publish.yml",
                '--signer-digest "$CONTRACT_REF"',
                '--source-digest "$GITHUB_SHA"',
                "--source-ref refs/heads/main",
                "python3 \"$oci\" index",
                "python3 \"$retry\" --verified-provenance",
                '--buildkit-provenance "$buildkit"',
                '--source-repository "$GITHUB_REPOSITORY"',
                '--source-commit "$GITHUB_SHA"',
            ):
                self.assertIn(required, command)
            self.assertNotIn("|| true", command)
            self.assertLess(command.index("gh attestation verify"), command.index("imagetools create -t"))

    def test_missing_or_unreadable_identity_fails_closed_and_immutable_guard_remains(self):
        self.assertEqual(self.text.count("could not prove immutable commit identity state"), 2)
        self.assertEqual(self.text.count("manifest unknown|not found"), 4)
        self.assertEqual(self.text.count("commit identity already records a different digest"), 2)
        self.assertNotRegex(
            self.text,
            re.compile(r'imagetools create -t "\$commit_tag".*\|\|'),
        )

    def test_derived_reuse_binds_the_exact_sha_base_identity(self):
        retry = next(
            step
            for step in self.workflow["jobs"]["publish-derived"]["steps"]
            if step.get("id") == "retry"
        )
        self.assertIn('"$base_repository:sha-$GITHUB_SHA"', retry["run"])
        self.assertIn('echo "base-digest=$base_digest"', retry["run"])
        self.assertIn('--base-repository "$base_repository"', retry["run"])
        self.assertIn('--base-digest "$base_digest"', retry["run"])


if __name__ == "__main__":
    unittest.main()
