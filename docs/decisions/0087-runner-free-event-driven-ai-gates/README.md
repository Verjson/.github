# 0087 — AI gates never hold runners waiting for external CI

- **Date:** 2026-08-09
- **Status:** Accepted
- **Issue:** [#341](https://github.com/Verjson/.github/issues/341)
- **Supersedes:** [ADR 0039](../0039-required-workflow-gate-provenance/README.md) only where its terminal gate polled, [ADR 0044](../0044-gate-provenance-bound-to-entry-workflow/README.md) only where provenance assumed a polling entry workflow, and [ADR 0058](../0058-github-waits-for-checks-not-the-gate/README.md) for its native-auto-merge migration mechanism
- **Affirms:** [ADR 0056](../0056-fleet-watchdog-retained-and-retargeted/README.md), [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md), and [ADR 0081](../0081-event-driven-terminal-ai-promotion/README.md)

## Context

The former review and privileged merge gates polled commit checks while occupying
shared runners. Lane selection reduced contention but could not prevent a future
configuration change from recreating starvation or deadlock. ADRs 0079 and 0081
introduced exact-head authorization and event-driven terminal promotion, but issue
#341 still lacked one explicit structural invariant tying that implementation to the
earlier polling, provenance, and runner-lane decisions.

## Decision

Neither `ai-review-merge.yml`'s `gate` job nor
`ai-privileged-merge.yml`'s `privileged_merge` job may poll, sleep, retry, or
otherwise retain a runner merely because external CI is pending. Review completion
performs one immediate promotion dispatch. A promotion invocation reads one current
snapshot of each explicitly declared trusted check and exits immediately when any is
absent or pending. Completion of a declared deterministic workflow re-enters through
`ai-promotion-retry.yml`; it cannot invoke the paid review workflow.

Every invocation independently revalidates the immutable arm receipt, dedicated App
identity, exact PR head, approval, hold and draft state, required-check App/workflow
provenance, and trusted workflow revision. Only the terminal invocation with all
successful evidence may issue the one exact-head squash merge. Duplicate events are
idempotent after merge.

Generated consumer callers remain thin immutable delegates. Their contract does not
gain a polling option or a new dependency. The retained fleet watchdog remains an
independent safety brake for legacy or misconfigured workloads, but its production
merge-gate allowlists stay inert while this structural contract holds.

## Consequences

- Runner selection cannot reintroduce merge-gate polling; changing a lane affects
  where bounded work executes, not whether a runner waits.
- Check and status provenance remains fail-closed across event boundaries without
  weakening organization rulesets, draft behavior, or explicit holds.
- Static contract tests reject polling and sleep mutations in both gate jobs and
  require privileged readiness to remain a single snapshot.
- The watchdog is retained under ADR 0056; removing it remains a separate decision.

## Rollback

Disable automatic review and promotion before restoring any polling implementation.
A rollback that occupies runners waiting for external CI requires a new superseding
ADR and an explicit capacity and deadlock analysis; changing runner variables alone
is not a rollback mechanism.
