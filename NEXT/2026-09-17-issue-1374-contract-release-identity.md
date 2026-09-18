---
date: 2026-09-17
issue: 1374
impact: minor
title: Give the organization contract a release identity an adopter can declare and a check can read back
---

ADR 0191 decides that a contract version is a published `Verjson/.github`
release, that an adopter declares exactly one of them in
`.github/verjson-contract.json`, and that the declaration is verified by
resolving it to that release's commit and requiring every `Verjson/.github`
reference on disk to name that commit. `scripts/contract-version.py` is the
readback: a declared version nothing verifies fails exactly like a pin nobody
advances.

The supported window is the two most recent minor lines, never narrower than the
three newest releases, so it cannot refuse a version GitHub Packages retention
still keeps. Versions outside the window are deprecated with a computed expiry
date and refused after it.

The readback is total over what actually ships, or it says so. The scan
enumerates the git index rather than walking the working tree, because the index
is what Actions checks out and executes; untracked build output and tool caches
reach no workflow run, and scanning them only produced `UNSCANNED` findings no
adopter could clear. A quoted `uses:` scalar, a generated header anywhere in the
file, and a caller vendored under a tracked `node_modules` are all references,
and a tracked file that cannot be read, decoded, or sized within the scan limit
is reported as `UNSCANNED` rather than skipped. The releases document is validated at load — one commit per
version, 40-hex object ids, `YYYY-MM-DD` dates — so an ambiguous or
`target_commitish`-derived list exits 2 instead of producing a verdict from it,
and `--today` defaults to the UTC date rather than the runner's local one.
