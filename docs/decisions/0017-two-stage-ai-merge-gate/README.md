# 0017 — AI merge gate uses two runner assignments and one long CI wait

- **Date:** 2026-07-21
- **Issue:** Verjson/.github#104
- **Category:** org merge-gate behavior (sensitive class)
- **Supersedes in part:** the four-job execution shape described by
  [ADR 0016](../0016-self-gate-runner-redundancy/README.md); the dedicated and
  redundant `meta` runner-lane decision itself remains in force.

## Context

The required org merge gate scheduled four sequential jobs: `freshness`,
`classify`, `ai-review`, and `ai-merge`. Every job transition required another
assignment from the scarce `meta` or `gate` runner pool. The AI lane also held a
runner for one CI polling loop before review, released it, queued again, and then
held another runner for a second CI polling loop before merge.

Those transitions amplified runner outages and contention. A workflow could
spend much longer waiting for runner capacity than performing its review, while
the second long CI wait duplicated the green-CI condition already established
before model spend. Increasing timeouts would hide neither queue delay nor the
duplicate occupancy and would leave the same failure mode in place.

The gate must continue to update stale branches, fail closed on genuine
conflicts, preserve the fast/AI/defer lanes, review each current head, retain the
deterministic audit record and follow-up filing, and re-check human holds and CI
at the moment of merge.

## Decision

The required merge gate has exactly two runner jobs:

1. `preflight` performs freshness handling and, only when the current run should
   proceed, classification on the same runner assignment. A branch update still
   steps aside for the `synchronize` run, a genuine conflict still fails closed,
   and a deferred Renovate release-age PR still schedules no gate job.
2. `gate` handles both fast and AI lanes. It performs the only long CI-green wait
   before any model spend. Fast-lane PRs proceed directly to the merge recheck;
   AI-lane PRs retain the bounded three-attempt review and deterministic review
   submission on that same assignment.

Immediately before merge, `gate` takes one authoritative snapshot and requires:

- the PR is open and has no draft, hold label, or `DO NOT MERGE` marker;
- the head SHA exactly matches the SHA classified and reviewed by `preflight`;
- every external CI check is complete and none is failed.

That final snapshot does not poll. A moved head or a red/pending check fails
closed; the workflow's existing event and concurrency behavior lets the current
revision receive a fresh run. The merge request also passes that expected SHA to
GitHub's `--match-head-commit` guard, closing the read/check/merge race if a push
lands after the snapshot. Completed CheckRuns are accepted only for `SUCCESS`,
`NEUTRAL`, or `SKIPPED`; the latter two preserve intentional conditional/no-op
checks. Every other or unknown completed conclusion—including `STALE` and
`STARTUP_FAILURE`—fails closed. Commit status contexts accept only `SUCCESS`,
with `PENDING`/`EXPECTED` continuing to wait and every other state failing.

The initial CI wait retains the former lane limits (30 minutes for AI, 40 minutes
for fast), and model budgets and retry limits are unchanged. The job ceilings are
bounded aggregates rather than the old per-job ceilings: `preflight` receives 20
minutes for the former 10-minute freshness plus 10-minute classification phases;
`gate` receives 45 minutes for fast and 80 minutes for AI (30-minute CI wait, the
former 45-minute review allowance, and five minutes for checkout/debounce,
deterministic submission, and merge recheck). These ceilings preserve the work
budget without using longer waits to mask runner outages.

Phase notices record preflight assignment, the preflight-to-gate queue interval,
CI-wait duration, model/retry outcome, and merge-recheck duration. These
diagnostics distinguish capacity delay from CI delay and model retries without
changing enforcement.

### Rejected alternatives

- **Raise runner or workflow timeouts.** Rejected because it increases resource
  occupancy without reducing queue transitions or duplicate work.
- **Keep a separate merge job but remove only its polling loop.** Rejected
  because the AI path would still queue a third time after review.
- **Trust the pre-review green result through merge.** Rejected because a new
  check, hold, or head revision can appear during model execution; the immediate
  recheck is the fail-closed authority.
- **Put freshness, classification, review, and merge in one job.** Rejected
  because a branch update or defer decision should release the preflight runner
  without reserving a gate assignment, and the two-stage boundary exposes queue
  time cleanly.

## Consequences

- An AI PR needs at most two gate-runner assignments instead of four, and a fast
  PR needs two instead of three.
- A successful AI review never enters a second 40-minute CI polling loop.
- GitHub refuses the merge atomically if the PR head no longer matches the
  classified/reviewed SHA.
- The gate remains sensitive to head movement, human holds, CI regressions,
  blocking verdicts, inconclusive model output, and non-success check conclusions.
- Runner-fleet availability remains an external dependency; this workflow change
  reduces amplification but does not make an offline pool available.
- Tests extract the shipped freshness, review, and merge shell blocks and pin the
  two-job workflow shape so future edits cannot silently restore the queue cost.
