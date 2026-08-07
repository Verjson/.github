---
date: 2026-08-07
issue: 384
title: Verify that a dispatched merge actually occurred
---

Fail `dispatch-merge` when its trusted continuation request succeeds but the pull request does not reach a merged state.

The postcondition reports typed review, policy, unavailable-state, and head-change blockers for deterministic remediation, while preserving the explicit green no-continuation fallback. Stale gate-review cleanup is supplied by #452.
