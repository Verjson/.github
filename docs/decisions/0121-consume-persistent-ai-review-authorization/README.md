# 0121 — Consume persistent AI-review authorization on synchronized heads

- **Date:** 2026-08-24
- **Status:** Accepted
- **Issue:** [#991](https://github.com/Verjson/.github/issues/991)
- **Extends:** [ADR 0090](../0090-human-first-opt-in-ai-review/README.md), [ADR 0105](../0105-budgeted-deepseek-review-cascade/README.md), and [ADR 0120](../0120-bind-terminal-merge-to-repository-app-token/README.md)

## Context

The organization-required authorization arm may not receive a label-only
`pull_request_target` delivery. When a maintainer adds `ai-review` after the ordinary
human-path arm has completed, a later synchronized head still sees the label and
revalidates the actor, but the workflow classifies only the literal `labeled` event as
an explicit opt-in. It therefore dispatches deterministic policy without model review,
completes the authorization check as neutral, and correctly prevents terminal merge.

Treating every persistent label as reusable authority without consuming it would fix
the liveness defect by creating a worse security defect: every subsequent push could
spend again under one historical label event. Removing the label without verifying its
authoritative absence would permit a racing or failed edit to dispatch paid review
while leaving replay authority attached to the pull request.

## Decision

When the current exact head carries `ai-review`, the arm resolves the most recent label
event, requires its actor to retain maintain or admin permission, and classifies the
authorization as explicit even when the current event is `synchronize`. The arm binds
that fact into its step outputs and immutable receipt path.

Before dispatching any provider-backed review, the trusted default-branch workflow
removes the exact normalized authorization label and authoritatively rereads the pull
request labels. Dispatch proceeds only when the reread is well-formed and proves the
label absent. Failed removal, unreadable state, a retained label, an invalid actor, or
insufficient current permission completes the dedicated authorization check as failure
before provider spend.

`re-review` keeps precedence when both authorization labels are present and retains its
existing explicit one-pass policy. Ordinary events with no current authorization label
remain deduplicated. Once `ai-review` is consumed, a later synchronization cannot reuse
the historical event; a new paid opt-in requires a new authorized label event.

## Security analysis

Authorization remains bound to current repository state, exact head, current actor
permission, the dedicated authorization App check, and the immutable arm receipt. The
label event supplies attribution but never bypasses the authoritative current-label
check. Consumption occurs after receipt publication but before workflow dispatch, so a
failure cannot spend and cannot grant a successful authorization.

The synchronization path does not trust the pusher as the review authorizer. It resolves
the recorded label actor and checks that actor's current maintain/admin permission.
Unauthorized retained labels are removed when possible and otherwise fail closed. A
single consumed label cannot authorize multiple heads or workflow reruns.

## Consequences

- A maintainer may add `ai-review` and push or update the branch to recover from a
  missing label-only required-workflow delivery.
- Every provider-backed opt-in consumes its label before spend, including direct
  `labeled` deliveries.
- The controlled terminal-App canary can obtain a successful exact-head authorization
  without PAT or manual-merge fallback.
- Rollout remains held until the canary records the authorization, token-mint, terminal
  job, and App merge receipts.
