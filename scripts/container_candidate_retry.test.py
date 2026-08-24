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
                    "predicate": {},
                }
            },
        }
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


if __name__ == "__main__":
    unittest.main()
