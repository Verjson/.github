---
date: 2026-09-12
issue: 1320
impact: patch
title: Triage the unregistered ci-gate tests and guard against new orphans
---

Nine `scripts/ci-gate/*.test.sh` files were registered in no `actions-ci` group and
so never ran in Actions. `dispatch-permission.test.sh` is rewritten against the
current five-job merge-gate shape and registered; the other eight assert a workflow
topology ADR 0079 removed and are deleted. `scripts/actions-ci-groups.test.sh` now
fails CI when a ci-gate test is reachable from neither the manifest nor the hosted
compatibility job, so the drift cannot recur silently.

`429d441` deleted the `ci_wait` polling step and deregistered its harnesses without
removing the files; `fb27dca` swept two of them a month ago and the rest stayed. A
stale test that no job runs is worse than no test, because it reads as coverage in
review while proving nothing.

Two invariants those files were the only nominal record of were re-covered in
registered suites *before* the deletions, not after. The #276 self-exclusion property
survives in ADR 0081's form — a `REQUIRED_CHECK_POLICY` entry may not name a gate
check or a gate workflow path, so the gate cannot satisfy its own readiness — and is
now driven over all three check names and all three workflow paths in
`native-automerge.test.sh`. The #458 property that a failing head-ref delete must not
fail an already-merged reconcile is now driven in `post-merge-reconcile.test.sh`.
Both additions were mutation-verified against the shipped workflow and script.

`dispatch-permission.test.sh` asserts an exact per-job permission map rather than the
original global `grep -c` counts. A count says one job holds `actions: write` without
saying which, so relocating the grant kept the old assertion green; the map makes a
new job or a widened scope a stated change. ADRs 0079, 0039, and 0044 carry dated
amendments recording which harness each deletion retires and where its coverage went.
