#!/usr/bin/env python3

import copy
import importlib.util
import sys
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("container_deployment_controller.py")
SPEC = importlib.util.spec_from_file_location("container_deployment_controller", MODULE_PATH)
assert SPEC and SPEC.loader
controller = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = controller
SPEC.loader.exec_module(controller)


def release(version: str, digit: str) -> dict:
    return {
        "releaseVersion": version,
        "manifestDigest": "sha256:" + digit * 64,
    }


def configuration() -> dict:
    return {
        "schemaVersion": 1,
        "cliCommand": ["npx", "--no-install", "verjson-cloud"],
        "evidenceCommand": ["python3", "scripts/runner-deployment-evidence.py"],
        "probeCommand": ["python3", "scripts/runner-deployment-probe.py"],
        "expectedRelease": {
            "repository": "ghcr.io/verjson/verjson-github-runner-release",
            "sourceRepository": "Verjson/verjson-github-runner",
            "sourceRef": "refs/heads/main",
            "signerWorkflow": "Verjson/.github/.github/workflows/container-release.yml",
            "contractCommit": "a" * 40,
            "variant": "runner",
        },
        "fleets": {
            "production": {
                "lane": "gate",
                "project": "runner-project",
                "canary": "gha-gate-1",
                "runners": ["gha-gate-1", "gha-gate-2", "gha-gate-3"],
                "minimumAvailable": 2,
                "drainTimeoutSeconds": 600,
                "probeTimeoutSeconds": 300,
                "observationSeconds": 120,
                "runnerGroup": "trusted-production",
                "requiredLabels": ["gate", "pwsh"],
                "requiredTools": ["pwsh"],
            }
        },
    }


def evidence() -> dict:
    now = datetime.now(timezone.utc)
    selected = release("2.0.0", "2")
    return {
        "manifestIdentity": (
            "ghcr.io/verjson/verjson-github-runner-release@" + selected["manifestDigest"]
        ),
        "manifest": {
            "schemaVersion": 1,
            "releaseVersion": selected["releaseVersion"],
            "source": {"repository": "Verjson/verjson-github-runner"},
            "release": {
                "workflow": {
                    "path": ".github/workflows/container-release.yml",
                    "contractCommit": "a" * 40,
                }
            },
            "images": [
                {
                    "variant": "runner",
                    "repository": "ghcr.io/verjson/verjson-github-runner",
                    "indexDigest": "sha256:" + "3" * 64,
                }
            ],
        },
        "attestation": {
            "verified": True,
            "repository": "Verjson/verjson-github-runner",
            "sourceRef": "refs/heads/main",
            "signerWorkflow": "Verjson/.github/.github/workflows/container-release.yml",
            "contractCommit": "a" * 40,
            "subjectDigest": selected["manifestDigest"],
            "expiresAt": (now + timedelta(days=1)).isoformat().replace("+00:00", "Z"),
        },
        "requestedAt": now.isoformat().replace("+00:00", "Z"),
        "activeDeploymentCount": 0,
        "authorization": {
            "dispatcher": "release-operator",
            "reviewer": "release-approver",
            "workflowRunId": 9001,
            "environmentProtectionRuleId": 44,
        },
        "fleet": {
            "runners": [
                {
                    "name": name,
                    "release": release("1.0.0", "1"),
                    "manifestIdentity": (
                        "ghcr.io/verjson/verjson-github-runner-release@sha256:"
                        + "1" * 64
                    ),
                    "online": True,
                    "admitted": True,
                    "busy": False,
                }
                for name in ("gha-gate-1", "gha-gate-2", "gha-gate-3")
            ]
        },
    }


class FakeAdapter:
    def __init__(
        self,
        failing_probe: str | None = None,
        result_overrides: dict | None = None,
        fail_update: str | None = None,
        interrupt_update: str | None = None,
    ):
        self.calls = []
        self.failing_probe = failing_probe
        self.result_overrides = result_overrides or {}
        self.fail_update = fail_update
        self.interrupt_update = interrupt_update

    def update_runner(self, runner, manifest_identity, variant, timeout_seconds):
        self.calls.append(("update", runner, manifest_identity, variant, timeout_seconds))
        if runner == self.fail_update:
            raise controller.DeploymentError("bounded drain timed out")
        if runner == self.interrupt_update:
            raise controller.DeploymentInterrupted("runner state is not terminal")
        result = {
            "beforeDigest": "sha256:" + "1" * 64,
            "afterDigest": "sha256:" + "3" * 64,
            "drained": True,
            "online": True,
            "admitted": True,
            "labels": ["gate", "pwsh"],
            "tools": ["pwsh"],
            "runnerGroup": "trusted-production",
            "healthy": True,
            "transactionLocked": False,
            "manifestIdentity": manifest_identity,
            "availableCapacity": 3,
        }
        result.update(self.result_overrides)
        return result

    def available_capacity(self):
        self.calls.append(("capacity",))
        return 3

    def probe_runner(self, runner, timeout_seconds):
        self.calls.append(("probe", runner, timeout_seconds))
        return {
            "outcome": "failed" if runner == self.failing_probe else "passed",
            "routedRunner": runner,
        }

    def observe(self, seconds):
        self.calls.append(("observe", seconds))


