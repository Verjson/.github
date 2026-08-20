---
date: 2026-08-20
issue: 964
impact: patch
title: Complete the authorization check when the arm never dispatches a review
---

`gate-rearm.yml` creates the required `AI review authorization` check-run before it
uploads the immutable receipt, but nothing completed that check-run when the upload
failed — so an artifact-quota rejection left the check `in_progress` forever and its PR
blocked with no visible failure. The arm now gives that check-run a terminal `failure`
conclusion with recovery guidance whenever it ends without a dispatched review.

The stall was self-sustaining rather than transient: the trusted review was never
dispatched, so nothing else owned the check; `ai-promotion-retry.yml` treats a pending
required check as "wait for the next attempt" by design (ADR 0081 §4) and never
completes one; and every later arm event took the duplicate-event no-op because a
check-run existed, reporting success while doing nothing. Observed on
`verjson-browser-agent#46` and `verjson-cloud-storage#92`, which sat behind four and
three conclusion-less `in_progress` authorization checks. The new guard only ever writes
a failure, skips any check-run a dispatched review or an earlier failure path already
owns, and is covered by
`scripts/ci-gate/arm-authorization-terminal-state.test.sh`. See
[ADR 0112](../docs/decisions/0112-arm-authorization-checks-reach-a-terminal-state/README.md);
automatic re-arming of a dead authorization is deliberately left out of scope there.
