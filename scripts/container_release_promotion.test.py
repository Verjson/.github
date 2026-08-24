import copy
import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("promotion", ROOT / "scripts/container_release_promotion.py")
promotion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(promotion)


class PromotionTest(unittest.TestCase):
    def setUp(self):
        self.config = {
            "repository": "Verjson/example",
            "registryNamespace": "ghcr.io/verjson",
            "nextStableVersion": "1.2.3",
            "images": [{"variant": "default", "repository": "ghcr.io/verjson/example", "platforms": [{"os": "linux", "architecture": "amd64"}], "provenance": {"predicateType": "https://slsa.dev/provenance/v1"}}],
        }
        digest = "sha256:" + "1" * 64
        workflow = "Verjson/.github/.github/workflows/container-candidate-publish.yml@" + "b" * 40
        self.config["images"][0]["provenance"]["builderIdentity"] = workflow
        self.candidate = {"schemaVersion": 2, "kind": "container-candidate", "candidateVersion": "1.2.3-rc.12345.1", "source": {"repository": "Verjson/example", "commit": "a" * 40, "ref": "refs/heads/main", "workflow": workflow, "runId": "12345", "runAttempt": "1"}, "images": [{"variant": "default", "repository": "ghcr.io/verjson/example", "indexDigest": digest, "identities": {"commit": "sha-" + "a" * 40, "candidate": "1.2.3-rc.12345.1"}, "platforms": [{"os": "linux", "architecture": "amd64", "digest": "sha256:" + "2" * 64}], "provenance": {"predicateType": "https://slsa.dev/provenance/v1", "builderIdentity": workflow, "subjectDigest": digest, "attestationId": "attestation-1"}, "sbom": {"predicateType": "https://spdx.dev/Document/v2.3", "attestations": [{"os": "linux", "architecture": "amd64", "digest": "sha256:" + "2" * 64, "attestationId": "attestation-2"}]}}]}
        self.state = {"candidateManifestDigest": "sha256:" + "9" * 64, "aliases": {}, "release": {"workflow": {"path": ".github/workflows/container-release.yml", "contractCommit": "c" * 40}, "sourceCommit": "d" * 40, "runId": 456, "runAttempt": 1}, "timestamps": {"candidatePublishedAt": "2026-08-09T00:00:00Z", "releasedAt": "2026-08-09T01:00:00Z"}, "previousRelease": None, "provenance": {"default": "sha256:" + "7" * 64}, "sbom": {"default": "sha256:" + "5" * 64}}

    def test_exact_digests_form_deterministic_release(self):
        result = promotion.release(self.candidate, self.config, self.state, "1.2.3")
        self.assertEqual(sorted(i["indexDigest"] for i in self.candidate["images"]), sorted(i["indexDigest"] for i in result["images"]))
        self.assertEqual("1.2.3", result["releaseVersion"])
        self.assertEqual(2, result["schemaVersion"])
        self.assertEqual(self.state["candidateManifestDigest"], result["candidateManifestDigest"])
        self.assertRegex(result["candidateManifestDigest"], r"^sha256:[0-9a-f]{64}$")
        self.assertEqual(sorted(result["promotion"]["operationOrder"]), result["promotion"]["operationOrder"])

    def test_exact_partial_alias_is_idempotent(self):
        image = self.candidate["images"][0]
        state = copy.deepcopy(self.state); state["aliases"] = {f"{image['repository']}:1.2.3": image["indexDigest"]}
        resumed = promotion.release(self.candidate, self.config, state, "1.2.3")
        fresh = promotion.release(self.candidate, self.config, self.state, "1.2.3")
        self.assertEqual(fresh, resumed)

    def test_divergent_partial_alias_is_rejected(self):
        image = self.candidate["images"][0]
        state = copy.deepcopy(self.state); state["aliases"] = {f"{image['repository']}:1.2.3": "sha256:" + "f" * 64}
        with self.assertRaisesRegex(Exception, "different digest"):
            promotion.release(self.candidate, self.config, state, "1.2.3")

    def test_repeat_and_downgrade_are_rejected(self):
        for extra in ({"gitTag": True}, {"githubRelease": True}, {"changelogSnapshot": True}):
            state = self.state | extra
            with self.assertRaises(Exception):
                promotion.release(self.candidate, self.config, state, "1.2.3")
        with self.assertRaisesRegex(Exception, "reviewed next stable"):
            promotion.release(self.candidate, self.config, self.state, "1.2.2")

    def test_stable_line_cannot_overwrite_or_move_backward(self):
        state = copy.deepcopy(self.state)
        state["previousRelease"] = {"releaseVersion": "1.2.3", "manifestDigest": "sha256:" + "6" * 64}
        with self.assertRaisesRegex(Exception, "advance"):
            promotion.release(self.candidate, self.config, state, "1.2.3")

    def test_tampered_candidate_is_rejected_before_plan(self):
        self.candidate["images"][0]["indexDigest"] = "sha256:" + "0" * 64
        with self.assertRaises(Exception):
            promotion.release(self.candidate, self.config, self.state, "1.2.3")


if __name__ == "__main__":
    unittest.main()
