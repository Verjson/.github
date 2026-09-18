#!/usr/bin/env python3
"""Regression suite for scripts/contract-version.py (Verjson/.github#1374)."""
import contextlib
import datetime
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

_root = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location(
    "contract_version", _root / "scripts" / "contract-version.py")
cv = importlib.util.module_from_spec(_spec)
# Registered before execution: `@dataclasses.dataclass` under
# `from __future__ import annotations` resolves field types through
# `sys.modules[cls.__module__]`, which is absent for a module loaded straight
# from a path.
sys.modules["contract_version"] = cv
_spec.loader.exec_module(cv)


def rel(version, commit_char="a", published="2026-01-01"):
    return cv.Release(version=version, commit=commit_char * 40, published=published)


# The scan enumerates tracked content, so a fixture tree has to be a real
# repository with a real index. Global and system config are neutralized so a
# developer's own `core.excludesFile` cannot decide what a fixture tracks.
GIT_ENV = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, env=GIT_ENV,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def init_repo(root):
    git(root, "init", "-q", "-b", "main")
    return root


def track(root):
    """Stage everything git would take, which is exactly what the scan enumerates."""
    git(root, "add", "-A")


class SupportedWindow(unittest.TestCase):
    def test_window_never_refuses_a_version_package_retention_still_keeps(self):
        # Three minor lines, three releases: "current and previous minor" alone
        # would refuse v3.0.0 while the keep-3 retention policy still considers
        # it current, stranding a consumer the org calls supported.
        releases = [rel("v2.9.0"), rel("v3.0.0"), rel("v3.1.0"), rel("v3.2.0")]
        self.assertEqual(
            cv.supported_versions(releases), {"v3.0.0", "v3.1.0", "v3.2.0"})


class DeprecationClock(unittest.TestCase):
    def test_a_version_pushed_out_of_the_window_expires_90_days_after_the_release_that_did_it(self):
        # v3.0.0 is still supported at v3.2.0 (it is one of the newest three);
        # v3.3.0, published 2026-03-01, is what pushes it out. The deprecation
        # error has to name a date a maintainer can act on, and that date is a
        # function of release metadata rather than a stored deadline.
        releases = [
            rel("v3.0.0", published="2026-01-01"),
            rel("v3.1.0", published="2026-01-15"),
            rel("v3.2.0", published="2026-02-01"),
            rel("v3.3.0", published="2026-03-01"),
        ]
        verdict = cv.classify("v3.0.0", releases, today="2026-04-01")
        self.assertEqual(verdict.state, cv.DEPRECATED)
        self.assertEqual(verdict.expires_on, "2026-05-30")


