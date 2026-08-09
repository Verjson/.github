# 0081 — Event-driven AI authorization ends in terminal privileged promotion

- **Date:** 2026-08-08
- **Status:** Accepted
- **Supersedes:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md) for merge promotion and CI readiness

## Context

[Issue #653](https://github.com/Verjson/.github/issues/653) records the controlled
rollout evidence. The dedicated App produced a successful exact-head check and
approval, but GitHub still reported `REVIEW_REQUIRED`: the organization ruleset
requires both code-owner review and approval after the last push, and an App cannot
be a code owner. Native auto-merge therefore cannot complete without weakening the
organization review policy or granting a broad bypass.

Runner-held polling is still unacceptable. It couples a paid review to unrelated CI
transitions, consumes scarce runners, and previously caused the failure mode tracked
by [#612](https://github.com/Verjson/.github/issues/612) and PR
[#623](https://github.com/Verjson/.github/pull/623). Repeated CI events must never
dispatch another model review.

## Decision

Keep ADR 0079's immutable arm receipt, dedicated-App check and exact-head approval.
Replace only its native-auto-merge conclusion with bounded terminal promotion:

1. Successful AI completion dispatches an immediate privileged promotion attempt.
2. Completion of each explicitly named deterministic CI workflow starts a separate,
   cheap retry workflow. That workflow can call only the privileged promotion
   workflow; it contains no model action or model-workflow dispatch.
3. Every promotion repeats receipt verification and checks the open PR, exact head,
   same-owner policy, holds and draft state, dedicated-App check, exact-head App
   review, and the repository's explicit required-check trust declarations. For each
   declared context, only the newest check-run ID is authoritative. It must be a
   completed success from the declared GitHub App and a run whose Actions workflow
   ID, path, repository, event, head, and details URL match. The workflow file blob
   at the PR head must equal the trusted default-branch blob. Legacy commit statuses,
   name-only checks, promotion workflows, and older duplicate contexts cannot satisfy
   readiness.
4. A pending or absent required check exits successfully and immediately. A later CI
   completion supplies the next attempt. A terminal unsuccessful check fails closed.
5. When every named requirement succeeds, the existing admin credential performs one
   squash merge guarded by the exact head SHA, then verifies the PR is merged at that
   head. PR/head concurrency and post-merge no-ops make duplicate deliveries safe.

No ruleset is weakened or mutated, and the promotion identity receives no new bypass.
The repository-local required CI declaration binds `shell-tests` to GitHub Actions and
the immutable `actions-ci` workflow identity. Adopters must declare their own App,
workflow ID/path, check name, and explicitly named deterministic completion workflows.

### 2026-08-08 correction ([#664](https://github.com/Verjson/.github/issues/664))

The exact opaque policy envelope is part of terminal promotion identity, alongside
the PR, head, dedicated-App check, arm run, and arm attempt. The successful review
passes it directly to the first promotion. CI-completion and hold-removal retries
read it from the named immutable arm artifact and pass it unchanged; the terminal
callee strictly decodes it and compares it with the receipt before checking merge
readiness. Missing, substituted, malformed, non-canonical, or drifted policy fails
before promotion.

For no-cost recovery after a promotion transport failure, an administrator downloads
the still-live named arm artifact, takes its opaque `review_policy` string, and
manually dispatches `ai-privileged-merge.yml` with that string and the receipt's exact
PR/head/check/run/attempt identities. The callee revalidates the artifact digest and
every identity. This recovery workflow contains no model action and must never invoke
`ai-review-merge.yml`.

## Consequences

- No job sleeps or polls while CI changes state, and CI completion cannot spend model
  tokens.
- The admin merge remains a narrow terminal operation after all authorization and CI
  evidence is revalidated; the ruleset itself remains unchanged.
- PR #623's bounded polling implementation is superseded by this event-driven path and
  should close without merge. Its underlying runner-saturation concern is satisfied.
- Issue #640 remains necessary for follow-up filing and branch cleanup. That post-merge
  behavior stays separate from authorization and merge authority, but its trigger must
  observe terminal privileged merges rather than native auto-merge.
- ADR 0079 continues to govern paid-review deduplication and App authorization; its
  native-auto-merge and GitHub-owned-waiting sections are superseded here.

## Rollback

Disable the retry and AI workflows first. Restore the previous workflow revision only
after restoring a compatible human/admin merge path. Never re-run a failed paid review
as part of rollback, and never remove the existing required review policy before a
replacement is proven.
