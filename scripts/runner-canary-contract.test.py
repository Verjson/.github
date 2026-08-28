#!/usr/bin/env python3
import copy
import hashlib
import re
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/runner-canary.yml"
EXPECTED_SHA256 = "0d9d0bbcce80a1a43686131d3538fc416ef281b90a9b4a0708cd7e2067517b7a"
IMMUTABLE_TAG = re.compile(r"^runner-canary-v[0-9]+\.[0-9]+\.[0-9]+$")


def load_workflow(path: Path = WORKFLOW) -> dict:
    with path.open(encoding="utf-8") as source:
        return yaml.safe_load(source)


def validate(workflow: dict) -> None:
    dispatch = workflow.get(True, workflow.get("on", {})).get("workflow_dispatch", {})
    expected_inputs = {
        "runner_name", "runner_id", "runner_label", "transaction_nonce",
        "release_manifest", "release_variant", "image_digest",
    }
    if set(dispatch.get("inputs", {})) != expected_inputs:
        raise AssertionError("dispatch inputs do not exactly bind the runner transaction")
    if not all(spec == {"required": True, "type": "string"} for spec in dispatch["inputs"].values()):
        raise AssertionError("every runner transaction input must be a required string")
    if workflow.get("permissions") != {"actions": "read", "contents": "read"}:
        raise AssertionError("workflow permissions exceed the receipt boundary")

    canary = workflow["jobs"]["canary"]
    if canary.get("environment") != "runner-fleet-production":
        raise AssertionError("canary must use the protected fleet environment")
    if canary.get("runs-on") != ["self-hosted", "${{ inputs.runner_label }}"]:
        raise AssertionError("canary must route only through the transaction-unique label")
    if canary.get("timeout-minutes") != 30:
        raise AssertionError("canary runtime must remain bounded")
    postgres = canary["services"]["postgres"]
    if not re.fullmatch(r"postgres@sha256:[0-9a-f]{64}", postgres.get("image", "")):
        raise AssertionError("database service image must be digest pinned")

    run_steps = [step for step in canary["steps"] if "run" in step]
    if len(run_steps) != 1:
        raise AssertionError("canary must have exactly one admission script")
    script = run_steps[0]["run"]
    required_guards = (
        'test "$RUNNER_NAME" = "$EXPECTED_RUNNER"', "pwsh --version",
        "postgres@sha256:", "docker network create", "curlimages/curl@sha256:",
        "nginx@sha256:", "FROM alpine@sha256:", "trap cleanup EXIT",
        "trap 'interrupted 130' INT", "trap 'interrupted 143' TERM",
        "trap 'record_cleanup_signal 130' INT", "trap 'record_cleanup_signal 143' TERM",
        "trap '' INT TERM", "final_signal_status=$cleanup_signal_status",
        "docker rm -f", "docker network rm", 'docker image rm "$build_image"',
        'docker container ls -a --filter "name=^/${sibling}$"',
        'docker network ls --filter "name=^${network}$"',
        'docker image ls --filter "reference=${build_image}"',
        'if [ "$final_status" -ne 0 ]; then',
        'test "$free_bytes" -ge 10737418240', 'test "$free_inodes" -ge 10',
        'contract:"verjson-runner-promotion/2"',
        '--arg workflowRef "$GITHUB_REF_NAME"',
        'headBranch:$workflowRef',
        'workflowPath:".github/workflows/runner-canary.yml"',
        'artifact:{name:"runner-promotion-receipt",contentDigest:""}',
    )
    missing = [guard for guard in required_guards if guard not in script]
    if missing:
        raise AssertionError(f"canary admission guards missing: {missing}")
    subprocess.run(["bash", "-n"], input=script, text=True, check=True)

    upload_steps = [step for step in canary["steps"] if "uses" in step]
    if len(upload_steps) != 1:
        raise AssertionError("canary must publish exactly one receipt artifact")
    upload = upload_steps[0]
    if not re.fullmatch(r"actions/upload-artifact@[0-9a-f]{40}", upload["uses"]):
        raise AssertionError("receipt upload action must be commit pinned")
    if upload.get("with") != {
        "name": "runner-promotion-receipt", "path": "runner-promotion-receipt.json",
        "if-no-files-found": "error", "retention-days": 7,
    }:
        raise AssertionError("receipt artifact identity or retention widened")


class RunnerCanaryContractTests(unittest.TestCase):
    def test_published_workflow_is_exact_reviewed_cli_contract(self) -> None:
        self.assertEqual(EXPECTED_SHA256, hashlib.sha256(WORKFLOW.read_bytes()).hexdigest())
        validate(load_workflow())

    def test_mutable_dependencies_and_target_widening_fail_closed(self) -> None:
        original = load_workflow()
        mutations = []
        mutable_service = copy.deepcopy(original)
        mutable_service["jobs"]["canary"]["services"]["postgres"]["image"] = "postgres:17-alpine"
        mutations.append(mutable_service)
        widened_target = copy.deepcopy(original)
        widened_target["jobs"]["canary"]["runs-on"] = ["self-hosted", "general"]
        mutations.append(widened_target)
        mutable_action = copy.deepcopy(original)
        mutable_action["jobs"]["canary"]["steps"][-1]["uses"] = "actions/upload-artifact@v4"
        mutations.append(mutable_action)
        missing_identity = copy.deepcopy(original)
        missing_identity["jobs"]["canary"]["steps"][0]["run"] = missing_identity["jobs"]["canary"]["steps"][0]["run"].replace(
            'test "$RUNNER_NAME" = "$EXPECTED_RUNNER"\n', ""
        )
        mutations.append(missing_identity)
        for index, mutation in enumerate(mutations):
            with self.subTest(mutation=index), self.assertRaises(AssertionError):
                validate(mutation)

    def test_publication_ref_is_semver_and_not_a_branch_or_moving_major(self) -> None:
        self.assertTrue(IMMUTABLE_TAG.fullmatch("runner-canary-v1.0.0"))
        for rejected in ("main", "runner-canary-v1", "runner-canary-v1.0", "runner-canary-v1.0.0-rc.1"):
            with self.subTest(ref=rejected):
                self.assertIsNone(IMMUTABLE_TAG.fullmatch(rejected))

    def test_capacity_probe_keeps_the_reviewed_trust_boundary(self) -> None:
        script = load_workflow()["jobs"]["canary"]["steps"][0]["run"]
        required = (
            "mktemp -d -p",
            "verjson.runner-canary-owner",
            "timeout --signal=KILL 30s",
            "--network none",
            "--read-only --cap-drop ALL",
            "stable_empty",
            "docker container ls -a --no-trunc",
            "docker rm -f \"$capacity_id\"",
            "test \"$free_bytes\" -ge 10737418240",
            "test \"$free_inodes\" -ge 10",
        )
        for marker in required:
            with self.subTest(marker=marker):
                self.assertIn(marker, script)
        self.assertNotIn("/var/lib/docker", script)
        self.assertNotIn("type=bind", script)

if __name__ == "__main__":
    unittest.main()
