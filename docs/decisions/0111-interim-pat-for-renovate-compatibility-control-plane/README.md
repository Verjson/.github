# 0111 — Interim human PAT for the Renovate compatibility control plane

- **Date:** 2026-08-20
- **Status:** Accepted
- **Issue:** [#699](https://github.com/Verjson/.github/issues/699)
- **Supersedes:** the "2026-08-18 authentication-boundary clarification" section of
  [ADR 0109](../0109-observe-first-renovate-compatibility-control-plane/README.md), for this
  repository's two workflows only. The rest of ADR 0109 (observe-only boundary, candidate
  trust separation, generated-caller contract) is unchanged.

## Context

ADR 0109 committed the reconciler and grouping-planner workflows to authenticate via a
dedicated, least-privilege `RENOVATE_COMPATIBILITY_*` GitHub App, minted per-call with
only the read scopes each job needs. That App was never provisioned: `RENOVATE_COMPATIBILITY_CLIENT_ID`
and `RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` do not exist at either organization or
repository scope, so both workflows have been non-functional since #699 was filed —
verified directly against the `create-github-app-token` step's required inputs.

The organization owner has a personal PAT with read access across every org they
belong to and wants to unblock this control plane now rather than wait for the App
provisioning flow (Settings → Developer settings → GitHub Apps → New App, install, wire
the client ID and private key). Provisioning the dedicated App remains the intended end
state; this ADR records a deliberate, time-boxed substitution, not a quiet abandonment
of ADR 0109's authentication design.

## Decision

Until the dedicated compatibility App is provisioned, both workflows authenticate with
a single new secret, `RENOVATE_COMPATIBILITY_PAT`, used directly as `GH_TOKEN` /
checkout `token` — no App-token minting step. This is strictly worse than ADR 0109's
target state on two axes the org should weigh consciously:

- **Blast radius.** The PAT carries whatever scope the owner's account has org-wide,
  not the four narrow read permissions (`contents`, `pull-requests`, `checks`,
  `statuses`) ADR 0109 specified. A leak of this secret is a leak of a
  broadly-scoped human credential, not a purpose-built read-only token.
- **Audit trail.** Actions taken with this PAT appear as the owner's own identity in
  GitHub's logs, indistinguishable from the owner acting by hand — unlike a dedicated
  App, which has its own bot identity separate from any human's.

Both workflows keep every other ADR 0109 invariant: `contents: read` job-level
permissions, no write grant anywhere on either workflow, and the observe-only /
no-mutation boundary (`mode:"observe-only"`, no issue/PR/contents write). Only the
credential-minting mechanism changes.

## Consequences

- `RENOVATE_COMPATIBILITY_PAT` must be added as an Actions secret (organization or
  repository scope) before either workflow can run; `RENOVATE_COMPATIBILITY_CLIENT_ID`
  and `RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` are no longer read by either workflow and
  can be left unset.
- If the PAT is ever revoked, rotated, or the owner's account access changes, both
  workflows silently start failing at the API-call step rather than at token minting —
  narrower failure visibility than ADR 0109's dedicated App would have given.
- This ADR is superseded, not amended, the moment the dedicated App is provisioned and
  the workflows revert to `actions/create-github-app-token`; that reversion does not
  need a new ADR number since it restores ADR 0109's already-decided design.
