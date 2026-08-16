---
date: 2026-08-16
issue: 833
impact: patch
title: Restore private package acquisition in secretless Node CI
---

The secretless Node acquisition job now requests package-read authority, restores
fresh private-package downloads, and rejects pre-existing cache state that could mask
missing authority, while keeping the token out of PR-controlled execution.

Every secretless caller must grant `packages: read`, including callers using a
dedicated package token, because reusable jobs cannot elevate the caller
permission ceiling. Exact package allowlists, canonical download URLs, integrity
checks, credential scrubbing, and exact-attempt cache validation remain unchanged
([ADR 0086](../docs/decisions/0086-secretless-node-pr-validation/README.md)).

A denied authenticated download now reports the caller's `packages: read` boundary.
There is no contents-only fallback: reusable workflows cannot elevate a caller's
`GITHUB_TOKEN`, and moving the credential into PR-controlled execution would weaken the
security boundary.
