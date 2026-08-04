# 0049 — A watchdog preempts merge-gate poll jobs on the self-hosted fleet

- **Date:** 2026-08-03
- **Issue:** [Verjson/.github#336](https://github.com/Verjson/.github/issues/336)
- **Amends:** ADR 0048 (covers the private repositories its visibility split cannot reach)
- **Status:** accepted, and deliberately temporary — see *Retirement*

## Context

ADR 0048 removed the poll deadlock for public targets by routing merge-gate
jobs to elastic hosted capacity, where sleepers cannot starve anyone. Measuring
the organization after it landed showed how little that covers: of 91
repositories, **89 are private and 2 are public**. The fix reaches two.

(#336's fragment, `scripts/fleet-watchdog.sh` and the watchdog workflow all say
"88 of 90", which is `owned_private_repos` rather than `total_private_repos`.
The ratio is the point and it is unchanged, but the three should be corrected to
one enumeration.)

Everything else still contends for six self-hosted runners on which `gate` and
`privileged_merge` sleep for 10–40 minutes while polling for checks they cannot
influence. That is the same resource deadlock ADR 0048 documents — six sleepers
holding six runners while the CI they wait on queues for those runners — and for
88 repositories nothing has changed.

The three options were: raise the spending limit so private repositories can use
the fast lane; add self-hosted capacity; or stop the jam once it forms. The first
two are recurring cost, and neither stops a job from sleeping on a runner. This
ADR records the third as an interim measure, not as the answer.

## Decision

`scripts/fleet-watchdog.sh` runs on a schedule and cancels a poll job **only**
when all four conditions hold:

1. **It is a known poll workflow** — never CI, never a build. The watchdog
   carries an allowlist of workflows whose runs are safe to interrupt, rather
   than inferring safety from duration. A long build and a long poll look
   identical from the outside, and cancelling the build is destructive.
2. **It is older than 35 minutes**, so its own polling window is nearly spent
   and little work is discarded.
3. **The pool has no idle runner.** Preemption with capacity to spare buys
   nothing and costs a run.
4. **Something is queued.** Without a waiter there is no jam to clear.

   Two honest limits on that fourth condition, both weaker than the intent: the
   queue count is an **organization-wide sum across every repository and every
   fleet**, so a run queued for *hosted* capacity — which no self-hosted
   preemption can help — still authorizes a sweep. And once a sweep is
   authorized the watchdog cancels **every** candidate rather than enough to
   break the tie. "Queued behind it" is the intent; "something, somewhere, is
   queued" is the implementation.

**An unreadable runner list is a fault, not a licence to cancel.** If the
watchdog cannot determine fleet state it refuses to act. The alternative —
treating "unknown" as "saturated" — would make an API blip look exactly like a
deadlock and cancel healthy runs.

Cancelling is safe because **the merge is atomic and happens at the end of the
poll**. A preempted run has not half-merged anything, and re-fires on the next
event.

It runs on the fast lane (`VERJSON_RUNNER_FASTLANE`), because a watchdog that
queued for a self-hosted runner would be waiting behind the jam it exists to
clear. This repository is public, so under ADR 0048 those minutes are free.

**Amended 2026-08-04 for
[#350](https://github.com/Verjson/.github/issues/350):** the privileged watchdog
has no `workflow_dispatch` trigger. A dispatch ref selects both a workflow's
definition and its checkout defaults, so pinning only the checkout could be
removed by the same branch-controlled workflow and did not close the reported
path. Scheduled runs load the workflow from the default branch, and checkout is
bound to `${{ github.sha }}`, the immutable default-branch revision for that
scheduled event. This avoids both branch-selected executable code and a stale
hardcoded revision.

The semantic contract test
`scripts/ci-gate/privileged-scheduled-workflows.test.py` proves that schedule is
the only trigger, checkout uses the event SHA, the privileged command is static,
and the job has exactly its two named steps with no unnamed or alternate
execution surface between checkout and token use. Negative mutations cover bare
sequence dashes and quoted executable keys so alternate valid YAML spellings do
not bypass the boundary.

Removing this dispatch path is not a claim that repository writers are fully
isolated from repository-visible organization secrets in every workflow. Signed
workflow identity and least-privilege secret scoping remain tracked in
[#261](https://github.com/Verjson/.github/issues/261) and
[#265](https://github.com/Verjson/.github/issues/265). The watchdog remains a
temporary mechanism and its retirement plan below is unchanged.

## Consequences

- A saturated fleet recovers without a human cancelling runs by hand.
- Preempted gate runs re-fire, so a PR is delayed rather than dropped, at the
  cost of repeating the poll work already done.
- The allowlist is now a load-bearing safety boundary. A poll workflow added
  without registering it is invisible to the watchdog; a *build* workflow added
  to it by mistake makes the watchdog destructive. Changes to that list are
  security-relevant review, not configuration.
- `VERJSON_WATCHDOG_DRY_RUN` is intended to gate the cancel path, defaulting to
  a dry run. **On the scheduled path — the only automatic one — it does not.**
  After #350 removes the manual path, the schedule explicitly retains its
  existing armed default with `vars.VERJSON_WATCHDOG_DRY_RUN || 'false'`; no
  `VERJSON_WATCHDOG_*` variable exists at organization or repository scope, so
  there is no kill switch. #336's fragment still asserts the opposite. Tracked in
  [#342](https://github.com/Verjson/.github/issues/342); this ADR records the
  decision, not the defect, and the defect must be fixed rather than adopted.
- **The 35-minute threshold cannot reach a polling AI-lane gate**, whose CI wait
  is bounded at 30 minutes (`max_attempts=60` × 30 s). Past 35 minutes such a
  gate is running the model review, so *in that lane* the only reachable target
  is a job doing real work. This does **not** generalize: a fast-lane gate
  (`max_attempts=80`) and a `privileged_merge` loop both poll for 40 minutes, so
  each is a correct target in a 35–40 minute window. A public target's gate runs
  hosted under ADR 0048 and is still a candidate, where cancelling frees no
  self-hosted capacity at all. Age is a proxy for the wrong property — a job is
  preemptable when it is *waiting*, not when it is *old*. Tracked in
  [#343](https://github.com/Verjson/.github/issues/343).
- The `*/15` schedule does not deliver every 15 minutes. Observed runs on
  2026-08-03 were 05:59, 10:01 and 13:20 — a few a day rather than ninety-six,
  ordinary scheduled-workflow deprioritization. A jam that forms and clears
  inside 30 minutes is usually invisible to it.
- **The watchdog is armed and cancelling for as long as #342 is open.** No
  cancellation has been observed yet — every run so far exited at condition 3
  with idle capacity — so its destructive path has no production evidence
  behind it. If #342 cannot be fixed promptly, disabling the schedule is the
  cheaper mitigation than leaving an unexercised cross-repository canceller
  running unattended.
- ADR 0033's blanket "a Verjson job never reaches hosted" is already retired by
  ADRs 0047 and 0048. `runner-routing-policy.test.sh` was narrowed to assert the
  property that still holds — no job reaches hosted *by accident*, and every
  fast-lane selector keeps a fallback for an unset variable — rather than being
  deleted.

## Why the tests assert the positive case

Three bugs surfaced while writing the suite, each of which would have made the
watchdog silently never fire:

- `label` is a reserved word in jq, which broke the `--arg` binding.
- `+` in `AI review + auto-merge` is a regex quantifier, so `test()` matched
  nothing.
- `gh api --jq` does not accept `--arg` at all.

All three failed **closed**, to "no candidates" — the same output a healthy,
unjammed fleet produces. A suite that only asserted "does not cancel the wrong
thing" would have passed on all three. It therefore also asserts that the
watchdog *does* cancel when every condition is met.

## Status of the mechanism as recorded

This ADR is written after the fact, and the honest record is that the mechanism
does not yet do what the decision says. The defects found while writing it are
all in the wiring rather than the reasoning: it is armed instead of dry-run on
its only automatic path (#342), its age threshold cannot reach a polling
AI-lane gate (#343), its schedule fires a few times a day rather than every 15
minutes (#343), and its queue condition is organization-wide rather than
"behind this job".

That is worth recording rather than quietly fixing, because the shape recurs
here: the argument in the fragment is sound, the implementation inverts a
default, and the test pins the guarded case while leaving the default
unasserted.

## Retirement

This is a stopgap and should be deleted, not maintained.

The real fix is for the gate to stop occupying a runner while it waits —
re-entering on `workflow_run: completed` rather than polling. A job that is not
running cannot starve anyone, which removes the failure mode instead of managing
it, and needs neither budget nor watchdog.

That work is tracked in
[#341](https://github.com/Verjson/.github/issues/341). When it lands, the
script, its workflow, its tests and the `VERJSON_WATCHDOG_*` variables are
removed together, and a decision record supersedes this one.
