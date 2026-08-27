---
date: 2026-08-27
id: 20260827T003233Z
impact: patch
title: Run candidate manifest after optional dependency skips
---

Evaluate the candidate-manifest job after skipped optional dependencies while requiring
every direct candidate publisher and attestation job to finish successfully.

The executable generator contract now rejects missing `always()` and partial-success
admission predicates.
