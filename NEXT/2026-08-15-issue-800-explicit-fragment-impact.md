---
date: 2026-08-15
issue: 800
impact: minor
title: Require explicit release impact on new changelog fragments
---

Require every newly added changelog fragment to declare `major`, `minor`, or
`patch`, while preserving the historical patch fallback for existing fragments
and immutable released snapshots.

The canonical required checks provide a bounded migration window through
2026-08-29 UTC, and generated adopter contract tests exercise the strict and
compatibility paths from the same immutable pin.
