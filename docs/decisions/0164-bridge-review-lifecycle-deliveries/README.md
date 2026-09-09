# 0164 — Bridge review lifecycle deliveries independently of required workflows

- **Date:** 2026-09-05
- **Status:** Accepted
- **Issue:** [#1257](https://github.com/Verjson/.github/issues/1257)
- **Extends:** [ADR 0130](../0130-separate-explicit-label-caller/README.md)

## Context

Required workflows dispatch on opened, synchronize and reopened. Declaring additional
pull-request activities does not deliver them to consumers. The live report in #1257
records no arm runs after ready-for-review, hold removal and title edits on
Verjson/verjson-temporal-kit#177 and #178. Its default-branch workflow inventory has
neither lifecycle caller. A declaration on the required workflow cannot repair this.

## Decision

Extend the existing separate `ai-review-label-rearm.yml` caller to deliver
`ready_for_review`, `converted_to_draft`, `edited` and `unlabeled` as well as `labeled`.
Keep its path stable because receipt verification already authenticates that identity.
The canonical required entrypoint declares only its three supported activities.
Legacy repository-local `gate-rearm.yml` callers remain supported.

Every delivery through the separate caller uses the existing schema-2 source binding:
protected default-branch caller, first run attempt, repository identity, actor, workflow
revision and exact event/current PR head. Label-specific authorization applies only to
label additions. Lifecycle events retain live draft/hold checks, existing review-policy
authorization and receipt-preserving promotion; clearing a hold grants no new review
permission. No PR code is checked out or executed in the credential-bearing arm.
Interrupted lifecycle arms use the existing failure-only orphan recovery, authenticated
against their local workflow registration. Published receipts must be schema 2 with
the matching delivery actor and protected caller revision; legacy arm receipts remain
schema 1. Recovery never turns a failed review into approval.

Generate the consumer caller with `scripts/gen-ai-review-label-rearm-caller.sh` at one
reviewed immutable contract SHA. The organization-owned same-repository wrapper uses
the protected revision's local reusable workflow. Do not duplicate policy or introduce
a new dispatcher. Consumer installation remains a separate owner-managed rollout;
merging this change does not install a caller in another repository.

## Verification and rollout

Behavioral tests exercise all four transitions, stale heads, replayed runs and actor
mismatch. Generator tests pin the event set and thin, explicitly permissioned shape.
The held-path message explains the caller requirement and reviewed-head push fallback.
Adopters must install the generated caller on their protected default branch, then
retain a real ready-for-review/hold-removal run receipt before claiming live recovery.

## Correction (2026-09-09) — reject body-only edits before admission (#1275)

The lifecycle caller delivers every PR `edited` event. Previously, the reusable arm
allocated its trusted runner and minted the dedicated App token before learning that
a body/base-only edit could not re-arm review. Restore the intended event boundary
with a job-level condition in the canonical callee: an edited event is eligible only
when `changes.title.from` is nonempty. Missing, null, and empty previous titles skip
the job before runner assignment or credential use. All other subscribed activities
retain their existing admission checks.

Keep title edits eligible in both directions. Adding `DO NOT MERGE` must still reach
the live hold check that disables native auto-merge; removing it must still reach the
existing source-bound re-arm path. The condition is scheduling policy, not review
authorization, so exact-head, actor, replay, hold, and App checks remain unchanged.
Keeping it in the callee applies the same policy to required, local, and generated
callers without duplicating expressions or changing byte-exact caller contracts.

The registered lifecycle bridge test evaluates the configured condition over body,
base, missing/null/empty-title, title-add/remove, and other lifecycle events. Existing
workflow concurrency remains PR-scoped with `cancel-in-progress: false`; it is not
duplicated in the caller. GitHub documents job conditions as running before runner
assignment and supports concurrency in called workflows. A live concurrency receipt
remains separate rollout evidence, not something the local condition test proves.

References: [#1275](https://github.com/Verjson/.github/issues/1275),
[job conditions and runner assignment](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts),
[reusable workflow concurrency](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations).
