# 0096 — Isolate checkouts on reusable runner workspaces

- **Date:** 2026-08-12
- **Issue:** [Verjson/.github#743](https://github.com/Verjson/.github/issues/743)
- **Category:** runner topology / workflow security

## Context

Scheduled workflows began failing after moving from fresh GitHub-hosted workspaces to the
reused self-hosted pool. Their event SHA remains the default-branch head, so checkout can
find the repository already at the requested commit and leave a damaged worktree unchanged.
The only root-level sparse checkout, in `ai-post-merge.yml`, could also narrow that shared
worktree to one script for the next job that inherited it.

The same runner lanes and immutable refs remain appropriate. The missing boundary is the
filesystem path assigned to each execution.

## Decision

Every job in a schedule-triggered workflow that checks out this repository uses a directory
whose name includes `github.run_id`, `github.run_attempt`, and `github.job`. Scheduled checkout
jobs do not use a matrix because matrix children share `github.job`; a future matrix must first
add a validated child discriminator. Job-level run defaults route commands into that directory,
and business steps cannot override that routing. On normal job completion, an `always()` cleanup
step runs from `github.workspace` and removes only the execution's exact directory.

Every sparse checkout in this repository must set `path:`. The trusted post-merge reconciler
therefore gets the same per-execution path and command routing even though it is not scheduled.
A semantic conformance test discovers scheduled workflows and all sparse checkouts, rather
than relying on a filename allowlist.

These paths are formed only from GitHub-owned numeric run and attempt identifiers plus the
repository-authored job name. Runner lane expressions, token bindings, permissions, event
SHA pins, and sparse checkout contents do not change.

## Consequences

- A static scheduled ref can no longer turn checkout into a no-op against another run's root
  worktree.
- A narrow sparse cone cannot strip files from the shared root workspace.
- Jobs continue to use their existing trusted, privileged, or fast lane and retain their
  existing secret boundary.
- The cleanup is deliberately path-exact. It does not attempt to clean legacy root state or
  another run's directory. Cancellation, timeout, or runner loss can prevent even an `always()`
  step from running, so runner-wide workspace lifecycle and residual cleanup remain tracked by
  [#629](https://github.com/Verjson/.github/issues/629).

## Rejected alternatives

- Moving the jobs back to GitHub-hosted capacity is unavailable and would bypass the
  variable-routed lane contract.
- Removing the immutable `github.sha` pin would trade provenance for incidental worktree
  repair.
- Running `git clean` in the shared root would keep concurrent jobs coupled and could delete
  another job's files.

## Verification

`scripts/workflow-checkout-isolation.test.py` rejects a sparse checkout without `path:`, a
scheduled checkout without run/attempt/job uniqueness, missing command routing, and cleanup
that could escape its exact isolated directory. It also rejects undiscriminated scheduled-job
matrices and business steps that override routing outside the isolated checkout. Existing
privileged scheduled-workflow tests continue to pin runner lanes, permissions, token bindings,
event SHA, and the expanded checkout lifecycle.

## Sensitive-hunk summary

- `.github/workflows/*.yml`: checkout location and command working directory change on
  runner-reused scheduled and privileged execution surfaces.
- No permission, secret, token, trigger, runner-lane, or immutable-ref expression changes.
