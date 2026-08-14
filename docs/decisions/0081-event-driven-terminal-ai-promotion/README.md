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

### 2026-08-12 correction ([#759](https://github.com/Verjson/.github/issues/759))

The authorization check run is **always driven to a terminal state once created**.
This decision already treats a completed check as the authorization signal, but the
completion path was reachable only when verification succeeded: `complete-authorization`
carries `if: always()` so it can report failure, and its step then aborted at the arm
receipt verifier — 52 lines before the PATCH that completes the check. A failed
receipt therefore left the check `in_progress` forever, blocking the PR with no
signal and nothing to rerun. Observed on #758, where check run `94125910988` stayed
pending indefinitely after the gate raised `arm run provenance mismatch`.

The verifier's status is now captured rather than fatal, and the same applies to the
workflow-token head lookup. Both failures fall through to complete the check with
`conclusion=failure`, then exit non-zero. This does **not** relax authorization: an
unverified receipt can never reach `conclusion=success`, and the approval `POST` is
still never issued — that mutation is what the original ordering protected, and it
remains gated. Only the *reporting* of failure moved; the authority to approve did
not. A hang is strictly worse than a red check, because branch protection blocks the
merge while naming no cause.

### 2026-08-12 correction ([#766](https://github.com/Verjson/.github/issues/766))

Deterministic CI completion retries terminal promotion only when the newest dedicated-
App authorization check for the exact head contains the versioned marker emitted after
that App's approval was persisted. A successful authorization check alone is not AI
authority: human-path, skipped, blocking, inconclusive, and failed-App-approval outcomes
also complete the check successfully so ordinary branch protection can proceed.

The marker binds its authorization-check ID, reviewed head SHA, and receipt-derived
authority. It is written into the App-owned check summary only after the approval
response and its persisted form both match that check and head. The retry requires the
exact `ai-merge` marker and a receipt policy with `ai-merge` authority before dispatch;
`ai-approve` remains non-merging. Selecting the
newest check before evaluating its state prevents an older success from overriding a
newer failed or human-path authorization. The privileged callee still independently
verifies the receipt, policy, dedicated-App check, and exact-head App approval, so this
early terminal no-op does not weaken the final fail-closed boundary.

Post-merge reconciliation uses the same newest-check marker boundary before reading
reviews or attestations. A merge completed through the human path, or after a skipped,
blocking, inconclusive, `ai-approve`, or failed-App outcome, is a successful no-op.
Only an exact check/head `ai-merge` marker proceeds to the existing exact-head approval,
review-run, and attestation validation. A present but malformed, stale, duplicated, or
forged AI marker remains a hard failure rather than being misclassified as human.

During rollout, an exact legacy marker without the authority suffix is accepted only
after the same validated review run proves its authority through the unique
`dispatch-merge` job: completed success means `ai-merge`, while completed skipped means
the non-merging `ai-approve` path and remains a no-op. A missing, duplicate, incomplete,
cancelled, or failed dispatch job fails closed. This compatibility is necessary because
`pull_request_target: closed` executes the newly merged reconciler while the approval
marker on that same PR was emitted by the pre-merge default-branch workflow. The review
run is default-branch code, so its Actions `head_sha` identifies that trusted workflow
revision rather than the reviewed PR head; the approval, check, and attestation retain
the exact reviewed-head binding.

### 2026-08-13 correction ([#789](https://github.com/Verjson/.github/issues/789))

The deterministic-CI retry is intentionally inert in a repository that has not
adopted the AI authorization App identity. When both `AI_REVIEW_APP_ID` and
`AI_REVIEW_APP_SLUG` are absent, resolution now emits `ready=false` and succeeds
without reading check runs, artifacts, or promotion inputs. Because the promotion
job requires `ready=true`, this quiet path cannot dispatch or merge.

Absence is an adoption state only when both variables are empty. A partial identity
or a non-empty malformed ID or slug remains a configuration failure and now emits an
explicit GitHub error annotation naming the invalid boundary before exiting nonzero.
This distinction keeps unadopted repositories from reddening their default branches
while preventing an attacker or operator mistake from converting a corrupted App
identity into the no-op path. The downstream privileged workflow continues to repeat
the exact-head receipt, App, policy, and merge-readiness verification.

## Consequences

- No job sleeps or polls while CI changes state, and CI completion cannot spend model
  tokens.
- The admin merge remains a narrow terminal operation after all authorization and CI
  evidence is revalidated; the ruleset itself remains unchanged.
- PR #623's bounded polling implementation is superseded by this event-driven path and
  should close without merge. Its underlying runner-saturation concern is satisfied.
- Issue #640 supplies follow-up filing and branch cleanup through a trusted
  `pull_request_target: closed` reconciler. For exact-head `ai-merge` authorizations, it
  accepts only the unique dedicated-App approval, the named successful review run, and
  that run's validated artifact; every non-merging authority is a no-op. It can file
  idempotent issues and delete same-repository merged head refs, but has no merge or
  workflow-dispatch authority.
- ADR 0079 continues to govern paid-review deduplication and App authorization; its
  native-auto-merge and GitHub-owned-waiting sections are superseded here.

## Rollback

Disable the retry and AI workflows first. Restore the previous workflow revision only
after restoring a compatible human/admin merge path. Never re-run a failed paid review
as part of rollback, and never remove the existing required review policy before a
replacement is proven.
