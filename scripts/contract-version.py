#!/usr/bin/env python3
"""Resolve, classify, and verify an adopter's declared organization contract version.

A `uses:` SHA is a content address. It cannot say which contract an adopter is
on, whether that contract is behind, or whether it is still supported, which is
why 22 of the 29 enforced repositories carry a review caller spread across
eleven distinct contract SHAs (ADR 0185, #1374).

This module is the readback half of ADR 0189: a version an adopter declares but
nothing verifies fails exactly like a pin nobody advances. It resolves the
declared version against published contract releases and then asserts that every
`Verjson/.github` reference on disk names that version's release commit.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import os
import pathlib
import re
import sys

VERSION_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
# The window is never narrower than GitHub Packages retention (ADR 0108 keeps the
# three newest stable versions), so a version the retention policy still considers
# current can never be one this contract refuses.
RETENTION_FLOOR = 3
# Two minor lines: the current one and the one before it.
SUPPORTED_MINOR_LINES = 2


@dataclasses.dataclass(frozen=True)
class Release:
    """One published contract release. `commit` is the tag's resolved object id."""
    version: str
    commit: str
    published: str


def parse_version(version: str) -> tuple[int, int, int] | None:
    """`vX.Y.Z` -> ordering key. Anything else is not a contract version."""
    match = VERSION_RE.match(version or "")
    return tuple(int(part) for part in match.groups()) if match else None


def _ordered(releases):
    """Releases newest first, dropping anything that is not `vX.Y.Z`.

    A prerelease or a non-contract tag must not occupy a slot in a window whose
    whole purpose is to say which contract an adopter may run.
    """
    keyed = [(parse_version(r.version), r) for r in releases]
    return [r for key, r in sorted(
        ((k, r) for k, r in keyed if k is not None), key=lambda p: p[0], reverse=True)]


def supported_versions(releases) -> set[str]:
    """The supported set: two minor lines, but never fewer than the newest three.

    "Current and previous minor" alone can be narrower than package retention --
    three releases on three minor lines leave the oldest unsupported while
    retention still keeps it -- and a window narrower than retention strands a
    consumer the organization's own policy calls current. The union is therefore
    the floor, not the intersection.
    """
    ordered = _ordered(releases)
    lines, supported = [], set()
    for release in ordered:
        major, minor, _ = parse_version(release.version)
        if (major, minor) not in lines:
            if len(lines) == SUPPORTED_MINOR_LINES:
                break
            lines.append((major, minor))
        supported.add(release.version)
    supported.update(r.version for r in ordered[:RETENTION_FLOOR])
    return supported


SUPPORTED = "SUPPORTED"
DEPRECATED = "DEPRECATED"
EXPIRED = "EXPIRED"
UNKNOWN = "UNKNOWN"

# Grace runs from the publication of the release that pushed a version out of the
# window, not from that version's own release: the clock a maintainer can act on
# starts when the obligation appears.
GRACE_DAYS = 90
# A major, by definition, requires adopter work rather than a repin, so crossing
# one buys the longer clock.
MAJOR_GRACE_DAYS = 180


@dataclasses.dataclass(frozen=True)
class Verdict:
    state: str
    reason: str
    expires_on: str | None = None


def _published_order(releases):
    """Oldest first. Publication order is the order the window actually moved in."""
    keyed = [(parse_version(r.version), r) for r in releases]
    return [r for _, r in sorted(
        ((k, r) for k, r in keyed if k is not None),
        key=lambda p: (p[1].published, p[0]))]


def _add_days(iso_date: str, days: int) -> str:
    return (datetime.date.fromisoformat(iso_date) + datetime.timedelta(days=days)).isoformat()


