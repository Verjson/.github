#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci-gate/closing-issue-visibility.py"


def load_subject():
    spec = importlib.util.spec_from_file_location("closing_issue_visibility", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load closing issue visibility module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DEFAULT_CURSOR = object()
REPOSITORY_ID = 123456789


def graphql_page(
    *references: tuple[int, str],
    state: str,
    has_next: bool = False,
    end_cursor: str | None | object = DEFAULT_CURSOR,
    reference_repository: str = "Verjson/example",
    repository_id: object = REPOSITORY_ID,
    reference_repository_id: object = REPOSITORY_ID,
) -> dict:
    nodes = [
        {
            "id": f"I_{number}",
            "number": number,
            "state": issue_state,
            "url": f"https://github.com/{reference_repository}/issues/{number}",
            "repository": {
                "databaseId": reference_repository_id,
                "nameWithOwner": reference_repository,
            },
        }
        for number, issue_state in references
    ]
    if end_cursor is DEFAULT_CURSOR:
        end_cursor = f"CURSOR_{references[-1][0]}" if references else None
    return {
        "data": {
            "repository": {
                "databaseId": repository_id,
                "nameWithOwner": "Verjson/example",
                "pullRequest": {
                    "number": 7,
                    "state": state,
                    "headRefOid": "1" * 40,
                    "closingIssuesReferences": {
                        "nodes": nodes,
                        "pageInfo": {"hasNextPage": has_next, "endCursor": end_cursor},
                    },
                }
            }
        }
    }


def pages(*graphql_pages: dict) -> str:
    return json.dumps(graphql_pages)


def api_page(graphql_page: dict) -> str:
    return json.dumps(graphql_page)


def page(*references: tuple[int, str], state: str) -> str:
    return api_page(graphql_page(*references, state=state))


class ClosingIssueVisibilityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.subject = load_subject()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.receipt = Path(self.temp.name) / "closing-issues.json"
        self.summary = Path(self.temp.name) / "summary.md"
        self.environment = {
            "TARGET_REPO": "Verjson/example",
            "GITHUB_REPOSITORY_ID": str(REPOSITORY_ID),
            "PR_NUMBER": "7",
            "EXPECTED_HEAD_SHA": "1" * 40,
            "GH_TOKEN": "caller-token",
            "GITHUB_STEP_SUMMARY": str(self.summary),
        }

    def run_cli(self, arguments: list[str], responses: list[subprocess.CompletedProcess[str]]):
        output = io.StringIO()
        with mock.patch.object(self.subject.subprocess, "run", side_effect=responses) as run:
            with contextlib.redirect_stdout(output):
                result = self.subject.main(arguments, self.environment)
        return result, output.getvalue(), run

    @staticmethod
    def response(body: str, returncode: int = 0, stderr: str = ""):
        return subprocess.CompletedProcess([], returncode, stdout=body, stderr=stderr)

    def capture(self, references: tuple[tuple[int, str], ...] = ()) -> None:
        result, output, _ = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(page(*references, state="OPEN"))],
        )
        self.assertEqual(result, 0, output)

    def tamper_receipt(
        self,
        mutation: Callable[[dict[str, Any]], object],
        references: tuple[tuple[int, str], ...] = ((10, "OPEN"),),
    ) -> None:
        self.receipt.unlink(missing_ok=True)
        self.capture(references)
        receipt = json.loads(self.receipt.read_text(encoding="utf-8"))
        mutation(receipt)
        self.receipt.write_text(json.dumps(receipt), encoding="utf-8")

    def assert_tampered_receipt_rejected(
        self,
        mutation: Callable[[dict[str, Any]], object],
        references: tuple[tuple[int, str], ...] = ((10, "OPEN"),),
    ) -> None:
        self.tamper_receipt(mutation, references)
        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [],
        )

        self.assertEqual(result, 1)
        self.assertIn("::error title=Closing issue outcome unavailable::", output)
        run.assert_not_called()

    def assert_capture_graphql_failure(self, responses: list[dict], reason: str) -> None:
        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(response)) for response in responses],
        )

        self.assertEqual(result, 1)
        self.assertIn("::error title=Closing issue capture failed::", output)
        self.assertIn(reason, output)
        self.assertNotIn("SUPER_SECRET_GRAPHQL_VARIABLE", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def assert_report_graphql_failure(
        self,
        responses: list[dict],
        reason: str,
        references: tuple[tuple[int, str], ...] = (),
    ) -> None:
        self.capture(references)
        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(api_page(response)) for response in responses],
        )

        self.assertEqual(result, 1)
        self.assertIn("::error title=Closing issue outcome unavailable::", output)
        self.assertIn(reason, output)
        self.assertNotIn("SUPER_SECRET_GRAPHQL_VARIABLE", output)
        summary = self.summary.read_text()
        self.assertIn("closing issue outcomes could not be read", summary)
        self.assertNotIn("SUPER_SECRET_GRAPHQL_VARIABLE", summary)
        self.assert_graphql_reads_only(run)

    def test_no_closing_references_reports_only_the_caller_visible_same_repository_scope(
        self,
    ) -> None:
        self.capture()

        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(page(state="MERGED"))],
        )

        self.assertEqual(result, 0, output)
        self.assertNotIn("::warning", output)
        summary = self.summary.read_text()
        self.assertIn(
            "No caller-token-visible, same-repository GitHub-resolved closing issue references",
            summary,
        )
        self.assertIn(
            "Private cross-repository references are outside this fallback's authority",
            summary,
        )
        self.assertNotIn(
            "No GitHub-resolved closing issue references were present",
            summary,
        )
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_an_accessible_cross_repository_reference(self) -> None:
        response = graphql_page(
            (10, "OPEN"),
            state="OPEN",
            reference_repository="Verjson/other-private-repository",
        )

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(response))],
        )

        self.assertEqual(result, 1)
        self.assertIn("outside the exact caller repository", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_requires_the_stable_caller_repository_id(self) -> None:
        del self.environment["GITHUB_REPOSITORY_ID"]

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [],
        )

        self.assertEqual(result, 1)
        self.assertIn("stable repository identity is missing or malformed", output)
        self.assertFalse(self.receipt.exists())
        run.assert_not_called()

    def test_capture_rejects_malformed_stable_caller_repository_ids(self) -> None:
        for repository_id in ("0", "-1", "+1", "01", "1.0", "true"):
            with self.subTest(repository_id=repository_id):
                self.environment["GITHUB_REPOSITORY_ID"] = repository_id

                result, output, run = self.run_cli(
                    ["capture", "--output", str(self.receipt)],
                    [],
                )

                self.assertEqual(result, 1)
                self.assertIn("stable repository identity is missing or malformed", output)
                self.assertFalse(self.receipt.exists())
                run.assert_not_called()

    def test_capture_rejects_a_different_target_repository_id(self) -> None:
        response = graphql_page(state="OPEN", repository_id=REPOSITORY_ID + 1)

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(response))],
        )

        self.assertEqual(result, 1)
        self.assertIn("target repository stable identity changed", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_malformed_target_repository_database_ids(self) -> None:
        for repository_id in (None, 0, -1, True, str(REPOSITORY_ID)):
            with self.subTest(repository_id=repository_id):
                response = graphql_page(state="OPEN", repository_id=repository_id)

                result, output, run = self.run_cli(
                    ["capture", "--output", str(self.receipt)],
                    [self.response(api_page(response))],
                )

                self.assertEqual(result, 1)
                self.assertIn("target repository stable identity changed", output)
                self.assertFalse(self.receipt.exists())
                self.assert_graphql_reads_only(run)

    def test_capture_rejects_non_integer_live_pull_request_numbers(self) -> None:
        for pull_request_number, expected_number in (
            (True, "1"),
            (1.0, "1"),
            ("7", "7"),
            (None, "7"),
            (0, "7"),
            (-1, "7"),
        ):
            with self.subTest(pull_request_number=pull_request_number):
                self.receipt.unlink(missing_ok=True)
                self.environment["PR_NUMBER"] = expected_number
                response = graphql_page(state="OPEN")
                response["data"]["repository"]["pullRequest"][
                    "number"
                ] = pull_request_number

                result, output, run = self.run_cli(
                    ["capture", "--output", str(self.receipt)],
                    [self.response(api_page(response))],
                )

                self.assertEqual(result, 1)
                self.assertIn("pull request state or exact head changed", output)
                self.assertFalse(self.receipt.exists())
                self.assert_graphql_reads_only(run)

    def test_capture_rejects_a_same_name_issue_repository_with_a_different_id(
        self,
    ) -> None:
        response = graphql_page(
            (10, "OPEN"),
            state="OPEN",
            reference_repository_id=REPOSITORY_ID + 1,
        )

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(response))],
        )

        self.assertEqual(result, 1)
        self.assertIn("outside the exact caller repository identity", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_persists_stable_repository_ids_in_the_snapshot(self) -> None:
        self.capture(((10, "OPEN"),))

        receipt = json.loads(self.receipt.read_text(encoding="utf-8"))

        self.assertEqual(receipt["repositoryId"], REPOSITORY_ID)
        self.assertEqual(receipt["references"][0]["repositoryId"], REPOSITORY_ID)

    def test_report_rejects_a_snapshot_with_a_different_repository_id(self) -> None:
        self.capture(((10, "OPEN"),))
        receipt = json.loads(self.receipt.read_text(encoding="utf-8"))
        receipt["repositoryId"] = REPOSITORY_ID + 1
        self.receipt.write_text(json.dumps(receipt), encoding="utf-8")

        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [],
        )

        self.assertEqual(result, 1)
        self.assertIn("does not bind this exact pull request", output)
        run.assert_not_called()

    def test_report_rejects_non_integer_receipt_pull_request_numbers(self) -> None:
        for pull_request_number, expected_number in (
            (True, "1"),
            (1.0, "1"),
            ("7", "7"),
            (None, "7"),
            (0, "7"),
            (-1, "7"),
        ):
            with self.subTest(pull_request_number=pull_request_number):
                self.environment["PR_NUMBER"] = "7"
                self.capture()
                receipt = json.loads(self.receipt.read_text(encoding="utf-8"))
                receipt["pullRequest"] = pull_request_number
                self.receipt.write_text(json.dumps(receipt), encoding="utf-8")
                self.environment["PR_NUMBER"] = expected_number

                result, output, run = self.run_cli(
                    ["report", "--input", str(self.receipt)],
                    [],
                )

                self.assertEqual(result, 1)
                self.assertIn("does not bind this exact pull request", output)
                run.assert_not_called()

    def test_report_rejects_tampered_snapshot_bindings_and_shapes(self) -> None:
        mutations = (
            ("head SHA", lambda receipt: receipt.__setitem__("headSha", "2" * 40)),
            (
                "repository name",
                lambda receipt: receipt.__setitem__("repository", "Verjson/renamed"),
            ),
            (
                "repository ID bool",
                lambda receipt: receipt.__setitem__("repositoryId", True),
            ),
            (
                "repository ID float",
                lambda receipt: receipt.__setitem__("repositoryId", float(REPOSITORY_ID)),
            ),
            (
                "repository ID string",
                lambda receipt: receipt.__setitem__("repositoryId", str(REPOSITORY_ID)),
            ),
            (
                "reference repository name",
                lambda receipt: receipt["references"][0].__setitem__(
                    "repository", "Verjson/renamed"
                ),
            ),
            (
                "reference repository ID bool",
                lambda receipt: receipt["references"][0].__setitem__(
                    "repositoryId", True
                ),
            ),
            (
                "reference repository ID float",
                lambda receipt: receipt["references"][0].__setitem__(
                    "repositoryId", float(REPOSITORY_ID)
                ),
            ),
            (
                "reference repository ID string",
                lambda receipt: receipt["references"][0].__setitem__(
                    "repositoryId", str(REPOSITORY_ID)
                ),
            ),
            (
                "issue number bool",
                lambda receipt: receipt["references"][0].__setitem__("number", True),
            ),
            (
                "issue number float",
                lambda receipt: receipt["references"][0].__setitem__("number", 10.0),
            ),
            (
                "issue number string",
                lambda receipt: receipt["references"][0].__setitem__("number", "10"),
            ),
            (
                "empty stable node ID",
                lambda receipt: receipt["references"][0].__setitem__("id", ""),
            ),
            (
                "reference URL",
                lambda receipt: receipt["references"][0].__setitem__(
                    "url", "https://github.com/Verjson/example/issues/11"
                ),
            ),
            (
                "reference state",
                lambda receipt: receipt["references"][0].__setitem__(
                    "stateBeforeMerge", "MERGED"
                ),
            ),
            (
                "extra receipt key",
                lambda receipt: receipt.__setitem__("unexpected", True),
            ),
            ("missing receipt key", lambda receipt: receipt.pop("headSha")),
            (
                "extra reference key",
                lambda receipt: receipt["references"][0].__setitem__(
                    "unexpected", True
                ),
            ),
            (
                "missing reference key",
                lambda receipt: receipt["references"][0].pop("url"),
            ),
        )

        for label, mutation in mutations:
            with self.subTest(label=label):
                self.assert_tampered_receipt_rejected(mutation)

    def test_report_rejects_tampered_stable_identity_and_issue_number(self) -> None:
        mutations = (
            (
                "stable node ID",
                lambda receipt: receipt["references"][0].__setitem__(
                    "id", "I_DIFFERENT"
                ),
            ),
            (
                "issue number",
                lambda receipt: receipt["references"][0].update(
                    {
                        "number": 11,
                        "url": "https://github.com/Verjson/example/issues/11",
                    }
                ),
            ),
        )

        for label, mutation in mutations:
            with self.subTest(label=label):
                self.tamper_receipt(mutation)
                result, output, run = self.run_cli(
                    ["report", "--input", str(self.receipt)],
                    [self.response(page((10, "CLOSED"), state="MERGED"))],
                )

                self.assertEqual(result, 1)
                self.assertIn("resolved closing issue set changed", output)
                self.assert_graphql_reads_only(run)

    def test_report_rejects_duplicate_semantic_issue_locators(self) -> None:
        def duplicate_locator(receipt: dict[str, Any]) -> None:
            receipt["references"][1].update(
                {
                    "number": 10,
                    "url": "https://github.com/Verjson/example/issues/10",
                }
            )

        self.assert_tampered_receipt_rejected(
            duplicate_locator,
            ((10, "OPEN"), (11, "OPEN")),
        )

    def test_capture_rejects_a_different_target_repository_name(self) -> None:
        response = graphql_page(state="OPEN")
        response["data"]["repository"]["nameWithOwner"] = "Verjson/renamed"

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(response))],
        )

        self.assertEqual(result, 1)
        self.assertIn("target repository stable identity changed", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_duplicate_semantic_issue_locators(self) -> None:
        response = graphql_page((10, "OPEN"), (11, "OPEN"), state="OPEN")
        duplicate = response["data"]["repository"]["pullRequest"][
            "closingIssuesReferences"
        ]["nodes"][1]
        duplicate.update(
            {
                "number": 10,
                "url": "https://github.com/Verjson/example/issues/10",
            }
        )

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(response))],
        )

        self.assertEqual(result, 1)
        self.assertIn("duplicate closing issue locators", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_report_rejects_an_accessible_cross_repository_reference(self) -> None:
        self.capture()
        response = graphql_page(
            (10, "CLOSED"),
            state="MERGED",
            reference_repository="Verjson/other-private-repository",
        )

        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(api_page(response))],
        )

        self.assertEqual(result, 1)
        self.assertIn("outside the exact caller repository", output)
        self.assertIn("outcomes could not be read", self.summary.read_text())
        self.assert_graphql_reads_only(run)

    def test_all_closed_references_are_named_without_warning(self) -> None:
        self.capture(((11, "OPEN"),))

        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(page((11, "CLOSED"), state="MERGED"))],
        )

        self.assertEqual(result, 0, output)
        self.assertNotIn("::warning", output)
        self.assertIn(
            "[Verjson/example#11](https://github.com/Verjson/example/issues/11) is closed",
            self.summary.read_text(),
        )
        self.assert_graphql_reads_only(run)

    def test_open_reference_is_visible_and_does_not_fail_completed_merge(self) -> None:
        self.capture(((12, "OPEN"),))

        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(page((12, "OPEN"), state="MERGED"))],
        )

        self.assertEqual(result, 0, output)
        self.assertIn("::warning title=Closing issue remains open::", output)
        self.assertIn("https://github.com/Verjson/example/issues/12", output)
        self.assertIn("merge-authorization intentionally lacks issues:write", output)
        self.assertIn(
            "[Verjson/example#12](https://github.com/Verjson/example/issues/12) remains open",
            self.summary.read_text(),
        )
        self.assert_graphql_reads_only(run)

    def test_mixed_references_name_closed_and_open_outcomes(self) -> None:
        self.capture(((13, "OPEN"), (14, "OPEN")))

        result, output, _ = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(page((13, "CLOSED"), (14, "OPEN"), state="MERGED"))],
        )

        self.assertEqual(result, 0, output)
        summary = self.summary.read_text()
        self.assertIn(
            "[Verjson/example#13](https://github.com/Verjson/example/issues/13) is closed",
            summary,
        )
        self.assertIn(
            "[Verjson/example#14](https://github.com/Verjson/example/issues/14) remains open",
            summary,
        )
        self.assertEqual(output.count("::warning title=Closing issue remains open::"), 1)

    def test_capture_api_failure_blocks_merge_with_visible_error(self) -> None:
        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response("", returncode=1, stderr="provider unavailable\n")],
        )

        self.assertEqual(result, 1)
        self.assertIn("::error title=Closing issue capture failed::", output)
        self.assertIn("terminal merge was withheld", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_graphql_errors_with_partial_references(self) -> None:
        response = graphql_page((20, "OPEN"), state="OPEN")
        response["errors"] = [
            {"message": "SUPER_SECRET_GRAPHQL_VARIABLE must never reach diagnostics"}
        ]
        self.assert_capture_graphql_failure(
            [response], "GitHub GraphQL response reported errors"
        )

    def test_report_rejects_graphql_errors_with_partial_references(self) -> None:
        response = graphql_page((20, "CLOSED"), state="MERGED")
        response["errors"] = [
            {"message": "SUPER_SECRET_GRAPHQL_VARIABLE must never reach diagnostics"}
        ]
        self.assert_report_graphql_failure(
            [response],
            "GitHub GraphQL response reported errors",
            ((20, "OPEN"),),
        )

    def test_capture_rejects_graphql_errors_only_response(self) -> None:
        self.assert_capture_graphql_failure(
            [
                {
                    "errors": [
                        {"message": "SUPER_SECRET_GRAPHQL_VARIABLE must stay sanitized"}
                    ]
                }
            ],
            "GitHub GraphQL response reported errors",
        )

    def test_report_rejects_graphql_errors_only_response(self) -> None:
        self.assert_report_graphql_failure(
            [
                {
                    "errors": [
                        {"message": "SUPER_SECRET_GRAPHQL_VARIABLE must stay sanitized"}
                    ]
                }
            ],
            "GitHub GraphQL response reported errors",
        )

    def test_capture_rejects_graphql_errors_with_empty_valid_connection(self) -> None:
        response = graphql_page(state="OPEN")
        response["errors"] = [
            {"message": "SUPER_SECRET_GRAPHQL_VARIABLE accompanies empty data"}
        ]
        self.assert_capture_graphql_failure(
            [response], "GitHub GraphQL response reported errors"
        )

    def test_report_rejects_graphql_errors_with_empty_valid_connection(self) -> None:
        response = graphql_page(state="MERGED")
        response["errors"] = [
            {"message": "SUPER_SECRET_GRAPHQL_VARIABLE accompanies empty data"}
        ]
        self.assert_report_graphql_failure(
            [response], "GitHub GraphQL response reported errors"
        )

    def test_capture_rejects_graphql_errors_on_later_page(self) -> None:
        first = graphql_page(
            (43, "OPEN"), state="OPEN", has_next=True, end_cursor="CURSOR_1"
        )
        second = graphql_page((44, "OPEN"), state="OPEN", end_cursor="CURSOR_2")
        second["errors"] = [
            {"message": "SUPER_SECRET_GRAPHQL_VARIABLE appears on page two"}
        ]
        self.assert_capture_graphql_failure(
            [first, second], "GitHub GraphQL response reported errors"
        )

    def test_report_rejects_graphql_errors_on_later_page(self) -> None:
        first = graphql_page(
            (45, "CLOSED"), state="MERGED", has_next=True, end_cursor="CURSOR_1"
        )
        second = graphql_page((46, "CLOSED"), state="MERGED", end_cursor="CURSOR_2")
        second["errors"] = [
            {"message": "SUPER_SECRET_GRAPHQL_VARIABLE appears on page two"}
        ]
        self.assert_report_graphql_failure(
            [first, second],
            "GitHub GraphQL response reported errors",
            ((45, "OPEN"), (46, "OPEN")),
        )

    def test_capture_rejects_malformed_graphql_errors_field(self) -> None:
        response = graphql_page(state="OPEN")
        response["errors"] = {"message": "SUPER_SECRET_GRAPHQL_VARIABLE"}
        self.assert_capture_graphql_failure(
            [response], "GitHub GraphQL response errors field was malformed"
        )

    def test_report_rejects_malformed_graphql_errors_field(self) -> None:
        response = graphql_page(state="MERGED")
        response["errors"] = "SUPER_SECRET_GRAPHQL_VARIABLE"
        self.assert_report_graphql_failure(
            [response], "GitHub GraphQL response errors field was malformed"
        )

    def test_empty_graphql_errors_list_is_allowed_for_capture_and_report(self) -> None:
        capture_response = graphql_page((47, "OPEN"), state="OPEN")
        capture_response["errors"] = []
        capture_result, capture_output, capture_run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(capture_response))],
        )
        report_response = graphql_page((47, "CLOSED"), state="MERGED")
        report_response["errors"] = []
        report_result, report_output, report_run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(api_page(report_response))],
        )

        self.assertEqual(capture_result, 0, capture_output)
        self.assertEqual(report_result, 0, report_output)
        self.assert_graphql_reads_only(capture_run)
        self.assert_graphql_reads_only(report_run)

    def test_capture_rejects_identical_duplicate_identity_across_pages(self) -> None:
        responses = [
            self.response(
                api_page(
                    graphql_page(
                        (21, "OPEN"), state="OPEN", has_next=True, end_cursor="CURSOR_1"
                    )
                )
            ),
            self.response(
                api_page(graphql_page((21, "OPEN"), state="OPEN", end_cursor="CURSOR_2"))
            ),
        ]

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            responses,
        )

        self.assertEqual(result, 1)
        self.assertIn("duplicate", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_nonprogressing_pagination_cursor(self) -> None:
        responses = [
            self.response(
                api_page(
                    graphql_page(
                        (22, "OPEN"), state="OPEN", has_next=True, end_cursor="CURSOR_1"
                    )
                )
            ),
            self.response(
                api_page(graphql_page((23, "OPEN"), state="OPEN", end_cursor="CURSOR_1"))
            ),
        ]

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            responses,
        )

        self.assertEqual(result, 1)
        self.assertIn("cursor", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_missing_cursor_when_another_page_is_claimed(self) -> None:
        response = api_page(
            graphql_page((24, "OPEN"), state="OPEN", has_next=True, end_cursor=None)
        )

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(response)],
        )

        self.assertEqual(result, 1)
        self.assertIn("cursor", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_malformed_page_info_types(self) -> None:
        malformed = graphql_page((26, "OPEN"), state="OPEN")
        malformed["data"]["repository"]["pullRequest"]["closingIssuesReferences"][
            "pageInfo"
        ]["endCursor"] = 17

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(malformed))],
        )

        self.assertEqual(result, 1)
        self.assertIn("malformed", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_final_page_without_cursor_after_pagination(self) -> None:
        responses = [
            self.response(
                api_page(
                    graphql_page(
                        (27, "OPEN"), state="OPEN", has_next=True, end_cursor="CURSOR_1"
                    )
                )
            ),
            self.response(api_page(graphql_page((28, "OPEN"), state="OPEN", end_cursor=None))),
        ]

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            responses,
        )

        self.assertEqual(result, 1)
        self.assertIn("cursor", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_page_count_above_bound(self) -> None:
        responses = [
            self.response(
                api_page(
                    graphql_page(
                        (number, "OPEN"),
                        state="OPEN",
                        has_next=True,
                        end_cursor=f"CURSOR_{number}",
                    )
                )
            )
            for number in range(1, 101)
        ]

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            responses,
        )

        self.assertEqual(result, 1)
        self.assertIn("page limit", output)
        self.assertEqual(run.call_count, 100)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_valid_multi_page_capture_and_report_preserve_the_exact_set(self) -> None:
        capture_responses = [
            self.response(
                api_page(
                    graphql_page((30, "OPEN"), state="OPEN", has_next=True, end_cursor="OPEN_1")
                )
            ),
            self.response(api_page(graphql_page((31, "OPEN"), state="OPEN", end_cursor="OPEN_2"))),
        ]
        capture_result, capture_output, capture_run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            capture_responses,
        )
        report_responses = [
            self.response(
                api_page(
                    graphql_page(
                        (30, "CLOSED"),
                        state="MERGED",
                        has_next=True,
                        end_cursor="MERGED_1",
                    )
                )
            ),
            self.response(
                api_page(graphql_page((31, "CLOSED"), state="MERGED", end_cursor="MERGED_2"))
            ),
        ]
        report_result, report_output, report_run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            report_responses,
        )

        self.assertEqual(capture_result, 0, capture_output)
        self.assertEqual(report_result, 0, report_output)
        self.assertEqual(
            [reference["number"] for reference in json.loads(self.receipt.read_text())["references"]],
            [30, 31],
        )
        self.assertNotIn("::warning", report_output)
        self.assert_graphql_reads_only(capture_run)
        self.assert_graphql_reads_only(report_run)

    def test_valid_multi_page_capture_requests_each_page_with_its_cursor(self) -> None:
        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [
                self.response(
                    api_page(
                        graphql_page(
                            (41, "OPEN"),
                            state="OPEN",
                            has_next=True,
                            end_cursor="CURSOR_1",
                        )
                    )
                ),
                self.response(
                    api_page(graphql_page((42, "OPEN"), state="OPEN", end_cursor="CURSOR_2"))
                ),
            ],
        )

        self.assertEqual(result, 0, output)
        self.assertEqual(run.call_count, 2)
        first_command = run.call_args_list[0].args[0]
        second_command = run.call_args_list[1].args[0]
        self.assertNotIn("--paginate", first_command)
        self.assertNotIn("--slurp", first_command)
        self.assertFalse(any(argument.startswith("endCursor=") for argument in first_command))
        self.assertIn("endCursor=CURSOR_1", second_command)
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_conflicting_duplicate_identity_across_pages(self) -> None:
        first = graphql_page(
            (32, "OPEN"), state="OPEN", has_next=True, end_cursor="CURSOR_1"
        )
        conflicting = graphql_page((33, "OPEN"), state="OPEN", end_cursor="CURSOR_2")
        conflicting["data"]["repository"]["pullRequest"]["closingIssuesReferences"][
            "nodes"
        ][0]["id"] = "I_32"

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(api_page(first)), self.response(api_page(conflicting))],
        )

        self.assertEqual(result, 1)
        self.assertIn("duplicate", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_aggregate_extra_page_response(self) -> None:
        response = pages(
            graphql_page((34, "OPEN"), state="OPEN", end_cursor="CURSOR_1"),
            graphql_page((35, "OPEN"), state="OPEN", end_cursor="CURSOR_2"),
        )

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(response)],
        )

        self.assertEqual(result, 1)
        self.assertIn("response page was malformed", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_cursor_on_empty_terminal_page(self) -> None:
        response = api_page(graphql_page(state="OPEN", end_cursor="UNEXPECTED_CURSOR"))

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [self.response(response)],
        )

        self.assertEqual(result, 1)
        self.assertIn("cursor", output)
        self.assertFalse(self.receipt.exists())
        self.assert_graphql_reads_only(run)

    def test_capture_rejects_missing_nodes_and_malformed_pull_request(self) -> None:
        missing_nodes = graphql_page(state="OPEN")
        del missing_nodes["data"]["repository"]["pullRequest"]["closingIssuesReferences"][
            "nodes"
        ]
        malformed_pull_request = graphql_page(state="OPEN")
        malformed_pull_request["data"]["repository"]["pullRequest"] = []

        for response in (missing_nodes, malformed_pull_request):
            with self.subTest(response=response):
                result, output, run = self.run_cli(
                    ["capture", "--output", str(self.receipt)],
                    [self.response(api_page(response))],
                )
                self.assertEqual(result, 1)
                self.assertIn("GraphQL", output)
                self.assertFalse(self.receipt.exists())
                self.assert_graphql_reads_only(run)

    def test_capture_rejects_mid_pagination_api_failure(self) -> None:
        partial_response = api_page(
            graphql_page((37, "OPEN"), state="OPEN", has_next=True, end_cursor="CURSOR_1")
        )

        result, output, run = self.run_cli(
            ["capture", "--output", str(self.receipt)],
            [
                self.response(partial_response),
                self.response("", returncode=1, stderr="page two unavailable\n"),
            ],
        )

        self.assertEqual(result, 1)
        self.assertIn("request failed", output)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(run.call_count, 2)
        self.assertIn("endCursor=CURSOR_1", run.call_args_list[1].args[0])
        self.assert_graphql_reads_only(run)

    def test_report_rejects_missing_post_merge_reference(self) -> None:
        self.capture(((38, "OPEN"),))

        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(page(state="MERGED"))],
        )

        self.assertEqual(result, 1)
        self.assertIn("resolved closing issue set changed", output)
        self.assertIn("outcome is indeterminate", self.summary.read_text())
        self.assert_graphql_reads_only(run)

    def test_report_rejects_extra_post_merge_reference(self) -> None:
        self.capture(((39, "OPEN"),))

        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(page((39, "CLOSED"), (40, "OPEN"), state="MERGED"))],
        )

        self.assertEqual(result, 1)
        self.assertIn("resolved closing issue set changed", output)
        self.assertIn("outcome is indeterminate", self.summary.read_text())
        self.assert_graphql_reads_only(run)

    def test_report_api_failure_is_visible_and_fails_post_merge_check(self) -> None:
        self.capture(((15, "OPEN"),))

        result, output, run = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response("", returncode=1, stderr="provider unavailable\n")],
        )

        self.assertEqual(result, 1)
        self.assertIn("::error title=Closing issue outcome unavailable::", output)
        self.assertIn("The merge completed, but closing issue outcomes could not be read", self.summary.read_text())
        self.assert_graphql_reads_only(run)

    def test_changed_resolved_set_fails_instead_of_reporting_partial_evidence(self) -> None:
        self.capture(((16, "OPEN"),))

        result, output, _ = self.run_cli(
            ["report", "--input", str(self.receipt)],
            [self.response(page((17, "OPEN"), state="MERGED"))],
        )

        self.assertEqual(result, 1)
        self.assertIn("resolved closing issue set changed", output)
        self.assertIn("outcome is indeterminate", self.summary.read_text())

    def assert_graphql_reads_only(self, run: mock.Mock) -> None:
        for call in run.call_args_list:
            command = call.args[0]
            self.assertEqual(command[:3], ["gh", "api", "graphql"])
            self.assertNotIn("--paginate", command)
            self.assertNotIn("--slurp", command)
            self.assertNotIn("--method", command)
            self.assertFalse(any("/issues/" in argument for argument in command))
            self.assertNotIn("ORG_ADMIN_TOKEN", " ".join(command))


if __name__ == "__main__":
    unittest.main()
