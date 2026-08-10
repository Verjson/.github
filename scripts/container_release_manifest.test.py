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
        "registryNamespace": "ghcr.io/verjson",
        "nextStableVersion": "2.4.0",
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
                    "builderIdentity": "Verjson/.github/.github/workflows/container-candidate.yml@" + "b" * 40,
                },
            }
        ],
    }


def manifest():
    return {
        "schemaVersion": 1,
        "kind": "container-candidate",
        "candidateVersion": "2.4.0-rc.123.1",
        "source": {
            "repository": "Verjson/verjson-github-runner",
            "commit": "a" * 40,
            "ref": "refs/heads/main",
            "workflow": "Verjson/.github/.github/workflows/container-candidate.yml@" + "b" * 40,
            "runId": "123",
            "runAttempt": "1",
        },
        "images": [
            {
                "variant": "default",
                "repository": "ghcr.io/verjson/runner",
                "indexDigest": "sha256:" + "1" * 64,
                "identities": {"commit": "sha-" + "a" * 40, "candidate": "2.4.0-rc.123.1"},
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
                    "builderIdentity": "Verjson/.github/.github/workflows/container-candidate.yml@" + "b" * 40,
                    "subjectDigest": "sha256:" + "1" * 64,
                    "attestationId": "https://github.com/Verjson/verjson-github-runner/attestations/42",
                },
                "sbom": {"predicateType": "https://spdx.dev/Document", "subjectDigest": "sha256:" + "1" * 64, "ociSubject": "ghcr.io/verjson/runner@sha256:" + "1" * 64},
            }
        ],
    }


class ContainerReleaseManifestTests(unittest.TestCase):
    def assert_rejected(self, candidate, expected):
        with self.assertRaisesRegex(manifest_contract.ManifestError, expected):
            manifest_contract.validate_manifest(candidate, config())

    def test_accepts_complete_manifest_bound_to_reviewed_identity(self):
        manifest_contract.validate_manifest(manifest(), config())

    def test_accepts_exact_reviewed_private_node_packages(self):
        reviewed = config()
        reviewed["privateNodePackages"] = ["@verjson/pg", "@verjson/observability"]
        manifest_contract.validate_manifest(manifest(), reviewed)

    def test_rejects_unapproved_private_package_shapes(self):
        for unsafe in ("@verjson/pg", ["lodash"], ["@verjson/pg", "@verjson/pg"], ["@verjson/../pg"]):
            with self.subTest(unsafe=unsafe):
                reviewed = config()
                reviewed["privateNodePackages"] = unsafe
                with self.assertRaisesRegex(manifest_contract.ManifestError, "privateNodePackages"):
                    manifest_contract.validate_manifest(manifest(), reviewed)

    def test_rejects_duplicate_image_variant_even_when_digests_diverge(self):
        candidate = manifest()
        duplicate = copy.deepcopy(candidate["images"][0])
        duplicate["indexDigest"] = "sha256:" + "9" * 64
        candidate["images"].append(duplicate)
        self.assert_rejected(candidate, "duplicate identity 'default'")

    def test_rejects_candidate_contract_pin_different_from_reviewed_config(self):
        candidate = manifest()
        candidate["source"]["workflow"] = "Verjson/.github/.github/workflows/container-candidate.yml@" + "c" * 40
        candidate["images"][0]["provenance"]["builderIdentity"] = candidate["source"]["workflow"]
        self.assert_rejected(candidate, "provenance builder identity differs")

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
        self.assert_rejected(candidate, "provenance signer workflow differs")

    def test_rejects_source_repository_substitution(self):
        candidate = manifest()
        candidate["source"]["repository"] = "attacker/repository"
        self.assert_rejected(candidate, "source repository differs")

    def test_rejects_mutable_manifest_identity(self):
        candidate = manifest()
        candidate["images"][0]["identities"] = {"commit": "latest", "candidate": "candidate"}
        self.assert_rejected(candidate, "immutable identities differ")

    def test_rejects_malformed_digest(self):
        candidate = manifest()
        candidate["images"][0]["indexDigest"] = "latest"
        self.assert_rejected(candidate, "lowercase sha256 digest")

    def test_rejects_candidate_not_derived_from_reviewed_release_line(self):
        candidate = manifest()
        candidate["candidateVersion"] = "2.5.0-rc.123.1"
        self.assert_rejected(candidate, "candidateVersion is not derived")

    def test_rejects_attestation_from_another_ref(self):
        candidate = manifest()
        candidate["source"]["ref"] = "refs/heads/feature"
        self.assert_rejected(candidate, "source ref")

    def test_rejects_unobserved_provenance_claim(self):
        candidate = manifest()
        candidate["images"][0]["provenance"].pop("attestationId")
        self.assert_rejected(candidate, "attestationId")

    def test_rejects_sbom_for_another_oci_subject(self):
        candidate = manifest()
        candidate["images"][0]["sbom"]["ociSubject"] = "ghcr.io/verjson/runner@sha256:" + "9" * 64
        self.assert_rejected(candidate, "SBOM OCI subject|sbom OCI subject")

    def test_rejects_arbitrary_registry_namespace(self):
        candidate = manifest()
        candidate["images"][0]["repository"] = "ghcr.io/attacker/runner"
        config()["images"][0]["repository"] = "ghcr.io/attacker/runner"
        self.assert_rejected(candidate, "image repository differs")

    def test_accepts_derived_variant_bound_to_same_run_base_digest(self):
        reviewed = config()
        candidate = manifest()
        derived_config = copy.deepcopy(reviewed["images"][0])
        derived_config["variant"] = "debug"
        derived_config["baseVariant"] = "default"
        reviewed["images"].append(derived_config)
        derived = copy.deepcopy(candidate["images"][0])
        derived["variant"] = "debug"
        derived["indexDigest"] = "sha256:" + "6" * 64
        derived["sbom"]["ociSubject"] = derived["repository"] + "@" + derived["indexDigest"]
        derived["provenance"]["subjectDigest"] = derived["indexDigest"]
        derived["sbom"]["subjectDigest"] = derived["indexDigest"]
        derived["base"] = {"variant": "default", "digest": candidate["images"][0]["indexDigest"]}
        candidate["images"].append(derived)
        manifest_contract.validate_manifest(candidate, reviewed)

    def test_rejects_derived_variant_bound_to_other_digest(self):
        candidate = manifest()
        reviewed = config()
        derived_config = copy.deepcopy(reviewed["images"][0])
        derived_config["variant"] = "debug"
        derived_config["baseVariant"] = "default"
        reviewed["images"].append(derived_config)
        derived = copy.deepcopy(candidate["images"][0])
        derived["variant"] = "debug"
        derived["indexDigest"] = "sha256:" + "6" * 64
        derived["sbom"]["ociSubject"] = derived["repository"] + "@" + derived["indexDigest"]
        derived["provenance"]["subjectDigest"] = derived["indexDigest"]
        derived["sbom"]["subjectDigest"] = derived["indexDigest"]
        derived["base"] = {"variant": "default", "digest": "sha256:" + "9" * 64}
        candidate["images"].append(derived)
        with self.assertRaisesRegex(manifest_contract.ManifestError, "same-run base digest"):
            manifest_contract.validate_manifest(candidate, reviewed)


if __name__ == "__main__":
    unittest.main()
