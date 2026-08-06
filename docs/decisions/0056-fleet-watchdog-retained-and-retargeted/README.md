# 0056 — Keep the fleet watchdog, retargeted at the poll job the overflow lane cannot reach

- **Date:** 2026-08-05
- **Issues:** [Verjson/.github#341](https://github.com/Verjson/.github/issues/341)
  (retire the watchdog),
  [#342](https://github.com/Verjson/.github/issues/342) (it ships armed),
  [#343](https://github.com/Verjson/.github/issues/343) (35 minutes cannot preempt
  a polling gate),
  [#355](https://github.com/Verjson/.github/issues/355) (it disables itself on a
  paginated runner list)
- **Amends:** [ADR 0049](../0049-fleet-watchdog-preempts-poll-jobs/README.md) —
  narrows what the watchdog targets and revises its *Retirement* section; the
  decision to have a watchdog at all is unchanged
- **Category:** merge-gate behaviour + runner topology (sensitive class)

## Context

Four issues arrived against the same component. #341 proposes deleting it; the
other three are defects inside it. Fixing three bugs in something slated for
removal is waste, and removing it while it is load-bearing is a regression, so
the disposition had to be settled before any of them could be worked.

### What the watchdog actually does

27 scheduled runs between 2026-08-03T05:59Z and 2026-08-05T15:37Z. Five reached a
saturated pool with work queued behind it:

| Run | Pool | Queued | Candidates | Outcome |
| --- | --- | --- | --- | --- |
| 2026-08-03 05:59 | `online=6 idle=0` | 35 | 4 | **preempted 4 of 4** |
| 2026-08-03 13:20 | `online=6 idle=0` | 14 | 0 | nothing to do |
| 2026-08-03 18:05 | `online=10 idle=0` | 26 | 0 | nothing to do |
| 2026-08-04 12:18 | `online=7 idle=0` | 12 | 0 | nothing to do |
| 2026-08-05 03:38 | `online=10 idle=0` | 101 | 0 | nothing to do |

So the cancel path *does* have production evidence, contrary to what #341 and
#342 recorded: it cleared a jam with 35 runs queued behind it. **3 of the 4**
cancelled runs belonged to `AI privileged merge` (all in `verjson-upload`); the
fourth was a `gate` — `verjson-infra` run `30786453794`, age 37m, workflow
`AI review + auto-merge`, in the log of run `30788707438`. That gate cancel
predates ADR 0053's overflow lane, which landed 2026-08-05: on 2026-08-03 `gate`
was still routed to the self-hosted pool, so cancelling it did free a runner.
And in four of five saturation events — including one with 101 runs queued — it
found nothing to preempt at all. Both halves of that are #343: 35 minutes is
longer than the AI lane's own 30-minute poll window, so a `gate` is either still
polling and too young to touch, or old enough to touch and no longer polling —
and that gate at 37m was in the second state, i.e. it was cancelled while
spending model-review budget, which is precisely the false positive #343 exists
to remove.

That correction does not weaken the keep decision; it sharpens the targeting
requirement. The one `gate` this watchdog ever reached was reachable *because*
`gate` was on the pool at the time. It no longer is (`VERJSON_RUNNER_OVERFLOW`
and `VERJSON_RUNNER_FASTLANE` are both `["ubuntu-24.04"]`), so a rule that
selects a `gate` today would cancel a job holding hosted capacity, free zero
self-hosted runners, leave the jam in place, and make the PR re-pay for CI and —
per [#292](https://github.com/Verjson/.github/issues/292) — for the model review
as well. Candidate selection therefore has to prove pool occupancy, not just
poll state.

### Why #341 cannot be executed as written

#341 proposes replacing the poll loop with re-entry on `workflow_run: completed`.
The gate does not wait on workflows. It polls the **commit check-runs and commit
statuses rollup** for the reviewed head
(`ai-review-merge.yml:700-704`), and acts on entries that `workflow_run` cannot
observe:

- **Commit statuses** — `renovate/stability-days` is handled explicitly at
  `ai-review-merge.yml:771`. It is a status context, not a workflow; no workflow
  completes and no event fires.
- **Check runs from other GitHub Apps**, which are not Actions workflows either.
- A `workflow_run` run carries **default-branch** context and no PR payload, so
  the PR number and head SHA must be re-derived — reopening the head/`main`
  conflation class that [#377](https://github.com/Verjson/.github/issues/377)
  exists for, and moving the anti-TOCTOU head binding across a process boundary
  it currently never has to cross (the recheck and the squash-merge are one step,
  `ai-review-merge.yml:1572`).
- The entry-workflow identity changes, which is the thing
  [ADR 0044](../0044-gate-provenance-bound-to-entry-workflow/README.md) binds
  provenance to.

#341 is therefore a multi-ADR rearchitecture of the org merge gate across ~90
consumers, not a change that can land alongside three bug fixes.

### Why the residual risk is `privileged_merge`, not `gate`

[ADR 0053](../0053-overflow-lane-for-polling-gate-jobs/README.md) delivered most
of #341's intended benefit by a cheaper, reversible route.
`VERJSON_RUNNER_OVERFLOW` was set to `["ubuntu-24.04"]` at 2026-08-05T13:52:24Z,
which moves `preflight`, `gate` and `dispatch-merge` off the self-hosted pool
entirely (`ai-review-merge.yml:173`, `:530`, `:1814`).

It does **not** move `privileged_merge`, which routes on `VERJSON_LANE_PRIVILEGED`
(`ai-privileged-merge.yml:80`, currently `["self-hosted","general"]`) and still
polls the shared pool for up to 45 minutes. That is exactly the workflow the
watchdog has actually preempted. ADR 0053 is also explicit that overflow is
hosted budget "that will be exhausted and must then be given back" — when it is
given back, the `gate` deadlock returns.

## Decision

**Keep the watchdog. Fix #342, #343 and #355. Do not close #341 — narrow it.**

1. **#342 — the arm/disarm decision lives only in the workflow, and the two
   selection rules arm separately.** The script carries no default for
   `WATCHDOG_DRY_RUN`; an unset or unparseable value is a fault (`exit 2`), not
   an implicit licence to cancel. #336 shipped armed precisely because two layers
   each carried their own default and the running log described the other one.

   The workflow supplies the org defaults, and there are now two, because the two
   rules carry different evidence:

   - `WATCHDOG_DRY_RUN` defaults to `'false'` — **armed**. It now governs only the
     35-minute age rule, which fired correctly in production on 2026-08-03 and is
     the only mitigation for a `privileged_merge` jam. Disarming a proven backstop
     to buy caution about a *different* rule would be a regression, not caution.
   - `WATCHDOG_POLL_STEP_DRY_RUN` defaults to `'true'` — **report only**. It
     governs the poll-step rule this change introduces, which has never fired in
     production. An operator arms it with
     `VERJSON_WATCHDOG_POLL_STEP_DRY_RUN=false` after reading a few
     `DRY RUN would cancel … rule=poll` lines.

   This is not #336's two-defaults trap re-introduced. #336 was a default that
   *authorised* cancelling; `WATCHDOG_POLL_STEP_DRY_RUN` can only *suppress* one,
   so drift in it cannot ship the watchdog armed. Both expressions are pinned
   literally by `fleet-watchdog.test.sh`, because nothing else guards them, and
   `WATCHDOG_POLL_STEP_DRY_RUN` is admitted explicitly to the exact env allowlist
   in `scripts/ci-gate/privileged-scheduled-workflows.test.py`.

2. **A candidate must prove it holds a runner from the saturated pool.**
   Selecting on poll state alone selects jobs that are not on the pool at all.
   `gate` routes on `VERJSON_RUNNER_OVERFLOW` (or `_FASTLANE` for public
   targets), both `["ubuntu-24.04"]` today, so **every `gate` in the org runs on
   hosted capacity**: cancelling one frees zero self-hosted runners, the jam
   survives, and the PR re-pays for CI and — because the #292 re-review skip never
   fires — for the model review too. The jobs API already returns the answer, so
   a candidate must carry both `self-hosted` and the pool label in its `.labels`.
   Missing or unexpected labels select nothing.

   The same class applies to the precondition. `status=queued` counted every
   queued run in the organisation, including runs queued for hosted runners, so
   "work is starved by this pool" was equally unproven. A queued run now counts
   only when one of its own `queued` jobs asks for this pool. That costs one extra
   API call per queued run (observed peak 101), which fits inside the job's
   10-minute budget; an unreadable job list is not counted, because over-counting
   the queue is what authorises cancelling.

3. **#343 — preemptability is a state, not an age.** Where a poll workflow names
   the step that does the polling, the watchdog reads that step's status instead
   of inferring "waiting" from the clock. A `gate` whose
   `Wait once for the rest of CI to be green` step is `in_progress` is provably
   sleeping on a check it cannot influence and is preemptable at any age past a
   10-minute floor; once that step completes the job is spending model-review
   budget and is never a candidate, however old. Workflows with no separable poll
   step — `AI privileged merge`, whose poll loop shares a step with the merge
   itself — keep the 35-minute age rule, which is the rule that has actually
   fired.

4. **#355 — aggregate the paginated runner list.** `gh api --paginate` emits one
   document per page, so counting with `jq` over that stream yields one count per
   page and the numeric guard then disables the watchdog. Pages are slurped and
   `.runners` aggregated across all of them; a page missing its `.runners` array
   is a fault, because an undercount of idle capacity is what authorises
   cancelling.

5. **The schedule is a backstop, not a latency bound.** `*/15` is nominal.
   Observed cadence over 2026-08-03..05 was roughly 15 runs a day with gaps up to
   ~2.5 h — ordinary GitHub scheduled-workflow deprioritization. Nothing in this
   repository fixes it, and it is recorded rather than papered over. A
   `workflow_dispatch` escape hatch is deliberately **not** added: this job reads
   `secrets.ORG_ADMIN_TOKEN`, and a branch-selectable dispatch would hand that
   secret to workflow code chosen by the dispatcher — the defect
   [#350](https://github.com/Verjson/.github/issues/350) tracks and #385 removed
   elsewhere.

## Consequences

The watchdog stays armed for the rule that has evidence and is report-only for
the rule that does not. In practice it can now reach only `privileged_merge`,
because that is the only poll job still on the pool — which is exactly the
residual exposure, and exactly what the 2026-08-03 05:59 firing was. Arming the
poll-step rule is a separate operational action item
(`VERJSON_WATCHDOG_POLL_STEP_DRY_RUN=false`), not something this change performs.

While `VERJSON_RUNNER_OVERFLOW` is set, the poll-step rule is expected to select
nothing at all: every `gate` is on hosted capacity and fails the pool-occupancy
test. That is the correct outcome, not a malfunction — the rule becomes live
again when overflow is given back and `gate` returns to the pool.

Three names are now contracts between `scripts/fleet-watchdog.sh` and the
workflows it polices, each of which fails **silently** when broken (the watchdog
finds zero candidates forever and every test stays green), so
`fleet-watchdog.test.sh` pins each one:

- the poll step name, against `ai-review-merge.yml`;
- both `POLL_WORKFLOWS` display names, against the `name:` of a real workflow;
- both dry-run expressions in `fleet-watchdog.yml`, literally.

ADR 0049's *Retirement* section stands in spirit and is narrowed in scope: the
component is still meant to be deleted, but the prerequisite is no longer "the
gate re-enters on `workflow_run`". It is that no merge-gate job polls on the
shared pool — which ADR 0053 already achieves for `gate` by configuration, and
which `privileged_merge` still needs. #341 should be re-scoped to that.

## Alternatives considered

**Delete it now.** Rejected: it is the only mitigation for `privileged_merge`,
which the overflow lane does not route, and it has one production firing that was
correct and cleared 35 queued runs. Deleting a proven backstop in favour of a
rearchitecture whose stated mechanism does not hold is a regression.

**Fix only #355 and #342 and leave the threshold.** Rejected: #343 is the reason
four of five saturation events found nothing to preempt, and leaving it means the
only `gate` the watchdog can ever reach is one doing paid model review.

**Route `privileged_merge` through `VERJSON_RUNNER_OVERFLOW` too.** Worth doing
and probably the right permanent fix, but it is a change to the privileged merge
lane's runner topology and belongs with #341's re-scope, not here.