def classify(version: str, releases, today: str) -> Verdict:
    """Where a declared version sits in the window, and when it stops being runnable.

    UNKNOWN is not a soft SUPPORTED. A version that resolves to no published
    release cannot be checked against anything, and reporting that as runnable is
    the fail-open shape ADR 0185 refused: `[ "$a" = "$b" ]` calling two failed
    lookups equal.
    """
    if parse_version(version) is None:
        return Verdict(UNKNOWN, f"{version!r} is not a vX.Y.Z contract version")
    published = _published_order(releases)
    if version not in {r.version for r in published}:
        return Verdict(UNKNOWN, f"{version} is not a published contract release")
    if version in supported_versions(published):
        return Verdict(SUPPORTED, f"{version} is inside the supported window")

    declared_major = parse_version(version)[0]
    superseder = None
    seen = []
    for release in published:
        seen.append(release)
        if version not in {r.version for r in seen}:
            continue
        if version not in supported_versions(seen):
            superseder = release
            break
    if superseder is None:
        # Unreachable against a consistent release list, and stated rather than
        # assumed: without a superseder there is no clock, and a version with no
        # clock must not be reported as runnable.
        return Verdict(UNKNOWN,
                       f"{version} is outside the window but no release explains when it left")
    grace = MAJOR_GRACE_DAYS if parse_version(superseder.version)[0] > declared_major else GRACE_DAYS
    expires_on = _add_days(superseder.published, grace)
    if today < expires_on:
        return Verdict(DEPRECATED,
                       f"{version} left the supported window at {superseder.version} "
                       f"and is refused from {expires_on}", expires_on)
    return Verdict(EXPIRED,
                   f"{version} left the supported window at {superseder.version} "
                   f"and expired on {expires_on}", expires_on)


DECLARATION_PATH = ".github/verjson-contract.json"
# One adopter-controlled field. A declaration that also carried the commit would
# reintroduce the skew it exists to remove, with the version and the commit free
# to disagree; the commit is resolved from the hub's release metadata instead.
DECLARATION_KEY = "contract_version"

# Anchored on the hub, so an adopter's own SHA-pinned third-party actions are not
# contract references. Case-insensitive because GitHub resolves owner/repo that
# way and a completeness check must not drop a lowercase reference.
USES_RE = re.compile(
    r"uses:\s*Verjson/\.github/(?P<path>[^@\s]+)@(?P<ref>[^\s\"']+)", re.IGNORECASE)
# The trailing boundary matters: without it a 64-hex container digest in the same
# header yields its first 40 characters as a bogus contract SHA.
HEADER_RE = re.compile(
    r"Verjson/\.github[^\n]*?\b(?P<sha>[0-9a-f]{40})(?![0-9a-f])", re.IGNORECASE)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
MAX_SCAN_BYTES = 1 << 20
SKIP_DIRS = {".git", "node_modules"}


@dataclasses.dataclass(frozen=True)
class Finding:
    kind: str
    detail: str


def _scan_files(root):
    """Every readable text file in the tree, because totality is the point.

    Scoping the scan to a list of known adopter files would reproduce the defect
    it is meant to catch: a contract reference somewhere the list did not name is
    exactly the intra-repository skew ADR 0185 measured.
    """
    root = pathlib.Path(root)
    for directory, subdirectories, names in os.walk(root):
        # Pruned in place rather than filtered afterwards: walking a large `.git`
        # only to discard every entry is the cost, not the correctness problem.
        subdirectories[:] = sorted(d for d in subdirectories if d not in SKIP_DIRS)
        for name in sorted(names):
            path = pathlib.Path(directory) / name
            if path.is_symlink() or not path.is_file():
                # A symlink is followed nowhere: it can point outside the tree
                # being verified, and its target is not this repository's state.
                continue
            try:
                if path.stat().st_size > MAX_SCAN_BYTES:
                    continue
                yield path.relative_to(root).as_posix(), path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                # Not decodable as text, so it carries no contract reference.
                continue


def references(root):
    """(file, kind, ref) for every contract reference on disk.

    Generated headers are read as *claims* alongside the pins, never as
    instructions: adopter-controlled text is an input to this comparison, not to
    anything privileged.
    """
    found = []
    for relative, text in _scan_files(root):
        for match in USES_RE.finditer(text):
            found.append((relative, "uses", match.group("ref")))
        # Comment lines only. A header is a comment; scanning the raw first six
        # lines would read a `uses:` pin a second time as a header claim and
        # report one reference as two.
        head = "\n".join(line for line in text.splitlines()[:6]
                          if line.lstrip().startswith("#"))
        for match in HEADER_RE.finditer(head):
            found.append((relative, "header", match.group("sha")))
    return found


