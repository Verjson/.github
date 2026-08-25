#!/usr/bin/env python3

import copy
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("retry", ROOT / "container_candidate_retry.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


REPOSITORY = "ghcr.io/verjson/example"
DIGEST = "sha256:" + "a" * 64
BASE_REPOSITORY = "ghcr.io/verjson/base"
BASE_DIGEST = "sha256:" + "b" * 64


def evidence():
    return [
        {
            "attestation": {"bundle": {"mediaType": "application/vnd.dev.sigstore.bundle+json;version=0.3"}},
            "verificationResult": {
                "statement": {
                    "predicateType": "https://slsa.dev/provenance/v1",
                    "subject": [
                        {"name": "verjson/example", "digest": {"sha256": "a" * 64}}
                    ],
                    "predicate": {
                        "buildDefinition": {
                            "resolvedDependencies": [
                                {
                                    "uri": f"pkg:docker/verjson/base@{BASE_DIGEST}",
                                    "digest": {"sha256": "b" * 64},
                                }
                            ]
                        }
                    },
                }
            },
        }
    ]


def buildkit_provenance():
    def entry(platform):
        return {
            "SLSA": {
                "buildDefinition": {
                    "buildType": "https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md",
                    "externalParameters": {
                        "request": {
                            "root": {
                                "configSource": {
                                    "path": "Dockerfile"
                                },
                                "request": {
                                    "args": {
                                        "vcs:revision": "c" * 40,
                                        "vcs:source": "https://github.com/Verjson/example",
                                    }
                                },
                            }
                        }
                    },
                    "resolvedDependencies": [
                        {
                            "uri": f"pkg:docker/{BASE_REPOSITORY}?digest={BASE_DIGEST}&platform={platform.replace('/', '%2F')}",
                            "digest": {"sha256": "b" * 64},
                        }
                    ],
                }
            }
        }

    return {"linux/amd64": entry("linux/amd64"), "linux/arm64": entry("linux/arm64")}


REVIEWED_PLATFORMS = [
    {"os": "linux", "architecture": "amd64"},
    {"os": "linux", "architecture": "arm64"},
]


class RetryEvidenceTests(unittest.TestCase):
    def assert_rejected(self, mutate, message):
        candidate = copy.deepcopy(evidence())
        mutate(candidate)
        with self.assertRaisesRegex(MODULE.RetryEvidenceError, message):
            MODULE.validate_verified_provenance(
                candidate, repository=REPOSITORY, digest=DIGEST
            )

    def test_accepts_one_exact_repository_and_digest_subject(self):
        identity = MODULE.validate_verified_provenance(
            evidence(), repository=REPOSITORY, digest=DIGEST
        )
        self.assertRegex(identity, r"^verified-bundle-sha256:[0-9a-f]{64}$")
        self.assertEqual(
            identity,
            MODULE.validate_verified_provenance(
                evidence(), repository=REPOSITORY, digest=DIGEST
            ),
        )

    def test_rejects_missing_duplicate_or_malformed_verification(self):
        for value in ([], evidence() * 2, {}, [None]):
            with self.subTest(value=value):
                with self.assertRaises(MODULE.RetryEvidenceError):
                    MODULE.validate_verified_provenance(
                        value, repository=REPOSITORY, digest=DIGEST
                    )

    def test_rejects_attacker_selected_repository_or_digest(self):
        self.assert_rejected(
            lambda value: value[0]["verificationResult"]["statement"]["subject"][0].update(name="attacker/image"),
            "repository differs",
        )
        self.assert_rejected(
            lambda value: value[0]["verificationResult"]["statement"]["subject"][0]["digest"].update(sha256="b" * 64),
            "digest differs",
        )

    def test_rejects_wrong_predicate_extra_subject_or_ambiguous_digest(self):
        self.assert_rejected(
            lambda value: value[0]["verificationResult"]["statement"].update(predicateType="https://example.invalid"),
            "predicate differs",
        )
        self.assert_rejected(
            lambda value: value[0]["verificationResult"]["statement"]["subject"].append(copy.deepcopy(value[0]["verificationResult"]["statement"]["subject"][0])),
            "exactly one subject",
        )
        self.assert_rejected(
            lambda value: value[0]["verificationResult"]["statement"]["subject"][0]["digest"].update(sha512="c" * 128),
            "digest differs",
        )

    def test_rejects_unexpected_unverified_envelope_fields(self):
        self.assert_rejected(
            lambda value: value[0].update(attackerSelected=True),
            "unexpected fields",
        )

    def test_accepts_one_exact_immutable_base_material_for_a_derived_image(self):
        MODULE.validate_buildkit_provenance(
            buildkit_provenance(),
            REVIEWED_PLATFORMS,
            source_repository="Verjson/example",
            source_commit="c" * 40,
            base_repository=BASE_REPOSITORY,
            base_digest=BASE_DIGEST,
        )

    def test_rejects_missing_mismatched_or_duplicate_base_material(self):
        cases = []
        missing = buildkit_provenance()
        missing["linux/amd64"]["SLSA"]["buildDefinition"]["resolvedDependencies"] = []
        cases.append(missing)
        mismatched = buildkit_provenance()
        mismatched["linux/amd64"]["SLSA"]["buildDefinition"]["resolvedDependencies"][0]["digest"]["sha256"] = "c" * 64
        cases.append(mismatched)
        duplicate = buildkit_provenance()
        duplicate["linux/amd64"]["SLSA"]["buildDefinition"]["resolvedDependencies"] *= 2
        cases.append(duplicate)
        for candidate in cases:
            with self.subTest(candidate=candidate):
                with self.assertRaisesRegex(
                    MODULE.RetryEvidenceError, "exactly one immutable base dependency"
                ):
                    MODULE.validate_buildkit_provenance(
                        candidate,
                        REVIEWED_PLATFORMS,
                        source_repository="Verjson/example",
                        source_commit="c" * 40,
                        base_repository=BASE_REPOSITORY,
                        base_digest=BASE_DIGEST,
                    )

    def test_rejects_platform_or_source_substitution(self):
        wrong_platform = buildkit_provenance()
        wrong_platform["linux/s390x"] = wrong_platform.pop("linux/arm64")
        wrong_source = buildkit_provenance()
        wrong_source["linux/amd64"]["SLSA"]["buildDefinition"]["externalParameters"]["request"]["root"]["request"]["args"]["vcs:revision"] = "d" * 40
        for candidate, message in (
            (wrong_platform, "platforms differ"),
            (wrong_source, "source identity differs"),
        ):
            with self.assertRaisesRegex(MODULE.RetryEvidenceError, message):
                MODULE.validate_buildkit_provenance(
                    candidate,
                    REVIEWED_PLATFORMS,
                    source_repository="Verjson/example",
                    source_commit="c" * 40,
                    base_repository=BASE_REPOSITORY,
                    base_digest=BASE_DIGEST,
                )


if __name__ == "__main__":
    unittest.main()
