# 0072 — Watchdog cadence is observed, not guaranteed

- **Date:** 2026-08-07
- **Issue:** [#414](https://github.com/Verjson/.github/issues/414)
- **Extends:** [ADR 0056](../0056-fleet-watchdog-retained-and-retargeted/README.md)
- **Category:** Merge infrastructure
- **Status:** Accepted

## Context

The fleet watchdog is an emergency backstop for merge-gate poll jobs that
occupy a saturated self-hosted runner pool. Its workflow asks GitHub to run
every 15 minutes, but GitHub schedules are best effort. Across 2026-08-03
through 2026-08-05 the workflow ran about 15 times per day rather than 96,
including gaps near 2.5 hours. A jam can therefore form and clear between
watchdog runs without a cancellation receipt.

Changing the cron expression cannot make GitHub's scheduler reliable. Adding
`workflow_dispatch` would be worse: the workflow reads the organization-wide
administration token, so a dispatcher could select code from a branch and run
it with that secret. An external scheduler would add another privileged token,
availability dependency, and operating surface solely to accelerate a
backstop that remains temporary while merge-gate polling is retired.

GitHub already retains each workflow run, but the interval must otherwise be
reconstructed manually from run history.

## Decision

The watchdog remains a schedule-only, best-effort backstop. The 15-minute cron
is a request, not a latency guarantee or service-level objective.

Every scheduled run queries the same workflow's run history, binds the current
measurement to `github.run_id`, and records the interval from the immediately
preceding scheduled run in the durable job summary. An interval above 30
minutes—twice the nominal period—also emits a workflow warning. The measurement
runs with `always()` after the sweep so a failed cancellation attempt does not
erase cadence evidence.

The cadence probe uses the job-scoped token with only `actions: read`.
`ORG_ADMIN_TOKEN` remains confined to the cancellation step. The workflow
continues to reject every trigger except `schedule`, checks out the immutable
event SHA, and has no caller-controlled ref.

Malformed or unavailable run history fails the cadence step visibly. A first
observable run establishes a baseline rather than inventing a predecessor.

## Consequences

- Operators see scheduler gaps directly in each run summary and as warnings
  without manually comparing timestamps.
- A delayed scheduler remains delayed; this decision makes that limitation
  explicit and observable rather than claiming to fix it.
- No new secret, external scheduler, issue-writing permission, or dispatch
  surface is introduced.
- The workflow gains read-only access to its own Actions run history.
- When merge-gate polling is retired, the watchdog and this cadence probe can
  be removed together.

## Rejected alternatives

- **Tighten the cron expression.** GitHub does not provide a latency guarantee
  for scheduled workflows, so a denser request is not a bound.
- **Add `workflow_dispatch`.** A branch-selectable privileged workflow would
  reopen the secret-exposure class closed by #350 and #385.
- **Use an external scheduler.** It would add a privileged credential and
  availability dependency for a temporary backstop.
- **Treat run-history inspection as sufficient.** The evidence exists, but the
  gap remains implicit and easy to miss during an incident.
