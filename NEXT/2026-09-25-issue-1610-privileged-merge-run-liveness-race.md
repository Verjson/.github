---
date: 2026-09-25
issue: 1610
impact: patch
title: Retry instead of hard-failing when a required check's job finishes before its multi-job run
---

`ai-privileged-merge.yml`'s required-check verification combined the trusted
workflow run's *identity* (`workflow_id`, `path`, `event`, `head_sha`,
`head_repository`) and its *liveness/conclusion* (`status == "completed" and
conclusion == "success"`) into one jq predicate. A required check's own job
routinely finishes (and publishes its check-run) before a slower sibling job
in the same run does — a fast `eligibility` job alongside a slower
`build-test` job is a normal CI shape, not an edge case. That made the whole
predicate fail while the run was still `in_progress`, which hard-failed
(`exit 1`) instead of retrying, so `ai-promotion-retry.yml` never got a
"try again later" signal and promotion needed a manual admin merge.

Identity and liveness are now checked separately: an identity mismatch still
hard-fails; a matching run that has not finished retries (`exit 0`, matching
the existing pending-check pattern); only a completed run with a
non-`success` conclusion is a terminal block. Covered by two new cases in
`scripts/ci-gate/native-automerge.test.sh` that reproduce the race directly
against the shipped step script.