class DeclarationVersusReality(unittest.TestCase):
    def write_repo(self, declaration, workflow):
        root = init_repo(pathlib.Path(tempfile.mkdtemp()))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / ".github" / "workflows").mkdir(parents=True)
        if declaration is not None:
            (root / ".github" / "verjson-contract.json").write_text(
                json.dumps(declaration))
        (root / ".github" / "workflows" / "ci.yml").write_text(workflow)
        track(root)
        return root

    def test_a_pin_that_is_not_the_declared_release_commit_is_a_finding(self):
        # The failure mode a declared version exists to close: the declaration
        # says v3.2.0 while the repository actually runs some other contract
        # commit. A version nothing reads back is a pin nobody advances.
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = self.write_repo(
            {"contract_version": "v3.2.0"},
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "b" * 40 + "\n")
        findings = cv.verify(root, releases, today="2026-02-02")
        self.assertEqual([f.kind for f in findings], ["PIN_MISMATCH"])
        self.assertIn(".github/workflows/ci.yml", findings[0].detail)

    def test_a_moving_tag_is_not_an_immutable_contract_reference(self):
        # `@v2` resolves to whatever the hub last re-pointed it at, so it can
        # name a different contract tomorrow while the declaration stays put.
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = self.write_repo(
            {"contract_version": "v3.2.0"},
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@v2\n")
        findings = cv.verify(root, releases, today="2026-02-02")
        self.assertEqual([f.kind for f in findings], ["UNPINNED_REFERENCE"])

    def test_a_consistent_repository_reports_nothing(self):
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = self.write_repo(
            {"contract_version": "v3.2.0"},
            "# Generated by Verjson/.github scripts/gen-changelog-caller.sh workflow "
            + "a" * 40 + "\njobs:\n  ci:\n    uses: "
            "Verjson/.github/.github/workflows/node-ci.yml@" + "a" * 40 + "\n")
        self.assertEqual(cv.verify(root, releases, today="2026-02-02"), [])

    def test_a_generated_header_claiming_another_contract_is_a_finding(self):
        # The intra-repository skew shape: the caller is repinned and the header
        # the generator stamped still names the contract it was generated at.
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = self.write_repo(
            {"contract_version": "v3.2.0"},
            "# Generated by Verjson/.github scripts/gen-changelog-caller.sh workflow "
            + "c" * 40 + "\njobs:\n  ci:\n    uses: "
            "Verjson/.github/.github/workflows/node-ci.yml@" + "a" * 40 + "\n")
        findings = cv.verify(root, releases, today="2026-02-02")
        self.assertEqual([f.kind for f in findings], ["PIN_MISMATCH"])
        self.assertIn("header", findings[0].detail)

    def test_references_without_a_declaration_are_reported(self):
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = self.write_repo(
            None,
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "a" * 40 + "\n")
        self.assertEqual([f.kind for f in cv.verify(root, releases, today="2026-02-02")],
                         ["DECLARATION_MISSING"])

    def test_a_declaration_governing_nothing_is_reported(self):
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = self.write_repo({"contract_version": "v3.2.0"}, "jobs:\n  ci:\n    steps: []\n")
        self.assertEqual([f.kind for f in cv.verify(root, releases, today="2026-02-02")],
                         ["UNGOVERNED_DECLARATION"])

    def test_a_repository_that_adopts_nothing_is_not_an_adopter(self):
        # No declaration and no reference is not a defect: it is a repository
        # that does not consume the contract. Reporting it would make the check
        # fire on every repository in the organization and get muted.
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = self.write_repo(None, "jobs:\n  ci:\n    steps: []\n")
        self.assertEqual(cv.verify(root, releases, today="2026-02-02"), [])

    def test_a_pin_naming_another_release_commit_is_still_a_mismatch(self):
        # The repinned-but-undeclared adopter: the pin is a perfectly good
        # release commit, just not the declared release's. "Not a release
        # commit" and "not THIS release's commit" are different assertions and
        # only the second one is the skew this check exists to catch.
        releases = [rel("v3.1.0", commit_char="c", published="2026-01-01"),
                    rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = self.write_repo(
            {"contract_version": "v3.2.0"},
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "c" * 40 + "\n")
        findings = cv.verify(root, releases, today="2026-02-02")
        self.assertEqual([f.kind for f in findings], ["PIN_MISMATCH"])
        self.assertIn("c" * 40, findings[0].detail)

    def test_an_expired_contract_is_refused_even_when_every_pin_agrees(self):
        # ADR 0191 sec.5/sec.6: expiry IS the enforcement. A repository whose pins are
        # internally consistent but whose declared version expired must not pass.
        releases = [
            rel("v3.0.0", commit_char="a", published="2026-01-01"),
            rel("v3.1.0", commit_char="d", published="2026-01-15"),
            rel("v3.2.0", commit_char="e", published="2026-02-01"),
            rel("v3.3.0", commit_char="f", published="2026-03-01"),
        ]
        root = self.write_repo(
            {"contract_version": "v3.0.0"},
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "a" * 40 + "\n")
        findings = cv.verify(root, releases, today="2026-06-01")
        self.assertEqual([f.kind for f in findings], [cv.EXPIRED])

    def test_a_corrupt_declaration_is_reported_even_when_the_tree_has_no_references(self):
        # "No declaration and no reference" is not an adopter. A declaration
        # that exists and cannot be parsed is a defect either way, and the
        # not-an-adopter guard must not swallow it.
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = init_repo(pathlib.Path(tempfile.mkdtemp()))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / ".github").mkdir(parents=True)
        (root / ".github" / "verjson-contract.json").write_text("{not json")
        track(root)
        self.assertEqual([f.kind for f in cv.verify(root, releases, today="2026-02-02")],
                         ["DECLARATION_UNREADABLE"])

    def test_a_declaration_without_a_string_version_is_reported_on_a_bare_tree(self):
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        root = init_repo(pathlib.Path(tempfile.mkdtemp()))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / ".github").mkdir(parents=True)
        (root / ".github" / "verjson-contract.json").write_text(
            json.dumps({"contract_version": 3}))
        track(root)
        self.assertEqual([f.kind for f in cv.verify(root, releases, today="2026-02-02")],
                         ["DECLARATION_UNREADABLE"])

    def test_an_unresolved_release_commit_fails_closed(self):
        # `target_commitish` is a branch name for many releases; comparing a pin
        # against "main" would report every adopter broken.
        releases = [cv.Release(version="v3.2.0", commit="main", published="2026-02-01")]
        root = self.write_repo(
            {"contract_version": "v3.2.0"},
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "a" * 40 + "\n")
        self.assertEqual([f.kind for f in cv.verify(root, releases, today="2026-02-02")],
                         [cv.UNKNOWN])


