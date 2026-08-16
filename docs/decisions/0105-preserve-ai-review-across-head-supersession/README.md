# 0105 — Preserve AI review across head supersession

- **Date:** 2026-08-16
- **Status:** Accepted
- **Issue:** [#850](https://github.com/Verjson/.github/issues/850)
- **Supersedes in part:** [ADR 0098](../0098-require-bounded-ai-review-for-code/README.md)
- **Category:** AI merge gate / cost authorization (sensitive class)

## Context

ADR 0098 capped automatic provider reservations across an entire pull request. A
`synchronize` event cancels the older workflow so stale code cannot gain authority, but
the canceled run's App-authored reservations remained charged to every later head. On
`Verjson/verjson-github-runner#153`, a replacement run canceled pass 1, the canceled job
still reserved and invoked fallback pass 2, and that fallback produced a valid blocking
verdict. Cancellation skipped deterministic publication. The replacement exact head was
then denied review because the two stale-head reservations exhausted the PR-wide cap.

That behavior violated the stronger contract that every ready code revision receives a
review. It also described a workflow race as provider failure and stranded a valid
security finding in Actions logs.

## Decision

The automatic two-pass ceiling is scoped to the exact reviewed head. Reservation
accounting accepts only dedicated-App markers whose PR, review commit, marker head, and
requested current head all match. A superseded head's paid calls remain visible in
PR-wide telemetry, but they cannot consume a replacement head's authorization allowance.
Each provider call retains its own receipt-bound budget, and forks remain unable to enter
the secret-backed review lane.

The workflow re-reads authoritative PR head state immediately before reserving pass 1
and again before reserving fallback. A mismatch refuses the reservation and records an
explicit supersession diagnostic. `always()` publication retains any validator-confirmed
stale-head verdict as non-authorizing evidence, clearly names both heads, and never mints
approval for the replacement revision. A stale run with no usable verdict reports
supersession rather than a generic provider failure.

The explicit maintainer `re-review` receipt remains one-shot for its exact authorization
check. No exact head may receive a third automatic provider invocation. Repeated trusted
same-repository pushes can incur a fresh bounded review because reviewing each ready
revision is the required behavior; per-call budgets, trusted-arm admission, and fork
exclusion remain the abuse boundary.

## Consequences

- Ordinary synchronize events cannot permanently exhaust AI review for later heads.
- Cancellation cannot start a paid fallback after authoritative head state has moved.
- Stale verdicts remain auditable but cannot approve or merge the current head.
- Total spend across a frequently updated PR is no longer bounded to two calls; it is
  bounded per exact head and remains visible through reservation telemetry.

## Verification

`review-attempt-count.test.py` proves stale-head reservations do not consume the current
head's allowance. `ai-review-retry.test.sh` mutation-tests exact-head admission before
both reservations. `review-comment.test.sh` executes the publication block for empty and
validator-confirmed stale-head outcomes and proves neither authorizes the replacement
head.
