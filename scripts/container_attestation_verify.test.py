#!/usr/bin/env python3

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import container_attestation_verify as verifier


WORKFLOW = "Verjson/.github/.github/workflows/container-candidate-publish.yml@" + "b" * 40
INDEX_DIGEST = "sha256:" + "1" * 64
AMD64_DIGEST = "sha256:" + "2" * 64
ARM64_DIGEST = "sha256:" + "3" * 64


def config():
    return {
        "repository": "Verjson/example",
        "registryNamespace": "ghcr.io/verjson",
        "nextStableVersion": "1.2.3",
        "images": [
            {
                "variant": "default",
                "repository": "ghcr.io/verjson/example",
                "platforms": [
                    {"os": "linux", "architecture": "amd64"},
                    {"os": "linux", "architecture": "arm64", "variant": "v8"},
                ],
                "provenance": {
                    "predicateType": "https://slsa.dev/provenance/v1",
                    "builderIdentity": WORKFLOW,
                },
            }
        ],
    }


def candidate():
    return {
        "schemaVersion": 2,
        "kind": "container-candidate",
        "candidateVersion": "1.2.3-rc.123.1",
        "source": {
            "repository": "Verjson/example",
            "commit": "a" * 40,
            "ref": "refs/heads/main",
            "workflow": WORKFLOW,
            "runId": "123",
            "runAttempt": "1",
        },
        "images": [
            {
                "variant": "default",
                "repository": "ghcr.io/verjson/example",
                "indexDigest": INDEX_DIGEST,
                "identities": {
                    "commit": "sha-" + "a" * 40,
                    "candidate": "1.2.3-rc.123.1",
                },
                "platforms": [
                    {"os": "linux", "architecture": "amd64", "digest": AMD64_DIGEST},
                    {
                        "os": "linux",
                        "architecture": "arm64",
                        "variant": "v8",
                        "digest": ARM64_DIGEST,
                    },
                ],
                "provenance": {
                    "predicateType": "https://slsa.dev/provenance/v1",
                    "builderIdentity": WORKFLOW,
                    "subjectDigest": INDEX_DIGEST,
                    "attestationId": "provenance-1",
                },
                "sbom": {
                    "predicateType": "https://spdx.dev/Document/v2.3",
                    "attestations": [
                        {
                            "os": "linux",
                            "architecture": "amd64",
                            "digest": AMD64_DIGEST,
                            "attestationId": "sbom-1",
                        },
                        {
                            "os": "linux",
                            "architecture": "arm64",
                            "variant": "v8",
                            "digest": ARM64_DIGEST,
                            "attestationId": "sbom-2",
                        },
                    ],
                },
            }
        ],
    }


class ContainerAttestationVerifierTests(unittest.TestCase):
    def test_accepts_actual_producer_identity_for_every_image_platform(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            self.assertEqual("Verjson/example", command[command.index("--repo") + 1])
            self.assertEqual(
                "Verjson/.github/.github/workflows/container-candidate-publish.yml",
                command[command.index("--signer-workflow") + 1],
            )
            self.assertEqual("b" * 40, command[command.index("--signer-digest") + 1])
            self.assertEqual("refs/heads/main", command[command.index("--source-ref") + 1])
            self.assertEqual("a" * 40, command[command.index("--source-digest") + 1])
            return subprocess.CompletedProcess(command, 0, json.dumps({"subject": command[3]}), "")

        with tempfile.TemporaryDirectory() as directory:
            receipts = verifier.verify(candidate(), config(), Path(directory), run=run)

        self.assertEqual(3, len(calls))
        self.assertEqual(
            {f"oci://ghcr.io/verjson/example@{INDEX_DIGEST}"},
            {call[3] for call in calls if "--bundle-from-oci" not in call},
        )
        self.assertEqual(
            {
                f"oci://ghcr.io/verjson/example@{AMD64_DIGEST}",
                f"oci://ghcr.io/verjson/example@{ARM64_DIGEST}",
            },
            {call[3] for call in calls if "--bundle-from-oci" in call},
        )
        self.assertEqual({"default"}, set(receipts["provenance"]))
        self.assertEqual({"default"}, set(receipts["sbom"]))

    def test_rejects_missing_attestation(self):
        def run(command, **kwargs):
            raise subprocess.CalledProcessError(1, command, stderr="no attestation found")

        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(subprocess.CalledProcessError):
                verifier.verify(candidate(), config(), Path(directory), run=run)

    def test_rejects_wrong_predicate_repository_workflow_and_digest(self):
        mutations = (
            (lambda value: value["images"][0]["sbom"].update(predicateType="https://example.invalid"), "SBOM predicate"),
            (lambda value: value["images"][0].update(repository="ghcr.io/attacker/example"), "repository differs"),
            (lambda value: value["images"][0]["provenance"].update(builderIdentity="attacker/workflow@" + "b" * 40), "signer workflow"),
            (lambda value: value["images"][0]["sbom"]["attestations"][0].update(digest="sha256:" + "9" * 64), "SBOM digest"),
        )
        for mutate, error in mutations:
            with self.subTest(error=error):
                invalid = copy.deepcopy(candidate())
                mutate(invalid)
                with tempfile.TemporaryDirectory() as directory:
                    with self.assertRaisesRegex(Exception, error):
                        verifier.verify(invalid, config(), Path(directory))


if __name__ == "__main__":
    unittest.main()