class WindowEdges(unittest.TestCase):
    def test_moving_and_non_contract_tags_never_occupy_a_window_slot(self):
        # The hub really carries `v1`, `v2`, and `runner-canary-v1.0.0`. A moving
        # tag holding a slot would shrink the window to two real releases.
        releases = [rel("v3.0.0"), rel("v3.1.0"), rel("v3.2.0"),
                    rel("v3"), rel("runner-canary-v1.0.0")]
        self.assertEqual(cv.supported_versions(releases),
                         {"v3.0.0", "v3.1.0", "v3.2.0"})

    def test_the_window_is_exactly_two_minor_lines_when_retention_does_not_widen_it(self):
        # Five releases on three minor lines, so the newest-three floor is a
        # subset of the minor-line half and the minor-line count alone decides.
        # One line would drop v3.1.0; three would admit v3.0.0.
        releases = [rel("v3.0.0"), rel("v3.1.0"), rel("v3.1.1"),
                    rel("v3.2.0"), rel("v3.2.1")]
        self.assertEqual(cv.supported_versions(releases),
                         {"v3.1.0", "v3.1.1", "v3.2.0", "v3.2.1"})

    def test_no_releases_supports_nothing(self):
        self.assertEqual(cv.supported_versions([]), set())

    def test_an_unreleased_version_is_unknown_not_supported(self):
        self.assertEqual(cv.classify("v9.9.9", [rel("v3.0.0")], today="2026-02-02").state,
                         cv.UNKNOWN)

    def test_a_malformed_version_is_unknown(self):
        self.assertEqual(cv.classify("main", [rel("v3.0.0")], today="2026-02-02").state,
                         cv.UNKNOWN)

    def test_crossing_a_major_buys_the_longer_clock(self):
        releases = [
            rel("v3.0.0", published="2026-01-01"),
            rel("v3.1.0", published="2026-01-15"),
            rel("v3.2.0", published="2026-02-01"),
            rel("v4.0.0", published="2026-03-01"),
        ]
        verdict = cv.classify("v3.0.0", releases, today="2026-04-01")
        self.assertEqual(verdict.state, cv.DEPRECATED)
        self.assertEqual(verdict.expires_on, "2026-08-28")

    def test_the_deprecation_becomes_a_refusal_on_its_stated_date(self):
        releases = [
            rel("v3.0.0", published="2026-01-01"),
            rel("v3.1.0", published="2026-01-15"),
            rel("v3.2.0", published="2026-02-01"),
            rel("v3.3.0", published="2026-03-01"),
        ]
        self.assertEqual(cv.classify("v3.0.0", releases, today="2026-05-30").state,
                         cv.EXPIRED)


