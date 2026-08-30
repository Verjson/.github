#!/usr/bin/env python3
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
LEGACY = ROOT / ".github/workflows/node-ci.yml"
PROTECTED = ROOT / ".github/workflows/node-ci-protected.yml"
HEAD = "a" * 40
LEGACY_SHA256 = "3901b24fee45e2dc839ebd13b2e461fcde961355cbb512b7b18c5687a5764fc5"


class RequiredWorkflowIdentityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.legacy_bytes = subprocess.check_output(
            ["git", "show", "HEAD:.github/workflows/node-ci.yml"], cwd=ROOT
        )
        cls.workflow = yaml.safe_load(PROTECTED.read_text(encoding="utf-8"))
        cls.verifiers = [step for job in cls.workflow["jobs"].values()
                         for step in job.get("steps", [])
                         if step.get("name") == "Revalidate protected pull-request identity"]

    def run_verifier(self, step, *, run_record=None, pr_record=None, token="bounded-token"):
        with tempfile.TemporaryDirectory() as directory:
            fake_gh = Path(directory) / "gh"
            fake_gh.write_text(
                "#!/bin/sh\n[ \"${GH_TOKEN:-}\" = bounded-token ] || exit 70\n"
                "case \"$*\" in\n *actions/runs/2468*) printf '%s\\n' \"$RUN_RECORD\" ;;\n"
                " *pulls/114*) printf '%s\\n' \"$PR_RECORD\" ;;\n *) exit 71 ;;\nesac\n",
                encoding="utf-8")
            fake_gh.chmod(0o755)
            environment = {**os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                           "GH_TOKEN": token, "ADMITTED_EVENT": "pull_request",
                           "ADMITTED_HEAD_REPOSITORY": "Verjson/repository",
                           "ADMITTED_HEAD_SHA": HEAD, "REPOSITORY": "Verjson/repository",
                           "RUN_ID": "2468",
                           "RUN_RECORD": run_record if run_record is not None else f"pull_request\t{HEAD}\t1\t114",
                           "PR_RECORD": pr_record if pr_record is not None else f"open\tVerjson/repository\t{HEAD}"}
            return subprocess.run(["/usr/bin/bash", "-c", step["run"]], env=environment,
                                  capture_output=True).returncode

    def test_generator_is_exact_and_legacy_workflow_is_byte_identical(self):
        self.assertEqual(self.legacy_bytes, LEGACY.read_bytes())
        self.assertEqual(LEGACY_SHA256, hashlib.sha256(LEGACY.read_bytes()).hexdigest())
        before = PROTECTED.read_bytes()
        subprocess.run(["python3", "scripts/gen-node-ci-protected.py"], cwd=ROOT, check=True)
        self.assertEqual(before, PROTECTED.read_bytes())

    def test_contract_requires_scopes_and_explicit_nonambient_token(self):
        self.assertEqual(7, len(self.verifiers))
        for step in self.verifiers:
            self.assertEqual("${{ github.token }}", step["env"].get("GH_TOKEN"))
            self.assertEqual(0, self.run_verifier(step))
            self.assertNotEqual(0, self.run_verifier(step, token="ambient-token"))
        for name in ("acquire-secretless-dependencies", "build-test"):
            permissions = self.workflow["jobs"][name]["permissions"]
            self.assertEqual("read", permissions["actions"])
            self.assertEqual("read", permissions["pull-requests"])

    def test_protected_variant_rejects_every_non_pr_secretless_mode(self):
        acquisition = self.workflow["jobs"]["acquire-secretless-dependencies"]
        self.assertEqual("needs.eligibility.outputs.should-run != 'false'", acquisition["if"])
        boundary = next(step for step in acquisition["steps"]
                        if step.get("name") == "Enforce the secretless event boundary")
        base = {**os.environ, "APPROVED_INTERNAL_PACKAGES": "@verjson/package",
                "EVENT_NAME": "pull_request", "HEAD_REPOSITORY": "Verjson/repository",
                "NODE_AUTH_TOKEN": "package-token", "REPOSITORY": "Verjson/repository",
                "SCHEMA_DIR": ""}
        for secretless_pr, trusted_ref, expected in (
            ("true", "false", 0), ("false", "false", 1),
            ("false", "true", 1), ("true", "true", 1)):
            result = subprocess.run(
                ["/usr/bin/bash", "-c", boundary["run"]],
                env={**base, "SECRETLESS_PR": secretless_pr,
                     "SECRETLESS_TRUSTED_REF": trusted_ref}, capture_output=True)
            self.assertEqual(expected, int(result.returncode != 0))

    def test_malformed_ambiguous_foreign_stale_and_partial_records_fail_closed(self):
        cases = ((f"pull_request\t{HEAD}\t0\t", None),
                 (f"pull_request\t{HEAD}\t2\t114", None),
                 (f"push\t{HEAD}\t1\t114", None),
                 (f"pull_request\t{'b' * 40}\t1\t114", None),
                 (f"pull_request\t{HEAD}\t1\tbad", None),
                 (None, f"closed\tVerjson/repository\t{HEAD}"),
                 (None, f"open\tattacker/fork\t{HEAD}"),
                 (None, f"open\tVerjson/repository\t{'c' * 40}"), ("", ""))
        for run_record, pr_record in cases:
            with self.subTest(run_record=run_record, pr_record=pr_record):
                self.assertNotEqual(0, self.run_verifier(self.verifiers[0],
                                                        run_record=run_record, pr_record=pr_record))

    def test_close_and_synchronize_between_boundaries_are_rejected(self):
        self.assertEqual(0, self.run_verifier(self.verifiers[0]))
        changed = "d" * 40
        for execution_verifier in self.verifiers[1:]:
            self.assertNotEqual(0, self.run_verifier(
                execution_verifier, pr_record=f"closed\tVerjson/repository\t{HEAD}"))
            self.assertNotEqual(0, self.run_verifier(
                execution_verifier, run_record=f"pull_request\t{changed}\t1\t114",
                pr_record=f"open\tVerjson/repository\t{changed}"))

    def test_shared_script_immediately_guards_both_boundaries_and_checkout(self):
        self.assertTrue(all(step["run"] == self.verifiers[0]["run"]
                            for step in self.verifiers[1:]))
        acquisition = self.workflow["jobs"]["acquire-secretless-dependencies"]["steps"]
        build = self.workflow["jobs"]["build-test"]["steps"]
        first = next(i for i, step in enumerate(acquisition)
                     if step.get("name") == "Revalidate protected pull-request identity")
        self.assertTrue(str(acquisition[first - 1].get("uses", "")).startswith("actions/checkout@"))
        self.assertEqual("Reject consumer-controlled npm configuration", acquisition[first + 1]["name"])
        acquisition_verifiers = [i for i, step in enumerate(acquisition)
                                 if step.get("name") == "Revalidate protected pull-request identity"]
        self.assertEqual(3, len(acquisition_verifiers))
        auxiliary_guard, populate_guard = acquisition_verifiers[1:]
        self.assertEqual("inputs.secretless-auxiliary-source != ''",
                         acquisition[auxiliary_guard]["if"])
        self.assertEqual("Acquire immutable auxiliary source",
                         acquisition[auxiliary_guard + 1]["name"])
        self.assertNotIn("if", acquisition[populate_guard])
        self.assertEqual("Populate verified private dependency cache",
                         acquisition[populate_guard + 1]["name"])
        guarded_routes = (
            "Rebuild exact approved lifecycle packages without credentials",
            "Run exact credentialless consumer script plan",
            None,
        )
        verifier_indexes = [i for i, step in enumerate(build)
                            if step.get("name") == "Revalidate protected pull-request identity"]
        self.assertEqual(4, len(verifier_indexes))
        self.assertIn("inputs.secretless-rebuild-packages != ''",
                      build[verifier_indexes[0]]["if"])
        self.assertIn("inputs.secretless-ci-script-plan != ''",
                      build[verifier_indexes[1]]["if"])
        self.assertIn("inputs.secretless-ci-script-plan == ''",
                      build[verifier_indexes[2]]["if"])
        for verifier_index in verifier_indexes:
            self.assertEqual(build[verifier_index]["if"],
                             build[verifier_index + 1]["if"])
        compatibility_condition = (
            "needs.eligibility.outputs.should-run != 'false' && "
            "(inputs.secretless-pr || inputs.secretless-trusted-ref) && "
            "inputs.secretless-compatibility-ranges != ''"
        )
        self.assertEqual(compatibility_condition, build[verifier_indexes[3]]["if"])
        self.assertEqual(guarded_routes[0], build[verifier_indexes[0] + 1]["name"])
        self.assertEqual(guarded_routes[1], build[verifier_indexes[1] + 1]["name"])
        grouped = build[verifier_indexes[2] + 1]
        self.assertEqual("Run default build, typecheck, test, and lint plan", grouped["name"])
        self.assertEqual(build[verifier_indexes[2]]["if"], grouped["if"])
        self.assertEqual(
            ["npm run build", "npm run typecheck --if-present", "npm test",
             "npm run lint --if-present"], grouped["run"].splitlines())
        self.assertEqual("Run runtime-resolved compatibility lanes without credentials",
                         build[verifier_indexes[3] + 1]["name"])
        self.assertEqual(build[verifier_indexes[3]]["if"],
                         build[verifier_indexes[3] + 1]["if"])
        for steps in (acquisition, build):
            checkout = next(step for step in steps
                            if str(step.get("uses", "")).startswith("actions/checkout@"))
            self.assertEqual("${{ inputs.head-sha }}", checkout["with"]["ref"])


if __name__ == "__main__":
    unittest.main()
