#!/usr/bin/env python3

import argparse
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import importlib.util


ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("type_surface_baseline", ROOT / "type-surface-baseline.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BaselineContractTests(unittest.TestCase):
    def test_duplicate_and_malformed_declarations_fail_closed(self):
        with self.assertRaises(MODULE.ContractError):
            MODULE.strict_object('{"package":"@verjson/x","package":"@verjson/y"}', "declaration")
        with self.assertRaises(MODULE.ContractError):
            MODULE.strict_object('{"package":', "declaration")
        with self.assertRaises(MODULE.ContractError):
            MODULE.strict_object('[]', "declaration")

    def test_resolution_uses_one_api_base_sha_and_never_head_or_merge_tree(self):
        base_sha = "a" * 40
        calls = []

        def fake_api(_token, path):
            calls.append(path)
            if path == "repos/Verjson/example/pulls/7":
                return {"base": {"sha": base_sha, "repo": {"full_name": "Verjson/example"}}}
            expected = f"repos/Verjson/example/contents/.github/ci/type-surface-baseline.json?ref={base_sha}"
            if path != expected:
                raise AssertionError(path)
            raw = b'{"package":"@verjson/example","version":"1.2.3","script":"test:type-surface-compatibility"}'
            return {
                "type": "file",
                "encoding": "base64",
                "sha": "b" * 40,
                "content": __import__("base64").b64encode(raw).decode(),
            }

        arguments = argparse.Namespace(
            repository="Verjson/example",
            pull_request=7,
            declaration_path=".github/ci/type-surface-baseline.json",
            expected_package="@verjson/example",
            expected_script="test:type-surface-compatibility",
            github_token="token",
            node_auth_token="token",
            package_policy=json.dumps(
                {
                    "scopes": ["@verjson"],
                    "packages": ["@verjson/example"],
                    "compatibility": {"@verjson/example": ["^1.0.0"]},
                }
            ),
        )
        with patch.dict(MODULE.os.environ, {"GITHUB_TOKEN": "token", "NODE_AUTH_TOKEN": "token"}), patch.object(
            MODULE, "api_json", side_effect=fake_api
        ), patch.object(
            MODULE,
            "registry_metadata",
            return_value={
                "integrity": "sha512-" + "A" * 86 + "==",
                "tarball": "https://npm.pkg.github.com/download/@verjson/example/1.2.3/example-1.2.3.tgz",
            },
        ):
            resolved = MODULE.resolve(arguments)
        self.assertEqual(calls, [
            "repos/Verjson/example/pulls/7",
            f"repos/Verjson/example/contents/.github/ci/type-surface-baseline.json?ref={base_sha}",
        ])
        self.assertEqual(resolved["version"], "1.2.3")

    def test_policy_rejects_unauthorized_and_unavailable_versions(self):
        policy = json.dumps(
            {
                "scopes": ["@verjson"],
                "packages": ["@verjson/example"],
                "compatibility": {"@verjson/example": ["^1.0.0"]},
            }
        )
        with self.assertRaises(MODULE.ContractError):
            MODULE.validate_policy(policy, "@verjson/other", "1.2.3")
        with self.assertRaises(MODULE.ContractError):
            MODULE.validate_policy(policy, "@verjson/example", "2.0.0")
        with patch("subprocess.run", return_value=argparse.Namespace(returncode=1, stdout="", stderr="404")):
            with self.assertRaises(MODULE.ContractError):
                MODULE.registry_metadata("@verjson/example", "1.2.3", "token")
        bad_registry = json.dumps(
            [{
                "name": "@verjson/example",
                "version": "1.2.3",
                "dist.integrity": "sha512-" + "A" * 86 + "==",
                "dist.tarball": "https://npm.pkg.github.com/download/@verjson/other/1.2.3/other.tgz",
            }]
        )
        with patch(
            "subprocess.run",
            return_value=argparse.Namespace(returncode=0, stdout=bad_registry, stderr=""),
        ):
            with self.assertRaises(MODULE.ContractError):
                MODULE.registry_metadata("@verjson/example", "1.2.3", "token")

    def test_receipt_tampering_fails_closed(self):
        receipt = {
            "schemaVersion": 1,
            "repository": "Verjson/example",
            "declarationPath": ".github/ci/type-surface-baseline.json",
            "baseSha": "a" * 40,
            "declarationBlobSha": "b" * 40,
            "declarationSha256": "c" * 64,
            "package": "@verjson/example",
            "version": "1.2.3",
            "script": "test:type-surface-compatibility",
            "request": {
                "package": "@verjson/example",
                "ranges": ["1.2.3"],
                "script": "test:type-surface-compatibility",
            },
            "artifact": {
                "integrity": "sha512-" + "A" * 86 + "==",
                "tarball": "https://npm.pkg.github.com/download/@verjson/example/1.2.3/example-1.2.3.tgz",
            },
            "typeSurfaceResult": "success",
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            path.write_text(json.dumps(receipt), encoding="utf-8")
            MODULE.verify_receipt(argparse.Namespace(receipt=str(path)))
            receipt["request"]["ranges"] = ["9.9.9"]
            path.write_text(json.dumps(receipt), encoding="utf-8")
            with self.assertRaises(MODULE.ContractError):
                MODULE.verify_receipt(argparse.Namespace(receipt=str(path)))


if __name__ == "__main__":
    unittest.main()
