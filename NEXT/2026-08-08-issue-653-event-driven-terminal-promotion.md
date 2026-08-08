---
date: 2026-08-08
issue: 653
title: Replace native auto-merge with terminal event-driven promotion
summary: Complete authorized merges with exact-head admin promotion after declared CI, without polling or paid retries.
---

The dedicated App authorization remains immutable and head-bound. Ordinary CI
completion now makes only a cheap, idempotent promotion attempt; pending checks exit
immediately, failures block, and all-success promotion squash-merges the exact head.
