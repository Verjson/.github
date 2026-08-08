---
date: 2026-08-08
issue: 611
title: Require actionable merge-gate blocking verdicts
---

Reject blocking AI-review verdicts without structured actionable findings, validate sensitive review locations, and retry semantically unusable model output within the existing bounded attempt chain.

The exact empty-findings payload from #611 is a regression fixture, and ADR 0002 records why semantic validation is part of the merge-authority boundary.
