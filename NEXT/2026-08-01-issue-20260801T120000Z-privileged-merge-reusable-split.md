---
date: 2026-08-01
id: 20260801T120000Z
title: Split privileged merge into a reusable workflow with a tested two-sided name contract
---

`ai-privileged-merge.yml` existed only as an event-triggered workflow that consumers
copied. The one fat copy in the organization, `verjson-cloud-storage`, never received the
ADR 0039 provenance fix precisely because it was a copy.

The canonical workflow is now a hybrid mirroring `ai-review-merge.yml`: it keeps
`pull_request_target` and `workflow_dispatch` for its own use and additionally accepts
`workflow_call`, with `runner_labels` **required** so a consumer org cannot silently queue
the job forever on labels nothing matches (#130).

The contract that makes this work is three-sided and fails silently. A reusable call
publishes its check as `<caller job> / <callee job>` — measured on `verjson-cloud-storage`
PR#27, which shows `preflight | ci / eligibility | gate | ci / build-test | dispatch-merge`,
both shapes at once. The gate filters required checks by exact name equality, so the
caller's job key must be `privileged_merge`, the gate must exclude that shape, **and so
must the canonical workflow itself** — under a thin caller its own check is
`privileged_merge / privileged_merge`, so filtering only the bare name made it count
itself as pending and burn ~40 minutes holding `ORG_ADMIN_TOKEN`. Adversarial review found
that third side; every consumer would have hit it.

The exclusion is a scoped suffix match, not a literal, so it also survives a misnamed
caller and one level of nesting.

So the caller is **generated** (`scripts/gen-privileged-merge-caller.sh`) rather than
hand-written, and `scripts/ci-gate/privileged-merge-caller-contract.test.sh` pins both
sides. Strip-before-`/` normalization was rejected as fail-open — it matches the callee segment
and would drop `security / review` from the required set. The scoped suffix used instead
cannot do that. Runtime self-derivation remains deferred to #276.

Review also hardened the generator, which had accepted a `ref` argument that injected
arbitrary YAML into a merge-authority workflow (and slipped past the pin guard, which
inspects only the `uses:` line) and accepted labels containing quotes that produced
unparseable output at exit 0. The parameter is gone, labels are charset-restricted, the
generator validates its own output before emitting, and the caller now grants exactly
`ORG_ADMIN_TOKEN` rather than `secrets: inherit`. Follow-ups filed: #278, #279.

Concurrency is now keyed by event as well as PR. Both the `pull_request_target` check and
the dispatched continuation previously shared one group with `cancel-in-progress`, so the
dispatch cancelled the check and left a red mark on a successfully merged PR — two such
runs are in the history. Thin callers use a distinct group name.

Callers pin `@main`, not a SHA. This is a deliberate exception to the pin policy, now
asserted in `scripts/node-workflow-pins.test.sh`: the canonical workflow already anchors
trust to `Verjson/.github@main` at runtime, so a SHA-pinned caller would let a repository
admin freeze an older gate while the trust anchor moved on. See
[ADR 0042](../docs/decisions/0042-privileged-merge-reusable-split/README.md).
