---
date: 2026-08-08
issue: 631
title: Normalize AI review-first locations
---

Preserve otherwise usable AI-review verdicts by reducing ranged or comma-separated human review pinpoints to one canonical `file:line`, while leaving blocking-finding validation fail-closed.

The prompt and schema now specify the exact location shape, retry diagnostics identify the invalid field, and range/comma regressions cover the normalization boundary documented in ADR 0002.
