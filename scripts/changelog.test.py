#!/usr/bin/env python3

import contextlib
import importlib.util
import io
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
    issue: str | None = "249",
    title: str = "Contract",
    identity_id: str | None = None,
    refs: str | None = None,
    summary: str | None = None,
    component: str | None = None,
    impact: str | None = None,
    body: str = "Body.",
) -> Path:
    path = root / "NEXT" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"date: {date}"]
    if identity_id is not None:
        lines.append(f"id: {identity_id}")
    elif issue is not None:
        lines.append(f"issue: {issue}")
    if refs is not None:
        lines.append(f"refs: {refs}")
    if summary is not None:
        lines.append(f"summary: {summary}")
    if component is not None:
        lines.append(f"component: {component}")
    if impact is not None:
        lines.append(f"impact: {impact}")
    lines.append(f"title: {title}")
    front = "\n".join(lines)
    path.write_text(f"---\n{front}\n---\n\n{body}\n", encoding="utf-8")
    return path


# A real lead is wrapped prose, not one line — the median across the release
# that prompted #426 was six lines. A split on the newline rather than the
# blank line would keep only "The lead paragraph," and pass a one-line fixture.
DIARY = """The lead paragraph,
which is what a release note needs.

## Why

A long argument nobody reading release notes asked for.

- a list
- another item
"""


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

    # --- refs: linkage separated from identity (#316) --------------------------
    # Identity must stay unique, so only one entry per issue can carry `issue:`.
    # Before `refs`, every other entry for that issue silently lost its release
    # back-link, because only issue-form identities render `#n`.

    def test_refs_render_back_links_for_entries_that_do_not_own_the_issue(self) -> None:
        fragment(
            self.root,
            "2026-07-30-issue-20260730T090000Z-transport.md",
            identity_id="20260730T090000Z",
            refs="13",
            title="Gateway transport",
        )
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("_Date: 2026-07-30; id:20260730T090000Z; refs #13_", rendered)

    def test_refs_accepts_several_issues_and_normalizes_hashes(self) -> None:
        fragment(
            self.root,
            "2026-07-30-issue-249-many.md",
            issue="249",
            refs="#13, 14",
            title="Several",
        )
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("_Date: 2026-07-30; issue #249; refs #13, #14_", rendered)

    def test_fragment_without_refs_renders_exactly_as_before(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-plain.md", issue="249")
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("_Date: 2026-07-30; issue #249_", rendered)
        self.assertNotIn("refs", rendered)

    # YAML requires a quoted scalar wherever a value contains `: `, so every
    # `Fix: …` title is quoted by anyone who checks their fragment parses. The
    # line-wise parser kept the quotes, so those fragments — the correct ones —
    # rendered `## 'Fix: …'` into an immutable released snapshot (#420).
    def test_single_quoted_title_renders_without_its_quotes(self) -> None:
        fragment(
            self.root, "2026-07-30-issue-249-single.md", title="'Fix: the thing'"
        )
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("## Fix: the thing\n", rendered)
        self.assertNotIn("'Fix", rendered)

    def test_double_quoted_title_renders_without_its_quotes(self) -> None:
        fragment(
            self.root, "2026-07-30-issue-249-double.md", title='"Fix: the thing"'
        )
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("## Fix: the thing\n", rendered)
        self.assertNotIn('"Fix', rendered)

    def test_unquoted_title_containing_a_colon_is_unchanged(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-bare.md", title="Fix: the thing")
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("## Fix: the thing\n", rendered)

    def test_doubled_quote_inside_a_single_quoted_title_becomes_one_quote(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-esc.md", title="'It''s fixed'")
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("## It's fixed\n", rendered)

    def test_escaped_quote_inside_a_double_quoted_title_survives(self) -> None:
        fragment(
            self.root, "2026-07-30-issue-249-dq.md", title='"Say \\"go\\" once"'
        )
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn('## Say "go" once\n', rendered)

    # A title that merely opens and closes with a quote character is not a
    # quoted scalar. Stripping by position rather than by structure would eat
    # real characters and silently corrupt the heading.
    # The parser leaves this shape alone rather than corrupting it, and
    # `validate` then refuses it: a snapshot is immutable, so ambiguous quoting
    # has to fail while the fragment is still editable (#425).
    def test_title_that_only_begins_and_ends_with_quotes_is_rejected(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-pair.md", title='"a" and "b"')
        with self.assertRaises(changelog.ChangelogError) as caught:
            changelog.load_canonical(path)
        self.assertIn("not a single quoted scalar", str(caught.exception))

    def test_lone_quote_inside_a_single_quoted_title_is_rejected(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-lone.md", title="'a' or 'b'")
        with self.assertRaises(changelog.ChangelogError) as caught:
            changelog.load_canonical(path)
        self.assertIn("not a single quoted scalar", str(caught.exception))

    def test_the_rejection_names_both_ways_out(self) -> None:
        # The fix is not obvious from the symptom, so the error has to carry it.
        path = fragment(self.root, "2026-07-30-issue-249-how.md", title="'a' or 'b'")
        with self.assertRaises(changelog.ChangelogError) as caught:
            changelog.load_canonical(path)
        message = str(caught.exception)
        self.assertIn("remove the outer pair", message)
        self.assertIn("escape the interior", message)

    # The rejection must not swallow titles that merely contain quotes, nor the
    # correctly-quoted ones the parser already resolves — those are the spelling
    # the contract wants, and failing them would re-invert the incentive #420
    # fixed.
    def test_a_title_with_interior_quotes_is_accepted(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-mid.md", title='Say "go" once')
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn('## Say "go" once\n', rendered)

    def test_a_title_that_only_starts_with_a_quote_is_accepted(self) -> None:
        # Both ends have to match for this to be quoting at all. Checking only
        # the opening character would reject ordinary prose that happens to
        # begin with a quoted word.
        fragment(self.root, "2026-07-30-issue-249-open.md", title='"go" is the fix')
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn('## "go" is the fix\n', rendered)

    def test_a_title_that_only_ends_with_a_quote_is_accepted(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-close.md", title='the fix is "go"')
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn('## the fix is "go"\n', rendered)

    def test_a_correctly_quoted_title_is_still_accepted(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-ok.md", title="'Fix: the thing'")
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("## Fix: the thing\n", rendered)

    def test_a_title_that_resolves_to_quotes_is_accepted(self) -> None:
        # `'''a'''` is a valid scalar denoting `'a'`. The author said what they
        # meant, so the result keeping its quotes is not ambiguity.
        fragment(self.root, "2026-07-30-issue-249-nest.md", title="'''a'''")
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("## 'a'\n", rendered)

    # Quoting is legal on every scalar, not just the one that exposed the bug.
    # A quoted identity used to reach `int()` with its quotes still attached.
    def test_quoted_issue_number_still_identifies_the_entry(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-qid.md", issue="'249'")
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("_Date: 2026-07-30; issue #249_", rendered)

    # Every repository pins its own contract SHA, so rejecting an unknown key
    # makes each future metadata addition breaking: the fragment fails in every
    # repository that has not bumped, and again on any backward pin (#424).
    def test_unknown_metadata_warns_instead_of_failing(self) -> None:
        path = self.root / "NEXT" / "2026-07-30-issue-249-fwd.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "---\ndate: 2026-07-30\nissue: 249\ntitle: Forward\n"
            "future-field: a key this contract does not know\n---\n\nBody.\n",
            encoding="utf-8",
        )
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            entry = changelog.load_canonical(path)
        self.assertEqual(entry.metadata["title"], "Forward")
        self.assertIn("future-field", stderr.getvalue())

    def test_an_unknown_key_does_not_become_a_renderable_field(self) -> None:
        # Tolerating the key must not mean honouring it. An older contract that
        # silently rendered a field it does not understand would be worse than
        # one that rejected it.
        path = self.root / "NEXT" / "2026-07-30-issue-249-ignored.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "---\ndate: 2026-07-30\nissue: 249\ntitle: Forward\n"
            "future-field: SHOULD-NOT-APPEAR\n---\n\nBody.\n",
            encoding="utf-8",
        )
        with contextlib.redirect_stderr(io.StringIO()):
            rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertNotIn("SHOULD-NOT-APPEAR", rendered)

    def test_a_typo_in_a_required_key_still_fails(self) -> None:
        # The relaxation must not swallow the failures it was never meant to
        # cover: `titel:` leaves `title:` absent, which is still an error.
        path = self.root / "NEXT" / "2026-07-30-issue-249-typo.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "---\ndate: 2026-07-30\nissue: 249\ntitel: Typo\n---\n\nBody.\n",
            encoding="utf-8",
        )
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(changelog.ChangelogError) as caught:
                changelog.load_canonical(path)
        self.assertIn("title is required", str(caught.exception))

    def test_a_fragment_with_only_known_keys_warns_about_nothing(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-clean.md")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            changelog.load_canonical(path)
        self.assertEqual(stderr.getvalue(), "")

    def test_refs_may_not_repeat_the_entry_own_issue(self) -> None:
        path = fragment(
            self.root, "2026-07-30-issue-249-self.md", issue="249", refs="249"
        )
        with self.assertRaises(changelog.ChangelogError) as caught:
            changelog.load_canonical(path)
        self.assertIn("own issue #249", str(caught.exception))

    def test_refs_rejects_duplicates_and_non_numbers(self) -> None:
        for value, expected in (("13, 13", "more than once"), ("abc", "positive issue numbers")):
            path = fragment(
                self.root, "2026-07-30-issue-249-bad.md", issue="249", refs=value
            )
            with self.assertRaises(changelog.ChangelogError) as caught:
                changelog.load_canonical(path)
            self.assertIn(expected, str(caught.exception))

    def test_refs_does_not_create_an_identity_so_two_entries_may_share_one_issue(self) -> None:
        # The whole point: eight fragments can be work on one issue without
        # colliding, which duplicate `issue:` identities would.
        fragment(
            self.root, "2026-07-30-issue-13-owner.md", issue="13", title="Owner"
        )
        fragment(
            self.root,
            "2026-07-30-issue-20260730T090000Z-sibling.md",
            identity_id="20260730T090000Z",
            refs="13",
            title="Sibling",
        )
        rendered = changelog.render(list(changelog.fragments(self.root)))
        self.assertIn("_Date: 2026-07-30; issue #13_", rendered)
        self.assertIn("_Date: 2026-07-30; id:20260730T090000Z; refs #13_", rendered)

    def test_refs_is_validated_at_validate_time_not_only_at_release(self) -> None:
        fragment(
            self.root, "2026-07-30-issue-249-late.md", issue="249", refs="nope"
        )
        with self.assertRaises(changelog.ChangelogError):
            list(changelog.fragments(self.root))

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

    # --- identity is a key, not a spelling (#434) -------------------------------
    # `identity` is lower-cased so two spellings of one hexadecimal id cannot
    # become two entries. That is right for comparison and wrong for the page:
    # a timestamp identity is ISO-8601, where `T` and `Z` are literals.

    def test_a_timestamp_identity_keeps_its_iso_8601_letters(self) -> None:
        fragment(
            self.root,
            "2026-08-05-issue-20260805T000000Z-issueless.md",
            identity_id="20260805T000000Z",
            issue=None,
            date="2026-08-05",
        )

        rendered = changelog.render(list(changelog.fragments(self.root)))

        self.assertIn("id:20260805T000000Z", rendered)
        self.assertNotIn("20260805t000000z", rendered)

    def test_a_hexadecimal_identity_renders_as_written(self) -> None:
        fragment(
            self.root,
            "2026-08-05-issue-ABC123-hex.md",
            identity_id="ABC123",
            issue=None,
            date="2026-08-05",
        )

        rendered = changelog.render(list(changelog.fragments(self.root)))

        self.assertIn("id:ABC123", rendered)

    def test_two_spellings_of_one_id_are_still_one_identity(self) -> None:
        # The whole reason the key is normalised. Rendering the author's
        # spelling must not buy a cosmetic fix with a duplicate-entry bug.
        fragment(self.root, "2026-08-05-issue-ABC123-upper.md",
                 identity_id="ABC123", issue=None, date="2026-08-05")
        fragment(self.root, "2026-08-05-issue-abc123-lower.md",
                 identity_id="abc123", issue=None, date="2026-08-05")

        with self.assertRaisesRegex(changelog.ChangelogError, "duplicate identity"):
            changelog.fragments(self.root)

    def test_an_issue_identity_still_renders_as_a_hash_reference(self) -> None:
        fragment(self.root, "2026-08-05-issue-249-plainer.md", issue="249", date="2026-08-05")

        rendered = changelog.render(list(changelog.fragments(self.root)))

        self.assertIn("_Date: 2026-08-05; issue #249_", rendered)

    # --- two audiences, two renderings (#426) ----------------------------------
    # The org convention asks a fragment to carry its rationale, so one renderer
    # shipped the engineering diary as release notes: 174 KB for 62 entries in
    # the first release cut under this contract, and a released snapshot cannot
    # be edited afterwards.

    def test_a_released_snapshot_keeps_the_lead_and_drops_the_argument(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-diary.md", body=DIARY)

        released = changelog.render(changelog.fragments(self.root), released=True)

        self.assertIn("The lead paragraph,\nwhich is what a release note needs.", released)
        self.assertNotIn("## Why", released)
        self.assertNotIn("- a list", released)

    def test_the_running_log_still_carries_the_whole_body(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-diary.md", body=DIARY)

        rendered = changelog.render(changelog.fragments(self.root))

        self.assertIn("## Why", rendered)
        self.assertIn("- a list", rendered)

    def test_a_lead_that_merely_looks_like_a_heading_is_left_whole(self) -> None:
        # The lead is a plain blank-line split on purpose. Detecting block types
        # to find "real" prose flagged 7 of 62 entries that open like this one,
        # none of which is a heading in CommonMark.
        fragment(
            self.root,
            "2026-07-30-issue-249-hash.md",
            body="#79 threaded its own reply, so the poller never woke.\n\n## Why\n\nLong.\n",
        )

        released = changelog.render(changelog.fragments(self.root), released=True)

        self.assertIn("#79 threaded its own reply, so the poller never woke.", released)
        self.assertNotIn("## Why", released)

    def test_summary_overrides_the_lead_for_the_released_form(self) -> None:
        fragment(
            self.root,
            "2026-07-30-issue-249-diary.md",
            summary="Poller now wakes on threaded replies.",
            body=DIARY,
        )

        released = changelog.render(changelog.fragments(self.root), released=True)

        self.assertIn("Poller now wakes on threaded replies.", released)
        self.assertNotIn("The lead paragraph", released)

    def test_folded_summary_joins_indented_continuation_lines(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-folded.md", body=DIARY)
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "title: Contract",
                "summary: >-\n"
                "  Poller now wakes on threaded\n"
                "  replies.\n"
                "title: Contract",
            ),
            encoding="utf-8",
        )

        released = changelog.render(changelog.fragments(self.root), released=True)

        self.assertIn("Poller now wakes on threaded replies.", released)
        self.assertNotIn("The lead paragraph", released)

    def test_folded_summary_preserves_paragraph_breaks(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-paragraphs.md", body=DIARY)
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "title: Contract",
                "summary: >-\n"
                "  Poller now wakes.\n"
                "\n"
                "  Threaded replies are handled.\n"
                "title: Contract",
            ),
            encoding="utf-8",
        )

        entry = changelog.fragments(self.root)[0]

        self.assertEqual(
            "Poller now wakes.\nThreaded replies are handled.",
            entry.metadata["summary"],
        )

    def test_literal_summary_preserves_indented_continuation_lines(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-literal.md", body=DIARY)
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "title: Contract",
                "summary: |-\n"
                "  Poller now wakes.\n"
                "  Threaded replies are handled.\n"
                "title: Contract",
            ),
            encoding="utf-8",
        )

        released = changelog.render(changelog.fragments(self.root), released=True)

        self.assertIn("Poller now wakes.\nThreaded replies are handled.", released)

    def test_keep_chomping_preserves_trailing_summary_lines(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-keep.md", body=DIARY)
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "title: Contract",
                "summary: >+\n"
                "  Poller now wakes.\n"
                "\n"
                "\n"
                "title: Contract",
            ),
            encoding="utf-8",
        )

        entry = changelog.fragments(self.root)[0]

        self.assertEqual("Poller now wakes.\n\n\n", entry.metadata["summary"])

    def test_summary_block_ends_at_the_next_metadata_key(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-next-key.md", body=DIARY)
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "title: Contract",
                "summary: >\n"
                "  Poller now wakes on threaded replies.\n"
                "title: Contract",
            ),
            encoding="utf-8",
        )

        entry = changelog.fragments(self.root)[0]

        self.assertEqual("Poller now wakes on threaded replies.\n", entry.metadata["summary"])
        self.assertEqual("Contract", entry.metadata["title"])

    def test_summary_block_without_an_indented_continuation_is_rejected(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-empty-block.md", body=DIARY)
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "title: Contract",
                "summary: >-\ntitle: Contract",
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            changelog.ChangelogError,
            "summary block scalar requires an indented continuation",
        ):
            changelog.fragments(self.root)

    def test_unindented_summary_continuation_is_rejected(self) -> None:
        path = fragment(self.root, "2026-07-30-issue-249-unindented.md", body=DIARY)
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "title: Contract",
                "summary: >-\nPoller now wakes.\ntitle: Contract",
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            changelog.ChangelogError,
            "summary block scalar requires an indented continuation",
        ):
            changelog.fragments(self.root)

    def test_malformed_summary_block_indicator_is_rejected(self) -> None:
        fragment(
            self.root,
            "2026-07-30-issue-249-bad-indicator.md",
            summary=">-unexpected",
            body=DIARY,
        )

        with self.assertRaisesRegex(
            changelog.ChangelogError,
            "invalid summary block scalar indicator",
        ):
            changelog.fragments(self.root)

    def test_single_line_summary_behavior_is_unchanged(self) -> None:
        path = fragment(
            self.root,
            "2026-07-30-issue-249-single-line.md",
            summary="Poller: now wakes on threaded replies.",
            body=DIARY,
        )

        entry = changelog.fragments(self.root)[0]

        self.assertEqual(
            "Poller: now wakes on threaded replies.",
            entry.metadata["summary"],
        )

    def test_summary_does_not_touch_the_running_log(self) -> None:
        # `summary` is a release-note override, not a replacement for the diary.
        fragment(
            self.root,
            "2026-07-30-issue-249-diary.md",
            summary="Poller now wakes on threaded replies.",
            body=DIARY,
        )

        rendered = changelog.render(changelog.fragments(self.root))

        self.assertIn("## Why", rendered)
        self.assertNotIn("Poller now wakes on threaded replies.", rendered)

    def test_a_summary_that_is_an_empty_quoted_scalar_is_rejected(self) -> None:
        # `summary:` with nothing after it never reaches validation — the line
        # parser rejects a blank value. `summary: ''` does: it is a well-formed
        # line whose scalar resolves to nothing, and it would silently blank the
        # entry's only released text.
        fragment(self.root, "2026-07-30-issue-249-blank.md", summary="''", body=DIARY)

        with self.assertRaisesRegex(changelog.ChangelogError, "summary must not be empty"):
            changelog.fragments(self.root)

    def test_an_ambiguously_quoted_summary_is_rejected_by_name(self) -> None:
        # It reaches the immutable snapshot exactly as the title does, so it is
        # held to the same standard, and the error says which field is wrong.
        fragment(
            self.root,
            "2026-07-30-issue-249-quoted.md",
            summary='"go" is now "vet"',
        )

        with self.assertRaisesRegex(changelog.ChangelogError, "summary opens and closes"):
            changelog.fragments(self.root)

    def test_release_writes_the_released_form_not_the_diary(self) -> None:
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-diary.md", body=DIARY)
        self.commit_all("initial")

        changelog.release(self.root, "v1.0.0", [])

        snapshot = (self.root / "CHANGELOG/v1.0.0.md").read_text(encoding="utf-8")
        self.assertIn("The lead paragraph,\nwhich is what a release note needs.", snapshot)
        self.assertNotIn("## Why", snapshot)
        self.assertIn("_Date: 2026-07-30; issue #249_", snapshot)

    def test_default_render_selects_only_unscoped_fragments(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-default.md", title="Default")
        fragment(
            self.root,
            "2026-07-30-issue-250-python.md",
            issue="250",
            title="Python",
            component="python",
        )

        rendered = changelog.render_next(self.root)

        self.assertIn("## Default", rendered)
        self.assertNotIn("## Python", rendered)

    def test_impact_defaults_to_patch_and_does_not_change_rendered_notes(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-default.md", title="Default")

        entries = changelog.fragments(self.root)

        self.assertEqual("patch", changelog.release_impact(entries))
        self.assertNotIn("impact", changelog.render(entries))

    def test_invalid_release_impact_is_rejected_during_fragment_validation(self) -> None:
        fragment(
            self.root,
            "2026-07-30-issue-249-invalid-impact.md",
            impact="breaking",
        )

        with self.assertRaisesRegex(changelog.ChangelogError, "impact"):
            changelog.fragments(self.root)

    def test_mixed_release_impacts_choose_the_highest_selected_impact(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-patch.md", impact="patch")
        fragment(
            self.root,
            "2026-07-30-issue-250-major.md",
            issue="250",
            impact="major",
        )
        fragment(
            self.root,
            "2026-07-30-issue-251-minor.md",
            issue="251",
            impact="minor",
        )

        self.assertEqual("major", changelog.release_impact(changelog.fragments(self.root)))

    def test_component_render_selects_only_that_component(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-default.md", title="Default")
        fragment(
            self.root,
            "2026-07-30-issue-250-python.md",
            issue="250",
            title="Python",
            component="python",
        )
        fragment(
            self.root,
            "2026-07-30-issue-251-node.md",
            issue="251",
            title="Node",
            component="node",
        )

        rendered = changelog.render_next(self.root, component="python")

        self.assertIn("## Python", rendered)
        self.assertNotIn("## Default", rendered)
        self.assertNotIn("## Node", rendered)

    def test_component_names_are_bounded_lowercase_identifiers(self) -> None:
        for index, bad in enumerate(("", ".", "..", "../python", "Python", "python/pkg", "a" * 65)):
            with self.subTest(component=bad):
                fragment(
                    self.root,
                    f"2026-07-30-issue-{300 + index}-bad-component.md",
                    issue=str(300 + index),
                    component=bad,
                )
                with self.assertRaisesRegex(changelog.ChangelogError, "component"):
                    changelog.fragments(self.root)
                for path in (self.root / "NEXT").glob("*.md"):
                    path.unlink()

        fragment(
            self.root,
            "2026-07-30-issue-399-valid-component.md",
            issue="399",
            component="python.worker_v2",
        )
        self.assertEqual(
            "python.worker_v2",
            changelog.fragments(self.root)[0].metadata["component"],
        )

    def test_default_render_fails_empty_when_only_scoped_fragments_exist(self) -> None:
        scoped = fragment(
            self.root,
            "2026-07-30-issue-250-python.md",
            issue="250",
            component="python",
        )

        with self.assertRaisesRegex(changelog.ChangelogError, "no unreleased fragments"):
            changelog.render_next(self.root)

        self.assertTrue(scoped.exists())

    def test_default_release_consumes_only_unscoped_fragments(self) -> None:
        self.init_git()
        plain = fragment(self.root, "2026-07-30-issue-249-default.md", title="Default")
        scoped = fragment(
            self.root,
            "2026-07-30-issue-250-python.md",
            issue="250",
            title="Python",
            component="python",
        )
        self.commit_all("fragments")

        changelog.release(self.root, "v1.0.0", [])

        self.assertFalse(plain.exists())
        self.assertTrue(scoped.exists())
        self.assertIn("## Default", (self.root / "CHANGELOG/v1.0.0.md").read_text())
        self.assertNotIn("## Python", (self.root / "CHANGELOG/v1.0.0.md").read_text())

    def test_component_release_consumes_only_matching_fragments(self) -> None:
        self.init_git()
        plain = fragment(self.root, "2026-07-30-issue-249-default.md", title="Default")
        python = fragment(
            self.root,
            "2026-07-30-issue-250-python.md",
            issue="250",
            title="Python",
            component="python",
        )
        node = fragment(
            self.root,
            "2026-07-30-issue-251-node.md",
            issue="251",
            title="Node",
            component="node",
        )
        self.commit_all("fragments")

        changelog.release(self.root, "python-v1.0.0", [], component="python")

        self.assertTrue(plain.exists())
        self.assertFalse(python.exists())
        self.assertTrue(node.exists())
        snapshot = (self.root / "CHANGELOG/python-v1.0.0.md").read_text()
        self.assertIn("## Python", snapshot)
        self.assertNotIn("## Default", snapshot)
        self.assertNotIn("## Node", snapshot)

    def test_explicit_selection_cannot_cross_component_boundaries(self) -> None:
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-default.md", title="Default")
        fragment(
            self.root,
            "2026-07-30-issue-250-python.md",
            issue="250",
            title="Python",
            component="python",
        )
        self.commit_all("fragments")

        with self.assertRaisesRegex(changelog.ChangelogError, "component"):
            changelog.release(
                self.root,
                "python-v1.0.0",
                [
                    "2026-07-30-issue-249-default.md",
                    "2026-07-30-issue-250-python.md",
                ],
                component="python",
            )

    def test_empty_component_stream_fails_without_consuming_other_streams(self) -> None:
        self.init_git()
        scoped = fragment(
            self.root,
            "2026-07-30-issue-250-python.md",
            issue="250",
            component="python",
        )
        self.commit_all("fragments")

        with self.assertRaisesRegex(changelog.ChangelogError, "selected no fragments"):
            changelog.release(self.root, "node-v1.0.0", [], component="node")

        self.assertTrue(scoped.exists())

    def test_release_refuses_a_version_smaller_than_selected_impact(self) -> None:
        self.init_git()
        snapshots = self.root / "CHANGELOG"
        snapshots.mkdir()
        (snapshots / "v0.0.0.md").write_text("previous\n", encoding="utf-8")
        selected = fragment(
            self.root,
            "2026-07-30-issue-249-breaking.md",
            impact="major",
        )
        self.commit_all("breaking fragment")

        with self.assertRaisesRegex(changelog.ChangelogError, "require a major bump"):
            changelog.release(self.root, "v0.0.1", [])

        self.assertTrue(selected.exists())
        self.assertFalse((self.root / "CHANGELOG/v0.0.1.md").exists())

    def test_zero_major_versions_follow_normal_semver_axes(self) -> None:
        self.init_git()
        snapshots = self.root / "CHANGELOG"
        snapshots.mkdir()
        (snapshots / "v0.4.2.md").write_text("previous\n", encoding="utf-8")
        fragment(
            self.root,
            "2026-07-30-issue-249-breaking.md",
            impact="major",
        )
        self.commit_all("breaking fragment")

        changelog.release(self.root, "v1.0.0", [])

        self.assertTrue((snapshots / "v1.0.0.md").exists())

    def test_minor_impact_on_zero_major_increments_the_minor_axis(self) -> None:
        self.init_git()
        snapshots = self.root / "CHANGELOG"
        snapshots.mkdir()
        (snapshots / "v0.4.2.md").write_text("previous\n", encoding="utf-8")
        fragment(
            self.root,
            "2026-07-30-issue-249-feature.md",
            impact="minor",
        )
        self.commit_all("feature fragment")

        changelog.release(self.root, "v0.5.0", [])

        self.assertTrue((snapshots / "v0.5.0.md").exists())

    def test_subset_impact_ignores_unselected_higher_impact_fragments(self) -> None:
        self.init_git()
        patch = fragment(
            self.root,
            "2026-07-30-issue-249-fix.md",
            impact="patch",
        )
        major = fragment(
            self.root,
            "2026-07-30-issue-250-breaking.md",
            issue="250",
            impact="major",
        )
        self.commit_all("mixed impacts")

        changelog.release(self.root, "v0.0.1", [patch.name])

        self.assertFalse(patch.exists())
        self.assertTrue(major.exists())

    def test_component_impact_ignores_other_components(self) -> None:
        self.init_git()
        python = fragment(
            self.root,
            "2026-07-30-issue-249-python-fix.md",
            component="python",
            impact="patch",
        )
        node = fragment(
            self.root,
            "2026-07-30-issue-250-node-breaking.md",
            issue="250",
            component="node",
            impact="major",
        )
        self.commit_all("component impacts")

        changelog.release(
            self.root,
            "python-v0.0.1",
            [],
            component="python",
        )

        self.assertFalse(python.exists())
        self.assertTrue(node.exists())

    def test_render_next_can_show_the_released_shape_before_it_is_immutable(self) -> None:
        fragment(self.root, "2026-07-30-issue-249-diary.md", body=DIARY)

        preview = run(
            self.root, sys.executable, str(MODULE_PATH), "render-next",
            "--repo-root", str(self.root), "--as-released",
        )
        diary = run(
            self.root, sys.executable, str(MODULE_PATH), "render-next",
            "--repo-root", str(self.root),
        )

        self.assertNotIn("## Why", preview)
        self.assertIn("## Why", diary)

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

    def test_release_accepts_a_next_relative_selected_fragment(self) -> None:
        """#328: release callers forward the repository-relative path they were given.

        `changelog-release.yml` passes each newline entry through unchanged, and
        callers supply `NEXT/<file>.md`. Indexing selection by basename alone
        rejected that with "selected fragment does not exist", which reads as a
        missing fragment rather than a path-shape mismatch — the diagnosis that
        cost a real release dry-run (verjson-customer-lifecycle#4, run
        30770166825).
        """
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-contract.md")
        fragment(self.root, "2026-07-31-issue-250-other.md", date="2026-07-31", issue="250", title="Other")
        self.commit_all("initial")

        changelog.release(self.root, "v1.0.0", ["NEXT/2026-07-30-issue-249-contract.md"])

        snapshot = (self.root / "CHANGELOG" / "v1.0.0.md").read_text(encoding="utf-8")
        self.assertIn("249", snapshot)
        # Selection still selects: the unnamed fragment must survive, or this
        # passes by releasing everything regardless of what was asked for.
        self.assertNotIn("250", snapshot)
        self.assertTrue((self.root / "NEXT/2026-07-31-issue-250-other.md").exists())

    def test_release_accepts_a_bare_selected_basename(self) -> None:
        """The pre-existing spelling keeps working — #328 adds a form, not swaps one."""
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-contract.md")
        self.commit_all("initial")

        changelog.release(self.root, "v1.0.0", ["2026-07-30-issue-249-contract.md"])

        self.assertIn("249", (self.root / "CHANGELOG" / "v1.0.0.md").read_text(encoding="utf-8"))

    def test_release_refuses_selected_paths_outside_the_unreleased_dir(self) -> None:
        """Traversal and foreign directories are refused, not reduced to a basename.

        Normalising by taking the basename unconditionally would make
        `../../elsewhere/<name>.md` select the fragment that happens to share its
        name — a value pointing outside `NEXT/` is a caller bug, and silently
        honouring it is how a release consumes a fragment nobody selected.
        """
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-contract.md")
        self.commit_all("initial")

        for bad, expected in (
            ("../2026-07-30-issue-249-contract.md", "traverse"),
            ("../../NEXT/2026-07-30-issue-249-contract.md", "traverse"),
            ("elsewhere/2026-07-30-issue-249-contract.md", "bare filename"),
            ("NEXT/nested/2026-07-30-issue-249-contract.md", "bare filename"),
            ("/abs/2026-07-30-issue-249-contract.md", "repository-relative"),
            ("", "empty"),
        ):
            with self.subTest(selected=bad):
                with self.assertRaisesRegex(changelog.ChangelogError, expected):
                    changelog.release(self.root, "v1.0.0", [bad])
                self.assertFalse(
                    (self.root / "CHANGELOG" / "v1.0.0.md").exists(),
                    "a refused selection must not have written a snapshot",
                )

    def test_release_still_reports_a_genuinely_missing_fragment(self) -> None:
        """The original error survives for its original cause, now unambiguously."""
        self.init_git()
        fragment(self.root, "2026-07-30-issue-249-contract.md")
        self.commit_all("initial")

        for missing in ("2026-07-30-issue-999-absent.md", "NEXT/2026-07-30-issue-999-absent.md"):
            with self.subTest(selected=missing):
                with self.assertRaisesRegex(changelog.ChangelogError, "does not exist"):
                    changelog.release(self.root, "v1.0.0", [missing])

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

    def test_feature_pr_cannot_consume_a_component_scoped_fragment(self) -> None:
        self.init_git()
        scoped = fragment(
            self.root,
            "2026-07-30-issue-390-python.md",
            issue="390",
            component="python",
        )
        self.commit_all("base")
        base = run(self.root, "git", "rev-parse", "HEAD")
        scoped.unlink()
        self.commit_all("consume scoped fragment")

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
        self.assertIn("COMPONENT: ${{ inputs.component }}", workflow)
        self.assertIn('args+=(--component "$COMPONENT")', workflow)
        self.assertNotIn("runs-on: ubuntu-latest", workflow)
        self.assertIn("inputs.runner != ''", workflow)

        validation_workflow = (
            MODULE_PATH.parent.parent / ".github/workflows/changelog-validate.yml"
        ).read_text(encoding="utf-8")
        self.assertNotIn("runs-on: ubuntu-latest", validation_workflow)
        self.assertIn("inputs.runner != ''", validation_workflow)

    def test_release_snapshots_the_dispatch_commit_not_the_branch_head(self) -> None:
        """The snapshot must take the commit the caller verified.

        Checking out ``github.event.repository.default_branch`` re-reads the
        branch head here, at snapshot time. A caller's ``verify`` job holds that
        window open for its whole suite run, and the ``cancel-in-progress:
        false`` concurrency group holds it open again behind a queued release,
        so anything merged in between used to be tagged, pushed and published
        with nothing having checked it (#463, #464).
        """
        workflow = (
            MODULE_PATH.parent.parent / ".github/workflows/changelog-release.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("ref: ${{ github.sha }}", workflow)
        # Not just "the pin is present": the branch-head re-read must be absent,
        # or a second checkout step reinstating it passes the assertion above.
        # Scoped to the `ref:` key, because DEFAULT_BRANCH legitimately binds
        # the same expression for the guard and the push refspec below.
        self.assertNotIn("ref: ${{ github.event.repository.default_branch }}", workflow)
        self.assertIn(
            "DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}",
            workflow,
        )
        # The push still targets the branch by name, which is what makes the pin
        # fail closed: from the dispatch commit this refspec is non-fast-forward
        # once the branch has moved, so a raced release tags nothing.
        self.assertIn('"$release_commit:refs/heads/$DEFAULT_BRANCH"', workflow)
        # The checkout is detached at the dispatch commit, so nothing may derive
        # the branch from HEAD.
        self.assertNotIn("git symbolic-ref", workflow)


if __name__ == "__main__":
    unittest.main()
