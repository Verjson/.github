#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/node-ci-protected.yml"
GENERATOR = ROOT / "scripts/gen-node-ci-protected.py"
BASE_SHA = "b" * 40
HEAD_SHA = "h" * 40


def load_generator():
    spec = importlib.util.spec_from_file_location("gen_node_ci_protected", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def step(name):
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for job in document["jobs"].values():
        for candidate in job.get("steps", []):
            if candidate.get("name") == name:
                return candidate
    raise AssertionError(f"workflow step not found: {name}")


def run_resolver(declaration):
    resolver = step("Resolve protected type-surface baseline from the pull-request base")
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        declaration_file = root / "declaration.json"
        declaration_file.write_text(declaration, encoding="utf-8")
        log = root / "gh.log"
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n"
            "case \"$*\" in\n"
            "  *'/pulls/42'*) printf '%s\\n' \"$BASE_SHA\" ;;\n"
            "  *\"/contents/.github/ci/type-surface-baseline.json?ref=$BASE_SHA\"*) cat \"$DECLARATION_FILE\" ;;\n"
            "  *) exit 91 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        output = root / "output"
        environment = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "ALLOW_PRERELEASE": "false",
            "BASE_SHA": BASE_SHA,
            "DECLARATION_FILE": str(declaration_file),
            "DECLARATION_PATH": ".github/ci/type-surface-baseline.json",
            "EXPECTED_PACKAGE": "@verjson/authn",
            "EXPECTED_SCRIPT": "test:type-surface-compatibility",
            "GH_LOG": str(log),
            "GITHUB_OUTPUT": str(output),
            "PULL_REQUEST_NUMBER": "42",
            "REPOSITORY": "Verjson/verjson-authn",
            "RUN_ATTEMPT": "1",
            "RUN_ID": "1001",
            "RUNNER_TEMP": str(root),
        }
        result = subprocess.run(
            ["bash", "-c", resolver["run"]],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
        output_text = output.read_text(encoding="utf-8") if output.exists() else ""
        receipt_text = ""
        if output_text:
            values = dict(line.split("=", 1) for line in output_text.splitlines())
            receipt_text = Path(values["receipt-path"]).read_text(encoding="utf-8")
        return result, calls, output_text, receipt_text


class ProtectedBaselineTest(unittest.TestCase):
    def test_generated_range_guard_accepts_stable_declarations(self):
        run = step("Validate approved internal dependency lock")["run"]
        lines = run.splitlines()
        prerelease = next(
            index for index, line in enumerate(lines)
            if "ALLOW_PRERELEASE" in line and "is_bounded_range" not in line
        )
        stable = next(
            index for index, line in enumerate(lines)
            if line.strip() == "if re.fullmatch(core_pattern, value):"
        )
        self.assertEqual(lines[prerelease].index("if"), lines[stable].index("if"))
        self.assertEqual(lines[stable + 1].strip(), "return True")
        self.assertGreater(stable, prerelease)

    def test_base_sha_is_resolved_once_and_head_or_merge_tree_cannot_supply_declaration(self):
        result, calls, output_text, receipt_text = run_resolver(
            '{"package":"@verjson/authn","version":"3.0.0","script":"test:type-surface-compatibility"}'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        pull_calls = [call for call in calls if "/pulls/" in call]
        content_calls = [call for call in calls if "/contents/" in call]
        self.assertEqual(len(pull_calls), 1)
        self.assertEqual(len(content_calls), 1)
        self.assertIn(f"ref={BASE_SHA}", content_calls[0])
        self.assertNotIn(HEAD_SHA, "\n".join(calls))
        self.assertNotIn("merge", "\n".join(calls).lower())
        values = dict(line.split("=", 1) for line in output_text.splitlines())
        self.assertEqual(
            values["compatibility-ranges"],
            '{"package":"@verjson/authn","ranges":["3.0.0"],"script":"test:type-surface-compatibility"}',
        )
        receipt = json.loads(receipt_text)
        self.assertEqual(receipt["baseSha"], BASE_SHA)
        self.assertEqual(receipt["declarationSha256"], hashlib.sha256(
            b'{"package":"@verjson/authn","version":"3.0.0","script":"test:type-surface-compatibility"}'
        ).hexdigest())

    def test_moving_base_does_not_trigger_a_second_lookup(self):
        result, calls, _, _ = run_resolver(
            '{"package":"@verjson/authn","version":"3.0.0","script":"test:type-surface-compatibility"}'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(1, sum("/pulls/" in call for call in calls))

    def test_malformed_duplicate_and_unauthorized_declarations_fail_closed(self):
        declarations = [
            "{}",
            '{"package":"@verjson/authn","package":"@attacker/pkg","version":"3.0.0","script":"test:type-surface-compatibility"}',
            '{"package":"@verjson/authz","version":"3.0.0","script":"test:type-surface-compatibility"}',
            '{"package":"@verjson/authn","version":"latest","script":"test:type-surface-compatibility"}',
            '{"package":"@verjson/authn","version":"3.0.0-rc.1","script":"test:type-surface-compatibility"}',
            '{"package":"@verjson/authn","version":"3.0.0","script":"test:other"}',
            '{"package":"@verjson/authn","version":"3.0.0","script":"test:type-surface-compatibility","extra":true}',
        ]
        for declaration in declarations:
            with self.subTest(declaration=declaration):
                result, _, _, _ = run_resolver(declaration)
                self.assertNotEqual(result.returncode, 0)

    def test_receipt_tampering_fails_the_protected_transfer_validator(self):
        generator = load_generator()
        validator = textwrap.dedent(generator.PROTECTED_BASELINE_TRANSFER_VALIDATION)
        baseline = {
            "schemaVersion": 1,
            "repository": "Verjson/verjson-authn",
            "declarationPath": ".github/ci/type-surface-baseline.json",
            "baseSha": BASE_SHA,
            "declarationSha256": "d" * 64,
            "package": "@verjson/authn",
            "version": "3.0.0",
            "script": "test:type-surface-compatibility",
            "artifact": {
                "integrity": "sha512-verified",
                "tarball": "https://npm.pkg.github.com/download/@verjson/authn/3.0.0/blob",
                "sha512": "a" * 128,
            },
        }
        provenance = {
            "schemaVersion": 1,
            "request": {
                "package": "@verjson/authn",
                "ranges": ["3.0.0"],
                "script": "test:type-surface-compatibility",
            },
            "lanes": [
                {
                    "package": "@verjson/authn",
                    "range": "3.0.0",
                    "version": "3.0.0",
                    "script": "test:type-surface-compatibility",
                    **baseline["artifact"],
                }
            ],
            "protectedBaseline": baseline,
        }
        environment = {
            "PROTECTED_BASELINE_DECLARATION_PATH": baseline["declarationPath"],
            "PROTECTED_BASELINE_REPOSITORY": baseline["repository"],
            "EXPECTED_PROTECTED_BASELINE_BASE_SHA": BASE_SHA,
            "EXPECTED_PROTECTED_BASELINE_DECLARATION_SHA256": "d" * 64,
            "PROTECTED_BASELINE_EXPECTED_PACKAGE": baseline["package"],
            "PROTECTED_BASELINE_EXPECTED_SCRIPT": baseline["script"],
        }

        def validate(candidate):
            namespace = {"os": os, "provenance": candidate, "request": candidate["request"]}
            previous = os.environ.copy()
            os.environ.update(environment)
            try:
                exec(validator, namespace)
            finally:
                os.environ.clear()
                os.environ.update(previous)

        validate(provenance)
        for mutation in (
            {**provenance["protectedBaseline"], "baseSha": "c" * 40},
            {**provenance["protectedBaseline"], "artifact": {**baseline["artifact"], "sha512": "b" * 128}},
        ):
            mutated = {**provenance, "protectedBaseline": mutation}
            with self.subTest(mutation=mutation):
                with self.assertRaises(SystemExit):
                    validate(mutated)


if __name__ == "__main__":
    unittest.main()
