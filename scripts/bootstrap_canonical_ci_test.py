import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("bootstrap-canonical-ci.py")
SPEC = importlib.util.spec_from_file_location("bootstrap_canonical_ci", MODULE_PATH)
bootstrap = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(bootstrap)


SHA = "a" * 40


def manifest():
    return {
        "organization": "acme",
        "contract_sha": SHA,
        "variables": {"CI_LANE_TRUSTED": {"value": '["ubuntu-24.04"]', "visibility": "all"}},
        "secrets": {"MERGE_APP_PRIVATE_KEY": {"environment": "BOOTSTRAP_MERGE_KEY", "visibility": "all"}},
        "apps": [{
            "role": "MERGE_APP", "slug": "acme-merge-authorization", "app_id": 101,
            "client_id": "Iv123abc", "installation_id": 202, "repository_selection": "all",
            "permissions": {"contents": "write", "pull_requests": "write", "metadata": "read"},
            "events": [],
        }],
        "callers": [{
            "repository": "consumer", "generator": "privileged-merge",
            "arguments": ['[{"name":"ci","app_id":1,"workflow_id":2,"workflow_path":".github/workflows/ci.yml"}]'],
            "output": ".github/workflows/ai-privileged-merge.yml",
        }],
    }


class FakeGitHub:
    def __init__(self, *, variable_current=True, secret_present=True, app_overrides=None):
        self.calls = []
        self.variable_current = variable_current
        self.secret_present = secret_present
        self.app_overrides = app_overrides or {}

    def json(self, endpoint):
        self.calls.append(("json", endpoint, None))
        if endpoint == "/user":
            return {"login": "operator"}
        if endpoint == "/orgs/acme/memberships/operator":
            return {"state": "active", "role": "admin"}
        if endpoint.startswith("/orgs/acme/actions/variables"):
            values = []
            if self.variable_current:
                values = [{"name": "CI_LANE_TRUSTED", "value": '["ubuntu-24.04"]', "visibility": "all"}]
            return {"total_count": len(values), "variables": values}
        if endpoint.startswith("/orgs/acme/actions/secrets"):
            values = []
            if self.secret_present:
                values = [{"name": "MERGE_APP_PRIVATE_KEY", "visibility": "all"}]
            return {"total_count": len(values), "secrets": values}
        if endpoint.startswith("/orgs/acme/installations"):
            installation = {
                "id": 202, "app_id": 101, "app_slug": "acme-merge-authorization", "client_id": "Iv123abc",
                "suspended_at": None, "repository_selection": "all",
                "permissions": {"contents": "write", "pull_requests": "write", "metadata": "read"}, "events": [],
            }
            installation.update(self.app_overrides)
            return {"total_count": 1, "installations": [installation]}
        raise AssertionError(endpoint)

    def run(self, arguments, *, stdin=None, sensitive=False):
        self.calls.append(("run", arguments, stdin, sensitive))
        return ""


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.workspace = self.root / "workspace"
        self.repository = self.workspace / "consumer"
        (self.repository / ".git").mkdir(parents=True)
        (self.repository / ".github/workflows").mkdir(parents=True)
        self.contract = self.root / "contract"
        scripts = self.contract / "scripts"
        scripts.mkdir(parents=True)
        generator = scripts / "gen-privileged-merge-caller.sh"
        generator.write_text("#!/bin/sh\nprintf 'pin=%s\\n' \"$1\"\n", encoding="utf-8")
        generator.chmod(0o755)
        subprocess = __import__("subprocess")
        subprocess.run(["git", "init", "-q", str(self.contract)], check=True)
        subprocess.run(["git", "-C", str(self.contract), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(self.contract), "config", "user.email", "test@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.contract), "add", "scripts"], check=True)
        subprocess.run(["git", "-C", str(self.contract), "commit", "-qm", "contract"], check=True)
        global SHA
        SHA = subprocess.run(["git", "-C", str(self.contract), "rev-parse", "HEAD"], check=True, text=True, stdout=subprocess.PIPE).stdout.strip()

    def tearDown(self):
        self.temp.cleanup()

    def test_dry_run_is_read_only_and_redacted(self):
        gh = FakeGitHub(variable_current=False, secret_present=False)
        with mock.patch.dict(os.environ, {"BOOTSTRAP_MERGE_KEY": "top-secret"}):
            receipt = bootstrap.converge(
                bootstrap.validate_manifest(manifest()), gh, self.workspace, self.contract, "dry-run"
            )
        self.assertEqual(receipt["status"], "planned")
        self.assertEqual(receipt["secrets"][0]["value"], "REDACTED")
        self.assertNotIn("top-secret", json.dumps(receipt))
        self.assertFalse(any(call[0] == "run" for call in gh.calls))
        self.assertFalse((self.repository / ".github/workflows/ai-privileged-merge.yml").exists())

    def test_apply_converges_variable_secret_and_immutable_caller(self):
        gh = FakeGitHub(variable_current=False, secret_present=False)
        with mock.patch.dict(os.environ, {"BOOTSTRAP_MERGE_KEY": "top-secret"}):
            receipt = bootstrap.converge(
                bootstrap.validate_manifest(manifest()), gh, self.workspace, self.contract, "apply"
            )
        generated = (self.repository / ".github/workflows/ai-privileged-merge.yml").read_text()
        self.assertEqual(generated, f"pin={SHA}\n")
        writes = [call for call in gh.calls if call[0] == "run"]
        self.assertEqual(len(writes), 2)
        self.assertIsNone(writes[0][2])
        self.assertEqual(writes[1][2], "top-secret")
        self.assertNotIn("top-secret", json.dumps(receipt))

    def test_second_apply_leaves_current_variable_and_caller_unchanged(self):
        output = self.repository / ".github/workflows/ai-privileged-merge.yml"
        output.write_text(f"pin={SHA}\n", encoding="utf-8")
        gh = FakeGitHub()
        with mock.patch.dict(os.environ, {"BOOTSTRAP_MERGE_KEY": "rotated"}):
            receipt = bootstrap.converge(
                bootstrap.validate_manifest(manifest()), gh, self.workspace, self.contract, "apply"
            )
        self.assertEqual(receipt["variables"][0]["status"], "current")
        self.assertEqual(receipt["callers"][0]["status"], "current")
        self.assertEqual([call[1][0] for call in gh.calls if call[0] == "run"], ["secret"])

    def test_check_rejects_drift_without_writes(self):
        (self.repository / ".github/workflows/ai-privileged-merge.yml").write_text(f"pin={SHA}\n", encoding="utf-8")
        gh = FakeGitHub(variable_current=False)
        with self.assertRaisesRegex(bootstrap.BootstrapError, "variable CI_LANE_TRUSTED differs"):
            bootstrap.converge(bootstrap.validate_manifest(manifest()), gh, self.workspace, self.contract, "check")
        self.assertFalse(any(call[0] == "run" for call in gh.calls))

    def test_app_permission_widening_is_rejected(self):
        gh = FakeGitHub(app_overrides={"permissions": {"contents": "write", "administration": "write"}})
        with self.assertRaisesRegex(bootstrap.BootstrapError, "permissions differ"):
            bootstrap.converge(bootstrap.validate_manifest(manifest()), gh, self.workspace, self.contract, "dry-run")

    def test_app_event_subscription_is_rejected(self):
        gh = FakeGitHub(app_overrides={"events": ["pull_request"]})
        with self.assertRaisesRegex(bootstrap.BootstrapError, "events differ"):
            bootstrap.converge(bootstrap.validate_manifest(manifest()), gh, self.workspace, self.contract, "dry-run")

    def test_wrong_or_suspended_installation_is_rejected(self):
        for override, message in (({"id": 999}, "installation is absent"), ({"suspended_at": "now"}, "suspended")):
            with self.subTest(override=override):
                with self.assertRaisesRegex(bootstrap.BootstrapError, message):
                    bootstrap.converge(
                        bootstrap.validate_manifest(manifest()), FakeGitHub(app_overrides=override),
                        self.workspace, self.contract, "dry-run",
                    )

    def test_malformed_ids_mutable_sha_and_branded_names_are_rejected(self):
        mutations = []
        value = manifest(); value["contract_sha"] = "main"; mutations.append(value)
        value = manifest(); value["apps"][0]["installation_id"] = "202"; mutations.append(value)
        value = manifest(); value["variables"] = {"VERJSON_LANE_TRUSTED": {"value": "x", "visibility": "all"}}; mutations.append(value)
        value = manifest(); value["secrets"] = {"VERJSON_RELEASE_TOKEN": {"environment": "KEY", "visibility": "all"}}; mutations.append(value)
        for value in mutations:
            with self.subTest(value=value):
                with self.assertRaises(bootstrap.BootstrapError):
                    bootstrap.validate_manifest(value)

    def test_traversal_duplicate_output_and_unknown_generator_are_rejected(self):
        for mutation in ("repository", "output", "generator", "duplicate"):
            value = manifest()
            if mutation == "repository": value["callers"][0]["repository"] = "../foreign"
            if mutation == "output": value["callers"][0]["output"] = "../secret"
            if mutation == "generator": value["callers"][0]["generator"] = "shell"
            if mutation == "duplicate": value["callers"].append(dict(value["callers"][0]))
            with self.subTest(mutation=mutation):
                with self.assertRaises(bootstrap.BootstrapError):
                    bootstrap.validate_manifest(value)

    def test_missing_secret_fails_before_secret_write(self):
        gh = FakeGitHub()
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(bootstrap.BootstrapError, "environment .* is missing"):
                bootstrap.converge(bootstrap.validate_manifest(manifest()), gh, self.workspace, self.contract, "apply")
        self.assertFalse(any(call[0] == "run" and call[1][0] == "secret" for call in gh.calls))

    def test_incomplete_inventory_and_foreign_operator_fail_closed(self):
        class Foreign(FakeGitHub):
            def json(self, endpoint):
                if endpoint == "/orgs/acme/memberships/operator":
                    return {"state": "active", "role": "member"}
                return super().json(endpoint)
        with self.assertRaisesRegex(bootstrap.BootstrapError, "not an active owner"):
            bootstrap.converge(bootstrap.validate_manifest(manifest()), Foreign(), self.workspace, self.contract, "dry-run")

    def test_generator_checkout_must_equal_manifest_sha(self):
        value = manifest()
        value["contract_sha"] = "b" * 40
        with self.assertRaisesRegex(bootstrap.BootstrapError, "contract root HEAD"):
            bootstrap.converge(bootstrap.validate_manifest(value), FakeGitHub(), self.workspace, self.contract, "dry-run")


if __name__ == "__main__":
    unittest.main()