class FakeClock:
    def __init__(self):
        self.value = datetime(2026, 8, 14, tzinfo=timezone.utc)

    def now(self):
        current = self.value
        self.value = current.replace(second=current.second + 1)
        return current


class DeploymentPlannerTests(unittest.TestCase):
    def test_builds_immutable_canary_first_sequential_plan(self):
        candidate = evidence()
        candidate["requestedAt"] = "2026-08-14T00:00:00Z"
        candidate["attestation"]["expiresAt"] = "2026-08-15T00:00:00Z"
        plan = controller.build_plan(
            configuration(),
            candidate,
            "production",
            now=datetime(2026, 8, 14, tzinfo=timezone.utc),
        )

        self.assertEqual(
            ["gha-gate-1", "gha-gate-2", "gha-gate-3"],
            [step["runner"] for step in plan["steps"]],
        )
        self.assertEqual(["canary", "rollout", "rollout"], [s["phase"] for s in plan["steps"]])
        self.assertEqual("sequential", plan["rolloutMode"])

    def test_rejects_mutable_manifest_tag(self):
        candidate = evidence()
        candidate["manifestIdentity"] = (
            "ghcr.io/verjson/verjson-github-runner-release:stable"
        )

        with self.assertRaisesRegex(controller.DeploymentError, "immutable digest"):
            controller.build_plan(configuration(), candidate, "production")

    def test_rejects_substituted_signer_source_or_contract_pin(self):
        for field, value, expected in (
            ("signerWorkflow", "Attacker/repo/.github/workflows/release.yml", "signer"),
            ("sourceRef", "refs/heads/feature", "source ref"),
            ("contractCommit", "b" * 40, "contract pin"),
        ):
            with self.subTest(field=field):
                candidate = evidence()
                candidate["attestation"][field] = value
                with self.assertRaisesRegex(controller.DeploymentError, expected):
                    controller.build_plan(configuration(), candidate, "production")

    def test_rejects_tampered_or_unverified_manifest_attestation(self):
        for field, value, expected in (
            ("subjectDigest", "sha256:" + "9" * 64, "subject digest"),
            ("verified", False, "not verified"),
        ):
            with self.subTest(field=field):
                candidate = evidence()
                candidate["attestation"][field] = value
                with self.assertRaisesRegex(controller.DeploymentError, expected):
                    controller.build_plan(configuration(), candidate, "production")

    def test_rejects_inventory_drift_and_insufficient_capacity(self):
        missing = evidence()
        missing["fleet"]["runners"].pop()
        with self.assertRaisesRegex(controller.DeploymentError, "inventory"):
            controller.build_plan(configuration(), missing, "production")

        insufficient = configuration()
        insufficient["fleets"]["production"]["minimumAvailable"] = 3
        with self.assertRaisesRegex(controller.DeploymentError, "capacity"):
            controller.build_plan(insufficient, evidence(), "production")

    def test_rejects_unexpected_fleet_baseline(self):
        candidate = evidence()
        candidate["fleet"]["runners"][2]["release"] = release("0.9.0", "9")
        with self.assertRaisesRegex(controller.DeploymentError, "baseline"):
            controller.build_plan(configuration(), candidate, "production")

    def test_rejects_expired_attestation_stale_request_or_concurrent_deployment(self):
        fixtures = []
        expired = evidence()
        expired["attestation"]["expiresAt"] = "2026-08-13T23:59:59Z"
        expired["requestedAt"] = "2026-08-14T00:00:00Z"
        fixtures.append((expired, "expired"))
        stale = evidence()
        stale["requestedAt"] = "2026-08-13T22:00:00Z"
        fixtures.append((stale, "stale"))
        concurrent = evidence()
        concurrent["requestedAt"] = "2026-08-14T00:00:00Z"
        concurrent["activeDeploymentCount"] = 1
        fixtures.append((concurrent, "concurrent"))

        for candidate, expected in fixtures:
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(controller.DeploymentError, expected):
                    controller.build_plan(
                        configuration(),
                        candidate,
                        "production",
                        now=datetime(2026, 8, 14, 0, 30, tzinfo=timezone.utc),
                    )


