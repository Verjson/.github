---
date: 2026-09-21
issue: 1498
impact: patch
title: Fail AI review authorization visibly when its key is invalid
---

The AI review gate now completes authorization checks with a clear failure when its private key is empty or malformed, while preserving receipt-bound compatibility for in-flight checks as ownership moves to GitHub Actions.

ADR 0199 records the check ownership boundary and the rollout path. Generated label callers now grant the exact check permission the reusable workflow needs, and downstream authorization readers recognize both current and legacy check identities.
