---
date: 2026-08-14
issue: 798
impact: minor
title: Expose the derived next changelog version
---

`changelog.py next-version` now prints the exact tag accepted by `release` for the same version-prefix history, component, and repeated-fragment selection without writing, invoking Git, consuming fragments, committing, or tagging.

The accessor shares the release engine's selection and bump derivation, keeps caller-owned version namespaces independent from components, rejects duplicate selectors before release mutation, enforces SemVer 2 prerelease/build identifiers, preserves typed selection diagnostics, and refuses to invent a version when a prefix has no previous release baseline.
