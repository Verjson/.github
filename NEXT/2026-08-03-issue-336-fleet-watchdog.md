---
date: 2026-08-03
issue: 336
title: A watchdog breaks merge-gate poll deadlocks on the self-hosted fleet
---

ADR 0048 removed the poll deadlock for public targets by routing merge-gate jobs
to elastic hosted capacity. Measuring after it landed showed how little that
covers: **88 of the 90 repositories in this organization are private**, so the
fix reaches two of them. Everything else still contends for six self-hosted
runners on which `gate` and `privileged_merge` sleep for 10-40 minutes while
polling for checks they cannot influence.

`scripts/fleet-watchdog.sh` preempts a poll job only when all four hold: it is a
known poll workflow (never CI, never a build), it is older than 35 minutes so its
own window is nearly spent, the pool has no idle runner, and something is
actually queued behind it. An unreadable runner list is a fault, not a licence to
cancel — the watchdog refuses to act on a fleet state it could not read.
Cancelling is safe because the merge is atomic and happens at the *end* of the
poll, so a preempted run has not half-merged anything and re-fires on the next
event.

It runs every 15 minutes on the fast lane, because a watchdog that queued for a
self-hosted runner would be waiting behind the jam it exists to clear, and this
repository is public so the minutes are free. It ships in **dry run**: it reports
what it would preempt and cancels nothing until `VERJSON_WATCHDOG_DRY_RUN` is
set to `false`.

This is a stopgap, and the entry that removes it should say so. The real fix is
for the gate to stop occupying a runner while it waits — re-entering on
`workflow_run: completed` rather than polling — which needs no budget and no
watchdog. The alternatives are raising the spending limit so private repositories
can use the fast lane, or adding self-hosted capacity.

The routing policy test also stopped asserting ADR 0033's blanket "a Verjson job
never reaches hosted", which ADR 0047/0048 already retired, and now asserts the
narrower property that actually matters: no job reaches hosted *by accident*, and
every fast-lane selector keeps a fallback for an unset variable.
