# 0042 — Privileged merge becomes a reusable workflow with a two-sided name contract

- **Date:** 2026-08-01
- **Issues:** [Verjson/.github#276](https://github.com/Verjson/.github/issues/276),
  [Verjson/verjson-cloud-storage#28](https://github.com/Verjson/verjson-cloud-storage/issues/28)
- **Extends:** ADR 0036 (privileged merge separated from review), ADR 0039 (required-workflow
  gate provenance), ADR 0022 (reusable gate for cross-org consumers)
- **Category:** merge authority / org admin token — **sensitive class**

## Context

`ai-privileged-merge.yml` existed only as a `pull_request_target` + `workflow_dispatch`
workflow that each consumer copied. One fat copy exists today, in
`verjson-cloud-storage`, and because it is a copy it never received the ADR 0039
provenance fix — the divergence that motivated this change. Copied trust logic drifts;
that is the whole problem.

## Decision

The canonical workflow becomes a **hybrid**, mirroring `ai-review-merge.yml`: it keeps
`pull_request_target` and `workflow_dispatch` for `.github`'s own use and additionally
accepts `workflow_call`. Consumers become thin callers that implement nothing.

Inputs on `workflow_call`: `pr_number`, `expected_head_sha`, `source_run_id` (all optional
— a `pull_request_target`-triggered caller leaves them empty and the inherited event
supplies them), and `runner_labels`, which is **required**. A consumer org has no runner
for Verjson's isolated pool, so inheriting it would queue the job forever on labels
nothing matches (#130); requiring it fails the call immediately with a clear message.

### The two-sided name contract

This is the part that fails silently, so it is stated as a contract and tested on both
sides.

A reusable call publishes its check as **`<caller job> / <callee job>`**. Measured on
`verjson-cloud-storage` PR#27, which shows both shapes in one PR:

```
preflight | ci / eligibility | gate | ci / build-test | dispatch-merge
```

`preflight`/`gate`/`dispatch-merge` are un-prefixed (installed as an organization required
workflow); `ci / *` are prefixed (a reusable call).

The gate filters required checks by **exact name equality**. Therefore:

1. The caller's job key **must** be `privileged_merge`, and
2. `ai-review-merge.yml` **must** exclude the literal `privileged_merge / privileged_merge`
   at both filter sites.

**Neither is sufficient alone.** The literal only ever matches if the job key is
contractual; a consumer who writes `merge:` produces `merge / privileged_merge`, which the
gate counts as one of its own required checks and waits on forever — while that check
waits for the gate. The failure surfaces as `trusted gate/checks did not become green`,
pointing nowhere near the cause.

`scripts/ci-gate/privileged-merge-caller-contract.test.sh` pins both sides, and the caller
is **generated** (`scripts/gen-privileged-merge-caller.sh`) rather than hand-written, so a
renamed job key cannot creep in through a copy-paste.

### Why not normalize check names

Normalization was considered and rejected as actively dangerous. Stripping the prefix
before `/` matches on the **callee** segment, so it silently excludes any consumer check
ending in `/ review`, `/ classify`, or `/ gate` — `security / review` from an unrelated
workflow would drop out of the required set. That is the fail-open direction, arriving
silently, in someone else's repository.

The principled fix is runtime self-derivation — asking GitHub for this run's own job names
— which cannot over-exclude by construction. It is deliberately **not** in this change:
it touches the wait loop ADR 0039 just stabilized and should not ride along with a
migration. Tracked in #276, which also records a latent consequence of the same bug class:
a cross-org consumer installing the *gate* itself as a reusable would deadlock on the
gate's own prefixed jobs. That shape is advertised as supported by ADR 0039 and, as
measured, has never actually been run.

### The `@main` pin — a deliberate exception

Callers pin `@main`, not a SHA. This contradicts the organization's default pin policy and
the exception is deliberate: the canonical workflow **already anchors trust to
`Verjson/.github@main` at runtime** (`gh api repos/Verjson/.github/commits/main --jq .sha`).
A SHA-pinned caller would let a repository admin freeze an older gate while the trust
anchor moved on — reintroducing exactly the divergence this split removes. The exception
is tested in `scripts/node-workflow-pins.test.sh` rather than left as a comment.

### Concurrency

The canonical group is now keyed by **event as well as PR**. Previously both the
`pull_request_target` check and the dispatched continuation shared
`ai-privileged-merge-<pr>` with `cancel-in-progress: true`, so the newer dispatch cancelled
the older check and left a red `privileged_merge` on a PR that had merged successfully —
the interaction ADR 0039 records. Two cancelled runs are observable in the history
(`30704237281`, `30645044359`). Separating by event lets both reach a terminal state; each
re-validates PR state before merging and treats an already-merged PR as a no-op, so
concurrent execution is safe.

A thin caller uses a **distinct** group name (`ai-privileged-merge-call-…`). A called
workflow's concurrency is evaluated in the caller's context, so an identical group would
put the reusable's job behind the caller job that invoked it. **This deadlock is reasoned
from job/group lifetimes, not reproduced** — the design avoids the collision by
construction, so correctness does not depend on the claim being right.

## Consequences

- Trust logic exists in exactly one place. `verjson-cloud-storage` receives the ADR 0039
  fix by migrating (handoff filed; that repository is outside this PM's managed scope).
- A consumer renaming the caller job breaks the gate silently — mitigated by generation
  plus a contract test, not by documentation.
- The gate's exclusion list now carries a literal that only makes sense alongside the job
  key. They must be changed together; the test enforces that.

## Rollback

Revert the implementing PR. The canonical workflow returns to `pull_request_target` +
`workflow_dispatch` only; consumers keep their existing copies, which continue to work as
they do today. No consumer has migrated at the time of writing, so rollback affects
nothing downstream.
