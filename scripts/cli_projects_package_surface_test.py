#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SCRIPT = ROOT / "scripts/cli-projects-package-surface.py"
SPEC = importlib.util.spec_from_file_location("cli_projects_package_surface", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
GENERATOR_SPEC = importlib.util.spec_from_file_location(
    "gen_node_required_workflow", ROOT / "scripts/gen-node-required-workflow.py"
)
GENERATOR = importlib.util.module_from_spec(GENERATOR_SPEC)
GENERATOR_SPEC.loader.exec_module(GENERATOR)


class CliProjectsPackageSurfaceTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        (self.root / ".github/workflows").mkdir(parents=True)
        (self.root / "templates/package/.github/workflows").mkdir(parents=True)
        (self.root / "package.json").write_text(json.dumps({
            "name": "@verjson/cli-projects",
            "type": "module",
            "bin": MODULE.EXPECTED_BINS,
            "files": ["src", "templates", "README.md"],
            "publishConfig": {"registry": "https://npm.pkg.github.com"},
            "scripts": {"build": "bash scripts/check-sources.sh"},
            "engines": {"node": ">=24.19.0"},
        }), encoding="utf-8")
        release = """on:\n  workflow_dispatch:\njobs:\n  release:\n    uses: Verjson/.github/.github/workflows/node-release.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"""
        ci = """on:\n  pull_request:\njobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"""
        (self.root / ".github/workflows/release.yml").write_text(release, encoding="utf-8")
        for name in ("ci.yml.tmpl", "actionlint.yml.tmpl"):
            (self.root / f"templates/package/.github/workflows/{name}").write_text(ci, encoding="utf-8")

    def tearDown(self):
        self.scratch.cleanup()

    def test_valid_surface_is_accepted(self):
        MODULE.validate_tree(self.root)

    def test_release_push_in_block_or_flow_form_is_rejected(self):
        path = self.root / ".github/workflows/release.yml"
        for trigger in ("on: [workflow_dispatch, push]\n", "on:\n  workflow_dispatch:\n  push:\n"):
            with self.subTest(trigger=trigger):
                path.write_text(trigger + "jobs:\n  release:\n    uses: x/y/z@" + "a" * 40 + "\n", encoding="utf-8")
                with self.assertRaisesRegex(MODULE.ContractError, "workflow_dispatch only"):
                    MODULE.validate_workflow(path, release=True)

    def test_duplicate_trigger_key_is_rejected(self):
        path = self.root / ".github/workflows/release.yml"
        path.write_text("on:\n  workflow_dispatch:\non:\n  push:\njobs:\n  x:\n    uses: x/y/z@" + "a" * 40 + "\n", encoding="utf-8")
        with self.assertRaisesRegex(MODULE.ContractError, "duplicate YAML key"):
            MODULE.validate_workflow(path, release=True)

    def test_mutable_action_and_container_references_are_rejected(self):
        path = self.root / "templates/package/.github/workflows/ci.yml.tmpl"
        for uses, message in (("actions/checkout@v4", "40-hex"), ("docker://alpine:latest", "sha256")):
            with self.subTest(uses=uses):
                path.write_text(f"on:\n  pull_request:\njobs:\n  x:\n    steps:\n      - uses: {uses}\n", encoding="utf-8")
                with self.assertRaisesRegex(MODULE.ContractError, message):
                    MODULE.validate_workflow(path)

    def test_verification_cannot_be_softened(self):
        path = self.root / "templates/package/.github/workflows/ci.yml.tmpl"
        cases = (
            ("continue-on-error: true\n        run: npm test", "continue on error"),
            ("run: npm test || true", "hide failure"),
            ("if: false\n        run: npm test", "unconditionally skipped"),
        )
        for body, message in cases:
            with self.subTest(body=body):
                path.write_text("on:\n  pull_request:\njobs:\n  x:\n    steps:\n      - " + body + "\n", encoding="utf-8")
                with self.assertRaisesRegex(MODULE.ContractError, message):
                    MODULE.validate_workflow(path)

    def test_manifest_rejects_added_binary_or_credential_file(self):
        package = json.loads((self.root / "package.json").read_text())
        package["bin"]["spoof"] = "src/spoof.js"
        (self.root / "package.json").write_text(json.dumps(package), encoding="utf-8")
        with self.assertRaisesRegex(MODULE.ContractError, "binary surface"):
            MODULE.validate_manifest(self.root)

    def test_manifest_accepts_reviewed_v1_floor_and_rejects_legacy_floor(self):
        MODULE.validate_manifest(self.root)
        package_path = self.root / "package.json"
        package = json.loads(package_path.read_text(encoding="utf-8"))
        package["engines"]["node"] = ">=20.20.2"
        package_path.write_text(json.dumps(package), encoding="utf-8")

        with self.assertRaisesRegex(MODULE.ContractError, "supported Node engine floor drifted"):
            MODULE.validate_manifest(self.root)

    def test_manifest_floor_stays_synchronized_with_required_node_config(self):
        config = json.loads(MODULE.REQUIRED_NODE_CONFIG.read_text(encoding="utf-8"))
        workflow = MODULE.load_yaml(
            ROOT / ".github/workflows/cli-projects-package-surface-required.yml"
        )
        floor_lane = workflow["jobs"]["ci-node-floor"]["with"]["node-version"]
        self.assertEqual(floor_lane, config["node_versions"][1])
        self.assertEqual(MODULE.required_node_engine(), f">={floor_lane}")

    def test_required_node_config_rejects_every_malformed_field_in_both_consumers(self):
        config = json.loads(MODULE.REQUIRED_NODE_CONFIG.read_text(encoding="utf-8"))
        mutations = {
            "schema_version": False,
            "repository": "attacker/example",
            "node_ci_sha": "main",
            "node_versions": [{"unhashable": True}, "24.19.0"],
            "approved_internal_packages": [{"unhashable": True}],
            "scripts": [{"unhashable": True}],
        }
        for field, value in mutations.items():
            with self.subTest(field=field):
                candidate = dict(config)
                candidate[field] = value
                self.assert_required_node_config_rejected(candidate)

    def test_required_node_config_rejects_missing_unknown_and_duplicate_fields(self):
        config = json.loads(MODULE.REQUIRED_NODE_CONFIG.read_text(encoding="utf-8"))
        for field in config:
            with self.subTest(missing=field):
                candidate = dict(config)
                del candidate[field]
                self.assert_required_node_config_rejected(candidate)

        self.assert_required_node_config_rejected({**config, "unknown": True})
        serialized = json.dumps(config)
        for field, value in config.items():
            with self.subTest(duplicate=field):
                duplicate = "{" + json.dumps(field) + ":" + json.dumps(value) + "," + serialized[1:]
                self.assert_required_node_config_rejected_text(duplicate)

    def assert_required_node_config_rejected(self, config):
        self.assert_required_node_config_rejected_text(json.dumps(config))

    def assert_required_node_config_rejected_text(self, text):
        path = self.root / "required-node.json"
        path.write_text(text, encoding="utf-8")
        with self.assertRaises(MODULE.ContractError):
            MODULE.required_node_engine(path)
        with self.assertRaises(GENERATOR.ContractError):
            GENERATOR.load_config(path)

    def test_container_digest_rejects_tag_and_action_pin_rejects_mutable_ref(self):
        with self.assertRaisesRegex(MODULE.ContractError, "sha256"):
            MODULE.validate_uses("fixture", "docker://example.invalid/tool:latest")
        with self.assertRaisesRegex(MODULE.ContractError, "40-hex"):
            MODULE.validate_uses("fixture", "Verjson/.github/action@main")


if __name__ == "__main__":
    unittest.main()
