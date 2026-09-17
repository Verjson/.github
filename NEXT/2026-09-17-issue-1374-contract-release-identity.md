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
