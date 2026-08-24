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

The post-merge canary disproved the premise that pull-request labels emit a usable
`issues:labeled` workflow event: applying `ai-review` produced no run. GitHub does emit
`pull_request_target:labeled`, but the workflow file registered as an organization-required
workflow is not independently scheduled for that later label. Therefore the label trigger
must live in a different protected caller while policy remains in the reusable arm.

## Decision

The ruleset-owned generated `gate-rearm.yml` caller retains only non-label head and hold
transitions. A separate generated `ai-review-label-rearm.yml` caller listens only for
`pull_request_target:labeled` and invokes the same immutable canonical `gate-rearm.yml`
reusable workflow. It contains no policy, shell, checkout, or broad secret inheritance.

The canonical reusable arm accepts a label delivery only when all of these facts agree:

- the action is `labeled` and the normalized label is exactly `ai-review` or `re-review`;
- the issue number is a positive decimal and authoritative PR metadata resolves an open
  pull request at a lowercase 40-hex head;
- the workflow run is attempt one, has a positive run ID, and GitHub's run API reports
  event `pull_request_target`, the exact separate `.github/workflows/ai-review-label-rearm.yml`
  path, the target repository ID/name, exact PR head, and the same delivery actor;
- `github.workflow_ref` names that workflow on `refs/heads/<default branch>`;
- the current label exists, its actor login is well formed, and the actor currently has
  `maintain` or `admin` permission;
- the PR head repository owner equals the target repository owner before any secret-backed
  model dispatch.

For the separate label caller, the schema-2 arm receipt binds the event, actor, protected
workflow ref and workflow SHA alongside the existing repository, PR, immutable head,
run/attempt, App, nonce, check and review-policy fields. Organization-required
`pull_request_target` runs retain schema 1: their Actions `head_sha` is the PR head while
`github.workflow_sha` is the separately protected required-workflow revision, so treating
those values as one identity would reject legitimate fleet receipts. Receipt verification
accepts schema-1 evidence only for the ruleset-owned `gate-rearm.yml` path. The label
caller must use schema 2, attempt one, its distinct local workflow identity, and the protected default
branch. Current PR head and actor permission are revalidated when the receipt is consumed.

Persistent `ai-review` label state on synchronize is no longer authority. A workflow
rerun cannot replay a label delivery. Unsupported event families, malformed or missing
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
