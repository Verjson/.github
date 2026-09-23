---
date: 2026-09-23
issue: 1565
title: Parameterize component release caller defaults
impact: patch
---

Allow canonical release callers to declare a strictly validated default
version prefix and component as one atomic pair. Generated component workflows
now open manual dispatches on their intended stream, while callers that omit the
new options retain the existing `v` and unscoped defaults. Contract tests bind
the emitted defaults to generator provenance and reject later byte drift.
