---
date: 2026-08-16
issue: 833
impact: patch
title: Restore private package acquisition in secretless Node CI
---

The secretless Node acquisition job now requests package-read authority, restoring
fresh private-package downloads while keeping the token out of PR-controlled
execution.

Callers that map `GITHUB_TOKEN` must grant `packages: read`; callers using a
dedicated package token keep that token's independent scope. Exact package
allowlists, canonical download URLs, integrity checks, credential scrubbing, and
exact-attempt cache validation remain unchanged
([ADR 0086](../docs/decisions/0086-secretless-node-pr-validation/README.md)).
