---
date: 2026-08-05
issue: 341
title: Keep the fleet watchdog, retarget it at the poll job the overflow lane cannot reach
---

#341 proposed deleting the fleet watchdog; #342, #343 and #355 are defects inside it. The
disposition is **keep and fix**, recorded in
[ADR 0056](docs/decisions/0056-fleet-watchdog-retained-and-retargeted/README.md).

Evidence: across 27 scheduled runs (2026-08-03..05) the watchdog reached a saturated pool
with queued work five times. Once it preempted 4 of 4 candidates and cleared a jam with 35
runs queued behind it. 3 of those 4 were an `AI privileged merge`; the fourth was a `gate`
(`verjson-infra` run `30786453794`, age 37m, in the log of run `30788707438`), reachable
only because `gate` was still on the pool on 2026-08-03, before ADR 0053's overflow lane
landed on 2026-08-05. The other four times, including
one with 101 runs queued, it found nothing to preempt. #341's replacement mechanism does not
hold as written: the gate polls the commit check-runs **and commit statuses** rollup
(`ai-review-merge.yml:700-704`), including `renovate/stability-days`, none of which emit a
`workflow_run` event. Meanwhile ADR 0053's `VERJSON_RUNNER_OVERFLOW` already moves `gate` off
the pool, but not `ai-privileged-merge.yml`, which routes on `VERJSON_LANE_PRIVILEGED` — so
`privileged_merge` is the residual exposure and the only poll job still on the pool.

- **Candidates must prove they hold the pool.** Selecting by poll state alone selected jobs
  that were not on the saturated pool at all: `gate` routes on `VERJSON_RUNNER_OVERFLOW` /
  `VERJSON_RUNNER_FASTLANE`, both `["ubuntu-24.04"]`, so cancelling one frees zero
  self-hosted runners, leaves the jam in place and makes the PR re-pay for CI and (per #292)
  for the model review. A candidate's `.labels` must now carry both `self-hosted` and the
  pool label. Same class at the precondition: a queued run counts as starved work only when
  one of its own `queued` jobs asks for this pool, instead of every queued run in the org.
- **#342** — `scripts/fleet-watchdog.sh` carries no default for `WATCHDOG_DRY_RUN`; unset or
  unparseable is a fault, never an implicit licence to cancel. The two selection rules now
  arm separately, because they carry different evidence: `WATCHDOG_DRY_RUN` defaults to
  `'false'` (**armed**) and governs only the proven 35-minute age rule, while the new
  `WATCHDOG_POLL_STEP_DRY_RUN` defaults to `'true'` (report only) and governs the #343
  poll-step rule until an operator sets `VERJSON_WATCHDOG_POLL_STEP_DRY_RUN=false`. Both
  expressions are pinned literally by `fleet-watchdog.test.sh`, since nothing else guards
  them, and the new key is admitted explicitly to the exact env allowlist in
  `scripts/ci-gate/privileged-scheduled-workflows.test.py`. Correcting #336's fragment,
  which claimed a dry-run default the code never had.
- **Silent-failure names are pinned.** The `POLL_WORKFLOWS` display names are matched against
  `name:` in `ai-review-merge.yml` / `ai-privileged-merge.yml`; renaming either would make
  the filter match nothing and the watchdog would find zero candidates forever with every
  test green. `fleet-watchdog.test.sh` now pins those two names alongside the poll step name.
- **#343** — preemptability is now read as a state, not inferred from age. A `gate` whose
  `Wait once for the rest of CI to be green` step is `in_progress` is provably polling and
  preemptable past a 10-minute floor; once that step completes it is spending model-review
  budget and is never a candidate at any age. `AI privileged merge` has no separable poll
  step and keeps the 35-minute rule. The floor measures the POLL step's own `started_at`,
  not job age, so a job that spent 40 minutes on checkout and 30 seconds polling is not a
  candidate. The floor is passed as `WATCHDOG_MIN_POLL_MINUTES`, so
  the privileged-scheduled-workflow env allowlist in
  `scripts/ci-gate/privileged-scheduled-workflows.test.py` admits it explicitly — the
  allowlist stays exact, it is not relaxed.
- **#355** — paginated runner pages are slurped and aggregated before counting, so a fleet
  larger than one page no longer produces a per-page count that fails the numeric guard and
  silently disables the watchdog. A page missing `.runners` is a fault, not an empty pool.
- **The working notes described the opposite arm state.** `CLAUDE.md` said the watchdog ships
  disarmed pending an operator setting `VERJSON_WATCHDOG_DRY_RUN=false`. No such variable
  exists at org or repository scope, and the workflow's fallbacks arm the age rule and
  suppress the poll-step rule, so the note pointed at a switch nobody could read and inverted
  the two defaults. Corrected and folded into the #341 bullet, which is where the re-scope it
  belongs to already lives.

`*/15` is nominal: observed cadence was roughly 15 runs a day with gaps up to ~2.5 h, so the
watchdog is a backstop and not a latency bound. No `workflow_dispatch` is added — the job
reads `secrets.ORG_ADMIN_TOKEN` and a branch-selectable dispatch is the #350 defect.