class ScanTotality(unittest.TestCase):
    """ADR 0191 sec.3 claims the scan is the whole tree. A missed reference is a
    clean PASS, and UNGOVERNED_DECLARATION only fires when the tree has zero
    references, so it never catches a partial miss."""

    def repo(self):
        root = init_repo(pathlib.Path(tempfile.mkdtemp()))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "verjson-contract.json").write_text(
            json.dumps({"contract_version": "v3.2.0"}))
        # One conformant pin, so the tree is never reference-free and the
        # UNGOVERNED_DECLARATION net cannot stand in for the scan.
        (root / ".github" / "workflows" / "ci.yml").write_text(
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "a" * 40 + "\n")
        track(root)
        return root

    def verify(self, root):
        releases = [rel("v3.2.0", commit_char="a", published="2026-02-01")]
        return cv.verify(root, releases, today="2026-02-02")

    def test_a_single_quoted_uses_scalar_is_a_contract_reference(self):
        root = self.repo()
        (root / ".github" / "workflows" / "quoted.yml").write_text(
            "jobs:\n  ci:\n    uses: 'Verjson/.github/.github/workflows/node-ci.yml@"
            + "b" * 40 + "'\n")
        track(root)
        self.assertEqual([f.kind for f in self.verify(root)], ["PIN_MISMATCH"])

    def test_a_double_quoted_uses_scalar_is_a_contract_reference(self):
        root = self.repo()
        (root / ".github" / "workflows" / "quoted.yml").write_text(
            'jobs:\n  ci:\n    uses: "Verjson/.github/.github/workflows/node-ci.yml@'
            + "b" * 40 + '"\n')
        track(root)
        self.assertEqual([f.kind for f in self.verify(root)], ["PIN_MISMATCH"])

    def test_a_header_below_the_first_six_lines_is_still_a_claim(self):
        # gen-changelog-caller.sh stamps CONTRACT_REF on line 13 of the ADR
        # index test and emits its workflow header below `concurrency:`. A
        # fixed leading window misses both.
        root = self.repo()
        (root / ".github" / "workflows" / "deep.yml").write_text(
            "name: x\n" * 8
            + "# Generated by Verjson/.github scripts/gen-changelog-caller.sh workflow "
            + "b" * 40 + "\n")
        track(root)
        findings = self.verify(root)
        self.assertEqual([f.kind for f in findings], ["PIN_MISMATCH"])
        self.assertIn("header", findings[0].detail)

    def test_a_commented_out_pin_is_one_reference_not_two(self):
        # The reason the old code used a window at all: a `uses:` line that is
        # also a comment must not be counted once as a pin and once as a header.
        root = self.repo()
        (root / ".github" / "workflows" / "commented.yml").write_text(
            "#    uses: Verjson/.github/.github/workflows/node-ci.yml@" + "b" * 40 + "\n")
        track(root)
        self.assertEqual([f.kind for f in self.verify(root)], ["PIN_MISMATCH"])

    def test_an_unreadable_file_is_reported_rather_than_skipped(self):
        # A tracked path that is a directory on disk, rather than `chmod 0o000`:
        # mode bits deny nothing to root, so a permission fixture passes
        # vacuously in exactly the container CI runs this in.
        root = self.repo()
        locked = root / ".github" / "workflows" / "locked.yml"
        locked.write_text("jobs: {}\n")
        track(root)
        locked.unlink()
        locked.mkdir()
        findings = self.verify(root)
        self.assertEqual([f.kind for f in findings], ["UNSCANNED"])
        self.assertIn("locked.yml", findings[0].detail)

    def test_a_file_past_the_scan_limit_is_reported_rather_than_skipped(self):
        root = self.repo()
        (root / "big.txt").write_text("x" * (cv.MAX_SCAN_BYTES + 1))
        track(root)
        self.assertEqual([f.kind for f in self.verify(root)], ["UNSCANNED"])

    def test_text_in_an_unknown_encoding_is_reported_rather_than_skipped(self):
        root = self.repo()
        (root / "latin.txt").write_bytes("caf\u00e9 pins\n".encode("latin-1"))
        track(root)
        self.assertEqual([f.kind for f in self.verify(root)], ["UNSCANNED"])

    def test_a_binary_file_carries_no_text_reference_and_is_quiet(self):
        # The counterweight: reporting every PNG as UNSCANNED is the noisy
        # check ADR 0185 says gets muted. Git's own NUL heuristic decides.
        root = self.repo()
        (root / "logo.png").write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00")
        track(root)
        self.assertEqual(self.verify(root), [])

    def test_a_reference_under_node_modules_is_not_a_hole(self):
        root = self.repo()
        vendored = root / "node_modules" / "@verjson" / "thing" / ".github" / "workflows"
        vendored.mkdir(parents=True)
        (vendored / "ci.yml").write_text(
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "b" * 40 + "\n")
        track(root)
        self.assertEqual([f.kind for f in self.verify(root)], ["PIN_MISMATCH"])

    def test_an_ignored_tree_is_neither_scanned_nor_reported_as_a_gap(self):
        # The cost claim, asserted rather than assumed. A whole-tree walk reads
        # untracked build output and tool caches, and every binary in them past
        # the scan limit becomes an UNSCANNED finding no adopter can ever clear
        # -- a permanent exit 1, which is the muted check ADR 0185 warns about.
        # Ignored content is not what Actions checks out, so it is neither a
        # reference the check can miss nor a gap it has to name.
        root = self.repo()
        (root / ".gitignore").write_text("junk/\n")
        junk = root / "junk"
        junk.mkdir()
        (junk / "vendored.yml").write_text(
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "b" * 40 + "\n")
        (junk / "tool-cache.bin").write_bytes(b"\xff" * (cv.MAX_SCAN_BYTES + 1))
        track(root)
        self.assertEqual(self.verify(root), [])

    def test_a_binary_past_the_scan_limit_is_quiet_like_any_other_binary(self):
        # The size check ran first, so the binary heuristic never got to speak
        # for anything over 1 MiB and every large image, archive, or compiled
        # artifact became an UNSCANNED finding. "Binary" does not become
        # "might carry a UTF-8 `uses:` line" at 1048577 bytes.
        root = self.repo()
        (root / "large.png").write_bytes(
            b"\x89PNG\r\n\x1a\n\x00" + b"\xde\xad\xbe\xef" * cv.MAX_SCAN_BYTES)
        track(root)
        self.assertEqual(self.verify(root), [])

    def test_a_utf_16_file_carrying_a_skewed_pin_is_a_finding(self):
        # The NUL heuristic's premise is sound -- a file with a NUL byte holds
        # no UTF-8 `uses:` line -- but the conclusion drawn from it was not: a
        # UTF-16 file is full of NUL bytes and holds a perfectly readable
        # `uses:` line in its own encoding. It was dropped as neither a finding
        # nor a gap, which is the clean PASS on a real skew.
        root = self.repo()
        (root / ".github" / "workflows" / "utf16.yml").write_bytes(
            ("jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
             + "b" * 40 + "\n").encode("utf-16"))
        track(root)
        findings = self.verify(root)
        self.assertEqual([f.kind for f in findings], ["PIN_MISMATCH"])
        self.assertIn("utf16.yml", findings[0].detail)

    def test_a_tracked_symlink_is_its_target_path_not_its_target_content(self):
        # git tracks a symlink as a blob holding the target path, which is never
        # a `uses:` line. Following it would read something outside the tree
        # being verified -- or, where the link points at tracked content, would
        # report the same file twice. This is the case the walk could not state:
        # `os.walk` never descended a symlinked directory at all, so a symlinked
        # `node_modules` (this branch's own 48c9cd36) was invisible to it.
        root = self.repo()
        outside = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, outside, ignore_errors=True)
        (outside / "evil.yml").write_text(
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "b" * 40 + "\n")
        (root / "link.yml").symlink_to(outside / "evil.yml")
        track(root)
        self.assertEqual(
            git(root, "ls-files", "-s", "link.yml").stdout.split()[0], "120000")
        self.assertEqual(self.verify(root), [])

    def test_an_absent_git_is_a_refusal_rather_than_an_empty_scan(self):
        # Without git there is no index to read, and an enumerator that
        # returned nothing would make every tree look reference-free -- the
        # exact clean PASS this check exists to deny.
        root = self.repo()
        previous = os.environ.get("PATH")
        os.environ["PATH"] = str(root / "no-such-bin")
        self.addCleanup(os.environ.__setitem__, "PATH", previous or "")
        with self.assertRaises(cv.TreeNotEnumerable):
            cv.verify(root, [rel("v3.2.0")], today="2026-02-02")

    def test_the_git_directory_is_not_repository_content(self):
        # The one skip that is correct rather than a hole: `.git` is git's own
        # object and ref storage, not the tree Actions executes.
        root = self.repo()
        (root / ".git" / "COMMIT_EDITMSG").write_text(
            "uses: Verjson/.github/.github/workflows/node-ci.yml@" + "b" * 40 + "\n")
        self.assertEqual(self.verify(root), [])


