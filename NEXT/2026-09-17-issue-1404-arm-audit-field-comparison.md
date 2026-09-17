---
date: 2026-09-17
issue: 1404
impact: patch
title: Compare the ruleset fields the arm contract asserts instead of whole objects
---

`scripts/ai-review-required-workflow-audit.py` now compares a live organization
ruleset against the fields its reviewed image actually asserts, tolerating keys
GitHub adds to its own schema while still rejecting an unexpected value, an
absent asserted key, or an added list member such as a bypass actor.

The audit had been exiting 1 at its first precondition because GitHub shipped
`require_extra_approval_for_unattributed_changes` into `pull_request` parameters
long after the `preimage`/`postimage` objects in
`config/ai-review-required-workflow-rollout.json` were frozen. Whole-object
equality against a vendor API that gains fields is guaranteed to rot, and its
failure is indistinguishable from real drift — which is why the fleet gap in
issue 1401 went undetected by the only control that could have caught it.
