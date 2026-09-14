import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts/provisioning-delegation-validate.py"
CONTRACT = ROOT / "config/provisioning-delegation-contract.json"
INVENTORY = ROOT / "config/app-role-custody-inventory.json"
EXAMPLE = ROOT / "docs/examples/provisioning-delegation-grant.json"
PIN = "0" * 39 + "a"
DIGEST = "sha256:" + "b" * 64


def grant(**overrides):
    document = {
        "schema": "verjson-provisioning-delegation-grant/v1",
        "grant_id": "verjson-2026-09-14-release-cohort",
        "issuer": {"kind": "organization-owner", "identity": "pyousefi", "organization": "Verjson"},
        "executor": {"kind": "agent", "identity": "verjson-cli/provisioning-executor"},
        "contract_pin": {"repository": "Verjson/verjson-ci", "sha": PIN, "contract_version": "1.0.0"},
        "cohort": {
            "completeness": "exact",
            "targets": [{
                "role_id": "release",
                "repository_selection": "all",
                "repositories": [],
                "permission_ceiling": {"contents": "write", "metadata": "read"},
                "effects": ["secret-write"],
            }],
        },
        "effects": ["secret-write"],
        "owner_consent": [{
            "effect": "secret-write",
            "reference": "https://github.com/Verjson/.github/issues/1325#issuecomment-1",
            "approved_by": ["pyousefi"],
        }],
        "evidence": {
            "plan_digest": DIGEST,
            "review": {
                "kind": "github-pull-request",
                "reference": "https://github.com/Verjson/.github/pull/1339",
                "approved_by": ["pyousefi"],
            },
        },
        "expiry": {"not_before": "2026-09-14T00:00:00Z", "not_after": "2026-09-21T00:00:00Z"},
        "revocation": {
            "surface": "github-issue",
            "reference": "https://github.com/Verjson/.github/issues/1325",
        },
    }
    document.update(overrides)
    return document


