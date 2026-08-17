---
date: 2026-08-16
issue: 833
impact: patch
title: Restore private package acquisition in secretless Node CI
---

The secretless Node acquisition job now requests package-read authority, restores
fresh private-package downloads, and rejects pre-existing cache state that could mask
missing authority, while keeping the token out of PR-controlled execution.

Every canonical secretless caller grants `packages: read`; this is necessary when
`NODE_AUTH_TOKEN` maps to the caller's `GITHUB_TOKEN`, whose permission ceiling a
reusable job cannot elevate. A separately issued PAT or App token retains its own
authority. Exact package allowlists, canonical download URLs, integrity
checks, credential scrubbing, and exact-attempt cache validation remain unchanged
([ADR 0086](../docs/decisions/0086-secretless-node-pr-validation/README.md)).

A denied authenticated download now reports both the credential-access and mapped
`GITHUB_TOKEN` permission checks without attributing the failure to either one. There
is no contents-only `GITHUB_TOKEN` fallback, and the credential never moves into
PR-controlled execution.
