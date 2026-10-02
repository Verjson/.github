---
date: 2026-10-02
issue: 1678
impact: patch
title: Accept integrity-pinned npm bundled dependencies
---

The container-candidate package planner now skips separately downloading npm lock entries marked `inBundle: true`, relying on the integrity-pinned containing tarball while continuing to reject ordinary entries without exact registry URLs and integrity.

Bundled entries still require a valid package identity and an integrity-pinned ancestor package. Regression coverage includes the nested `@emnapi/core` case and an orphaned bundled entry.
