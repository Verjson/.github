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
