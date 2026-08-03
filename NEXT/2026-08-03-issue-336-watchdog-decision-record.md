---
date: 2026-08-03
issue: 336
title: The fleet watchdog gets the decision record its class of change requires
---

The watchdog changes runner topology and can cancel merge-gate runs. Both are
sensitive classes that must leave an ADR, and #336 shipped without one — ADRs
0047 and 0048 covered the two routing changes either side of it, and the
numbering stopped at 0048.

[ADR 0049](docs/decisions/0049-fleet-watchdog-preempts-poll-jobs/README.md)
records the four conjunctive preemption conditions, why an unreadable runner
list is a fault rather than a licence to cancel, why cancelling is safe (the
merge is atomic and happens at the end of the poll), and why the allowlist is a
safety boundary rather than configuration.

Writing it surfaced three defects in the wiring, none of them in the reasoning:

- The dry-run guard is unreachable. Both the script and the workflow expression
  default to armed, and on a scheduled run the expression short-circuits before
  reading `VERJSON_WATCHDOG_DRY_RUN` at all, so the documented kill switch does
  nothing. #336's fragment states the opposite (#342).
- The 35-minute age threshold cannot reach a **polling** AI-lane gate, whose CI
  wait is bounded at 30 minutes. Past 35 minutes that gate is running the model
  review, so the watchdog's only reachable AI-lane target is a job doing real
  work (#343).
- The `*/15` schedule fires roughly twice a day in practice.

The ADR records these rather than quietly omitting them. A decision record that
describes an intent the code does not implement is worse than none, because it
is the document a future reader trusts.

Measured while writing: at 13:26Z all six `general` runners were busy, five of
them held by poll jobs, with `verjson-observability`'s `build-test` queued and
unassigned for 12 minutes while that repository's gate polled for it. The
deadlock forms in about a third of the time the watchdog waits before looking.
