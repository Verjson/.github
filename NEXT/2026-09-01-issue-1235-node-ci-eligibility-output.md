---
date: 2026-09-01
issue: 1235
impact: patch
title: Expose whether reusable Node CI executed or deferred
---

Expose the reusable Node CI lane's `should-run` decision so callers can distinguish an executed suite from a successful deferred no-op.

The output maps directly from the eligibility job for both regular and protected Node CI while preserving the existing successful `build-test` context during Renovate stability deferrals.
