# 0036 — Separate PR review from privileged merge authority

- **Date:** 2026-07-30
- **Issue:** [Verjson/.github#230](https://github.com/Verjson/.github/issues/230)
- **Supersedes:** the single-context merge design in ADR 0022
- **Refines:** ADR 0012, ADR 0020, ADR 0024, and ADR 0035

## Context

The required gate performed read-only classification, PR-head checkout, CI waiting,
model review, review publication, and the final administrative merge in jobs that all
received `ORG_ADMIN_TOKEN`. GitHub correctly withholds Actions secrets from Dependabot
and fork pull-request events, so those runs failed before their CI could be evaluated.
Giving bots or pull-request-controlled execution the token would instead turn a
delivery failure into an administrative credential-exposure path.

Renovate's same-repository branches are not a trust boundary. Dependabot, Renovate,
forks, and ordinary contributors must all follow the same credential-free validation
path.

## Decision

The required workflow has two event contexts:

1. `pull_request` performs credential-free classification, checkout, CI-first waiting,
   and review for the required-check path.
2. A separate `pull_request_target` workflow loads from the trusted base branch and
   performs only the administrative merge. It uses no action, checkout, artifact,
   cache, PR environment file, or PR output.

The privileged job resolves the trusted central workflow ID and current default-branch
SHA, then verifies that the successful `gate` check links to a completed `pull_request`
run of that exact workflow or a reusable call referencing that exact revision,
repository, and immutable head. A check name alone is never authorization. Changes to
any workflow file in any target require a human merge because workflow identity alone
cannot authenticate a PR-modified caller definition. The privileged job binds
its action to the event repository owner, exact repository,
numeric PR number, and the event's immutable 40-hex head SHA. It repeatedly reads
GitHub API metadata, requires the `gate` check and every other reported check to be
terminal-green, and rejects failed checks, drafts, holds, closed PRs, missing
credentials, malformed identity, and stale heads. Immediately before the irreversible
operation it re-reads head, state, draft, hold, and complete check state. The merge API
receives `--match-head-commit`.

No validation result is carried through an artifact, cache, environment file, or job
output. Verified workflow-run provenance plus GitHub's current check state for the
immutable commit is the handoff.

## Cross-organization consumers

The reusable `workflow_call` remains a validation and review check. A consumer cannot
safely obtain merge authority from an untrusted caller event, so cross-organization
automatic merge requires the consumer to install an equivalent base-branch-controlled
trusted merge workflow with its own credential. Until then, green validation terminates
without auto-merge. Passing `secrets: inherit` must never be used to make an untrusted
caller a privileged merge context.

## Consequences

- Dependabot and Renovate no longer fail merely because the administrative token is
  unavailable to their PR event.
- Administrative merge authority is absent from PR checkout, tools, actions, caches,
  artifacts, environment files, and outputs.
- The trusted half may wait while the unprivileged required check completes, consuming
  isolated runner capacity.
- Fork AI reviews still depend on model credentials being made available through a
  separately governed mechanism; absence fails the review closed and the trusted job
  cannot merge.
- The old in-job merge block remains disabled temporarily to preserve extract-based
  regression coverage while consumers move to the split context. It has only the
  event-scoped token and cannot perform an administrative merge.

## Rollback

Revert the implementing PR. Do not restore `ORG_ADMIN_TOKEN` to a job that checks out,
executes, or otherwise consumes pull-request-controlled data. If split execution must
be suspended, disable auto-merge and retain the unprivileged required check.
