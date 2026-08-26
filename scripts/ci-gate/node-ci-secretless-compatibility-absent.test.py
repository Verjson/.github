#!/usr/bin/env python3
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile
import tempfile
import threading
import time
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/node-ci.yml"
PACKAGE = "@verjson/authn"
PROTECTED_ENV = {
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    "ACTIONS_ID_TOKEN_REQUEST_URL",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AZURE_CREDENTIALS",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "NODE_AUTH_TOKEN",
    "NPM_TOKEN",
}


def add_file(archive, name, content):
    info = tarfile.TarInfo(name)
    info.mode = 0o644
    info.size = len(content)
    archive.addfile(info, io.BytesIO(content))


class SecretlessAbsentCompatibilityTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        steps = document["jobs"]["build-test"]["steps"]
        step = next(
            item for item in steps
            if item.get("name") == "Run runtime-resolved compatibility lanes without credentials"
        )
        cls.temp_root = Path(tempfile.mkdtemp(prefix="node-ci-absent-compat-"))
        cls.runner = cls.temp_root / "run-lanes.sh"
        cls.runner.write_text(step["run"], encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.temp_root)

    def setUp(self):
        self.fixture = Path(tempfile.mkdtemp(dir=self.temp_root))

    def tearDown(self):
        shutil.rmtree(self.fixture)

    def prepare(self, *, target="absent", versions=("1.0.0",), package=PACKAGE,
                padding_members=0):
        node_modules = self.fixture / "node_modules"
        node_modules.mkdir()
        scope = node_modules / "@verjson"
        outside = self.fixture / "outside"
        outside.mkdir()
        if target == "node-modules-symlink":
            node_modules.rmdir()
            node_modules.symlink_to(outside, target_is_directory=True)
        elif target == "scope-symlink":
            scope.symlink_to(outside, target_is_directory=True)
        elif target != "missing-parent":
            scope.mkdir()

        package_target = node_modules.joinpath(*package.split("/"))
        if target == "existing":
            package_target.mkdir()
            (package_target / "package.json").write_text(
                json.dumps({"name": package, "version": "0.9.0"}) + "\n",
                encoding="utf-8",
            )
            (package_target / "baseline-only").write_text("baseline\n", encoding="utf-8")
        elif target == "target-symlink":
            package_target.symlink_to(outside, target_is_directory=True)

        ranges = [f"^{version}" for version in versions]
        request = {"package": package, "ranges": ranges, "script": "test:compat"}
        artifact_dir = self.fixture / "artifacts"
        artifact_dir.mkdir()
        lanes = []
        for index, version in enumerate(versions):
            artifact = artifact_dir / f"lane-{index}.tgz"
            with tarfile.open(artifact, "w:gz") as archive:
                add_file(
                    archive,
                    "package/package.json",
                    json.dumps({"name": package, "version": version}).encode(),
                )
                add_file(archive, "package/index.js", b"module.exports = true;\n")
                if index == 0:
                    for member in range(padding_members):
                        info = tarfile.TarInfo(f"package/padding/{member}")
                        info.type = tarfile.DIRTYPE
                        archive.addfile(info)
            artifact_bytes = artifact.read_bytes()
            digest = hashlib.sha512(artifact_bytes).digest()
            lanes.append({
                "index": index,
                "package": package,
                "range": ranges[index],
                "script": "test:compat",
                "version": version,
                "integrity": "sha512-" + base64.b64encode(digest).decode(),
                "tarball": f"https://npm.pkg.github.com/download/{package}/{version}/archive",
                "sha512": digest.hex(),
            })
        provenance = json.dumps(
            {"schemaVersion": 1, "request": request, "lanes": lanes},
            sort_keys=True,
            separators=(",", ":"),
        ) + "\n"
        (artifact_dir / "provenance.json").write_text(provenance, encoding="utf-8")
        (self.fixture / "package.json").write_text(json.dumps({
            "name": "self-package-consumer",
            "version": "1.0.0",
            "scripts": {"test:compat": "node test-compat.cjs"},
        }) + "\n", encoding="utf-8")
        (self.fixture / "test-compat.cjs").write_text(
            """const assert = require('node:assert/strict');
const fs = require('node:fs');
const target = './node_modules/@verjson/authn';
const manifest = require(target + '/package.json');
assert.equal(manifest.version, process.env.VERJSON_COMPATIBILITY_VERSION);
assert.deepEqual(fs.readdirSync(target).sort(), ['index.js', 'package.json']);
fs.appendFileSync('observed-versions', manifest.version + '\\n');
if (process.env.TEST_SIGNAL === 'true') {
  fs.writeFileSync('consumer-started', 'yes');
  setInterval(() => {}, 1000);
}
if (process.env.TEST_FAIL === 'true') process.exit(42);
""",
            encoding="utf-8",
        )
        self.request = request
        self.provenance_sha = hashlib.sha256(provenance.encode()).hexdigest()
        self.package_target = package_target
        self.scope = scope
        self.outside = outside

    def environment(self, **updates):
        env = os.environ.copy()
        for name in PROTECTED_ENV:
            env[name] = ""
        env.update({
            "COMPATIBILITY_ARTIFACT_DIR": str(self.fixture / "artifacts"),
            "COMPATIBILITY_RANGES": json.dumps(self.request, separators=(",", ":")),
            "EXPECTED_COMPATIBILITY_PROVENANCE_SHA256": self.provenance_sha,
        })
        env.update(updates)
        return env

    def run_lane(self, **updates):
        return subprocess.run(
            ["bash", str(self.runner)],
            cwd=self.fixture,
            env=self.environment(**updates),
            capture_output=True,
            text=True,
        )

    def assert_absence_restored(self):
        self.assertFalse(self.package_target.exists())
        self.assertFalse(self.package_target.is_symlink())
        self.assertEqual([], list(self.scope.glob(".authn.*")))

    def test_initially_absent_target_is_removed_after_success(self):
        self.prepare()
        result = self.run_lane()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("1.0.0\n", (self.fixture / "observed-versions").read_text())
        self.assert_absence_restored()

    def test_initially_absent_target_is_removed_after_script_failure(self):
        self.prepare()
        result = self.run_lane(TEST_FAIL="true")
        self.assertNotEqual(0, result.returncode)
        self.assert_absence_restored()

    def test_initially_absent_target_is_removed_after_signal(self):
        self.prepare()
        process = subprocess.Popen(
            ["bash", str(self.runner)],
            cwd=self.fixture,
            env=self.environment(TEST_SIGNAL="true"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        marker = self.fixture / "consumer-started"
        for _ in range(200):
            if marker.exists() or process.poll() is not None:
                break
            time.sleep(0.025)
        if not marker.exists():
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=5)
            self.fail(f"signal fixture did not reach consumer: {stdout}\n{stderr}")
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=10)
        self.assertNotEqual(0, process.returncode)
        self.assert_absence_restored()

    def test_multiple_lanes_replace_only_verified_staging_then_restore_absence(self):
        self.prepare(versions=("1.0.0", "2.0.0"))
        result = self.run_lane()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("1.0.0\n2.0.0\n", (self.fixture / "observed-versions").read_text())
        self.assert_absence_restored()

    def test_existing_target_behavior_remains_replaced(self):
        self.prepare(target="existing")
        result = self.run_lane()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("1.0.0", json.loads(
            (self.package_target / "package.json").read_text()
        )["version"])
        self.assertFalse((self.package_target / "baseline-only").exists())

    def test_each_parent_component_must_be_a_real_directory(self):
        for target, reason in (
            ("node-modules-symlink", "parent is not a real directory"),
            ("scope-symlink", "parent is not a real directory"),
            ("missing-parent", "parent is absent"),
        ):
            with self.subTest(target=target):
                self.tearDown()
                self.setUp()
                self.prepare(target=target)
                result = self.run_lane()
                self.assertNotEqual(0, result.returncode)
                self.assertIn(reason, result.stderr)
                self.assertEqual([], list(self.outside.iterdir()))

    def test_symlinked_target_fails_before_staging(self):
        self.prepare(target="target-symlink")
        result = self.run_lane()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("target is not a real directory", result.stderr)
        self.assertEqual([], list(self.outside.iterdir()))

    def test_package_path_escape_fails_before_staging(self):
        self.prepare(package="@verjson/../escaped")
        result = self.run_lane()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("package path is invalid", result.stderr)
        self.assertFalse((self.fixture / "node_modules/escaped").exists())

    def test_target_appearing_during_staging_fails_closed(self):
        self.prepare(padding_members=1024)
        appeared = threading.Event()

        def occupy_target():
            for _ in range(5000):
                if list(self.scope.glob(".authn.compat-*")):
                    self.package_target.mkdir()
                    appeared.set()
                    return
                time.sleep(0.001)

        watcher = threading.Thread(target=occupy_target)
        watcher.start()
        result = self.run_lane()
        watcher.join(timeout=6)
        self.assertTrue(appeared.is_set())
        self.assertNotEqual(0, result.returncode)
        self.assertIn("target appeared unexpectedly", result.stderr)
        self.assertFalse((self.fixture / "observed-versions").exists())
        self.assertEqual([], list(self.scope.glob(".authn.*")))


if __name__ == "__main__":
    unittest.main()
