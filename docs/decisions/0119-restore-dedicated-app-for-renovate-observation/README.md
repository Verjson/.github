# 0119 — Restore the dedicated App for Renovate observation

- **Date:** 2026-08-23
- **Status:** Accepted
- **Issue:** [#699](https://github.com/Verjson/.github/issues/699)
- **Extends:** [ADR 0109](../0109-observe-first-renovate-compatibility-control-plane/README.md)
- **Supersedes:** [ADR 0111](../0111-interim-pat-for-renovate-compatibility-control-plane/README.md)

## Context

ADR 0109 separated organization-wide compatibility observation from untrusted
candidate execution and selected a dedicated read-only GitHub App for observation.
ADR 0111 temporarily replaced that design with a human PAT because the App and its
Actions credentials did not exist. The dedicated `verjson-renovate-compatibility`
App is now installed on all repositories with only Actions, checks, contents, pull
requests, commit statuses, and metadata read permissions. Its organization client-ID
variable and private-key secret are available, while `RENOVATE_COMPATIBILITY_PAT`
remains absent.

The installation's all-repository selection is broader than either workflow's actual
call surface. Installation-token minting must therefore narrow authority again at run
time. The planner needs only the private `renovate-config` policy repository. The
reconciler needs that policy repository plus the explicitly managed CI-infrastructure
repositories whose Renovate failures it observes; it does not need product or customer
repositories.

## Decision

Restore ADR 0109's dedicated-App design. Both workflows validate that
`RENOVATE_COMPATIBILITY_CLIENT_ID` is present and non-numeric before invoking the
immutable `actions/create-github-app-token` action. Missing or malformed credentials,
an inaccessible repository, or a token-mint failure terminates the job; there is no PAT,
`GITHUB_TOKEN`, or unauthenticated fallback.

The grouping planner mints a token for exactly `Verjson/renovate-config` with only
`contents: read`, passes it only to the immutable policy checkout, and does not persist
it. The reconciler mints one token whose repository list is the exact managed
CI-infrastructure set and whose requested permissions are only `actions: read`,
`checks: read`, `contents: read`, `pull-requests: read`, and `statuses: read`. It binds
that token only to the policy fetch and compact failure inventory steps. Neither
workflow requests or receives a write permission, and the reconciler remains
observe-only.

The static reconciliation repository allowlist is an authorization boundary, not a
discovery convenience. Adding another repository requires a reviewed workflow change;
attacker-controlled candidate or repository data cannot widen the minted token.

## Security analysis

The App private key exists only in the trusted observation jobs and is consumed only by
the token action. The resulting installation tokens are short-lived, repository-bound,
and permission-narrowed below the App installation. Candidate code never runs in either
credentialed job and continues to execute in the separate credentialless canary.

The workflow `GITHUB_TOKEN` remains contents-read-only and is never substituted for a
failed App mint. The planner token cannot read pull requests, checks, statuses, or
Actions. The reconciler cannot create issues, update pull requests, push contents,
dispatch workflows, or approve Renovate changes. GitHub rejects a wrong installation or
repository selection during minting, so configuration drift fails closed.

## Consequences

- The human PAT path and its human-attributed audit trail are retired.
- Repository additions to observation are deliberate code-reviewed changes.
- Rotation or removal of either App credential fails at validation or minting without
  exposing a broader fallback credential.
- Rollback disables the two workflows; restoring the superseded PAT path requires a new
  security decision and is not an operational fallback.
