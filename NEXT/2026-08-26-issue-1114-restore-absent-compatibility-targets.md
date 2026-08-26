---
date: 2026-08-26
issue: 1114
impact: minor
title: Restore absent secretless compatibility targets
---

Allow verified secretless compatibility artifacts to occupy an initially absent self-package target, then restore that absence after success, failure, or signal without adding a self-dependency pin.

Every installed parent is held as a real directory, path escapes and target races fail closed, multi-lane swaps remain provenance-bound, and existing-target behavior is unchanged under ADR 0146.