class ReleaseDocument(unittest.TestCase):
    def load(self, payload):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(payload, handle)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return cv.load_releases(handle.name)

    def test_one_version_published_at_two_commits_is_a_usage_failure(self):
        # First-wins picks a commit silently, and which one it picks decides
        # every PIN_MISMATCH in the sweep. An ambiguous list cannot be asked.
        with self.assertRaises(ValueError):
            self.load([{"version": "v3.2.0", "commit": "a" * 40, "published": "2026-02-01"},
                       {"version": "v3.2.0", "commit": "b" * 40, "published": "2026-02-01"}])

    def test_a_commit_that_is_not_a_40_hex_object_id_is_a_usage_failure(self):
        # `target_commitish` is a branch name for v2.0.0 and older on this
        # repository right now; a producer that used it is broken at the source.
        with self.assertRaises(ValueError):
            self.load([{"version": "v3.2.0", "commit": "main", "published": "2026-02-01"}])

    def test_a_timestamp_shaped_publication_date_is_a_usage_failure(self):
        # `published_at` is `2026-03-01T00:00:00Z` raw; the deprecation clock
        # calls date.fromisoformat on it and would raise mid-verdict.
        with self.assertRaises(ValueError):
            self.load([{"version": "v3.2.0", "commit": "a" * 40,
                        "published": "2026-02-01T00:00:00Z"}])

    def test_a_well_formed_document_loads(self):
        releases = self.load(
            [{"version": "v3.2.0", "commit": "a" * 40, "published": "2026-02-01"}])
        self.assertEqual(releases, [cv.Release("v3.2.0", "a" * 40, "2026-02-01")])


