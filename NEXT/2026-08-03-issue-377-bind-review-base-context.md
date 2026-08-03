---
date: 2026-08-03
issue: 377
title: Bind AI review evidence to the PR-head context
---

The merge-gate prompt now states that its workspace and `HEAD` are the pull
request head, never evidence of base-branch content. Lifecycle state such as
an inferred duplicate submission, stale head, closed PR, or already-merged PR
remains owned by deterministic API checks, preventing a byte-identical PR
checkout from becoming a false blocker without suppressing idempotency review.
ADR 0051 records the evidence boundary.
