# 0051 — AI review does not infer base state from the PR checkout

- **Date:** 2026-08-03
- **Issue:** [Verjson/.github#377](https://github.com/Verjson/.github/issues/377)
- **Status:** accepted

## Context

The AI review workspace is checked out at the pull-request head. On PR #376 the
model compared the proposed post-images to `HEAD`, found the expected
byte-for-byte match, and blocked the change as already merged. Remote `main`
still pointed at the PR's base commit; only the PR branch contained those blobs
and commits.

The model has read-only file tools, not an authoritative GitHub lifecycle view.
Treating its checkout as base-branch evidence turns every proposed file into
proof that the proposal is already live.

## Decision

The review prompt states that the workspace and `HEAD` are the PR head, never
evidence of base-branch content. The model must not block because it infers that
the PR submission is stale, duplicate, closed, or already merged.

Deterministic API code owns PR lifecycle state, head freshness, and the
matched-head merge. The restriction is about submission state only: duplicate
processing, replay, and idempotency defects in the proposed behavior remain
normal correctness findings.

## Consequences

- Byte-identical post-images in the PR checkout cannot become a false
  already-merged verdict.
- Lifecycle and merge decisions remain bound to GitHub API state and the
  expected head SHA.
- The model still blocks real duplicate-processing and idempotency defects.
- An extraction-based contract test pins the active prompt text rather than
  matching an inactive comment elsewhere in the workflow.
