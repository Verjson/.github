#!/usr/bin/env python3

import copy
import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("container_release_manifest.py")
SPEC = importlib.util.spec_from_file_location("container_release_manifest", MODULE_PATH)
assert SPEC and SPEC.loader
manifest_contract = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = manifest_contract
SPEC.loader.exec_module(manifest_contract)


def config():
    return {
        "repository": "Verjson/verjson-github-runner",
        "images": [
            {
                "variant": "default",
                "repository": "ghcr.io/verjson/runner",
                "platforms": [
                    {"os": "linux", "architecture": "amd64"},
                    {"os": "linux", "architecture": "arm64", "variant": "v8"},
                ],
                "provenance": {
                    "predicateType": "https://slsa.dev/provenance/v1",
                    "builderIdentity": "https://github.com/Verjson/.github/container-candidate.yml@abc",
                },
            }
        ],
    }


def manifest():
    return {
        "source": {"repository": "Verjson/verjson-github-runner"},
        "images": [
            {
                "variant": "default",
                "repository": "ghcr.io/verjson/runner",
                "indexDigest": "sha256:" + "1" * 64,
                "platforms": [
                    {
                        "os": "linux",
                        "architecture": "amd64",
                        "digest": "sha256:" + "2" * 64,
                    },
                    {
                        "os": "linux",
                        "architecture": "arm64",
                        "variant": "v8",
                        "digest": "sha256:" + "3" * 64,
                    },
                ],
                "provenance": {
                    "predicateType": "https://slsa.dev/provenance/v1",
                    "builderIdentity": "https://github.com/Verjson/.github/container-candidate.yml@abc",
                    "attestationDigest": "sha256:" + "4" * 64,
                },
            }
        ],
    }


class ContainerReleaseManifestTests(unittest.TestCase):
    def assert_rejected(self, candidate, expected):
        with self.assertRaisesRegex(manifest_contract.ManifestError, expected):
            manifest_contract.validate_manifest(candidate, config())

    def test_accepts_complete_manifest_bound_to_reviewed_identity(self):
        manifest_contract.validate_manifest(manifest(), config())

    def test_rejects_duplicate_image_variant_even_when_digests_diverge(self):
        candidate = manifest()
        duplicate = copy.deepcopy(candidate["images"][0])
        duplicate["indexDigest"] = "sha256:" + "9" * 64
        candidate["images"].append(duplicate)
        self.assert_rejected(candidate, "duplicate identity 'default'")

    def test_rejects_duplicate_platform_tuple_even_when_digests_diverge(self):
        candidate = manifest()
        duplicate = copy.deepcopy(candidate["images"][0]["platforms"][0])
        duplicate["digest"] = "sha256:" + "9" * 64
        candidate["images"][0]["platforms"].append(duplicate)
        self.assert_rejected(candidate, "duplicate identity.*amd64")

    def test_rejects_incomplete_platform_matrix(self):
        candidate = manifest()
        candidate["images"][0]["platforms"].pop()
        self.assert_rejected(candidate, "platform matrix differs")

    def test_rejects_extra_variant(self):
        candidate = manifest()
        extra = copy.deepcopy(candidate["images"][0])
        extra["variant"] = "debug"
        candidate["images"].append(extra)
        self.assert_rejected(candidate, "variants differ")

    def test_rejects_repository_substitution(self):
        candidate = manifest()
        candidate["images"][0]["repository"] = "ghcr.io/attacker/runner"
        self.assert_rejected(candidate, "image repository differs")

    def test_rejects_platform_identity_substitution(self):
        candidate = manifest()
        candidate["images"][0]["platforms"][0]["architecture"] = "s390x"
        self.assert_rejected(candidate, "platform matrix differs")

    def test_rejects_provenance_identity_substitution(self):
        candidate = manifest()
        candidate["images"][0]["provenance"]["builderIdentity"] = "attacker"
        self.assert_rejected(candidate, "provenance builderIdentity differs")

    def test_rejects_source_repository_substitution(self):
        candidate = manifest()
        candidate["source"]["repository"] = "attacker/repository"
        self.assert_rejected(candidate, "source repository differs")


if __name__ == "__main__":
    unittest.main()
