# 0129 — Bridge explicit review-label deliveries into the authorization arm

- **Date:** 2026-08-24
- **Status:** Accepted
- **Issue:** [#1054](https://github.com/Verjson/.github/issues/1054)
- **Supersedes:** [ADR 0121](../0121-consume-persistent-ai-review-authorization/README.md)
- **Extends:** [ADR 0079](../0079-external-ai-code-review/README.md), [ADR 0091](../0091-ruleset-requires-authorization-arm/README.md), and [ADR 0120](../0120-bind-terminal-merge-to-repository-app-token/README.md)

## Context

The organization-required `gate-rearm.yml` evaluates synchronized pull-request heads,
but GitHub does not schedule that required workflow again for a label added after the
head run. On a later synchronization, only durable label state remains. ADR 0121 treated
that state and the most recent historical label actor as an opt-in. That restored
liveness only after another head event and made a historical label carry authority into
a different delivery. It could not authorize an unchanged, already-reviewed head and
made replay reasoning depend on successful label consumption.

Pull-request labels independently emit an `issues:labeled` event to a repository's
protected default-branch workflow. That event is not the organization-required run and
must never impersonate it. It can, however, supply the explicit, attributable delivery
that the existing reusable authorization arm needs before it creates its dedicated-App
check and immutable receipt.

## Decision

The generated protected `gate-rearm.yml` caller listens for `issues:labeled` in addition
to non-label `pull_request_target` head and hold transitions. `pull_request_target:labeled`
is removed so one label cannot enter through two event families.

The canonical reusable arm accepts an issues delivery only when all of these facts agree:

- the action is `labeled` and the normalized label is exactly `ai-review` or `re-review`;
- the issue number is a positive decimal and authoritative PR metadata resolves an open
  pull request at a lowercase 40-hex head;
- the workflow run is attempt one, has a positive run ID, and GitHub's run API reports
  event `issues`, the exact `.github/workflows/gate-rearm.yml` path, the target repository
  ID/name, protected default branch and workflow SHA, and the same delivery actor;
- `github.workflow_ref` names that workflow on `refs/heads/<default branch>`;
- the current label exists, its actor login is well formed, and the actor currently has
  `maintain` or `admin` permission;
- the PR head repository owner equals the target repository owner before any secret-backed
  model dispatch.

The schema-2 arm receipt binds the event, actor, protected workflow ref and workflow SHA
alongside the existing repository, PR, immutable head, run/attempt, App, nonce, check and
review-policy fields. Receipt verification accepts legacy schema-1 evidence only for a
`pull_request_target` run. An issues bridge must use schema 2, attempt one, the local
workflow identity, and the current protected default branch. Current PR head and actor
permission are revalidated when the receipt is consumed.

Persistent `ai-review` label state on synchronize is no longer authority. A workflow
rerun cannot replay an issues delivery. Unsupported event families, malformed or missing
identities, stale heads, forks, API failures, mismatched source metadata, and widened
workflow permissions fail before receipt-backed review dispatch.

## Trust boundaries

The bridge uses the repository-scoped workflow token only to read authoritative state,
manage labels/PR state, upload the receipt, and dispatch the already-reviewed workflow.
It mints the dedicated AI-review App token for exactly `github.event.repository.name`;
the App token does not become the terminal merge token. ADR 0120's separately minted,
exact-repository merge App token remains isolated to `gh pr merge --admin --squash`.
There is no PAT, `ORG_ADMIN_TOKEN`, manual-merge, fork-code checkout, or pull-request
prose execution path.

## Consequences

- An authorized label on an unchanged synchronized head can start exact-head review.
- Each explicit delivery is single-attempt and receipt-bound; historical labels and
  reruns cannot spend or authorize.
- Managed adopters must regenerate the caller from the canonical generator at one
  immutable contract SHA before relying on the bridge.
- Rollout and hold removal remain separate operations: independent adversarial review,
  green CI, and a held live canary must succeed before terminal promotion.

## Verification

The bridge contract test rejects trigger duplication, permission widening, persistent
label authority, missing actor/source binding, mutable caller refs, broad secret passing,
and repository-scope drift. Behavioral arm and receipt suites exercise unauthorized
actors, malformed IDs and metadata, stale/fork heads, reruns, missing credentials/API
evidence, wrong workflow/repository/run identity, receipt substitution, and exact-head
revalidation.
