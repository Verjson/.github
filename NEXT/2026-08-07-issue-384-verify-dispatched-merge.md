---
date: 2026-08-07
issue: 384
title: Verify that a dispatched merge actually occurred
---

Fail `dispatch-merge` when its trusted continuation request succeeds but the pull request does not reach a merged state.

The postcondition reports typed review, policy, unavailable-state, head-change,
and closed-without-merge blockers for deterministic remediation, while
preserving the explicit green no-continuation fallback. Its read-only PR
permission and 66-minute job ceiling cover the privileged workflow's 45-minute
timeout, ten minutes of shared-runner queue contention, five minutes of API
margin, and publication headroom. Review and policy diagnostics remain
`true|false|unknown` until terminal evidence is available; a validated step
summary and workflow annotation expose the typed blocker and remediation to
operators. Stale gate-review cleanup is supplied by #452.