class DeploymentExecutionTests(unittest.TestCase):
    def test_persists_admission_before_any_mutation_and_rolls_out_sequentially(self):
        adapter = FakeAdapter()
        persisted = []
        plan = controller.build_plan(configuration(), evidence(), "production")

        final = controller.execute_plan(
            plan,
            configuration(),
            evidence(),
            adapter,
            lambda receipt: persisted.append(copy.deepcopy(receipt)),
            clock=FakeClock(),
        )

        self.assertEqual("admitted", persisted[0]["outcome"])
        self.assertEqual([], persisted[0]["runners"])
        self.assertEqual("succeeded", final["outcome"])
        controller.validate_receipt(final)
        self.assertEqual(
            ["gha-gate-1", "gha-gate-2", "gha-gate-3"],
            [entry["name"] for entry in final["runners"]],
        )
        self.assertEqual(
            [
                "capacity",
                "update",
                "probe",
                "observe",
                "capacity",
                "update",
                "probe",
                "capacity",
                "update",
                "probe",
            ],
            [call[0] for call in adapter.calls],
        )
        self.assertTrue(
            all(
                receipt["previousReceiptDigest"]
                == controller.receipt_digest(previous)
                for previous, receipt in zip(persisted, persisted[1:])
            )
        )

    def test_canary_failure_stops_before_observation_or_rollout(self):
        adapter = FakeAdapter(failing_probe="gha-gate-1")
        persisted = []

        final = controller.execute_plan(
            controller.build_plan(configuration(), evidence(), "production"),
            configuration(),
            evidence(),
            adapter,
            lambda receipt: persisted.append(copy.deepcopy(receipt)),
            clock=FakeClock(),
        )

        self.assertEqual("failed", final["outcome"])
        self.assertEqual(
            ["capacity", "update", "probe"], [call[0] for call in adapter.calls]
        )
        self.assertEqual("failed", final["runners"][0]["probe"])

    def test_rejects_failed_admission_evidence_before_touching_next_host(self):
        cases = (
            ({"drained": False}, "drain"),
            ({"online": False}, "online"),
            ({"labels": ["gate"]}, "labels"),
            ({"tools": []}, "tools"),
            ({"runnerGroup": "wrong"}, "runner group"),
            ({"healthy": False}, "health"),
            ({"transactionLocked": True}, "transaction lock"),
            ({"afterDigest": "sha256:" + "4" * 64}, "digest"),
        )
        for overrides, expected in cases:
            with self.subTest(expected=expected):
                adapter = FakeAdapter(result_overrides=overrides)
                persisted = []
                final = controller.execute_plan(
                    controller.build_plan(configuration(), evidence(), "production"),
                    configuration(),
                    evidence(),
                    adapter,
                    lambda receipt: persisted.append(copy.deepcopy(receipt)),
                    clock=FakeClock(),
                )
                self.assertEqual("failed", final["outcome"])
                self.assertRegex(final["failure"], expected)
                self.assertEqual(
                    ["gha-gate-1"],
                    [call[1] for call in adapter.calls if call[0] == "update"],
                )

    def test_rejects_probe_routed_to_another_host(self):
        adapter = FakeAdapter()

        def routed_elsewhere(runner, timeout_seconds):
            adapter.calls.append(("probe", runner, timeout_seconds))
            return {"outcome": "passed", "routedRunner": "gha-gate-2"}

        adapter.probe_runner = routed_elsewhere
        final = controller.execute_plan(
            controller.build_plan(configuration(), evidence(), "production"),
            configuration(),
            evidence(),
            adapter,
            lambda _receipt: None,
            clock=FakeClock(),
        )
        self.assertEqual("failed", final["outcome"])
        self.assertRegex(final["failure"], "probe routing")

    def test_mid_fleet_interruption_retains_progress_and_stops(self):
        adapter = FakeAdapter(interrupt_update="gha-gate-2")
        persisted = []
        final = controller.execute_plan(
            controller.build_plan(configuration(), evidence(), "production"),
            configuration(),
            evidence(),
            adapter,
            lambda receipt: persisted.append(copy.deepcopy(receipt)),
            clock=FakeClock(),
        )
        self.assertEqual("interrupted", final["outcome"])
        self.assertEqual(["gha-gate-1"], [r["name"] for r in final["runners"]])
        self.assertNotIn("gha-gate-3", [call[1] for call in adapter.calls if call[0] == "update"])

    def test_capacity_drop_stops_before_next_runner_mutation(self):
        adapter = FakeAdapter()
        capacities = iter((3, 2))

        def capacity():
            adapter.calls.append(("capacity",))
            return next(capacities)

        adapter.available_capacity = capacity
        final = controller.execute_plan(
            controller.build_plan(configuration(), evidence(), "production"),
            configuration(),
            evidence(),
            adapter,
            lambda _receipt: None,
            clock=FakeClock(),
        )
        self.assertEqual("failed", final["outcome"])
        self.assertRegex(final["failure"], "capacity")
        self.assertEqual(
            ["gha-gate-1"], [call[1] for call in adapter.calls if call[0] == "update"]
        )

    def test_dry_run_has_no_receipt_or_runner_side_effect(self):
        adapter = FakeAdapter()
        persisted = []
        plan = controller.build_plan(configuration(), evidence(), "production")

        result = controller.execute_plan(
            plan,
            configuration(),
            evidence(),
            adapter,
            persisted.append,
            dry_run=True,
        )

        self.assertIs(result, plan)
        self.assertEqual([], adapter.calls)
        self.assertEqual([], persisted)

    def test_failed_admission_persistence_prevents_mutation(self):
        adapter = FakeAdapter()

        def fail_persist(_receipt):
            raise OSError("retention unavailable")

        with self.assertRaisesRegex(OSError, "retention unavailable"):
            controller.execute_plan(
                controller.build_plan(configuration(), evidence(), "production"),
                configuration(),
                evidence(),
                adapter,
                fail_persist,
            )

        self.assertEqual([], adapter.calls)

    def test_rollback_must_bind_failed_attempt_baseline(self):
        source = controller.admitted_receipt(
            controller.build_plan(configuration(), evidence(), "production"),
            configuration(),
            evidence(),
            FakeClock().now(),
        )
        source["outcome"] = "failed"
        source["completedAt"] = "2026-08-14T00:01:00Z"
        rollback_evidence = evidence()
        rollback_evidence["manifestIdentity"] = rollback_evidence["fleet"]["runners"][0][
            "manifestIdentity"
        ]
        rollback_evidence["manifest"]["releaseVersion"] = "1.0.0"
        rollback_evidence["attestation"]["subjectDigest"] = release("1.0.0", "1")[
            "manifestDigest"
        ]

        plan = controller.build_plan(
            configuration(),
            rollback_evidence,
            "production",
            action="rollback",
            rollback_source=source,
        )

        self.assertEqual("rollback", plan["action"])
        self.assertEqual(source["attemptId"], plan["rollbackOfAttempt"]["attemptId"])

        adapter = FakeAdapter()
        controller.execute_plan(
            plan,
            configuration(),
            rollback_evidence,
            adapter,
            lambda _receipt: None,
            clock=FakeClock(),
        )
        self.assertTrue(
            all(
                call[2] == rollback_evidence["manifestIdentity"]
                for call in adapter.calls
                if call[0] == "update"
            )
        )

    def test_rollback_failure_stops_before_remaining_hosts(self):
        source_plan = controller.build_plan(configuration(), evidence(), "production")
        source = controller.admitted_receipt(
            source_plan, configuration(), evidence(), FakeClock().now()
        )
        source["outcome"] = "failed"
        source["completedAt"] = "2026-08-14T00:01:00Z"
        source["failure"] = "fixture failure"
        rollback_evidence = evidence()
        rollback_evidence["manifestIdentity"] = rollback_evidence["fleet"]["runners"][0][
            "manifestIdentity"
        ]
        rollback_evidence["manifest"]["releaseVersion"] = "1.0.0"
        rollback_evidence["attestation"]["subjectDigest"] = release("1.0.0", "1")[
            "manifestDigest"
        ]
        plan = controller.build_plan(
            configuration(),
            rollback_evidence,
            "production",
            action="rollback",
            rollback_source=source,
        )
        adapter = FakeAdapter(interrupt_update="gha-gate-1")
        final = controller.execute_plan(
            plan,
            configuration(),
            rollback_evidence,
            adapter,
            lambda _receipt: None,
            clock=FakeClock(),
        )
        self.assertEqual("interrupted", final["outcome"])
        self.assertEqual(
            ["gha-gate-1"], [call[1] for call in adapter.calls if call[0] == "update"]
        )

    def test_partial_failure_rollback_accepts_only_recorded_mixed_fleet(self):
        source_plan = controller.build_plan(configuration(), evidence(), "production")
        source = controller.admitted_receipt(
            source_plan, configuration(), evidence(), FakeClock().now()
        )
        source["outcome"] = "failed"
        source["completedAt"] = "2026-08-14T00:01:00Z"
        source["failure"] = "probe failed"
        source["previousReceiptDigest"] = "sha256:" + "0" * 64
        source["finalFleet"][0]["release"] = copy.deepcopy(source["selectedRelease"])

        rollback_evidence = evidence()
        rollback_evidence["fleet"]["runners"][0]["release"] = copy.deepcopy(
            source["selectedRelease"]
        )
        rollback_evidence["fleet"]["runners"][0]["manifestIdentity"] = source_plan[
            "manifestIdentity"
        ]
        rollback_evidence["manifestIdentity"] = rollback_evidence["fleet"]["runners"][1][
            "manifestIdentity"
        ]
        rollback_evidence["manifest"]["releaseVersion"] = "1.0.0"
        rollback_evidence["attestation"]["subjectDigest"] = release("1.0.0", "1")[
            "manifestDigest"
        ]

        plan = controller.build_plan(
            configuration(),
            rollback_evidence,
            "production",
            action="rollback",
            rollback_source=source,
        )
        self.assertEqual(source["observedDeployedRelease"], plan["selectedRelease"])

        rollback_evidence["fleet"]["runners"][2]["release"] = release("0.9.0", "9")
        with self.assertRaisesRegex(controller.DeploymentError, "source final state"):
            controller.build_plan(
                configuration(),
                rollback_evidence,
                "production",
                action="rollback",
                rollback_source=source,
            )

    def test_idempotent_resume_skips_recorded_completed_runners(self):
        adapter = FakeAdapter()
        persisted = []
        plan = controller.build_plan(configuration(), evidence(), "production")
        previous = controller.admitted_receipt(
            plan, configuration(), evidence(), FakeClock().now()
        )
        previous["outcome"] = "in_progress"
        previous["previousReceiptDigest"] = "sha256:" + "0" * 64
        previous["runners"] = [
            {
                "name": "gha-gate-1",
                "beforeDigest": "sha256:" + "1" * 64,
                "afterDigest": "sha256:" + "3" * 64,
                "probe": "passed",
                "completedAt": "2026-08-14T00:00:01Z",
            }
        ]

        final = controller.execute_plan(
            plan,
            configuration(),
            evidence(),
            adapter,
            lambda receipt: persisted.append(copy.deepcopy(receipt)),
            previous_receipt=previous,
            clock=FakeClock(),
        )

        self.assertEqual("succeeded", final["outcome"])
        self.assertNotIn("gha-gate-1", [call[1] for call in adapter.calls if call[0] == "update"])

    def test_process_adapter_keeps_secret_out_of_arguments_and_never_scales(self):
        completed = mock.Mock()
        completed.stdout = "runner update complete"
        config = configuration()
        fleet = config["fleets"]["production"]
        adapter = controller.ProcessAdapter(config, fleet)
        with mock.patch.dict(
            controller.os.environ,
            {"VERJSON_RUNNER_DEPLOY_TOKEN": "redacted-fixture"},
            clear=False,
        ), mock.patch.object(
            controller.subprocess, "run", return_value=completed
        ) as run, mock.patch.object(controller.ProcessAdapter, "_run", return_value={}):
            adapter.update_runner(
                "gha-gate-1",
                "ghcr.io/verjson/verjson-github-runner-release@sha256:" + "2" * 64,
                "runner",
                600,
            )

        command = run.call_args.args[0]
        self.assertIn("--only", command)
        self.assertNotIn("redacted-fixture", command)
        self.assertTrue({"--replicas", "--standard", "create", "resize"}.isdisjoint(command))
        self.assertEqual(
            "redacted-fixture",
            run.call_args.kwargs["env"]["DIGITALOCEAN_ACCESS_TOKEN"],
        )
        self.assertEqual(720, run.call_args.kwargs["timeout"])


if __name__ == "__main__":
    unittest.main()
