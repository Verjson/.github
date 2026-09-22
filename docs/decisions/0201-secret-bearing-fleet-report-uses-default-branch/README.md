# 0201 — Keep the full fleet report in a private workflow run

- **Date:** 2026-09-22

## Context

Issue #1506 needs a periodic report containing adopter names, workflow paths, and pinned contract SHAs. `Verjson/.github` is public, so its workflow summaries, logs, and artifacts are visible to repository readers. The inventory also reads private organization repositories. Publishing its full output from the public repository would disclose private adopter metadata.

## Decision

`Verjson/.github` provides the inventory as a reusable workflow pinned by immutable commit SHA. The scheduled caller lives in the private `verjson-agents` repository, so its run summary, logs, and artifacts retain that repository's access controls. The reusable workflow refuses callers other than `Verjson/verjson-agents`, uses the passed read-only App credentials, and checks out its own source at `job.workflow_repository` and `job.workflow_sha`. This binds inventory code to the immutable workflow revision selected by the caller, so a caller cannot choose different code to run with the App token. The private caller runs on the default-branch schedule and on matching pushes to `main`; it has no `workflow_dispatch` trigger.

## Consequences

The report remains actionable to authorized maintainers without publishing private repository names or pin state. A caller update must keep its reusable-workflow reference pinned to a reviewed immutable `.github` commit; the reusable workflow checks out that exact revision as its inventory implementation. Manual branch-selected runs remain unavailable while the caller uses the App private key.
