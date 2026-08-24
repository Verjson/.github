#!/usr/bin/env python3

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "scripts/container_private_dependencies.py"
SPEC = importlib.util.spec_from_file_location("container_private_dependencies", MODULE)
assert SPEC and SPEC.loader
contract = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = contract
SPEC.loader.exec_module(contract)

INTEGRITY = "sha512-" + "A" * 86 + "=="


def pnpm_lock():
    return {
        "lockfileVersion": "9.0",
        "packages": {
            "@tequityapp/schema@1.2.3": {
                "resolution": {
                    "integrity": INTEGRITY,
                    "tarball": "https://npm.pkg.github.com/download/@tequityapp/schema/1.2.3/hash",
                }
            },
            "@verjson/authz@2.0.0(peer@1.0.0)": {
                "resolution": {
                    "integrity": INTEGRITY,
                    "tarball": "https://npm.pkg.github.com/download/@verjson/authz/2.0.0/hash",
                }
            },
            "zod@4.0.0": {"resolution": {"integrity": INTEGRITY}},
        },
    }


class PnpmCandidateTests(unittest.TestCase):
    def test_accepts_exact_multi_scope_private_set(self):
        plan = contract.build_pnpm_plan(
            pnpm_lock(), ["@tequityapp/schema", "@verjson/authz"]
        )
        self.assertEqual([item["private"] for item in plan], [True, True])

    def test_rejects_alias_missing_tarball_wrong_scope_and_malformed_peer_context(self):
        candidates = []
        alias = pnpm_lock()
        alias["packages"]["@tequityapp/schema@npm:@attacker/pkg@1.2.3"] = alias["packages"].pop("@tequityapp/schema@1.2.3")
        candidates.append(alias)
        missing = pnpm_lock()
        del missing["packages"]["@tequityapp/schema@1.2.3"]["resolution"]["tarball"]
        candidates.append(missing)
        wrong = pnpm_lock()
        wrong["packages"]["@tequityapp/schema@1.2.3"]["resolution"]["tarball"] = "https://npm.pkg.github.com/download/@attacker/schema/1.2.3/hash"
        candidates.append(wrong)
        peer = pnpm_lock()
        peer["packages"]["@verjson/authz@2.0.0(peer@1.0.0"] = peer["packages"].pop("@verjson/authz@2.0.0(peer@1.0.0)")
        candidates.append(peer)
        for candidate in candidates:
            with self.subTest(candidate=candidate), self.assertRaises(contract.DependencyError):
                contract.build_pnpm_plan(candidate, ["@tequityapp/schema", "@verjson/authz"])

    def test_workflows_bind_reviewed_manager_lock_and_credentials_to_acquisition(self):
        for name in ("container-candidate.yml", "container-candidate-publish.yml"):
            workflow = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
            prepare = workflow["jobs"]["prepare"]
            acquire = workflow["jobs"]["acquire-private-node-dependencies"]
            self.assertEqual(prepare["outputs"]["package-manager"], "${{ steps.config.outputs.package-manager }}")
            script = next(step["run"] for step in acquire["steps"] if step.get("name", "").startswith("Acquire exact"))
            self.assertIn('[ "$base_package_manager" = "$PACKAGE_MANAGER" ]', script)
            self.assertIn("corepack pnpm install --frozen-lockfile --ignore-scripts", script)
            self.assertNotIn("pnpm run", script)
            self.assertNotIn("--dangerously-allow-all-builds", script)
            self.assertIn("env -i", script)
            self.assertIn("validator_args+=(--manifest package.json)", script)
            scopes = "jq -r '.[] | split(\"/\")[0]' <<<\"$APPROVED_PRIVATE_PACKAGES\""
            self.assertIn(scopes, script)
            acquire_text = yaml.safe_dump(acquire)
            self.assertEqual(acquire_text.count("NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}"), 1)
            for job_name, job in workflow["jobs"].items():
                if job_name == "acquire-private-node-dependencies":
                    continue
                self.assertNotIn("secrets.NODE_AUTH_TOKEN", yaml.safe_dump(job))

    def test_cli_rejects_unpinned_manager_and_unsafe_yaml(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock_path = root / "pnpm-lock.yaml"
            manifest_path = root / "package.json"
            lock_path.write_text(yaml.safe_dump(pnpm_lock()), encoding="utf-8")
            manifest_path.write_text(json.dumps({
                "packageManager": "pnpm@11.22.0+sha512." + "a" * 128
            }), encoding="utf-8")
            command = [sys.executable, str(MODULE), "--package-manager", "pnpm",
                       "--lock", str(lock_path), "--manifest", str(manifest_path),
                       "--approved", '["@tequityapp/schema","@verjson/authz"]']
            self.assertEqual(subprocess.run(command, check=False).returncode, 0)
            manifest_path.write_text('{"packageManager":"pnpm@11.22.0"}', encoding="utf-8")
            self.assertNotEqual(subprocess.run(command, check=False, capture_output=True).returncode, 0)
            manifest_path.write_text(json.dumps({
                "packageManager": "pnpm@11.22.0+sha512." + "a" * 128
            }), encoding="utf-8")
            lock_path.write_text("x: &unsafe value\ny: *unsafe\n", encoding="utf-8")
            self.assertNotEqual(subprocess.run(command, check=False, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
