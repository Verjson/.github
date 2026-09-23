# 0203 — Retire review-App authorization-check ownership

- **Date:** 2026-09-23
- **Status:** Accepted
- **Related:** [ADR 0199](../0199-authorization-checks-fail-without-review-app-credentials/README.md)
- **Issues:** [#1540](https://github.com/Verjson/.github/issues/1540)
- **Supersedes:** [ADR 0200](../0200-temporary-legacy-authorization-check-write/README.md)

## Context

[ADR 0200](../0200-temporary-legacy-authorization-check-write/README.md)
temporarily granted the AI review App `checks:write` so receipt-bound review
runs could finish authorization checks created before
[ADR 0199](../0199-authorization-checks-fail-without-review-app-credentials/README.md)
moved check creation to GitHub Actions. The adopter rollout is complete and no
active receipt depends on review-App-owned authorization checks. Keeping the
compatibility path would preserve a repository-wide check mutation permission
whose only remaining purpose was the completed migration.

## Decision

GitHub Actions App ID `15368` with slug `github-actions` is the sole producer
and terminalizer of `AI review authorization` checks. Every receipt must carry
explicit `check_app_id` and `check_app_slug` fields bound to that identity;
receipts that omit those fields or name the review App are rejected.

The verifier, gate rearm and orphan recovery, zero-provider recovery,
completion and fallback finalizer, privileged merge, promotion retry, and
post-merge evidence readers all require the Actions-owned identity. The
completion workflow uses its caller-owned `GITHUB_TOKEN` to finish the exact
receipt-bound check. The dedicated AI review App token no longer requests
`checks:write`; its ID and slug remain authoritative only for authenticating
the approval author and its token retains the content and pull-request
permissions needed to persist and verify that approval.

Exact repository, PR, head SHA, check ID, external ID, arm run, run attempt,
details URL, receipt digest, and review-policy bindings remain unchanged.
Unknown, omitted, or legacy check ownership fails closed and cannot authorize
or promote a merge.

## Consequences

- The review App cannot create, update, or complete repository check runs.
- An old review-App-owned check or receipt cannot be replayed through current
  recovery, completion, promotion, or post-merge paths.
- Current Actions-owned checks still reach a terminal failure through the
  always-run fallback when review credentials or approval persistence fail.
- `AI_REVIEW_APP_ID` and `AI_REVIEW_APP_SLUG` remain required where the trusted
  workflow verifies the dedicated App approval author; they no longer identify
  an acceptable authorization-check owner.

Focused mutation tests cover missing `check_app_*` fields, legacy review-App
ownership, token-permission regression, exact Actions ownership, recovery,
promotion, and post-merge evidence.
