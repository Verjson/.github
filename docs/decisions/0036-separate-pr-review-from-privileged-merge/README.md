# 0036 — Separate PR review from privileged merge authority

- **Date:** 2026-07-30
- **Issue:** [Verjson/.github#230](https://github.com/Verjson/.github/issues/230)
- **Supersedes:** ADR 0020's sibling-dispatch behavior and the single-context merge design in ADR 0022
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

Workflow-file detection reads the complete paginated pull-files API, rather than the
100-file-limited PR GraphQL field, and repeats immediately before merge. A workflow
change hidden behind more than 100 padding files or introduced between admission and
merge therefore fails closed.

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

## Repository-local dispatch

`workflow_dispatch` and `workflow_call` no longer accept a `repository` input.
`TARGET_REPO` is always `github.repository`. Operators re-gate a PR by dispatching the
workflow in the repository that owns that PR.

This supersedes ADR 0020's same-organization sibling-dispatch allowance. Once
`ORG_ADMIN_TOKEN` was removed from PR validation, `github.token` correctly became
repository-scoped and could not read or update a sibling repository. Restoring a broad
secret would collapse the trust boundary, so the convenience feature is retired.

A successful repository-local gate dispatch starts the privileged workflow with the
PR number, exact reviewed head, and source run ID. The privileged workflow accepts the
recovery path only when that source is a successful dispatch of the trusted central
workflow and the PR carries the matching run/head attestation. It then repeats every
normal head, check, hold, workflow-file, and provenance guard.

The gate uploads a one-day, run-bound attestation containing repository, PR, exact
head, source run, and bounded follow-up JSON. The privileged workflow fetches it by the
verified run's unique artifact name, reads only `attestation.json`, validates the
complete shape and identity, and never sources or executes it. It files issues only
after the matched-head merge command succeeds. A privileged failure cannot file
follow-ups.

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

## Bounded recovery when Actions review approval is disabled

**Amended 2026-07-30 for #241 and #242:** Actions review approval remains disabled
by default at both organization and repository scope. GitHub will not accept a
repository override while the organization capability is disabled. If that policy
prevents the credential-free gate from publishing an otherwise non-blocking verdict,
an organization owner may recover one exact immutable head only after applying `hold`,
capturing the complete paginated repository ID set, and explicitly pinning every
existing organization repository to disabled. The owner may then enable the
organization capability, enable only this repository, and exhaustively verify every
snapshotted repository except this one remains disabled; any pagination or API failure
aborts recovery. Only after that verification may the owner rerun the failed gate for
the held PR's exact immutable head.

Before merge, disable this repository and the organization capability and verify both
disabled states. Compare the complete post-window repository ID set with the snapshot.
Any new repository aborts recovery and merge, triggers immediate policy disablement,
and requires incident review because detection occurs after it may have inherited the
temporary organization policy.

The temporary permission does not grant `ORG_ADMIN_TOKEN` or move it into
pull-request-controlled execution. The permanent fix is to treat GitHub's policy-denial
response like the existing self-approval denial: publish a non-approval audit comment
while keeping unexpected publication errors fail-closed.

**Implemented for #242:** the credential-free gate now recognizes GitHub's
Actions-approval-disabled response alongside the existing self-approval denial.
Both produce the same head- and patch-id-bound approved-verdict audit comment.
Any other review-publication failure remains terminal. Repository and
organization Actions approval permissions therefore stay disabled without
blocking a reviewed PR or moving privileged credentials into the review job.

The allowlist matches complete observed stderr forms, including the `gh` CLI's
`failed to create review:` prefix. Substring matches are forbidden because a
known denial followed by an unrelated transport error must remain terminal.
