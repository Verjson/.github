# 0145 — Recover receipt-bound reviews that stop before provider execution

- **Date:** 2026-08-26
- **Status:** Accepted
- **Issue:** [#1112](https://github.com/Verjson/.github/issues/1112)
- **Extends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md)
- **Extends:** [ADR 0130](../0130-separate-explicit-label-caller/README.md)
- **Extends:** [ADR 0139](../0139-recover-orphaned-authorization-checks-across-runs/README.md)

## Context

An authorized `re-review` label is a one-shot permission to dispatch a paid review. The
trusted arm consumes that label before dispatch and binds the exact head, check, App,
policy, and arm run to an immutable receipt. The dispatched workflow previously copied
the reviewed head and authority from preflight outputs into completion. If preflight
failed or classified a newly held pull request, those outputs were empty, the provider
gate skipped, and completion replaced the real cause with a missing-head receipt error.

Rerunning the review workflow was categorically rejected to prevent a second provider
charge. That was safe but stranded a consumed label even when the gate had no runner and
no provider reservation, submission, or review had occurred. Applying another label would
pay for evidence that had never been attempted, while broadly allowing reruns could pay
twice.

## Decision

Completion takes the head identity directly from the immutable workflow-dispatch input.
Preflight status, lane, and gate status remain diagnostic inputs only. When the receipt is
valid but preflight failed or was held and the gate skipped, completion records that
causal pre-provider state on the exact authorization check, grants no approval, and keeps
the arm receipt available.

Every direct review dispatch must pass a helper checked out at the executing workflow
revision before freshness or classification proceeds. The first attempt is admitted only
when the run and triggering actors are `github-actions[bot]`, the App-owned authorization
check remains in progress, and the current run is the sole direct workflow-dispatch run
with the receipt-correlated title. This rejects a maintainer manually replaying retained
receipt inputs as a new run, even if the maintainer changes the untrusted explicit-review
input. A recovery may proceed only as a later attempt of that same
GitHub Actions run and must prove all of the following:

1. The arm receipt still verifies the exact repository, pull request, head, check, arm
   run and attempt, review-policy envelope, and configured App ID and slug.
2. The current review run is the same receipt-correlated `workflow_dispatch` run on the
   protected default branch, and a recovery attempt is greater than one.
3. Every earlier attempt has exactly one completed preflight, a skipped gate with no
   steps, a failed completion, and a skipped terminal dispatch. All attempts are checked,
   not only the immediately preceding one.
4. The pull request remains open at the receipt head and the exact App-owned check remains
   the failed check named by the receipt.
5. No exact-head App review or reservation marker exists. Any provider-bound gate step,
   App review, missing page, duplicate job, malformed identity, stale head, or API failure
   refuses recovery.

The recovery proof enables only the existing preflight and gate. It does not reserve a
provider, mutate a review, create a check, or grant authorization. Once any recovered
attempt reaches the gate, every later attempt fails the all-prior-gates-skipped proof.
Receipt deletion remains at the existing terminal consumer: successful non-merging
completion or successful privileged merge. A pre-provider failure never consumes it.

## Trust boundaries

- Initial admission and recovery execute only from the protected review workflow and check
  out the verifier at `job.workflow_sha`; pull-request code and prose are never executed.
- The workflow token gains Actions/read and Checks/read only for immutable run, job, and
  check evidence. The dedicated App remains the only identity that can mutate the
  authorization check or submit a review.
- The receipt verifier remains authoritative for policy, check, App, source-run, and head
  identity. Recovery adds evidence of provider absence; it cannot substitute identities.
- GitHub's paginated all-attempt job history and paginated review history must both be
  readable and structurally exact. Absence inferred from an incomplete response is never
  accepted.
- A human can still request a genuinely new paid review with a new authorized label. This
  recovery path is deliberately unavailable after any provider-bound attempt.

## Consequences

- Failed/conflicted and newly held preflights preserve their real cause instead of a blank
  output error.
- Operators can rerun the same failed workflow attempt without applying another paid
  label, but only while durable evidence proves zero provider work.
- Receipt retention lasts through recoverable pre-provider failures and remains single-use
  after provider execution or terminal authorization.
- Recovery adds bounded Actions and review-list reads before an exceptional rerun; ordinary
  first attempts perform none of those reads.

## Alternatives rejected

- **Always allow explicit workflow reruns:** a prior provider reservation could be charged
  again.
- **Trust only the previous attempt:** an older attempt may already have crossed the paid
  boundary.
- **Trust a skipped authorization check alone:** check conclusion does not prove that the
  provider gate had no reservation or review side effect.
- **Require another `re-review` label:** preserves safety but charges again for a review
  that was never attempted and hides the causal preflight failure.
- **Delete the receipt when completion records preflight failure:** makes safe recovery
  impossible and turns a transient pre-provider defect into permanent authorization loss.