class CommandLine(unittest.TestCase):
    def releases_file(self, payload):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(payload, handle)
        handle.close()
        return handle.name

    def test_verify_exits_nonzero_when_the_declaration_does_not_match_the_tree(self):
        root = init_repo(pathlib.Path(tempfile.mkdtemp()))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "verjson-contract.json").write_text(
            json.dumps({"contract_version": "v3.2.0"}))
        (root / ".github" / "workflows" / "ci.yml").write_text(
            "jobs:\n  ci:\n    uses: Verjson/.github/.github/workflows/node-ci.yml@"
            + "b" * 40 + "\n")
        track(root)
        releases = self.releases_file(
            [{"version": "v3.2.0", "commit": "a" * 40, "published": "2026-02-01"}])
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            status = cv.main(["verify", "--repo-root", str(root), "--releases", releases,
                              "--today", "2026-02-02"])
        self.assertEqual(status, 1)
        self.assertIn("PIN_MISMATCH", captured.getvalue())

    def test_a_today_that_is_not_an_iso_date_is_rejected_at_the_flag(self):
        releases = self.releases_file(
            [{"version": "v3.2.0", "commit": "a" * 40, "published": "2026-02-01"}])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            cv.main(["classify", "--version", "v3.2.0", "--releases", releases,
                     "--today", "not-a-date"])

    def test_the_default_today_is_utc_not_the_runner_local_date(self):
        # Two zones 26 hours apart, so whatever hour it is in UTC at least one
        # of them has a different local date. `date.today()` would follow TZ and
        # the expiry verdict would depend on which host ran the check.
        for zone in ("Pacific/Kiritimati", "Etc/GMT+12"):
            with self.subTest(zone=zone):
                previous = os.environ.get("TZ")
                os.environ["TZ"] = zone
                time.tzset()
                self.addCleanup(time.tzset)
                if previous is None:
                    self.addCleanup(os.environ.pop, "TZ", None)
                else:
                    self.addCleanup(os.environ.__setitem__, "TZ", previous)
                self.assertEqual(
                    cv.today_utc(),
                    datetime.datetime.now(datetime.timezone.utc).date().isoformat())

    def test_a_target_that_is_not_a_repository_is_a_usage_failure_not_a_verdict(self):
        # The scan enumerates the index, so a target with no index was never
        # compared against anything. Reporting that as conformant is the
        # fail-open shape ADR 0185 refused, and exit 2 is "the question could
        # not be asked" -- the same answer an unreadable releases file gets.
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        releases = self.releases_file(
            [{"version": "v3.2.0", "commit": "a" * 40, "published": "2026-02-01"}])
        with contextlib.redirect_stderr(io.StringIO()) as captured:
            status = cv.main(["verify", "--repo-root", str(root), "--releases", releases,
                              "--today", "2026-02-02"])
        self.assertEqual(status, 2)
        self.assertIn("could not enumerate", captured.getvalue())

    def test_a_releases_file_that_cannot_be_read_is_a_usage_failure_not_a_verdict(self):
        # A sweep that lost its input must not report the tree it never compared
        # as conformant; exit 2 is "the question could not be asked".
        with contextlib.redirect_stderr(io.StringIO()):
            status = cv.main(["verify", "--repo-root", ".", "--releases",
                              "/nonexistent.json", "--today", "2026-02-02"])
        self.assertEqual(status, 2)


if __name__ == "__main__":
    unittest.main()
