---
date: 2026-08-05
issue: 341
title: Keep the fleet watchdog, retarget it at the poll job the overflow lane cannot reach
---

#341 proposed deleting the fleet watchdog; #342, #343 and #355 are defects inside it. The
disposition is **keep and fix**, recorded in
[ADR 0055](docs/decisions/0055-fleet-watchdog-retained-and-retargeted/README.md).

Evidence: across 27 scheduled runs (2026-08-03..05) the watchdog reached a saturated pool
with queued work five times. Once it preempted 4 of 4 candidates and cleared a jam with 35
runs queued behind it — every one an `AI privileged merge`. The other four times, including
one with 101 runs queued, it found nothing to preempt. #341's replacement mechanism does not
hold as written: the gate polls the commit check-runs **and commit statuses** rollup
(`ai-review-merge.yml:700-704`), including `renovate/stability-days`, none of which emit a
`workflow_run` event. Meanwhile ADR 0053's `VERJSON_RUNNER_OVERFLOW` already moves `gate` off
the pool, but not `ai-privileged-merge.yml`, which routes on `VERJSON_LANE_PRIVILEGED` — so
`privileged_merge` is the residual exposure and the only thing the watchdog has ever
preempted.

- **#342** — `scripts/fleet-watchdog.sh` carries no default for `WATCHDOG_DRY_RUN`; unset or
  unparseable is a fault, never an implicit licence to cancel. The org default in
  `fleet-watchdog.yml` is now `'true'` (report only). This **disarms** the watchdog until an
  operator sets `VERJSON_WATCHDOG_DRY_RUN=false`, deliberately, because #343 widens the rule
  that selects candidates. Correcting #336's fragment, which claimed a dry-run default the
  code never had.
- **#343** — preemptability is now read as a state, not inferred from age. A `gate` whose
  `Wait once for the rest of CI to be green` step is `in_progress` is provably polling and
  preemptable past a 10-minute floor; once that step completes it is spending model-review
  budget and is never a candidate at any age. `AI privileged merge` has no separable poll
  step and keeps the 35-minute rule.
- **#355** — paginated runner pages are slurped and aggregated before counting, so a fleet
  larger than one page no longer produces a per-page count that fails the numeric guard and
  silently disables the watchdog. A page missing `.runners` is a fault, not an empty pool.

`*/15` is nominal: observed cadence was roughly 15 runs a day with gaps up to ~2.5 h, so the
watchdog is a backstop and not a latency bound. No `workflow_dispatch` is added — the job
reads `secrets.ORG_ADMIN_TOKEN` and a branch-selectable dispatch is the #350 defect.
