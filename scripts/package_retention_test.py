#!/usr/bin/env python3

import importlib.util
import pathlib
import sys
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("package_retention", ROOT / "package_retention.py")
assert SPEC and SPEC.loader
retention = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = retention
SPEC.loader.exec_module(retention)


class PackageRetentionTest(unittest.TestCase):
    def test_npm_keeps_three_highest_stable_versions_and_ignores_prereleases(self):
        target = retention.Target("npm", "cli-cloud", "4.0.0")
        versions = [
            {"id": 1, "name": "1.0.0"},
            {"id": 2, "name": "2.0.0"},
            {"id": 3, "name": "2.10.0"},
            {"id": 4, "name": "3.0.0-beta.1"},
            {"id": 5, "name": "4.0.0"},
        ]

        plan = retention.plan_target(target, versions)

        self.assertEqual([(item.version_id, item.labels) for item in plan], [(1, ("1.0.0",))])

    def test_container_deletes_old_numbered_and_all_untagged_versions(self):
        target = retention.Target("container", "api", "1.3.0")
        versions = [
            {"id": 10, "metadata": {"container": {"tags": ["1.0.0"]}}},
            {"id": 11, "metadata": {"container": {"tags": ["1.1.0"]}}},
            {"id": 12, "metadata": {"container": {"tags": ["1.2.0"]}}},
            {"id": 13, "metadata": {"container": {"tags": ["1.3.0"]}}},
            {"id": 14, "metadata": {"container": {"tags": []}}},
            {"id": 15, "metadata": {"container": {"tags": ["candidate-abc"]}}},
        ]

        plan = retention.plan_target(target, versions)

        self.assertEqual([(item.version_id, item.reason) for item in plan], [
            (10, "numbered release older than newest three"),
            (14, "untagged container version"),
        ])

    def test_inventory_all_targets_completes_before_first_deletion(self):
        targets = [
            retention.Target("npm", "one", "1.0.0"),
            retention.Target("npm", "two", "1.0.0"),
        ]

        class Client:
            def __init__(self):
                self.reads = []

            def versions(self, target):
                self.reads.append(target.name)
                if target.name == "two":
                    raise retention.RetentionError("ambiguous")
                return [{"id": 1, "name": "1.0.0"}]

        client = Client()
        with self.assertRaisesRegex(retention.RetentionError, "ambiguous"):
            retention.build_plan(client, targets)
        self.assertEqual(client.reads, ["one", "two"])

    def test_fails_closed_when_released_version_is_missing(self):
        target = retention.Target("npm", "cli", "2.0.0")
        with self.assertRaisesRegex(retention.RetentionError, "released version"):
            retention.plan_target(target, [{"id": 1, "name": "1.0.0"}])

    def test_fails_closed_instead_of_deleting_a_historically_resumed_release(self):
        target = retention.Target("npm", "cli", "1.0.0")
        versions = [
            {"id": 1, "name": "1.0.0"},
            {"id": 2, "name": "2.0.0"},
            {"id": 3, "name": "3.0.0"},
            {"id": 4, "name": "4.0.0"},
        ]
        with self.assertRaisesRegex(retention.RetentionError, "historical cleanup"):
            retention.plan_target(target, versions)

    def test_fails_closed_when_container_numbered_tag_shares_a_manifest(self):
        target = retention.Target("container", "api", "2.0.0")
        versions = [{"id": 1, "metadata": {"container": {"tags": ["2.0.0", "latest"]}}}]
        with self.assertRaisesRegex(retention.RetentionError, "mixes a numbered release"):
            retention.plan_target(target, versions)

    def test_fails_closed_on_duplicate_semver_or_version_id(self):
        target = retention.Target("npm", "cli", "2.0.0")
        with self.assertRaisesRegex(retention.RetentionError, "multiple version ids"):
            retention.plan_target(target, [{"id": 1, "name": "2.0.0"}, {"id": 2, "name": "2.0.0"}])
        with self.assertRaisesRegex(retention.RetentionError, "duplicate version id"):
            retention.plan_target(target, [{"id": 1, "name": "2.0.0"}, {"id": 1, "name": "1.0.0"}])

    def test_target_boundary_rejects_duplicates_prereleases_and_unknown_fields(self):
        with self.assertRaises(retention.RetentionError):
            retention.parse_targets('[{"type":"npm","name":"cli","releasedVersion":"1.0.0-beta.1"}]', "Verjson")
        with self.assertRaises(retention.RetentionError):
            retention.parse_targets('[{"type":"npm","name":"cli","releasedVersion":"1.0.0","extra":true}]', "Verjson")
        with self.assertRaises(retention.RetentionError):
            retention.parse_targets('[{"type":"npm","name":"cli","releasedVersion":"1.0.0"},{"type":"npm","name":"cli","releasedVersion":"1.0.0"}]', "Verjson")
        with self.assertRaises(retention.RetentionError):
            retention.parse_targets('[{"type":"npm","name":"scope/name","releasedVersion":"1.0.0"}]', "Verjson")
        with self.assertRaises(retention.RetentionError):
            retention.parse_targets('[{"type":"container","name":"scope//name","releasedVersion":"1.0.0"}]', "Verjson")

    def test_pagination_must_stay_on_configured_api_origin(self):
        with self.assertRaisesRegex(retention.RetentionError, "escaped"):
            retention._next_path('<https://evil.invalid/p?page=2>; rel="next"', "https://api.github.com")
        self.assertEqual(
            retention._next_path('<https://api.github.com/p?page=2>; rel="next"', "https://api.github.com"),
            "/p?page=2",
        )

    def test_delete_uses_encoded_supported_package_endpoint_and_bearer_token(self):
        target = retention.Target("container", "studio/api", "1.0.0")
        deletion = retention.Deletion(target, 42, "old", ("0.1.0",))
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b""
        response.__enter__.return_value.headers.get.return_value = None
        client = retention.GitHubPackages("Verjson", "test-token", "https://api.github.test")

        with mock.patch.object(retention.urllib.request, "urlopen", return_value=response) as urlopen:
            client.delete(deletion)

        request = urlopen.call_args.args[0]
        self.assertEqual(request.method, "DELETE")
        self.assertEqual(
            request.full_url,
            "https://api.github.test/orgs/Verjson/packages/container/studio%2Fapi/versions/42",
        )
        self.assertEqual(request.headers["Authorization"], "Bearer test-token")


if __name__ == "__main__":
    unittest.main()
