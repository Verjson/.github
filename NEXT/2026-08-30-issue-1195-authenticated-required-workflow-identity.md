---
date: 2026-08-30
issue: 1195
title: Authenticate required-workflow identity overrides
impact: patch
---

- Generate a separately permissioned protected Node CI variant while preserving the legacy reusable workflow byte-for-byte.
- Bind required-workflow identity to the current authenticated Actions run and live numeric pull request before any auxiliary/package credential use and before every candidate execution route.
- Bind candidate checkouts to the immutable admitted head and fail closed on ambiguous, stale, malformed, partial, or ambient-auth identity evidence.
