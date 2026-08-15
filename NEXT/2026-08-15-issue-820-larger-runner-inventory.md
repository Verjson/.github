---
date: 2026-08-15
issue: 820
impact: patch
title: Reconcile GitHub-hosted larger-runner inventory
---

The scheduled organization runner reconciler now rejects GitHub-hosted larger runners
unless their numeric IDs appear in an explicit reviewed allowlist, which is empty by
default, closing the arbitrary-label route around static hosted-selector policy.

The inventory query validates complete pagination and response shape; a 404, malformed
response, count mismatch, or API failure is undetermined rather than clean. Drift reuses
the durable #820 issue and cannot create tracker churn. Decided in ADR 0103.