def read_declaration(root):
    """(version, finding). Exactly one of the two is None."""
    path = pathlib.Path(root) / DECLARATION_PATH
    if not path.is_file():
        return None, Finding("DECLARATION_MISSING",
                             f"{DECLARATION_PATH} is absent, so no contract version is declared")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return None, Finding("DECLARATION_UNREADABLE", f"{DECLARATION_PATH}: {error}")
    if not isinstance(document, dict) or not isinstance(document.get(DECLARATION_KEY), str):
        return None, Finding("DECLARATION_UNREADABLE",
                             f"{DECLARATION_PATH} has no string {DECLARATION_KEY!r}")
    return document[DECLARATION_KEY], None


def verify(root, releases, today: str):
    """Assert the declared version against the references the repository really has.

    The comparison is a version lookup followed by an equality on one resolved
    object id, not a blob diff of each file against the hub's default branch. The
    diff was rejected in ADR 0185 for failing open, for being the wrong
    granularity, and for reporting comment-only upstream edits as drift; none of
    those apply once there is a version to compare.
    """
    version, finding = read_declaration(root)
    found = references(root)
    if finding is not None:
        # No declaration and no reference is a repository that does not consume
        # the contract, not a defect. Reporting it would fire on every repository
        # in the organization, and a check that fires everywhere gets muted --
        # which is how the previous invalid drift test survived.
        return [finding] if found else []
    verdict = classify(version, releases, today)
    if verdict.state in (UNKNOWN, EXPIRED):
        return [Finding(verdict.state, verdict.reason)]

    commit = next((r.commit for r in releases if r.version == version), "")
    if not SHA_RE.match(commit or ""):
        # `target_commitish` is a branch name for many releases. Treating one as a
        # commit would compare a pin against the string "main" and report every
        # adopter broken, so an unresolved release fails closed instead.
        return [Finding(UNKNOWN,
                        f"{version} resolved to {commit!r}, not a 40-hex commit")]

    findings = []
    if verdict.state == DEPRECATED:
        findings.append(Finding(DEPRECATED, verdict.reason))
    if not found:
        findings.append(Finding("UNGOVERNED_DECLARATION",
                                f"{DECLARATION_PATH} declares {version} but the repository "
                                "carries no Verjson/.github reference for it to govern"))
    for relative, kind, ref in found:
        if ref == commit:
            continue
        if not SHA_RE.match(ref):
            findings.append(Finding("UNPINNED_REFERENCE",
                                    f"{relative}: {kind} names {ref!r}, which is not an "
                                    "immutable commit"))
            continue
        findings.append(Finding("PIN_MISMATCH",
                                f"{relative}: {kind} names {ref}, but the declared {version} "
                                f"is {commit}"))
    return findings


def load_releases(path: str):
    """Published contract releases, or a usage failure. Never a partial list.

    Resolve them with the tag's own object id, not `target_commitish`:

        gh api repos/Verjson/.github/releases --paginate --jq '.[] | {version: .tag_name,
          published: (.published_at | split("T")[0])}' \\
          | while read -r row; do ...; done   # commit from git/ref/tags/<tag>

    The `commit` field must be a 40-hex object id; `verify` fails closed on
    anything else rather than comparing a pin against a branch name.
    """
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, list):
        raise ValueError("the releases document must be a JSON array")
    releases = []
    for entry in payload:
        if not isinstance(entry, dict):
            raise ValueError("every release entry must be an object")
        releases.append(Release(version=str(entry.get("version", "")),
                                commit=str(entry.get("commit", "")),
                                published=str(entry.get("published", ""))))
    return releases


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("classify", "verify"):
        child = sub.add_parser(name)
        child.add_argument("--releases", required=True)
        child.add_argument("--today", default=datetime.date.today().isoformat())
        if name == "classify":
            child.add_argument("--version", required=True)
        else:
            child.add_argument("--repo-root", default=".")
    args = parser.parse_args(argv)

    try:
        releases = load_releases(args.releases)
    except (OSError, ValueError) as error:
        # Exit 2 is "the question could not be asked". Reporting a tree that was
        # never compared as conformant is the fail-open shape ADR 0185 refused.
        print(f"contract-version: could not read {args.releases}: {error}", file=sys.stderr)
        return 2

    if args.command == "classify":
        verdict = classify(args.version, releases, args.today)
        print(f"{verdict.state}\t{verdict.reason}")
        return 0 if verdict.state == SUPPORTED else 1

    findings = verify(args.repo_root, releases, args.today)
    for finding in findings:
        print(f"{finding.kind}\t{finding.detail}")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
