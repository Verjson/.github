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

So the rule is keyed on what the document actually says. A test file an ADR names --
as a full `scripts/ci-gate/` path or as a bare basename, because both spellings make
the same present-tense promise -- and which no longer resolves must be named, somewhere
in the same ADR, in a sentence that says why it is absent: it was retired, or it is
generated into adopter repositories and was never a file here.

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
import tempfile
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
DECISIONS = ROOT / "docs" / "decisions"
# Two arms, because an ADR spells a harness both ways and both spellings make the same
# present-tense promise to a reader. The full-path arm is scoped to `scripts/ci-gate/`:
# a full path elsewhere routinely names a file that is *generated into adopter
# repositories* and correctly does not exist here, so it is not this repository's
# coverage claim to check. A bare basename carries no such ambiguity -- in these ADRs it
# is always shorthand for a harness in this tree -- so it is resolved against every test
# file in the repository and flagged when it resolves nowhere.
TEST_PATH = re.compile(r"scripts/ci-gate/[A-Za-z0-9._-]+\.test\.(?:sh|py)")
# A basename only: the lookbehind rejects anything with a directory in front of it, so a
# full path is never double-counted, and the leading class rejects the `.test.sh` tail of
# a `*.test.sh` glob written in prose.
BARE_NAME = re.compile(r"(?<![A-Za-z0-9._/-])[A-Za-z0-9_-][A-Za-z0-9._-]*\.test\.(?:sh|py)")
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
# The second stated reason a named harness is absent from this tree: it was never meant
# to be here. `scripts/changelog-contract.test.sh` is emitted into adopter repositories
# by `gen-changelog-caller.sh`, so an ADR naming it is describing a contract it exports,
# not coverage it has lost. That has to be said in the document, exactly as a retirement
# does -- an unexplained missing name stays a failure.
GENERATED_ELSEWHERE = re.compile(
    r"""
      \b(?:is|are|was|were)\s+generated\s+into\b
    | \bemitted\s+into\b
    | \bnot\ a\ file\ in\ this\ repository\b
    """,
    re.IGNORECASE | re.VERBOSE,
)


def exempts(paragraph):
    """A paragraph excuses the names it contains only by saying why they are absent."""
    return bool(RETIRED.search(paragraph) or GENERATED_ELSEWHERE.search(paragraph))


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
    """Yield (paragraph, reference) for every test file an ADR names, path or basename.

    The paragraph is the unit, not the sentence. A retirement is normally written
    across two sentences -- name the claim, then correct it -- so splitting finer
    rejects correctly-written amendments while adding no precision: no paragraph
    plausibly both retires a file and asserts it as live coverage. Markdown wrapping
    is undone first, or a clause would be cut off from the path it qualifies.
    """
    for paragraph in re.split(r"\n\s*\n", text):
        flat = " ".join(paragraph.split())
        matches = [m.group(0) for m in TEST_PATH.finditer(flat)]
        matches += [m.group(0) for m in BARE_NAME.finditer(flat)]
        for path in dict.fromkeys(matches):
            yield flat, path


def _label(readme):
    try:
        return readme.relative_to(ROOT).as_posix()
    except ValueError:
        return readme.as_posix()


def dangling_live_claims(readmes=None):
    """Yield (adr, reference, paragraph) for every unexplained absent test an ADR names.

    Exemption is keyed on the **basename**, not the reference string. An amendment that
    retires `scripts/ci-gate/x.test.sh` has retired the file, so the same document's
    shorthand `x.test.sh` is the same statement and must not be reported again.
    """
    reported = set()
    for readme in adrs() if readmes is None else readmes:
        found = list(claims(readme.read_text(encoding="utf-8")))
        excused = {
            PurePosixPath(path).name for paragraph, path in found if exempts(paragraph)
        }
        for paragraph, path in found:
            if resolves(path) or PurePosixPath(path).name in excused:
                continue
            seen = _label(readme), path
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

    def test_a_bare_basename_claim_on_a_missing_harness_is_flagged(self):
        """The negative control for the bare-basename arm: it must actually bite."""
        sentence = "Covered by `absent-harness.test.sh`, wired into `actions-ci.yml`."
        self.assertEqual(
            ["absent-harness.test.sh"],
            [ref for para, ref in claims(sentence) if not RETIRED.search(para)],
        )

    def test_the_bare_basename_arm_bites_on_a_full_scan(self):
        """End-to-end negative control: an injected ADR making the claim must fail."""
        with tempfile.TemporaryDirectory() as tmp:
            readme = Path(tmp) / "0999-injected" / "README.md"
            readme.parent.mkdir()
            readme.write_text(
                "Covered by `absent-harness.test.sh`, wired into `actions-ci.yml`.\n",
                encoding="utf-8",
            )
            found = list(dangling_live_claims([readme]))
        self.assertEqual(1, len(found), found)
        self.assertEqual("absent-harness.test.sh", found[0][1])

    def test_a_bare_basename_that_resolves_is_not_flagged(self):
        """The arm must not flag the shorthand every disposition table legitimately uses."""
        with tempfile.TemporaryDirectory() as tmp:
            readme = Path(tmp) / "0999-injected" / "README.md"
            readme.parent.mkdir()
            readme.write_text("Covered by `native-automerge.test.sh`.\n", encoding="utf-8")
            self.assertEqual([], list(dangling_live_claims([readme])))

    def test_a_full_path_retirement_exempts_the_same_file_named_bare(self):
        """Exemption is keyed on the file, not on how the sentence spelled it."""
        text = (
            "Covered by `gone.test.sh`, wired into actions-ci.yml.\n\n"
            "## Amendment\n\nscripts/ci-gate/gone.test.sh is deleted."
        )
        with tempfile.TemporaryDirectory() as tmp:
            readme = Path(tmp) / "0999-injected" / "README.md"
            readme.parent.mkdir()
            readme.write_text(text, encoding="utf-8")
            self.assertEqual([], list(dangling_live_claims([readme])))

    def test_a_generated_adopter_artifact_is_excused_only_when_stated(self):
        """An absent name is excused by saying why, never by being absent quietly."""
        unstated = "Covered by `changelog-contract.test.sh`."
        self.assertFalse(exempts(unstated))
        stated = "`changelog-contract.test.sh` is generated into adopter repositories."
        self.assertTrue(exempts(stated))

    def test_a_glob_written_in_prose_is_not_read_as_a_claim(self):
        """`scripts/ci-gate/*.test.sh` names a pattern, not a file."""
        self.assertEqual([], [ref for _, ref in claims("Every scripts/ci-gate/*.test.sh is registered.")])

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
