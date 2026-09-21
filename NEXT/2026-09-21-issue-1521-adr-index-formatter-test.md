---
date: 2026-09-21
issue: 1521
impact: patch
title: Stabilize generated ADR-index formatter checks
---

Select only the pinned Prettier version and fail when formatter results are mismatched or incomplete, so an invocation failure cannot hide an earlier finding.
