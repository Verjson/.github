#!/usr/bin/env python3

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("changelog.py")
SPEC = importlib.util.spec_from_file_location("changelog", MODULE_PATH)
assert SPEC and SPEC.loader
changelog = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = changelog
SPEC.loader.exec_module(changelog)


def run(repo: Path, *args: str) -> str:
    return subprocess.run(
        args,
        cwd=repo,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()


def fragment(
    root: Path,
    name: str,
    *,
    date: str = "2026-07-30",
    issue: str = "249",
    title: str = "Contract",
) -> Path:
    path = root / "NEXT" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"---\ndate: {date}\nissue: {issue}\ntitle: {title}\n---\n\nBody.\n",
        encoding="utf-8",
    )
    return path


class ChangelogContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def init_git(self) -> None:
        run(self.root, "git", "init", "-q")
        run(self.root, "git", "config", "user.name", "Test")
        run(self.root, "git", "config", "user.email", "test@example.com")

    def commit_all(self, message: str) -> None:
        run(self.root, "git", "add", ".")
        run(self.root, "git", "commit", "-qm", message)

    def test_filename_and_metadata_must_match(self) -> None:
        fragment(
            self.root,
            "2026-07-30-issue-250-contract.md",
            issue="249",
        )

        with self.assertRaisesRegex(changelog.ChangelogError, "does not match"):
            changelog.fragments(self.root)

    def test_duplicate_identity_across_canonical_and_legacy_is_rejected(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-contract.md")
        legacy = self.root / "CHANGELOG-unreleased"
        legacy.mkdir()
        (legacy / "old.md").write_text(
            "---\ndate: 2026-07-29\nissue: 249\ntitle: Old entry\n---\n\nBody.\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(changelog.ChangelogError, "duplicate identity issue:249"):
            changelog.fragments(self.root, "CHANGELOG-unreleased")

    def test_historical_next_prose_does_not_infer_duplicate_issue_identity(self) -> None:
        next_dir = self.root / "NEXT"
        next_dir.mkdir()
        (next_dir / "2026-07-01-first.md").write_text(
            "# First\n\nFollow-up context from #64.\n", encoding="utf-8"
        )
        (next_dir / "2026-07-02-second.md").write_text(
            "# Second\n\nAlso references #64.\n", encoding="utf-8"
        )

        entries = changelog.fragments(self.root, allow_legacy_next=True)

        self.assertEqual(
            {"legacy-file:2026-07-01-first.md", "legacy-file:2026-07-02-second.md"},
            {entry.identity for entry in entries},
        )

    def test_render_order_uses_metadata_not_slug_allocation(self) -> None:
        fragment(
            self.root,
            "2026-07-29-issue-300-zzz.md",
            date="2026-07-29",
            issue="300",
            title="Older",
        )
        fragment(
            self.root,
            "2026-07-30-issue-200-aaa.md",
            issue="200",
            title="Newer",
        )

        rendered = changelog.render(changelog.fragments(self.root))

        self.assertLess(rendered.index("## Newer"), rendered.index("## Older"))

    def test_release_creates_one_snapshot_consumes_fragment_and_tags_commit(self) -> None:
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-contract.md")
        self.commit_all("initial")

        changelog.release(self.root, "v1.0.0", [])

        snapshot = self.root / "CHANGELOG" / "v1.0.0.md"
        self.assertTrue(snapshot.is_file())
        self.assertFalse((self.root / "NEXT/2026-07-30-issue-249-contract.md").exists())
        self.assertEqual(run(self.root, "git", "rev-parse", "HEAD"), run(self.root, "git", "rev-list", "-n", "1", "v1.0.0"))
        self.assertEqual("", run(self.root, "git", "status", "--porcelain"))

    def test_release_refuses_to_overwrite_snapshot(self) -> None:
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-contract.md")
        snapshot = self.root / "CHANGELOG" / "v1.0.0.md"
        snapshot.parent.mkdir()
        snapshot.write_text("released\n", encoding="utf-8")
        self.commit_all("initial")

        with self.assertRaisesRegex(changelog.ChangelogError, "already exists"):
            changelog.release(self.root, "v1.0.0", [])

    def test_feature_pr_cannot_edit_aggregate_or_consume_fragment(self) -> None:
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-contract.md")
        self.commit_all("base")
        base = run(self.root, "git", "rev-parse", "HEAD")
        (self.root / "CHANGELOG.md").write_text("authored\n", encoding="utf-8")
        (self.root / "NEXT/2026-07-30-issue-249-contract.md").unlink()
        self.commit_all("feature")

        with self.assertRaisesRegex(changelog.ChangelogError, "generated aggregates"):
            changelog.check_pr(self.root, base, "HEAD")

    def test_feature_pr_cannot_consume_fragment_by_rename(self) -> None:
        self.init_git()
        original = fragment(self.root, "2026-07-30-issue-249-contract.md")
        self.commit_all("base")
        base = run(self.root, "git", "rev-parse", "HEAD")
        destination = self.root / "archive.md"
        original.rename(destination)
        self.commit_all("rename")

        with self.assertRaisesRegex(changelog.ChangelogError, "cannot consume"):
            changelog.check_pr(self.root, base, "HEAD")

    def test_feature_pr_can_rename_fragment_within_next(self) -> None:
        self.init_git()
        original = fragment(self.root, "2026-07-30-issue-249-contract.md")
        self.commit_all("base")
        base = run(self.root, "git", "rev-parse", "HEAD")
        destination = self.root / "NEXT/2026-07-30-issue-249-canonical-contract.md"
        original.rename(destination)
        self.commit_all("rename")

        changelog.check_pr(self.root, base, "HEAD")

    def test_released_snapshots_use_natural_version_order(self) -> None:
        snapshots = self.root / "CHANGELOG"
        snapshots.mkdir()
        (snapshots / "v1.9.0.md").write_text("nine\n", encoding="utf-8")
        (snapshots / "v1.10.0.md").write_text("ten\n", encoding="utf-8")
        (snapshots / "v1.10.0-rc.1.md").write_text("candidate\n", encoding="utf-8")

        rendered = changelog.render_released(self.root)

        self.assertLess(rendered.index("# v1.10.0"), rendered.index("# v1.9.0"))
        self.assertLess(
            rendered.index("# v1.10.0"),
            rendered.index("# v1.10.0-rc.1"),
        )

    def test_release_workflow_serializes_and_does_not_cancel(self) -> None:
        workflow = (
            MODULE_PATH.parent.parent / ".github/workflows/changelog-release.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("group: changelog-release-${{ github.repository }}", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("contract_ref:", workflow)
        self.assertIn("ref: ${{ inputs.contract_ref }}", workflow)
        self.assertNotIn("runs-on: ubuntu-latest", workflow)
        self.assertIn("inputs.runner != ''", workflow)
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", workflow)
        self.assertIn(
            '"$release_commit:refs/heads/$DEFAULT_BRANCH"',
            workflow,
        )
        self.assertNotIn("git symbolic-ref", workflow)

        validation_workflow = (
            MODULE_PATH.parent.parent / ".github/workflows/changelog-validate.yml"
        ).read_text(encoding="utf-8")
        self.assertNotIn("runs-on: ubuntu-latest", validation_workflow)
        self.assertIn("inputs.runner != ''", validation_workflow)


if __name__ == "__main__":
    unittest.main()
