---
date: 2026-08-28
issue: 1127
impact: patch
title: Bind candidate manifest checks to direct producers
---

Bind the candidate-manifest contract test to its exact direct-producer graph and prove that skipped, cancelled, or failed producers remain fail closed.

This closes #1127 and #1128 by covering dependency-graph drift and every non-success terminal producer state without changing publication behavior.
