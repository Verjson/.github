# 0203 — Retire review-App authorization-check ownership

- **Date:** 2026-09-23
- **Status:** Proposed
- **Related:** [ADR 0199](../0199-authorization-checks-fail-without-review-app-credentials/README.md)
- **Issues:** [#1540](https://github.com/Verjson/.github/issues/1540)
- **Supersedes:** [ADR 0200](../0200-temporary-legacy-authorization-check-write/README.md)

## Context

[ADR 0200](../0200-temporary-legacy-authorization-check-write/README.md)
temporarily granted the AI review App `checks:write` so receipt-bound review
runs could finish authorization checks created before
[ADR 0199](../0199-authorization-checks-fail-without-review-app-credentials/README.md)
moved check creation to GitHub Actions.

New arms now create Actions-owned checks, but live-state review on 2026-09-23
found three legacy in-progress checks owned by App `4528902`
(`ai-review-authorization`). Two belong to a merged or closed pull request. The
third remains required by the open
[verjson-git-runners#221](https://github.com/Verjson/verjson-git-runners/pull/221),
where the source arm completed and the paired review dispatch failed. Removing
legacy terminalization before that check becomes terminal or is replaced would
strand the open adopter.

This decision becomes Accepted only after every legacy check is terminal and a
fresh organization-wide query proves that no open pull-request head depends on
a review-App-owned authorization check. Until then ADR 0200 remains effective,
and this implementation must not merge.

## Decision

After the prerequisite is satisfied, GitHub Actions App ID `15368`, with slug
`github-actions`, will be the sole producer and terminalizer of
`AI review authorization` checks. Every receipt must carry explicit
`check_app_id` and `check_app_slug` fields bound to that identity; receipts that
omit those fields or name the review App will be rejected.

The verifier, gate rearm and orphan recovery, zero-provider recovery,
completion and fallback finalizer, privileged merge, promotion retry, and
post-merge evidence readers will all require the Actions-owned identity. The
completion workflow will use its caller-owned `GITHUB_TOKEN` to finish the
exact receipt-bound check. The dedicated AI review App token will no longer
request `checks:write`; its ID and slug will remain authoritative only for
authenticating the approval author, and the token will retain the content and
pull-request permissions needed to persist and verify that approval.

Exact repository, pull request, head SHA, check ID, external ID, arm run, run
attempt, details URL, receipt digest, and review-policy bindings remain
unchanged. Unknown, omitted, or legacy check ownership fails closed and cannot
authorize, promote, or merge.

## Consequences

- The review App cannot create, update, or complete repository check runs after
  this decision is accepted and implemented.
- An old review-App-owned check or receipt cannot be replayed through current
  recovery, completion, promotion, retry, or post-merge paths.
- Current Actions-owned checks still reach terminal failure through the
  always-run fallback when review credentials or approval persistence fail.
- `AI_REVIEW_APP_ID` and `AI_REVIEW_APP_SLUG` remain required where a trusted
  workflow verifies the dedicated App's approval author; they no longer
  identify an acceptable authorization-check owner.

Focused mutation tests cover missing `check_app_*` fields, legacy review-App
ownership, token-permission regression, exact Actions ownership, same-head
retry, recovery, promotion, and post-merge evidence.
