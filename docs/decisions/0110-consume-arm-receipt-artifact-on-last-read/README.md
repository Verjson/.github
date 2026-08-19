# 0110 — Delete the arm receipt artifact on its last required read

- **Date:** 2026-08-19
- **Status:** Accepted
- **Issues:** [#931](https://github.com/Verjson/.github/issues/931)
- **Category:** Merge-gate / authorization behavior — **sensitive class**
- **Extends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md) (head-bound authorization via the immutable arm receipt)

## Context

`gate-rearm.yml` uploads an immutable receipt artifact (`ai-review-arm-<run>-<attempt>`)
that binds an authorization check run to the exact trusted arm that created it.
`scripts/ci-gate/verify-arm-receipt.sh` re-downloads and re-verifies that artifact
at every point the trust chain needs it: `ai-review-merge.yml`'s `gate` job (pre-review),
its `complete-authorization` job (pre-decision), and, only under `AI_REVIEW_AUTHORITY
=ai-merge`, `ai-privileged-merge.yml`'s `privileged_merge` job (the terminal merge
itself).

The artifact was uploaded with `retention-days: 90` and no delete-on-consumption. GitHub
Actions artifact storage is pooled at the organization level, so with organization PR
volume this grew unbounded and reached 100% of the org's included quota, observed as
`Failed to CreateArtifact: Artifact storage quota has been hit` at the upload step of
`gate-rearm.yml` itself in `verjson-browser-agent#46` and `verjson-cloud-storage#92` —
blocking the authorization arm, and therefore every merge behind it, org-wide.

## Decision

`verify-arm-receipt.sh` deletes the receipt artifact it just verified when its caller
sets `CONSUME_RECEIPT=true`, immediately after the existing success path, using the
same token already in scope for the read. Deletion is:

- **Best-effort, never a security control.** A delete failure logs `::warning::` and the
  verification still succeeds — the artifact's own retention window is the fallback for
  an unconsumed or undeleted receipt, exactly as it already was before this decision. A
  cleanup optimization must never be able to fail an otherwise-valid authorization.
- **Opt-in per caller, gated on being the receipt's last required read.** `gate`'s earlier
  read never sets it (the receipt is still needed downstream). `complete-authorization`
  sets it only when the resolved authority is not `ai-merge` — under every other
  authority, its own read is the last one, since no further job re-verifies the receipt
  before a human completes the merge. `privileged_merge` always sets it: that job only
  ever runs under `ai-merge` authority, immediately after `complete-authorization` has
  deliberately deferred consumption to it, so it is unconditionally the terminal read on
  that path.
- **A `human`/`ai-approve` review path's held PR still gets the fallback.** If a check run
  never reaches `complete-authorization`'s success path (e.g. `receipt_ok=false`), no
  `CONSUME_RECEIPT=true` read occurs, and the artifact ages out under its unchanged
  90-day retention rather than being deleted early.

### Permission change

`complete-authorization`'s workflow token moves from `actions: read` to `actions: write`
to perform the delete. `privileged_merge` needs no permissions-block change: it already
authenticates with `secrets.ORG_ADMIN_TOKEN`, whose scope is independent of the
workflow's `permissions:` block and already exceeds what deletion requires.

### Immediate remediation

Landing this stops re-accumulation but does not, by itself, free the quota already
consumed. Clearing the existing backlog of already-consumed `ai-review-arm-*` artifacts
enough to unblock `verjson-browser-agent#46` and `verjson-cloud-storage#92` is tracked
as a one-time operational cleanup in #931, separate from this structural fix.

## Consequences

- Steady-state artifact storage for this mechanism is now bounded by in-flight
  authorizations rather than organization PR history.
- `complete-authorization` can delete an Actions artifact in the target repository; it
  could not before. This is a narrow, single-purpose grant on a job that already reads
  and writes other Checks/PR state for the same repository under the same authorization
  flow.
- A held PR (draft, `DO NOT MERGE`/`hold`, or one that never completes authorization)
  keeps its receipt for the full 90-day retention, unchanged from before this decision.

## Rejected alternatives

- **Delete from a new dedicated job.** Would need to re-derive or pass through the
  artifact ID and re-authenticate, duplicating `verify-arm-receipt.sh`'s own lookup for
  no isolation benefit — the script already computes `artifact_id` as part of
  verification.
- **Delete unconditionally at every read site.** Would delete the artifact after `gate`'s
  first (non-terminal) read, breaking `complete-authorization`'s later re-verification.
- **Shorten `retention-days` instead of consuming on read.** Trades the outage for a
  narrower one: a review that legitimately takes longer than the shortened window (a
  held PR, a slow re-review) would lose its receipt before authorization completes.
