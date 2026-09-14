#!/usr/bin/env python3
"""No ADR may describe a deleted test file as live coverage (Verjson/.github#1331).

An ADR body is the decided record and is written in the present tense: "covered by
X", "wired into actions-ci". When the harness it names is later deleted, that
sentence silently becomes false in the one place a reader goes to find out whether a
property is still guarded. #1329 deleted eight `ci-gate` tests and amended three
ADRs; five more kept making concrete present-tense claims about the same files, and
two of the three amended ones kept a live claim in their body as well. Nothing caught
any of it, which is why this is a check rather than another manual sweep.

The rule is not "never name a deleted file" — recording a retirement requires naming
it. Nor is it keyed on a heading: a *dated amendment written before the deletion* is
exactly as stale as the body, so exempting a section for being an amendment would
have passed the worst case here (ADR 0012's 2026-08-07 amendment).

So the rule is keyed on what the document actually says. A `scripts/ci-gate/*.test.*`
path that no longer resolves must be named, somewhere in the same ADR, in a sentence
that states its retirement.

Scope is the whole document rather than the enclosing section, deliberately. A stale
claim usually sits in `## Consequences`, which is decided text an amendment may never
edit; requiring the retirement note to sit beside it would make the check satisfiable
only by rewriting the record CANON forbids rewriting. Document scope is therefore the
strongest rule that an *appended* amendment can satisfy. The cost is real and worth
stating: a retirement note anywhere in a long ADR will launder a live claim elsewhere
in it for the same file. That is acceptable because the reader's failure mode is
"nothing in this ADR says the file is gone", and this closes exactly that.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DECISIONS = ROOT / "docs" / "decisions"
# Scoped to full `scripts/ci-gate/` paths on purpose, and the boundary is a judgment
# call worth stating. Widening to bare basenames does find more -- ADR 0024 names two
# of the deleted harnesses without a directory -- but it also sweeps in every
# historical disposition table (ADR 0079 lists all eight by basename, correctly) and
# a dozen pre-existing dangling references in ADRs #1329 never touched. That is a
# different, larger cleanup than this one, and folding it in here would blur what
# this check asserts. Full paths are the unambiguous, bounded rule; the bare-name
# residue is tracked in this PR's receipt rather than half-enforced.
TEST_PATH = re.compile(r"scripts/ci-gate/[A-Za-z0-9._-]+\.test\.(?:sh|py)")
# The vocabulary an ADR uses to record that a harness is gone. Deliberately phrasal
# rather than stemmed: ADR 0042 is *about* branch deletion, so a bare `delet` stem
# matched "merge and delete outcomes" in its live claim and exempted it. A retirement
# is stated, not merely adjacent to the word.
RETIRED = re.compile(
    r"""
      \b(?:is|was|are|were|been|now)\s+(?:deleted|removed|retired|deregistered|superseded)\b
    | \bderegistered\b
    | \bretired\b
    | \bno\ longer\ (?:exists|runs|ships|registered|wired)\b
    """,
    re.IGNORECASE | re.VERBOSE,
)


def adrs():
    return sorted(DECISIONS.glob("[0-9]*/README.md"))


def _test_files():
    """Every test file in the tree, by full path and by basename."""
    paths, names = set(), set()
    for suffix in ("sh", "py"):
        for candidate in ROOT.glob(f"**/*.test.{suffix}"):
            if any(part in (".git", "node_modules") for part in candidate.parts):
                continue
            paths.add(candidate.relative_to(ROOT).as_posix())
            names.add(candidate.name)
    return paths, names


TEST_PATHS, TEST_NAMES = _test_files()


def resolves(reference):
    """A reference resolves if the exact path exists, or the basename does anywhere.

    Basename resolution is deliberately generous: this check exists to catch a claim
    about coverage that is *gone*, not to police how an ADR spells a path that is
    still there.
    """
    if "/" in reference:
        return reference in TEST_PATHS
    return reference in TEST_NAMES


def claims(text):
    """Yield (paragraph, path) for every ci-gate test path named in an ADR.

    The paragraph is the unit, not the sentence. A retirement is normally written
    across two sentences -- name the claim, then correct it -- so splitting finer
    rejects correctly-written amendments while adding no precision: no paragraph
    plausibly both retires a file and asserts it as live coverage. Markdown wrapping
    is undone first, or a clause would be cut off from the path it qualifies.
    """
    for paragraph in re.split(r"\n\s*\n", text):
        flat = " ".join(paragraph.split())
        for path in dict.fromkeys(m.group(0) for m in TEST_PATH.finditer(flat)):
            yield flat, path


def dangling_live_claims():
    reported = set()
    for readme in adrs():
        found = list(claims(readme.read_text(encoding="utf-8")))
        retired = {path for paragraph, path in found if RETIRED.search(paragraph)}
        for paragraph, path in found:
            if resolves(path) or path in retired:
                continue
            seen = readme.relative_to(ROOT).as_posix(), path
            if seen not in reported:
                reported.add(seen)
                yield seen[0], path, paragraph


class AdrLiveCoverageClaimsTest(unittest.TestCase):
    def test_adr_directory_is_readable(self):
        """A silently empty scan would pass every assertion below while checking nothing."""
        self.assertTrue(adrs(), "no ADRs were scanned")

    def test_the_scan_sees_real_ci_gate_references(self):
        """Guards the regex: a scan that matches nothing also reports nothing wrong."""
        found = {path for readme in adrs() for _, path in claims(readme.read_text(encoding="utf-8"))}
        self.assertTrue(found, "no ADR names a test file; the matcher has drifted")
        self.assertTrue(
            any(resolves(path) for path in found),
            "no named test resolves; the resolver has drifted and would flag everything",
        )

    def test_an_existing_and_a_deleted_path_are_told_apart(self):
        self.assertTrue(resolves("scripts/ci-gate/native-automerge.test.sh"))
        self.assertFalse(resolves("scripts/ci-gate/ci-wait-fail-closed.test.sh"))

    def test_every_live_coverage_claim_names_an_existing_test(self):
        dangling = list(dangling_live_claims())
        self.assertEqual(
            [],
            dangling,
            "an ADR describes a deleted test as live coverage. Restore the coverage, or "
            "append a dated `## Amendment` naming the file and where the property lives "
            "now — never by editing the decided text:\n"
            + "\n".join(f"  {adr} -> {path}\n    {text[:160]}" for adr, path, text in dangling),
        )

    def test_a_domain_use_of_delete_is_not_a_retirement(self):
        """ADR 0042's live claim, which a stemmed matcher wrongly exempted."""
        sentence = "Enforced by scripts/ci-gate/gone.test.sh, run against stubbed merge and delete outcomes."
        self.assertEqual(
            ["scripts/ci-gate/gone.test.sh"],
            [p for para, p in claims(sentence) if not RETIRED.search(para)],
        )

    def test_a_retirement_sentence_is_recognized(self):
        sentence = "The file scripts/ci-gate/gone.test.sh is now deleted; the property moved."
        self.assertEqual([], [p for para, p in claims(sentence) if not RETIRED.search(para)])

    def test_a_present_tense_claim_is_not_recognized_as_a_retirement(self):
        sentence = "Covered by scripts/ci-gate/gone.test.sh, wired into actions-ci.yml."
        self.assertEqual(
            ["scripts/ci-gate/gone.test.sh"],
            [p for para, p in claims(sentence) if not RETIRED.search(para)],
        )

    def test_a_wrapped_retirement_clause_is_not_split_from_its_path(self):
        """Markdown wrapping must not turn a correct amendment into a false failure."""
        wrapped = "The harness\nscripts/ci-gate/gone.test.sh was retired with the step\nit extracted."
        self.assertEqual([], [p for para, p in claims(wrapped) if not RETIRED.search(para)])

    def test_a_retirement_note_does_not_exempt_a_different_file(self):
        """Document scope is per path: one retirement must not launder every claim."""
        text = (
            "Covered by scripts/ci-gate/alive.test.sh.\n\n"
            "## Amendment\n\nscripts/ci-gate/gone.test.sh was deleted."
        )
        found = list(claims(text))
        retired = {path for paragraph, path in found if RETIRED.search(paragraph)}
        self.assertEqual({"scripts/ci-gate/gone.test.sh"}, retired)
        self.assertNotIn("scripts/ci-gate/alive.test.sh", retired)


if __name__ == "__main__":
    unittest.main()
