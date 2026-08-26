# 0139 — Recover orphaned authorization checks across runs

- **Date:** 2026-08-26
- **Status:** Accepted
- **Issue:** [#1094](https://github.com/Verjson/.github/issues/1094)
- **Extends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md)
- **Extends:** [ADR 0081](../0081-event-driven-terminal-ai-promotion/README.md)
- **Extends:** [ADR 0138](../0138-keep-canonical-app-identities-organization-neutral/README.md)

## Context

The trusted arm creates an exact-head `AI review authorization` check before it
publishes the immutable receipt and dispatches the review workflow. Same-job cleanup
normally completes a check when either later operation fails. It cannot cover process
loss, a runner disappearing, or GitHub accepting the check mutation while every response
and cleanup request is lost.

A later arm run previously treated every exact-head check as a duplicate. That is safe
against duplicate model spend, but an orphaned `in_progress` check can then remain pending
forever. Conversely, blindly completing an old pending check could terminate a legitimate
queued or running review and let another paid review start for the same head.

The Checks API does not supply an atomic compare-and-swap operation, and a successful
`workflow_dispatch` response does not return the created workflow run ID. Cross-run
recovery therefore needs a durable correlation identity and independent live-state
revalidation rather than treating the source arm's conclusion or elapsed time alone as
proof of abandonment.

## Decision

The dispatched review workflow has a deterministic run title containing the exact
authorization check ID, arm run ID, and arm attempt. The authorization check's existing
external ID remains the primary binding over repository, PR, exact head, source arm run,
source attempt, and a cryptographic nonce. Its details URL must point to that same source
run.

A later ordinary arm event may complete a pending authorization as `failure` only when
all of these conditions hold:

1. The check is attributed to the configured authorization App and its external ID and
   details URL exactly bind the current repository, PR, head, source run, and attempt.
2. The source is a terminal `pull_request_target` run of the canonical arm workflow in
   the same numeric repository, and it is not the recovery run itself.
3. At least five minutes have elapsed since source completion, bounding GitHub's
   workflow-run listing consistency window.
4. Immutable arm artifacts are either absent or exactly one. If present, its receipt
   must reproduce every repository, head, check, source-run, App, and external-ID field.
   More than one receipt is ambiguous and fails closed. Absence proves that a downstream
   review could not pass its mandatory receipt verification; it does not weaken that
   verification.
5. Across every page of live workflow runs, there is no queued, waiting, pending,
   requested, or in-progress canonical review with the exact deterministic correlation
   title, workflow path, default branch, event, and repository identity. Duplicate
   correlated runs are ambiguous and fail closed. A terminal review no longer owns a
   still-pending check and may be recovered as failure.
6. Immediately before mutation, the App re-reads the check and revalidates its exact
   identity and `in_progress` state. The PATCH response must prove the same App,
   external ID, terminal failure, and recovery marker.

Recovery can only write `failure`; it can never grant review or merge authorization.
After a proven recovery, the same synchronized arm run may create a new receipt-bound
authorization. If that run dies between closing the orphan and creating its replacement,
a later run recognizes the exact App-authored recovery marker and resumes. All missing,
malformed, stale, contradictory, or ambiguous state either leaves the existing check
untouched or fails the arm visibly.

## Trust boundaries

- The dedicated App token remains scoped to the current repository and retains only its
  existing Checks/write, Contents/read, Pull requests/write, and Metadata/read grant.
- `github.token` reads source and downstream Actions state; it cannot complete the App's
  check. The App token performs only the final exact-check read and failure mutation.
- Pull-request titles, bodies, labels, changed files, and checked-out code are not inputs
  to orphan classification. The arm continues to execute no PR-controlled code.
- A receipt is evidence of arm activation, not evidence of dispatch. Active downstream
  ownership is independently established from canonical workflow-run identity.
- The five-minute floor is only an eventual-consistency safeguard. Time alone never
  authorizes recovery.
- Repository identity, numeric repository ID, PR number, exact head, App ID/slug, source
  run/attempt, external ID, details URL, receipt, and downstream run identity must agree.
- Races fail closed. Repository-level arm concurrency serializes ordinary recovery; an
  unexpected terminal transition detected on the final re-read is never overwritten.

## Consequences

- A lost activation response or exhausted same-job cleanup can be repaired by a later
  synchronized run without a PAT, manual check mutation, or CI-policy exception.
- A legitimate queued or running review remains authoritative and cannot be terminated
  by recovery.
- Review run titles become a security-relevant correlation surface and are covered by
  adversarial contract tests.
- Recovery performs bounded paginated Actions reads and may fail rather than guess during
  an API outage or malformed response.
- Historical orphaned checks whose source identity predates this correlation contract may
  be closed only when no active canonical review matches and every other binding is
  independently verifiable.

## Alternatives rejected

- **Complete every old pending check:** elapsed time does not prove a dispatched review is
  absent and could cause duplicate spend.
- **Trust only the source arm conclusion:** the arm intentionally tolerates failures and
  a dispatch may have been accepted before its response was lost.
- **Trust receipt presence as dispatch proof:** publication precedes dispatch by design.
- **Use a PAT or administrator to rewrite checks:** that widens authority and loses the
  repository-, App-, and receipt-bound audit trail.
- **Leave all orphans for manual recovery:** permanent pending checks are an availability
  defect with a deterministic fail-closed repair path.
