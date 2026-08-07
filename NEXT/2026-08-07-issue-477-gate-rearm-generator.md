---
date: 2026-08-07
issue: 477
title: Generate immutable gate re-arm callers for fleet rollout
---

Generate thin, immutable-SHA-pinned gate re-arm callers so repositories can bridge activity types that the organization required workflow never receives, with the canonical security guards bound to reviewed code.

The contract covers #497’s normalized hold-removal behavior, terminal holds and drafts, `re-review` recursion, no head checkout, fail-closed metadata, and least-privilege `actions: write`. This delivers the rollout artifact but leaves #477 open until fleet adoption is complete.
