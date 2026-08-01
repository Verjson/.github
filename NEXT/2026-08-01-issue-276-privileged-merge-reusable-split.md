---
date: 2026-08-01
issue: 276
title: Split privileged merge into a reusable workflow with a tested two-sided name contract
---

`ai-privileged-merge.yml` existed only as an event-triggered workflow that consumers
copied. The one fat copy in the organization, `verjson-cloud-storage`, never received the
ADR 0039 provenance fix precisely because it was a copy.

The canonical workflow is now a hybrid mirroring `ai-review-merge.yml`: it keeps
`pull_request_target` and `workflow_dispatch` for its own use and additionally accepts
`workflow_call`, with `runner_labels` **required** so a consumer org cannot silently queue
the job forever on labels nothing matches (#130).

The contract that makes this work is two-sided and fails silently. A reusable call
publishes its check as `<caller job> / <callee job>` — measured on `verjson-cloud-storage`
PR#27, which shows `preflight | ci / eligibility | gate | ci / build-test | dispatch-merge`,
both shapes at once. The gate filters required checks by exact name equality, so the
caller's job key **must** be `privileged_merge` **and** `ai-review-merge.yml` must exclude
the literal `privileged_merge / privileged_merge`. Neither half works alone: a consumer who
writes `merge:` produces `merge / privileged_merge`, which the gate counts as one of its
own required checks and waits on forever while that check waits for the gate.

So the caller is **generated** (`scripts/gen-privileged-merge-caller.sh`) rather than
hand-written, and `scripts/ci-gate/privileged-merge-caller-contract.test.sh` pins both
sides. Normalizing check names was rejected as actively dangerous: stripping before `/`
matches the callee segment, silently dropping any consumer check ending in `/ review` or
`/ gate` out of the required set — fail-open, in someone else's repository. The principled
fix, runtime self-derivation of the gate's own job names, is deliberately deferred to #276
because it touches the wait loop ADR 0039 just stabilised.

Concurrency is now keyed by event as well as PR. Both the `pull_request_target` check and
the dispatched continuation previously shared one group with `cancel-in-progress`, so the
dispatch cancelled the check and left a red mark on a successfully merged PR — two such
runs are in the history. Thin callers use a distinct group name.

Callers pin `@main`, not a SHA. This is a deliberate exception to the pin policy, now
asserted in `scripts/node-workflow-pins.test.sh`: the canonical workflow already anchors
trust to `Verjson/.github@main` at runtime, so a SHA-pinned caller would let a repository
admin freeze an older gate while the trust anchor moved on. See
[ADR 0042](../docs/decisions/0042-privileged-merge-reusable-split/README.md).
