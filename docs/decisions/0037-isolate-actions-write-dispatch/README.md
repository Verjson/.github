# 0037 — Isolate Actions write permission in a metadata-only dispatcher

- **Date:** 2026-07-30
- **Issue:** [Verjson/.github#235](https://github.com/Verjson/.github/issues/235)
- **Supersedes:** ADR 0036's placement of trusted-continuation dispatch

## Context

ADR 0036 removed `ORG_ADMIN_TOKEN` from PR validation and introduced an exact-run
attestation. The gate job still needed `actions: write` to start the privileged
continuation. That job checks out the PR head and runs model-review tooling, so the
permission also enlarged the impact of any future injection defect: it can cancel or
rerun workflows and manage repository Actions artifacts.

## Decision

The PR-processing `gate` job returns to `actions: read`. A dedicated `dispatch-merge`
job alone receives `actions: write`, with `contents: read` and no other permission.

The dispatcher:

- depends on successful `preflight` and `gate` jobs;
- runs on the isolated/default privileged lane for Verjson and retains the governed
  hosted fallback for external consumers;
- never checks out code, invokes a model, reads caches/artifacts, or evaluates/sources
  PR-controlled data;
- accepts only the repository identity, numeric PR number, immutable 40-hex head, and
  numeric source run emitted by trusted workflow contexts;
- resolves the fixed `.github/workflows/ai-privileged-merge.yml` identity before
  dispatch and passes only those validated scalar values.

The gate still creates the bounded exact-run attestation. The privileged workflow
continues to validate it and all current PR/check/head/hold state before merging, so
both pull-request and manual recovery behavior remain fail-closed. The gate excludes
the `dispatch-merge` and `privileged_merge` continuation checks from its repository-CI
snapshots: neither trusted continuation may circularly authorize or block the review
that must complete before dispatch.

Workflow-file changes remain ineligible for privileged auto-merge. Both the initial
file guard and final recheck terminate successfully with a human-review-and-merge
notice, without merging or filing follow-ups. This reports the intentional policy hold
as a terminal no-op instead of a CI failure while preserving the human merge boundary.

## Consequences

- PR checkout/review code cannot cancel/rerun workflows or manage Actions artifacts
  through its `GITHUB_TOKEN`.
- One short metadata-only job and runner assignment are added after a green gate.
- Dispatch failure leaves the PR unmerged and is safely retryable.
- Workflow-file PRs can finish validation green but always require a human merge.

## Rollback

Revert the implementing PR. Do not return `actions: write` to a job that checks out or
reviews PR-controlled content; if dispatch must be disabled, retain the unprivileged
gate and require manual merge.

## Private-consumer check visibility

**Amended 2026-07-30 for #240:** the unprivileged, `ORG_ADMIN_TOKEN`-free gate also receives
`checks: read`. GitHub's `statusCheckRollup` GraphQL field rejects the
consumer-scoped token without that explicit permission on private repositories,
so the gate cannot determine whether CI is green. The permission is read-only
and stays in that review job; `checks: write` remains absent and
`actions: write` remains isolated to the metadata-only dispatcher. No
`ORG_ADMIN_TOKEN` is introduced into PR-controlled execution.

**Amended 2026-07-30 for #248:** the gate reads check runs and commit statuses
through repository-scoped REST endpoints at the immutable PR head. It no longer
requests GraphQL's nested `statusCheckRollup`, which can be denied to an
otherwise correctly scoped GitHub App token. The gate retains `checks: read` and
adds only `statuses: read`; both are read-only, and the existing check-name
exclusions and fail-closed classifications remain unchanged.

The REST pagination contract is implemented with the broadly available
`gh api --paginate` stream and `jq -s`, rather than requiring the newer
`gh api --slurp` flag. Endpoint transport/JSON failures and unusable page shapes
remain fail-closed; diagnostics expose only bounded return codes and the CLI
version, never response bodies or credentials. Gate job 91043852657 demonstrated
that the self-hosted runner rejected the newer CLI flag before either endpoint
could be classified.

## Consumers without a privileged continuation

**Amended 2026-07-30 for #247:** the dispatcher enumerates the repository's workflows
with its event-scoped token before resolving the fixed trusted path. If that path is
absent, the job succeeds with a notice that validation is green but a human must merge.
This implements ADR 0036's no-auto-merge consumer fallback without making the required
review check red.

Workflow enumeration or transport failures remain terminal. A non-empty result other
than the one fixed trusted path also fails closed. The fallback grants no merge
authority and does not introduce a credential into pull-request-controlled execution.

## Dispatcher runtime contract

**Amended 2026-07-30 for #257:** the metadata-only dispatcher keeps the
isolated/default self-hosted routing required by ADR 0033 and bootstraps GitHub
CLI only when the selected runner does not provide it. The fallback downloads a
pinned release for the runner architecture, verifies an immutable SHA-256
digest, and installs it under `RUNNER_TEMP`; preinstalled `gh` remains the fast
path.

The exact repository, PR, head, source-run, and trusted-workflow validation;
read-only contents permission; isolated `actions: write`; and separation from
the administrative token remain unchanged.