class ProvisioningDelegationValidateTest(unittest.TestCase):
    def run_validator(self, document, *, contract=None, now="2026-09-15T00:00:00Z", raw=None):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            grant_path = temp / "grant.json"
            grant_path.write_text(raw if raw is not None else json.dumps(document), encoding="utf-8")
            arguments = ["--grant", str(grant_path), "--inventory", str(INVENTORY), "--now", now]
            if contract is None:
                contract_path = temp / "contract.json"
                active = json.loads(CONTRACT.read_text(encoding="utf-8"))
                active["activation"]["status"] = "active"
                contract_path.write_text(json.dumps(active), encoding="utf-8")
                arguments += ["--contract", str(contract_path)]
            else:
                arguments += ["--contract", str(contract)]
            return subprocess.run(
                ["python3", str(VALIDATOR), *arguments], capture_output=True, text=True
            )

    def receipt(self, result):
        return json.loads(result.stdout)

    def test_reviewed_owner_grant_authorizes_every_listed_action(self):
        result = self.run_validator(grant())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = self.receipt(result)
        self.assertEqual(receipt["authorization"], "granted")
        self.assertEqual(receipt["reasons"], [])
        self.assertEqual(receipt["effects"], ["secret-write"])
        self.assertEqual(receipt["targets"], ["release"])

    def test_shipped_contract_is_defined_but_not_activated(self):
        result = self.run_validator(grant(), contract=CONTRACT)
        self.assertEqual(result.returncode, 1, result.stdout)
        receipt = self.receipt(result)
        self.assertEqual(receipt["authorization"], "withheld")
        self.assertIn("contract-not-activated", receipt["reasons"])

    def test_non_object_activation_is_an_input_error(self):
        document = json.loads(CONTRACT.read_text(encoding="utf-8"))
        document["activation"] = "active"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            result = self.run_validator(grant(), contract=path)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("activation", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


    def test_agent_cannot_manufacture_its_own_authority(self):
        executor = {"kind": "agent", "identity": "verjson-cli/provisioning-executor"}
        cases = [
            (grant(issuer={"kind": "agent", "identity": "verjson-cli/provisioning-executor",
                           "organization": "Verjson"}),
             "issuer-is-not-an-owner"),
            (grant(issuer={"kind": "organization-owner",
                           "identity": "verjson-cli/provisioning-executor",
                           "organization": "Verjson"}),
             "self-issued-grant-is-not-authority"),
            (grant(evidence={
                "plan_digest": DIGEST,
                "review": {"kind": "github-pull-request",
                           "reference": "https://github.com/Verjson/.github/pull/1339",
                           "approved_by": ["verjson-cli/provisioning-executor"]},
             }),
             "executor-cannot-approve-its-own-plan"),
            (grant(evidence={
                "plan_digest": DIGEST,
                "review": {"kind": "model-response", "reference": "model said yes",
                           "approved_by": ["model"]},
             }),
             "review-reference-is-not-hosted"),
        ]
        for document, reason in cases:
            with self.subTest(reason=reason):
                document["executor"] = dict(executor)
                result = self.run_validator(document)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(reason, self.receipt(result)["reasons"])

    def test_approval_shortcut_field_is_not_authority(self):
        document = grant()
        document["approved"] = True
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 1, result.stdout)
        reasons = self.receipt(result)["reasons"]
        self.assertIn("approval-shortcut-is-not-authority", reasons)
        self.assertIn("grant-fields-unexpected", reasons)

    def test_plan_must_pin_an_immutable_contract_revision(self):
        document = grant(contract_pin={"repository": "Verjson/verjson-ci", "sha": "main",
                                       "contract_version": "1.0.0"})
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("contract-pin-is-not-immutable", self.receipt(result)["reasons"])

    def test_role_effect_boundaries_are_enforced(self):
        cases = [
            ("ruleset-audit", {"administration": "read", "metadata": "read"}, ["secret-write"],
             "effect-not-permitted-for-role:ruleset-audit:secret-write"),
            ("runner-registration",
             {"metadata": "read", "organization_self_hosted_runners": "write"}, ["secret-write"],
             "effect-not-permitted-for-role:runner-registration:secret-write"),
            ("review", {"checks": "write", "contents": "write", "metadata": "read",
                        "pull_requests": "write"}, ["secret-write"],
             "permission-ceiling-exceeded:review"),
            ("dependency-supersession", {"contents": "read", "metadata": "read",
                                         "pull_requests": "write"}, ["resource-destruction"],
             "effect-not-permitted-for-role:dependency-supersession:resource-destruction"),
        ]
        for role_id, ceiling, effects, reason in cases:
            with self.subTest(role_id=role_id, reason=reason):
                document = grant()
                document["cohort"]["targets"] = [{
                    "role_id": role_id, "repository_selection": "all", "repositories": [],
                    "permission_ceiling": ceiling, "effects": effects,
                }]
                document["effects"] = effects
                document["owner_consent"] = [{
                    "effect": effect,
                    "reference": "https://github.com/Verjson/.github/issues/1325#issuecomment-1",
                    "approved_by": ["pyousefi"],
                } for effect in effects]
                result = self.run_validator(document)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(reason, self.receipt(result)["reasons"])

    def test_incomplete_cohort_inventory_is_never_proof_of_scope(self):
        cases = [
            ({"completeness": "partial", "targets": grant()["cohort"]["targets"]},
             "cohort-inventory-incomplete"),
            ({"completeness": "exact", "targets": []}, "cohort-targets-missing"),
            ({"completeness": "exact", "targets": [{
                "role_id": "release", "repository_selection": "selected", "repositories": [],
                "permission_ceiling": {"contents": "write", "metadata": "read"},
                "effects": ["secret-write"],
             }]}, "selected-repository-inventory-incomplete:release"),
            ({"completeness": "exact", "targets": [{
                "role_id": "unknown-role", "repository_selection": "all", "repositories": [],
                "permission_ceiling": {}, "effects": [],
             }]}, "cohort-target-role-unknown"),
        ]
        for cohort, reason in cases:
            with self.subTest(reason=reason):
                result = self.run_validator(grant(cohort=cohort))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(reason, self.receipt(result)["reasons"])

    def test_grant_window_is_bounded_and_must_be_in_force(self):
        cases = [
            ("2026-09-30T00:00:00Z", grant(), "grant-not-in-force"),
            ("2026-09-13T00:00:00Z", grant(), "grant-not-in-force"),
            ("2026-09-15T00:00:00Z",
             grant(expiry={"not_before": "2026-09-14T00:00:00Z", "not_after": "2026-12-14T00:00:00Z"}),
             "expiry-window-too-long"),
            ("2026-09-15T00:00:00Z",
             grant(expiry={"not_before": "2026-09-14T00:00:00Z", "not_after": "2026-09-14T00:00:00Z"}),
             "expiry-window-invalid"),
        ]
        for now, document, reason in cases:
            with self.subTest(now=now, reason=reason):
                result = self.run_validator(document, now=now)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(reason, self.receipt(result)["reasons"])

    def test_every_gated_effect_needs_its_own_owner_consent(self):
        document = grant()
        document["cohort"]["targets"][0]["effects"] = ["secret-write", "secret-withdrawal"]
        document["effects"] = ["secret-withdrawal", "secret-write"]
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("owner-consent-required:secret-withdrawal", self.receipt(result)["reasons"])

        document["owner_consent"].append({
            "effect": "secret-withdrawal",
            "reference": "https://github.com/Verjson/.github/issues/1325#issuecomment-2",
            "approved_by": ["pyousefi"],
        })
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.receipt(result)["effects"], ["secret-withdrawal", "secret-write"])

    def test_declared_effects_must_match_the_reviewed_plan(self):
        document = grant()
        document["effects"] = ["secret-write", "governance-change"]
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("declared-effects-differ-from-plan", self.receipt(result)["reasons"])

    def test_revocation_surface_is_required(self):
        cases = [
            ({"surface": "chat-message", "reference": "https://github.com/Verjson/.github/issues/1325"},
             "revocation-surface-missing"),
            ({"surface": "github-issue", "reference": "ask the operator"},
             "revocation-reference-is-not-hosted"),
        ]
        for revocation, reason in cases:
            with self.subTest(reason=reason):
                result = self.run_validator(grant(revocation=revocation))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(reason, self.receipt(result)["reasons"])

    def test_unusable_input_fails_without_a_traceback(self):
        result = self.run_validator(None, raw="{not json")
        self.assertEqual(result.returncode, 2)
        self.assertIn("grant is unreadable", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

        result = self.run_validator(None, raw="[]")
        self.assertEqual(result.returncode, 2)
        self.assertIn("grant must be a JSON object", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_published_example_grant_matches_the_contract(self):
        document = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        result = self.run_validator(document, now=document["expiry"]["not_before"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.receipt(result)["authorization"], "granted")

        result = self.run_validator(document, contract=CONTRACT, now=document["expiry"]["not_before"])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("contract-not-activated", self.receipt(result)["reasons"])

    def test_custody_inventory_covers_every_owned_role(self):
        inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
        roles = inventory["roles"]
        self.assertEqual(set(roles), {
            "review", "merge", "release", "renovate-observation",
            "dependency-supersession", "ruleset-audit", "runner-registration",
        })
        for role_id, role in roles.items():
            with self.subTest(role_id=role_id):
                for field in ("storage", "trust", "rotation", "proof", "permissionCeiling",
                              "permittedEffects", "ownerGatedEffects", "custodyRecord"):
                    self.assertIn(field, role)
                self.assertFalse(role["rotation"]["automationAllowed"])
                self.assertTrue(role["proof"]["insufficient"])
                self.assertLessEqual(set(role["ownerGatedEffects"]), set(role["permittedEffects"]))
        self.assertEqual(roles["ruleset-audit"]["permittedEffects"], [])
        for role_id in ("review", "merge", "release"):
            self.assertEqual(roles[role_id]["storage"]["kind"], "repository-environment")
            self.assertIn("organization secret metadata presence",
                          roles[role_id]["proof"]["insufficient"])


    def test_consent_may_not_exceed_the_reviewed_plan(self):
        document = grant()
        document["owner_consent"].append({
            "effect": "governance-change",
            "reference": "https://github.com/Verjson/.github/issues/1325#issuecomment-3",
            "approved_by": ["pyousefi"],
        })
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("owner-consent-exceeds-plan:governance-change", self.receipt(result)["reasons"])

    def test_environment_configuration_is_a_permitted_gated_effect(self):
        document = grant()
        document["cohort"]["targets"][0]["effects"] = ["environment-configuration", "secret-write"]
        document["effects"] = ["environment-configuration", "secret-write"]
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("owner-consent-required:environment-configuration", self.receipt(result)["reasons"])

        document["owner_consent"].append({
            "effect": "environment-configuration",
            "reference": "https://github.com/Verjson/.github/issues/1325#issuecomment-4",
            "approved_by": ["pyousefi"],
        })
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        document["cohort"]["targets"][0]["role_id"] = "ruleset-audit"
        document["cohort"]["targets"][0]["permission_ceiling"] = {"administration": "read", "metadata": "read"}
        result = self.run_validator(document)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(
            "effect-not-permitted-for-role:ruleset-audit:environment-configuration",
            self.receipt(result)["reasons"],
        )


if __name__ == "__main__":
    unittest.main()
