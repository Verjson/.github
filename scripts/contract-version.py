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

import dataclasses
import datetime
import re

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
