---
date: 2026-08-03
id: 20260803T140000Z
refs: 336
title: The fleet watchdog gets the decision record its class of change requires
---

The watchdog changes runner topology and can cancel merge-gate runs. Both are
sensitive classes that must leave an ADR, and #336 shipped without one — ADRs
0047 and 0048 covered the two routing changes either side of it, and the
numbering stopped at 0048.

This entry carries an `id` rather than `issue: 336`, because #337's fragment
already owns that identity and only one entry per issue may claim it.

[ADR 0049](docs/decisions/0049-fleet-watchdog-preempts-poll-jobs/README.md)
records the four conjunctive preemption conditions, why an unreadable runner
list is a fault rather than a licence to cancel, why cancelling is safe (the
merge is atomic and happens at the end of the poll), and why the allowlist is a
safety boundary rather than configuration.

Writing it surfaced defects in the wiring, none of them in the reasoning:

- The dry-run guard is unreachable on the scheduled path. Both the script and
  the workflow expression resolve to armed, and on a scheduled run the
  expression short-circuits before reading `VERJSON_WATCHDOG_DRY_RUN` — which
  does not exist at any scope anyway. #336's fragment and the workflow's own
  header comment both state the opposite (#342).
- The 35-minute age threshold cannot reach a **polling AI-lane** gate, whose CI
  wait is bounded at 30 minutes. Past 35 minutes that gate is running the model
  review, so in that lane the watchdog's only reachable target is a job doing
  real work. It does reach genuinely-polling fast-lane gates and
  `privileged_merge` loops, both bounded at 40 minutes (#343).
- The `*/15` schedule delivers a few runs a day, not ninety-six.

The ADR records these rather than omitting them. A decision record that
describes an intent the code does not implement is worse than none, because it
is the document a future reader trusts.

Measured while writing: at 13:26Z all six `general` runners were busy, five of
them held by poll jobs, with `verjson-observability`'s `build-test` queued and
unassigned for 12 minutes while that repository's gate polled for it. The
deadlock forms in about a third of the time the watchdog waits before looking.
