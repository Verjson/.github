---
date: 2026-09-27
id: 20260927T160037Z
impact: patch
title: Recover an orphaned authorization check whose source run has a null completed_at
---
`gate-rearm.yml`'s `recover_orphaned_authorization` required the source arm run's
`completed_at` to be a valid timestamp string before it would treat that run as terminal.
GitHub can report `status: "completed"` with `completed_at: null` (an observed API
anomaly), which permanently blocked recovery of the affected check — discovered
re-arming `verjson-compliance-schema#23`'s canary, whose check-run `108560905178` had sat
`in_progress` since this morning's outage. The live-state check and the five-minute
eventual-consistency floor now fall back to `updated_at` when `completed_at` is exactly
`null`; every other binding is unchanged. ADR 0139 amended.
