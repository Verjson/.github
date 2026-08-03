---
date: 2026-08-03
title: Active Issues sync after the merge-gate deadlock audit
---

`CLAUDE.md`'s Active Issues list loads into every session, so a stale entry
costs context in each one and misreports the state of the work.

Dropped: **#300**, closed by the documentation advance to `v2.2.0`.

Added, all from auditing the merge gate against a live deadlock:

- **#340** — `repo-hygiene.test.sh` commits to the repository it is run from.
  Carried on the list rather than only in the tracker because it is an active
  hazard to any session that runs the shell suite locally.
- **#341** — retire the watchdog by making the gate re-enter on
  `workflow_run: completed` instead of holding a runner while polling.
- **#342** — the watchdog's dry-run guard is unreachable, so it is armed.
- **#343** — its 35-minute threshold cannot preempt a polling AI-lane gate.

#342 and #343 are kept separate from #341 deliberately: #341 deletes the
watchdog, but it is a large change and the watchdog is cancelling runs today.
