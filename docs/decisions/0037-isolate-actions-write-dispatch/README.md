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
both pull-request and manual recovery behavior remain unchanged.

## Consequences

- PR checkout/review code cannot cancel/rerun workflows or manage Actions artifacts
  through its `GITHUB_TOKEN`.
- One short metadata-only job and runner assignment are added after a green gate.
- Dispatch failure leaves the PR unmerged and is safely retryable.

## Rollback

Revert the implementing PR. Do not return `actions: write` to a job that checks out or
reviews PR-controlled content; if dispatch must be disabled, retain the unprivileged
gate and require manual merge.
