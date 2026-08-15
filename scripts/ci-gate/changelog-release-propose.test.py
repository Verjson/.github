#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "release-propose.py"
SPEC = importlib.util.spec_from_file_location("release_propose", MODULE_PATH)
assert SPEC and SPEC.loader
release_propose = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_propose)


class FakeClient:
    def __init__(self, responses: dict[str, list[list[object]]]):
        self.responses = responses
        self.mutations: list[tuple[str, str, dict[str, object]]] = []

    def pages(self, path: str) -> list[object]:
        queued = self.responses.get(path)
        if not queued:
            raise AssertionError(f"unexpected or exhausted API read: {path}")
        return queued.pop(0)

    def mutate(self, method: str, path: str, payload: dict[str, object]) -> None:
        self.mutations.append((method, path, payload))


class ReleaseProposalEffectsTests(unittest.TestCase):
    repository = "Verjson/example"
    branch = "main"
    version = "v1.2.3"
    head = "a" * 40
    issue_path = "repos/Verjson/example/issues?state=open&per_page=100"
    runs_path = (
        "repos/Verjson/example/actions/workflows/release.yml/runs"
        "?event=workflow_dispatch&per_page=100"
    )

    def proposal(self, number: int, preview: str = "Preview.\n") -> dict[str, object]:
        return {
            "number": number,
            "title": f"Release proposal: {self.version}",
            "user": {"login": "github-actions[bot]"},
            "body": release_propose.proposal_body(
                self.version, self.branch, self.head, preview
            ),
        }

    def test_propose_scans_every_page_and_leaves_a_current_surface_unchanged(self) -> None:
        client = FakeClient(
            {
                self.issue_path: [
                    [
                        [{"number": 1, "title": "unrelated", "body": "ordinary"}],
                        [self.proposal(42)],
                    ]
                ]
            }
        )

        outcome = release_propose.ensure_proposal(
            client, self.repository, self.version, self.branch, self.head, "Preview.\n"
        )

        self.assertEqual("release proposal #42 is already current", outcome)
        self.assertEqual([], client.mutations)

    def test_propose_updates_the_owned_surface_instead_of_duplicating_it(self) -> None:
        client = FakeClient({self.issue_path: [[[self.proposal(42, "Old.")]]]})

        outcome = release_propose.ensure_proposal(
            client, self.repository, self.version, self.branch, self.head, "New.\n"
        )

        self.assertEqual("updated release proposal #42", outcome)
        self.assertEqual(1, len(client.mutations))
        method, path, payload = client.mutations[0]
        self.assertEqual(("PATCH", "repos/Verjson/example/issues/42"), (method, path))
        self.assertEqual("Release proposal: v1.2.3", payload["title"])
        self.assertIn("New.", payload["body"])

    def test_propose_creation_is_mocked_and_uses_one_durable_marker(self) -> None:
        client = FakeClient({self.issue_path: [[[]]]})

        outcome = release_propose.ensure_proposal(
            client, self.repository, self.version, self.branch, self.head, "Preview.\n"
        )

        self.assertEqual("created release proposal", outcome)
        self.assertEqual(
            ("POST", "repos/Verjson/example/issues"),
            client.mutations[0][:2],
        )
        self.assertEqual(
            1,
            str(client.mutations[0][2]["body"]).count(
                release_propose.PROPOSAL_MARKER
            ),
        )

    def test_propose_fails_closed_when_two_surfaces_claim_ownership(self) -> None:
        client = FakeClient(
            {self.issue_path: [[[self.proposal(7)], [self.proposal(8)]]]}
        )

        with self.assertRaisesRegex(
            release_propose.ProposalError, "multiple open release proposal"
        ):
            release_propose.ensure_proposal(
                client, self.repository, self.version, self.branch, self.head, "Preview.\n"
            )

        self.assertEqual([], client.mutations)

    def test_propose_does_not_adopt_a_foreign_issue_that_copied_the_marker(self) -> None:
        foreign = self.proposal(9)
        foreign["user"] = {"login": "maintainer"}
        client = FakeClient({self.issue_path: [[[foreign]]]})

        with self.assertRaisesRegex(
            release_propose.ProposalError, "not owned by github-actions"
        ):
            release_propose.ensure_proposal(
                client,
                self.repository,
                self.version,
                self.branch,
                self.head,
                "Preview.\n",
            )

        self.assertEqual([], client.mutations)

    def run_record(self, run_id: int = 91) -> dict[str, object]:
        return {
            "id": run_id,
            "event": "workflow_dispatch",
            "display_title": f"Release {self.version}",
            "head_sha": self.head,
        }

    def test_dispatch_scans_every_page_and_does_not_duplicate_an_exact_run(self) -> None:
        client = FakeClient(
            {
                self.runs_path: [
                    [
                        {"workflow_runs": [{"id": 1, "event": "schedule"}]},
                        {"workflow_runs": [self.run_record()]},
                    ]
                ]
            }
        )

        outcome = release_propose.ensure_dispatch(
            client,
            self.repository,
            "release.yml",
            self.branch,
            self.head,
            self.version,
            "",
            "",
            1,
            0,
        )

        self.assertEqual("release dispatch already exists as run 91", outcome)
        self.assertEqual([], client.mutations)

    def test_dispatch_posts_only_the_exact_derived_inputs_and_waits_for_receipt(self) -> None:
        client = FakeClient(
            {
                self.runs_path: [
                    [{"workflow_runs": []}],
                    [{"workflow_runs": [self.run_record(99)]}],
                ]
            }
        )

        outcome = release_propose.ensure_dispatch(
            client,
            self.repository,
            "release.yml",
            self.branch,
            self.head,
            self.version,
            "NEXT/one.md\nNEXT/two.md",
            "python",
            1,
            0,
        )

        self.assertEqual("dispatched release as run 99", outcome)
        self.assertEqual(
            [
                (
                    "POST",
                    "repos/Verjson/example/actions/workflows/release.yml/dispatches",
                    {
                        "ref": "main",
                        "inputs": {
                            "version": "v1.2.3",
                            "fragments": "NEXT/one.md\nNEXT/two.md",
                            "component": "python",
                        },
                    },
                )
            ],
            client.mutations,
        )

    def test_dispatch_fails_when_the_api_never_acknowledges_the_exact_run(self) -> None:
        client = FakeClient(
            {
                self.runs_path: [
                    [{"workflow_runs": []}],
                    [{"workflow_runs": []}],
                ]
            }
        )

        with self.assertRaisesRegex(
            release_propose.ProposalError, "no exact-version, exact-head run"
        ):
            release_propose.ensure_dispatch(
                client,
                self.repository,
                "release.yml",
                self.branch,
                self.head,
                self.version,
                "",
                "",
                1,
                0,
            )

    def test_github_failures_are_typed_without_echoing_response_content(self) -> None:
        completed = subprocess.CompletedProcess(
            ["gh"], returncode=1, stdout="sensitive stdout", stderr="sensitive stderr"
        )
        with mock.patch.object(subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(
                release_propose.ProposalError, "GitHub API request failed"
            ) as captured:
                release_propose.GitHubClient().pages(self.issue_path)

        self.assertNotIn("sensitive", str(captured.exception))

    def test_malformed_pagination_fails_closed(self) -> None:
        client = FakeClient({self.runs_path: [[[]]]})

        with self.assertRaisesRegex(
            release_propose.ProposalError, "has no workflow_runs array"
        ):
            release_propose.workflow_runs(client, self.repository, "release.yml")

    def test_default_branch_must_still_match_the_derived_head(self) -> None:
        ref_path = "repos/Verjson/example/git/ref/heads/release%2Fstable"
        client = FakeClient(
            {ref_path: [[{"object": {"sha": "b" * 40}}]]}
        )

        with self.assertRaisesRegex(
            release_propose.ProposalError, "default branch advanced"
        ):
            release_propose.require_current_head(
                client, self.repository, "release/stable", self.head
            )


class GeneratedCallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sha = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()

    def generate(self, mode: str) -> tuple[str, dict[str, object]]:
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts" / "gen-changelog-caller.sh"),
                "release-propose",
                self.sha,
                "--autonomy",
                mode,
            ],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        )
        return result.stdout, yaml.safe_load(result.stdout)

    def test_autonomy_is_fixed_in_source_with_mode_specific_permissions(self) -> None:
        for mode, permission in (("propose", "issues"), ("dispatch", "actions")):
            with self.subTest(mode=mode):
                raw, document = self.generate(mode)
                triggers = document.get("on", document.get(True))
                self.assertEqual({"schedule", "workflow_dispatch"}, set(triggers))
                self.assertNotIn("autonomy", triggers["workflow_dispatch"]["inputs"])
                job = document["jobs"]["release-propose"]
                self.assertEqual(
                    f"Verjson/.github/.github/workflows/release-propose.yml@{self.sha}",
                    job["uses"],
                )
                self.assertEqual(self.sha, job["with"]["contract_ref"])
                self.assertEqual(mode, job["with"]["autonomy"])
                self.assertEqual({"contents", permission}, set(job["permissions"]))
                self.assertNotIn("issues: write", raw if mode == "dispatch" else "")
                self.assertNotIn("actions: write", raw if mode == "propose" else "")

    def test_generator_refuses_implicit_or_invalid_autonomy(self) -> None:
        generator = str(ROOT / "scripts" / "gen-changelog-caller.sh")
        for arguments in ([], ["--autonomy", "publish"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    ["bash", generator, "release-propose", self.sha, *arguments],
                    cwd=ROOT,
                    check=False,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(2, result.returncode)

    def test_reusable_workflow_derives_and_previews_without_release_writes(self) -> None:
        raw = (ROOT / ".github" / "workflows" / "release-propose.yml").read_text(
            encoding="utf-8"
        )
        document = yaml.safe_load(raw)
        triggers = document.get("on", document.get(True))
        self.assertEqual({"workflow_call"}, set(triggers))
        self.assertEqual(
            {
                "contents": "read",
                "issues": "write",
                "actions": "write",
            },
            document["jobs"]["release-propose"]["permissions"],
        )
        self.assertEqual(
            {
                "group": "release-propose-${{ github.repository }}",
                "cancel-in-progress": False,
            },
            document["concurrency"],
        )
        self.assertIn("next-version", raw)
        self.assertIn("render-next", raw)
        self.assertIn("--as-released", raw)
        self.assertIn("scripts/release-propose.py", raw)
        self.assertNotIn("changelog.py release", raw)
        self.assertNotIn("git push", raw)
        self.assertNotIn("git tag", raw)

    def test_generated_release_run_title_is_the_dispatch_idempotency_key(self) -> None:
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts" / "gen-changelog-caller.sh"),
                "release-node",
                self.sha,
            ],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        )
        document = yaml.safe_load(result.stdout)

        self.assertEqual("Release ${{ inputs.version }}", document["run-name"])


if __name__ == "__main__":
    unittest.main()
