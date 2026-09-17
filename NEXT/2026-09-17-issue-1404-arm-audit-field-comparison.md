---
date: 2026-09-17
issue: 1404
impact: patch
title: Make the authorization arm audit runnable, and run it on a schedule
---

`scripts/ai-review-required-workflow-audit.py` now compares a live organization
ruleset against the fields its reviewed image actually asserts — tolerating keys
GitHub adds to its own schema, while still reporting an unexpected value, an
absent asserted key, or an added list member such as a bypass actor — and runs
daily in its own job alongside the organization ruleset conformance audit.

The audit had been exiting 1 at its first precondition because GitHub shipped
`require_extra_approval_for_unattributed_changes` into `pull_request` parameters
long after the `preimage`/`postimage` objects in
`config/ai-review-required-workflow-rollout.json` were frozen. Whole-object
equality against a vendor API that gains fields is guaranteed to rot, and its
failure is indistinguishable from real drift. It was also invoked nowhere, so
the failure stayed invisible while the only control that could have caught the
fleet gap in issue 1401 could not run.

Three pieces of unrecorded intent are now written into the contract as reviewed
decisions rather than adopted from live state: the `release-authorization` and
`merge-authorization` bypass grants, and the `changelog-contract` required
context ADR 0186 already decided. `ai-review-authorization` deliberately holds
no bypass. The audit now reaches its fleet-coverage check and reports the real
condition it exists for — an armed repository with no deterministic CI behind
it. See ADR 0188.
