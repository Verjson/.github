#!/usr/bin/env python3
import copy
import hashlib
import os
import re
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/runner-canary.yml"
EXPECTED_SHA256 = "d91c840de787a787f5cafe559cc22fcb9dbf7a94651398d5cfa58175bd5dd8a4"
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

    def test_exit_and_signals_remove_exact_resources_and_fail_closed(self) -> None:
        script = load_workflow()["jobs"]["canary"]["steps"][0]["run"]
        def run_case(mode: str, expected_status: int, extra: dict[str, str] | None = None) -> None:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bin_dir = root / "bin"
                bin_dir.mkdir()
                log = root / "docker.log"
                ready = root / "ready"
                docker = bin_dir / "docker"
                docker.write_text(
                    "#!/bin/bash\n"
                    'printf \'%s\\n\' "$*" >>"$DOCKER_LOG"\n'
                    'cat >/dev/null || true\n'
                    'if [ "${FAIL_CURL:-}" = 1 ] && [[ "$*" == *curlimages/curl@* ]]; then exit 42; fi\n'
                    'if [ -n "${BLOCK_CLEANUP:-}" ] && [[ "$*" == *"$BLOCK_CLEANUP"* ]] && [ ! -e "$READY_FILE.blocked" ]; then\n'
                    '  : >"$READY_FILE.blocked"; : >"$READY_FILE"\n'
                    "  trap 'exit 130' INT; trap 'exit 143' TERM\n"
                    '  while :; do sleep 1; done\n'
                    'fi\n'
                    'if [[ "$*" == "container ls -a --filter name=^/runner-canary-sibling-123-1$ --format {{.Names}}" ]]; then\n'
                    '  [ "${FAIL_INVENTORY:-}" = CONTAINER ] && exit 44\n'
                    '  [ "${SURVIVE_CONTAINER:-}" = 1 ] && printf \'%s\\n\' runner-canary-sibling-123-1\n'
                    '  exit 0\nfi\n'
                    'if [[ "$*" == "network ls --filter name=^runner-canary-123-1$ --format {{.Name}}" ]]; then\n'
                    '  [ "${FAIL_INVENTORY:-}" = NETWORK ] && exit 44\n'
                    '  [ "${SURVIVE_NETWORK:-}" = 1 ] && printf \'%s\\n\' runner-canary-123-1\n'
                    '  exit 0\nfi\n'
                    'if [[ "$*" == "image ls --filter reference=runner-canary:123-1 --format {{.Repository}}:{{.Tag}}" ]]; then\n'
                    '  [ "${FAIL_INVENTORY:-}" = IMAGE ] && exit 44\n'
                    '  [ "${SURVIVE_IMAGE:-}" = 1 ] && printf \'%s\\n\' runner-canary:123-1\n'
                    '  exit 0\nfi\n'
                    'if [ "${BLOCK_BUILD:-}" = 1 ] && [[ "$*" == build* ]]; then\n'
                    '  : >"$READY_FILE"\n'
                    "  trap 'exit 130' INT\n"
                    "  trap 'exit 143' TERM\n"
                    '  while :; do sleep 1; done\n'
                    "fi\nexit 0\n",
                    encoding="utf-8",
                )
                docker.chmod(0o755)
                for name, body in {
                    "pwsh": "exit 0",
                    "gh": "printf 456",
                    "df": "if [ \"$1\" = -PB1 ]; then printf 'Filesystem 1-blocks Used Available Capacity Mounted\\nmock 1 1 11811160064 1%% /var/lib/docker\\n'; else printf 'Filesystem Inodes IUsed IFree IUse%% Mounted\\nmock 100 20 80 20%% /var/lib/docker\\n'; fi",
                }.items():
                    executable = bin_dir / name
                    executable.write_text(f"#!/bin/bash\n{body}\n", encoding="utf-8")
                    executable.chmod(0o755)
                env = {
                    **os.environ,
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "DOCKER_LOG": str(log), "READY_FILE": str(ready),
                    "RUNNER_NAME": "gha-general-8", "EXPECTED_RUNNER": "gha-general-8",
                    "RUNNER_ID": "479", "TRANSACTION_NONCE": "123e4567-e89b-42d3-a456-426614174000",
                    "RELEASE_MANIFEST": f"ghcr.io/verjson/gha-runner-release@sha256:{'a' * 64}",
                    "RELEASE_VARIANT": "pwsh", "IMAGE_DIGEST": f"ghcr.io/verjson/gha-runner@sha256:{'b' * 64}",
                    "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_REPOSITORY": "Verjson/.github",
                    "GITHUB_SHA": "c" * 40, "GITHUB_REF_NAME": "runner-canary-v1.0.0",
                    **(extra or {}),
                }
                if mode == "failure":
                    env["FAIL_CURL"] = "1"
                elif mode != "success" and not (extra or {}).get("BLOCK_CLEANUP"):
                    env["BLOCK_BUILD"] = "1"
                process = subprocess.Popen(
                    ["bash", "-c", script], cwd=root, env=env,
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, start_new_session=True,
                )
                if mode not in ("success", "failure"):
                    for _ in range(200):
                        if ready.exists():
                            break
                        time.sleep(0.01)
                    self.assertTrue(ready.exists(), "canary did not reach blocking build")
                    os.killpg(process.pid, getattr(signal, mode))
                _, stderr = process.communicate(timeout=10)
                self.assertEqual(expected_status, process.returncode, stderr)
                commands = log.read_text(encoding="utf-8")
                self.assertIn("rm -f runner-canary-sibling-123-1", commands)
                self.assertIn("container ls -a --filter name=^/runner-canary-sibling-123-1$", commands)
                self.assertIn("network rm runner-canary-123-1", commands)
                self.assertIn("network ls --filter name=^runner-canary-123-1$", commands)
                self.assertIn("image rm runner-canary:123-1", commands)
                self.assertIn("image ls --filter reference=runner-canary:123-1", commands)
                self.assertEqual(
                    (root / "runner-promotion-receipt.json").exists(),
                    mode == "success" and not extra,
                )
                self.assertFalse((root / "receipt.tmp").exists())

        for mode, expected_status in (("success", 0), ("failure", 42), ("SIGINT", 130), ("SIGTERM", 143)):
            with self.subTest(mode=mode):
                run_case(mode, expected_status)
        for survivor in ("SURVIVE_CONTAINER", "SURVIVE_NETWORK", "SURVIVE_IMAGE"):
            for mode, expected_status in (("success", 1), ("failure", 42), ("SIGINT", 130), ("SIGTERM", 143)):
                with self.subTest(survivor=survivor, mode=mode):
                    run_case(mode, expected_status, {survivor: "1"})
        for resource in ("CONTAINER", "NETWORK", "IMAGE"):
            with self.subTest(inventory_failure=resource):
                run_case("success", 1, {"FAIL_INVENTORY": resource})
        for blocked in (
            "rm -f runner-canary-sibling-123-1",
            "container ls -a --filter name=^/runner-canary-sibling-123-1$",
            "image ls --filter reference=runner-canary:123-1",
        ):
            for mode, expected_status in (("SIGINT", 130), ("SIGTERM", 143)):
                with self.subTest(blocked_cleanup=blocked, mode=mode):
                    run_case(mode, expected_status, {"BLOCK_CLEANUP": blocked})


if __name__ == "__main__":
    unittest.main()
