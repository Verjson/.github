#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

import yaml

ROOT = Path(__file__).resolve().parents[2]
LEGACY = ROOT / ".github/workflows/node-ci.yml"
PROTECTED = ROOT / ".github/workflows/node-ci-protected.yml"
HEAD = "a" * 40
LEGACY_SHA256 = "1d2a26fc6a19ee13030fa3a1dace585cd1dcd8ce4da2b5f60f51cec0281bdc6a"


class RequiredWorkflowIdentityTest(unittest.TestCase):
    credential_keys = (
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "NODE_AUTH_TOKEN",
        "NPM_TOKEN",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "AZURE_CREDENTIALS",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
        "ACTIONS_ID_TOKEN_REQUEST_URL",
    )

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

        nonempty_schema = subprocess.run(
            ["/usr/bin/bash", "-c", boundary["run"]],
            env={
                **base,
                "SCHEMA_DIR": "candidate-schema",
                "SECRETLESS_PR": "true",
                "SECRETLESS_TRUSTED_REF": "false",
            },
            capture_output=True,
        )
        self.assertNotEqual(0, nonempty_schema.returncode)
        self.assertNotIn(
            "Install schema submodule deps",
            {
                step.get("name")
                for step in self.workflow["jobs"]["build-test"]["steps"]
            },
        )

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
             "npm run lint --if-present"], grouped["run"].splitlines()[1:])
        self.assertEqual("Run runtime-resolved compatibility lanes without credentials",
                         build[verifier_indexes[3] + 1]["name"])
        self.assertEqual(build[verifier_indexes[3]]["if"],
                         build[verifier_indexes[3] + 1]["if"])
        for steps in (acquisition, build):
            checkout = next(step for step in steps
                            if str(step.get("uses", "")).startswith("actions/checkout@"))
            self.assertEqual("${{ inputs.head-sha }}", checkout["with"]["ref"])

    def test_candidate_routes_remove_credential_keys_instead_of_emptying_them(self):
        routes = {
            "Rebuild exact approved lifecycle packages without credentials",
            "Run exact credentialless consumer script plan",
            "Run default build, typecheck, test, and lint plan",
            "Run runtime-resolved compatibility lanes without credentials",
        }
        steps = {
            step.get("name"): step
            for step in self.workflow["jobs"]["build-test"]["steps"]
            if step.get("name") in routes
        }
        self.assertEqual(routes, set(steps))
        expected_scrub = "unset -v " + " ".join(self.credential_keys)
        probe = (
            "node -e 'const keys="
            + json.dumps(self.credential_keys)
            + "; if (keys.some((key) => Object.hasOwn(process.env, key))) process.exit(1)'"
        )
        populated = {**os.environ, **dict.fromkeys(self.credential_keys, "sensitive")}
        empty_string_mutation = "export " + " ".join(
            f"{key}=''" for key in self.credential_keys
        )

        for route, step in steps.items():
            with self.subTest(route=route):
                self.assertEqual(expected_scrub, step["run"].splitlines()[0])
                self.assertEqual(
                    0,
                    subprocess.run(
                        ["/usr/bin/bash", "-c", f"{expected_scrub}\n{probe}"],
                        env=populated,
                    ).returncode,
                )
                self.assertNotEqual(
                    0,
                    subprocess.run(
                        ["/usr/bin/bash", "-c", f"{empty_string_mutation}\n{probe}"],
                        env=populated,
                    ).returncode,
                )


    def candidate_plan_step(self):
        return next(
            step
            for step in self.workflow["jobs"]["build-test"]["steps"]
            if step.get("name") == "Run exact credentialless consumer script plan"
        )

    def run_candidate_plan(
        self,
        cache_setup,
        npm_body,
        *,
        run=None,
        environment_updates=None,
        workspace_in_runner_temp=False,
        shadow_candidate_path=False,
        tool_root_mode=0o755,
        tool_bin_mode=0o755,
        workspace_symlink=False,
        swap_tool_prefix=False,
        root_owned_tools=True,
        pwsh_fixture=None,
        mutate_tool_in_place=False,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner_temp = root / "runner-temp"
            runner_temp.mkdir()
            baseline = runner_temp / "baseline"
            baseline.mkdir()
            workspace_parent = runner_temp if workspace_in_runner_temp else root
            workspace = workspace_parent / "workspace"
            if workspace_symlink:
                workspace_real = workspace_parent / "workspace-real"
                workspace_real.mkdir()
                workspace.symlink_to(workspace_real, target_is_directory=True)
            else:
                workspace.mkdir()
            cache_setup(baseline)
            (workspace / "package.json").write_text(
                json.dumps({"scripts": {"first": "true", "second": "true"}}),
                encoding="utf-8",
            )
            tool_bin = root / "tool" / "bin"
            tool_bin.mkdir(parents=True)
            tool_bin.parent.chmod(tool_root_mode)
            tool_bin.chmod(tool_bin_mode)
            npm = tool_bin / "npm"
            npm.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + npm_body, encoding="utf-8")
            npm.chmod(0o755)
            node = tool_bin / "node"
            node.write_text("#!/usr/bin/env bash\nexec /usr/bin/node \"$@\"\n", encoding="utf-8")
            node.chmod(0o755)
            tool_package = tool_bin.parent / "lib" / "node_modules" / "npm" / "package.json"
            tool_package.parent.mkdir(parents=True)
            tool_package.write_text('{"name":"npm"}\n', encoding="utf-8")
            tool_package.chmod(0o644)
            for directory_name, _, _ in os.walk(tool_bin.parent):
                Path(directory_name).chmod(0o755)
            tool_bin.parent.chmod(tool_root_mode)
            tool_bin.chmod(tool_bin_mode)
            if root_owned_tools:
                subprocess.run(
                    ["sudo", "-n", "chown", "-R", "0:0", str(tool_bin.parent)], check=True
                )
            fixture_roots = []
            if pwsh_fixture is not None:
                fixture_usr = root / "usr"
                fixture_opt = root / "opt"
                fixture_link = fixture_usr / "bin" / "pwsh"
                fixture_link.parent.mkdir(parents=True)
                if pwsh_fixture == "valid":
                    fixture_target = fixture_opt / "microsoft" / "powershell" / "7" / "pwsh"
                else:
                    fixture_target = root / "untrusted" / "pwsh"
                fixture_target.parent.mkdir(parents=True)
                fixture_target.write_text(
                    "#!/usr/bin/env bash\nprintf verified > \"$PWD/pwsh-marker\"\n",
                    encoding="utf-8",
                )
                fixture_target.chmod(0o755)
                fixture_link.symlink_to(fixture_target)
                fixture_roots = [fixture_usr, fixture_opt, root / "untrusted"]
                for fixture_root in fixture_roots:
                    if fixture_root.exists():
                        for directory, _, _ in os.walk(fixture_root):
                            Path(directory).chmod(0o755)
                        subprocess.run(
                            ["sudo", "-n", "chown", "-R", "0:0", str(fixture_root)], check=True
                        )
            path = f"{tool_bin}:{os.environ['PATH']}"
            if shadow_candidate_path:
                shadow_bin = workspace / "bin"
                shadow_bin.mkdir()
                shadow_npm = shadow_bin / "npm"
                shadow_npm.write_text("#!/usr/bin/env bash\nexit 91\n", encoding="utf-8")
                shadow_npm.chmod(0o755)
                path = f"{shadow_bin}:{path}"
            env = {
                **os.environ,
                "PATH": path,
                "RUNNER_TEMP": str(runner_temp),
                "CI_SCRIPT_PLAN": json.dumps(["first", "second"]),
                "CANDIDATE_CACHE_ROOT": str(runner_temp / "verjson-candidate-caches-test"),
                "npm_config_cache": str(baseline),
                "RUNNER_TOOL_CACHE": str(tool_bin.parent),
                "PWD": str(workspace),
            }
            env.update(environment_updates or {})
            env = {
                name: (
                    str(workspace)
                    if value == "WORKSPACE"
                    else str(tool_bin.parent)
                    if value == "TOOL_ROOT"
                    else value
                )
                for name, value in env.items()
            }
            swap_thread = None
            if swap_tool_prefix:
                def replace_tool_prefix():
                    cache_root = Path(env["CANDIDATE_CACHE_ROOT"])
                    for _ in range(10000):
                        if cache_root.exists():
                            original = tool_bin.parent.with_name("tool-original")
                            tool_bin.parent.rename(original)
                            replacement_bin = tool_bin.parent / "bin"
                            replacement_bin.mkdir(parents=True)
                            replacement_bin.parent.chmod(0o755)
                            replacement_npm = replacement_bin / "npm"
                            replacement_npm.write_text(
                                "#!/usr/bin/env bash\nexit 91\n", encoding="utf-8"
                            )
                            replacement_npm.chmod(0o755)
                            replacement_node = replacement_bin / "node"
                            replacement_node.write_text(
                                "#!/usr/bin/env bash\nexit 91\n", encoding="utf-8"
                            )
                            replacement_node.chmod(0o755)
                            return
                        time.sleep(0.0001)
                swap_thread = threading.Thread(target=replace_tool_prefix)
                swap_thread.start()
            mutation_thread = None
            if mutate_tool_in_place:
                def mutate_selected_executable():
                    with npm.open("a", encoding="utf-8") as stream:
                        stream.write("\nexit 91\n")
                    with tool_package.open("a", encoding="utf-8") as stream:
                        stream.write("{}\n")
                mutation_thread = threading.Thread(target=mutate_selected_executable)
                mutation_thread.start()
            candidate_run = run or self.candidate_plan_step()["run"]
            if pwsh_fixture is not None:
                candidate_run = candidate_run.replace(
                    'Path("/usr/bin/pwsh")', f'Path("{fixture_link}")'
                ).replace(
                    'Path("/opt/microsoft/powershell")',
                    f'Path("{fixture_opt / "microsoft" / "powershell"}")',
                ).replace(
                    'Path("/usr"), system_candidate',
                    f'Path("{fixture_usr}"), system_candidate',
                ).replace('Path("/opt")', f'Path("{fixture_opt}")').replace(
                    'is_relative_to("/opt/microsoft/powershell")',
                    f'is_relative_to("{fixture_opt / "microsoft" / "powershell"}")',
                )
            result = subprocess.run(
                ["/usr/bin/bash", "-c", candidate_run],
                cwd=workspace,
                env=env,
                capture_output=True,
                text=True,
            )
            if swap_thread is not None:
                swap_thread.join(timeout=5)
                self.assertFalse(swap_thread.is_alive())
            if mutation_thread is not None:
                mutation_thread.join(timeout=5)
                self.assertFalse(mutation_thread.is_alive())
            remaining = [path.name for path in runner_temp.glob("verjson-candidate-caches-*")]
            if root_owned_tools:
                for owned_tool_root in [*root.glob("tool*"), *fixture_roots]:
                    if not owned_tool_root.exists():
                        continue
                    subprocess.run(
                        [
                            "sudo",
                            "-n",
                            "chown",
                            "-R",
                            f"{os.getuid()}:{os.getgid()}",
                            str(owned_tool_root),
                        ],
                        check=True,
                    )
            return result, remaining

    def test_candidate_mount_paths_reject_overlap_and_noncanonical_aliases(self):
        cache_setup = lambda baseline: (baseline / "blob").write_text(
            "verified", encoding="utf-8"
        )
        cases = (
            ("workspace-runner-temp", {}, True),
            ("baseline-root", {"CANDIDATE_CACHE_ROOT": "BASELINE"}, False),
            ("shared-service-network", {"DB_PORT": "5432"}, False),
        )
        for name, updates, nested_workspace in cases:
            if updates.get("CANDIDATE_CACHE_ROOT") == "BASELINE":
                with tempfile.TemporaryDirectory() as directory:
                    runner_temp = Path(directory) / "runner-temp"
                    runner_temp.mkdir()
                    baseline = runner_temp / "baseline"
                    baseline.mkdir()
                    (baseline / "blob").write_text("verified", encoding="utf-8")
                    run = self.candidate_plan_step()["run"]
                    result = subprocess.run(
                        ["/usr/bin/bash", "-c", run],
                        cwd=Path(directory),
                        env={
                            **os.environ,
                            "RUNNER_TEMP": str(runner_temp),
                            "CI_SCRIPT_PLAN": '["first"]',
                            "CANDIDATE_CACHE_ROOT": str(baseline),
                            "npm_config_cache": str(baseline),
                        },
                        capture_output=True,
                    )
                    self.assertNotEqual(0, result.returncode)
                continue
            result, remaining = self.run_candidate_plan(
                cache_setup,
                "exit 0\n",
                environment_updates=updates,
                workspace_in_runner_temp=nested_workspace,
            )
            with self.subTest(case=name):
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], remaining)

    def test_candidate_path_shadow_cannot_replace_setup_node_tools(self):
        result, remaining = self.run_candidate_plan(
            lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
            "exit 0\n",
            shadow_candidate_path=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], remaining)

    def test_trusted_tool_root_rejects_workspace_equality_and_writable_mode(self):
        cache_setup = lambda baseline: (baseline / "blob").write_text(
            "verified", encoding="utf-8"
        )
        equal_result, _ = self.run_candidate_plan(
            cache_setup,
            "exit 0\n",
            environment_updates={"RUNNER_TOOL_CACHE": "WORKSPACE"},
        )
        writable_result, _ = self.run_candidate_plan(
            cache_setup,
            "exit 0\n",
            tool_root_mode=0o775,
        )
        self.assertNotEqual(0, equal_result.returncode)
        self.assertNotEqual(0, writable_result.returncode)

    def test_nested_writable_tool_directory_rejects_replacement_executable(self):
        result, remaining = self.run_candidate_plan(
            lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
            "exit 91\n",
            tool_bin_mode=0o777,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], remaining)

    def test_runner_owned_tool_and_in_place_executable_mutation_are_rejected(self):
        result, remaining = self.run_candidate_plan(
            lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
            "exit 0\n",
            root_owned_tools=False,
            mutate_tool_in_place=True,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], remaining)

    def test_tool_prefix_swap_between_validation_and_bind_fails_closed(self):
        result, remaining = self.run_candidate_plan(
            lambda baseline: (baseline / "blob").write_bytes(b"x" * (32 * 1024 * 1024)),
            "exit 0\n",
            swap_tool_prefix=True,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], remaining)

    def test_lexical_workspace_symlink_is_rejected(self):
        result, remaining = self.run_candidate_plan(
            lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
            "exit 0\n",
            workspace_symlink=True,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], remaining)

    def test_pwsh_accepts_only_verified_microsoft_runtime_contract(self):
        run = self.candidate_plan_step()["run"]
        self.assertIn('Path("/usr/bin/pwsh")', run)
        self.assertIn('Path("/opt/microsoft/powershell")', run)
        self.assertIn('"pwsh resolved runtime"', run)
        self.assertIn("system_metadata.st_uid != 0", run)

        valid, _ = self.run_candidate_plan(
            lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
            "pwsh\ntest -f pwsh-marker\n",
            pwsh_fixture="valid",
        )
        invalid, _ = self.run_candidate_plan(
            lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
            "exit 0\n",
            pwsh_fixture="invalid",
        )
        self.assertEqual(0, valid.returncode, valid.stderr)
        self.assertNotEqual(0, invalid.returncode)
    def test_each_candidate_script_receives_a_fresh_verified_cache_copy(self):
        for attempt in range(2):
            result, remaining = self.run_candidate_plan(
                lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
                """case "$2" in
first) rm -f "$NPM_CONFIG_CACHE/blob" ;;
second) [ "$(cat "$NPM_CONFIG_CACHE/blob")" = verified ] ;;
esac
[ "$NPM_CONFIG_CACHE" = "$npm_config_cache" ]
[ ! -e "$RUNNER_TEMP/baseline/blob" ]
if mv "$CANDIDATE_CACHE_ROOT" "$CANDIDATE_CACHE_ROOT-renamed" 2>/dev/null; then exit 92; fi
[ ! -e /run/docker.sock ]
[ ! -e /var/run/docker.sock ]
[ ! -e /root ]
[ ! -e "$RUNNER_TEMP/baseline" ]
python3 - <<'PY'
import socket
for endpoint in (("127.0.0.1", 22), ("169.254.169.254", 80)):
    probe = socket.socket()
    probe.settimeout(0.1)
    try:
        probe.connect(endpoint)
    except OSError:
        pass
    else:
        raise SystemExit(f"unexpected network reachability: {{endpoint}}")
    finally:
        probe.close()
PY
""",
            )
            with self.subTest(attempt=attempt):
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual([], remaining)

        steps = self.workflow["jobs"]["build-test"]["steps"]
        plan_index = steps.index(self.candidate_plan_step())
        cleanup = steps[plan_index + 1]
        self.assertEqual("Remove isolated candidate runtime caches", cleanup["name"])
        self.assertTrue(cleanup["if"].startswith("always() && "))
        self.assertIn('rm -rf -- "$CANDIDATE_CACHE_ROOT"', cleanup["run"])

    def marked_processes(self, marker):
        matches = []
        for command_line in Path("/proc").glob("[0-9]*/cmdline"):
            try:
                arguments = command_line.read_bytes().split(b"\0")
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
            if marker.encode() in arguments:
                matches.append(command_line.parent.name)
        return matches

    def test_success_and_failure_extinguish_background_and_setsid_descendants(self):
        for status in (0, 23):
            marker = f"verjson-cache-descendant-{uuid.uuid4().hex}"
            body = (
                f"setsid bash -c 'exec -a {marker} sleep 300' >/dev/null 2>&1 &\n"
                f"exit {status}\n"
            )
            result, remaining = self.run_candidate_plan(
                lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
                body,
            )
            with self.subTest(status=status):
                self.assertEqual(status != 0, result.returncode != 0)
                self.assertEqual([], remaining)
                self.assertEqual([], self.marked_processes(marker))

    def test_cache_inventory_rejects_symlinks_special_files_and_bounds(self):
        def symlink(baseline):
            (baseline / "link").symlink_to("outside")

        def special(baseline):
            os.mkfifo(baseline / "fifo")

        def too_many(baseline):
            for index in range(3):
                (baseline / str(index)).write_text("x", encoding="utf-8")

        def too_large(baseline):
            (baseline / "large").write_text("0123456789", encoding="utf-8")

        cases = (
            ("symlink", symlink, None),
            ("special", special, None),
            ("count", too_many, ("max_cache_files = 4096", "max_cache_files = 2")),
            ("bytes", too_large, ("max_cache_bytes = 268435456", "max_cache_bytes = 4")),
        )
        for name, setup, replacement in cases:
            run = self.candidate_plan_step()["run"]
            if replacement:
                run = run.replace(*replacement)
            with self.subTest(case=name):
                result, remaining = self.run_candidate_plan(setup, "exit 0\n", run=run)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], remaining)

    def test_failing_candidate_script_removes_isolated_cache_root(self):
        result, remaining = self.run_candidate_plan(
            lambda baseline: (baseline / "blob").write_text("verified", encoding="utf-8"),
            "exit 23\n",
        )
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], remaining)

    def test_terminated_candidate_script_removes_cache_and_child_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner_temp = root / "runner-temp"
            runner_temp.mkdir()
            baseline = runner_temp / "baseline"
            baseline.mkdir()
            workspace = root / "workspace"
            workspace.mkdir()
            (baseline / "blob").write_text("verified", encoding="utf-8")
            (workspace / "package.json").write_text(
                json.dumps({"scripts": {"first": "true"}}), encoding="utf-8"
            )
            tool_bin = root / "tool" / "bin"
            tool_bin.mkdir(parents=True)
            tool_bin.parent.chmod(0o755)
            npm = tool_bin / "npm"
            npm.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s' \"$$\" > child.pid\nwhile :; do sleep 1; done\n",
                encoding="utf-8",
            )
            npm.chmod(0o755)
            node = tool_bin / "node"
            node.write_text("#!/usr/bin/env bash\nexec /usr/bin/node \"$@\"\n", encoding="utf-8")
            node.chmod(0o755)
            subprocess.run(
                ["sudo", "-n", "chown", "-R", "0:0", str(tool_bin.parent)], check=True
            )
            process = subprocess.Popen(
                ["/usr/bin/bash", "-c", self.candidate_plan_step()["run"]],
                cwd=workspace,
                env={
                    **os.environ,
                    "PATH": f"{tool_bin}:{os.environ['PATH']}",
                    "RUNNER_TEMP": str(runner_temp),
                    "CI_SCRIPT_PLAN": '["first"]',
                    "CANDIDATE_CACHE_ROOT": str(runner_temp / "verjson-candidate-caches-test"),
                "npm_config_cache": str(baseline),
                "RUNNER_TOOL_CACHE": str(tool_bin.parent),
                },
            )
            for _ in range(100):
                if (workspace / "child.pid").exists():
                    break
                time.sleep(0.02)
            process.send_signal(signal.SIGTERM)
            self.assertNotEqual(0, process.wait(timeout=20))
            self.assertEqual([], list(runner_temp.glob("verjson-candidate-caches-*")))
            subprocess.run(
                [
                    "sudo",
                    "-n",
                    "chown",
                    "-R",
                    f"{os.getuid()}:{os.getgid()}",
                    str(tool_bin.parent),
                ],
                check=True,
            )


if __name__ == "__main__":
    unittest.main()
