# 0042 — Privileged merge becomes a reusable workflow with a two-sided name contract

- **Date:** 2026-08-01
- **Issues:** [Verjson/verjson-cloud-storage#28](https://github.com/Verjson/verjson-cloud-storage/issues/28)
  (consumer migration). Deferred work: [#276](https://github.com/Verjson/.github/issues/276)
  (runtime self-derivation + the latent cross-org gate deadlock),
  [#278](https://github.com/Verjson/.github/issues/278) (`@main` unenforced downstream),
  [#279](https://github.com/Verjson/.github/issues/279) (forgeable attestation).
  #276 is a **deferral target, not this change's implementing issue** — it must survive
  this merge.
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

> The `runner_labels` requirement stated here is superseded by
> [ADR 0057](../0057-runner-labels-optional-lane-routed-callers/README.md) (#405).

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

1. The caller's job key **must** be `privileged_merge`,
2. `ai-review-merge.yml` **must** exclude that shape at every filter site, and
3. **`ai-privileged-merge.yml` must exclude it too** — under a thin caller its *own*
   check is `privileged_merge / privileged_merge`, so filtering only the bare name made
   it count itself as pending, burning ~40 minutes holding `ORG_ADMIN_TOKEN` before
   reporting an error pointing nowhere near the cause. Side 3 was missed on the first
   pass and found by adversarial review; every consumer would have hit it.

**No one of them is sufficient alone.** The literal only ever matches if the job key is
contractual; a consumer who writes `merge:` produces `merge / privileged_merge`, which the
gate counts as one of its own required checks and waits on forever — while that check
waits for the gate. The failure surfaces as `trusted gate/checks did not become green`,
pointing nowhere near the cause.

`scripts/ci-gate/privileged-merge-caller-contract.test.sh` pins both sides, and the caller
is **generated** (`scripts/gen-privileged-merge-caller.sh`) rather than hand-written, so a
renamed job key cannot creep in through a copy-paste.

### Why not normalize check names — and what is used instead

Stripping the prefix before `/` was rejected as actively dangerous: it matches on the
**callee** segment, so it silently excludes any consumer check ending in `/ review`,
`/ classify`, or `/ gate` — `security / review` from an unrelated workflow would drop out
of the required set. Fail-open, silently, in someone else's repository.

The exclusion actually used is a **scoped suffix match**, `endswith("/ privileged_merge")`,
which is not that transform. The only thing it can over-exclude is a check whose *callee*
job is literally `privileged_merge` — the target itself. Verified against a realistic
rollup: it excludes `privileged_merge`, `privileged_merge / privileged_merge`,
`merge / privileged_merge` and `outer / inner / privileged_merge`, while retaining
`security / review` and `ci / build-test`.

That makes the contract robust rather than brittle: a consumer who misnames the caller job
gets a working gate anyway, and nesting one level deeper still resolves. The job-key pin
remains as defence in depth, not as the sole mechanism.

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
(`30704237281`, `30645044359`). Separating by event lets both reach a terminal state.

**That makes both runs live at once, and the earlier claim that this is inherently safe
was wrong.** State re-validation happens before the merge but is *not atomic* with it: a
base-ref resolve, a paginated rules call, a gate lookup and an attestation download sit in
between. The loser of that race gets a legitimate `--match-head-commit` failure, which
under `set -euo pipefail` would surface as a red `privileged_merge` on a PR that merged
correctly — trading a deterministic cancelled check for a probabilistic failed one, which
is harder to diagnose, not easier. So the merge call tolerates exactly one cause: the PR is
already `MERGED` at the attested head. Anything else stays red.

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

**Time-limited.** Because callers pin `@main`, rollback is unconditional only while no
consumer has migrated. Once one has, reverting removes the `workflow_call` trigger its
caller depends on and breaks it instantly with no fallback ref. After the first migration,
roll back by migrating consumers off first.

Revert the implementing PR. The canonical workflow returns to `pull_request_target` +
`workflow_dispatch` only; consumers keep their existing copies, which continue to work as
they do today. No consumer has migrated at the time of writing, so rollback affects
nothing downstream.

## Amendment (2026-08-06, #458) — branch cleanup is not part of the merge verdict

The decision above states the merge call tolerates exactly one non-fatal cause and stays
red otherwise. A second cause was tolerated by nobody and should have been: the call was
`gh pr merge … --squash --admin --delete-branch --match-head-commit …`, so on a repository
with **auto-delete-branch-on-merge** enabled GitHub removed the head ref as part of the
merge and `--delete-branch` then lost the race against it:

```
All checks green and head unchanged; merging PR #344 (lane: ai).
failed to delete remote branch chore/233-production-audit-triage:
  HTTP 404: Reference does not exist
##[error]Process completed with exit code 1.
```

Observed on `tequityapp/tequity-api` PR #344 (merge 2026-08-06 09:15:34Z, delete failure
09:15:36Z). The PR squash-merged, the commit reached `main`, the linked issue auto-closed —
and the gate went red. **That report came from `@v1`**, where `ai-review-merge.yml`'s own
merge step is still live and carries the same coupling with no recovery block at all. On
`main` the same 404 produced a quieter defect: the failure fell into the concurrent-merge
recovery path, which — the PR being genuinely `MERGED` at the attested head — misread an
already-deleted branch as another run's work and `exit 0`ed **above** the follow-up filing
block, so ADR 0009's follow-up issues were silently never filed. Both readings are wrong for
the same reason, and neither is cosmetic: a red gate on a merged PR trains reviewers to
ignore the signal, and a green one that skipped follow-ups loses the findings.

Deleting the head ref is idempotent cleanup whose post-condition — *ref absent* — a 404
already satisfies. It now runs **after** the merge, as `gh api -X DELETE
repos/$TARGET_REPO/git/refs/heads/$head_ref`, and cannot fail the step. The ref name comes
from `headRefName` added to the `gh pr view` projection the step already fetched, so this
costs no extra API call.

**A cross-repository PR is skipped entirely, and that is a gate rather than an assumption.**
The first draft of this fix reasoned that naming `TARGET_REPO` explicitly made a fork PR 404
harmlessly. It does the opposite. `headRefName` is `head.ref` — the branch name *inside the
head repository*, unqualified by owner. `--delete-branch` resolved that name against the head
repo; a bare `gh api -X DELETE repos/$TARGET_REPO/...` resolves it against the base repo. A
fork PR from `attacker/x:develop` would therefore have aimed an `ORG_ADMIN_TOKEN` delete at
the base repository's own `develop` — a branch that has nothing to do with the PR, under a
name the contributor chooses, with the outcome swallowed by the same `2>&1 ||` that makes the
404 tolerable. Nothing else in the gate rejects fork PRs outright; `workflow_files_changed`
only rejects those touching `.github/workflows/`. So `isCrossRepository` joins the projection
and the delete runs only when it is literally `false`; an absent or unreadable value is
treated as cross-repository, because the safe direction here is *not deleting*.

Consumers were bitten by the same coupling in the other direction — a *failed* merge that
still deleted the branch, stranding the PR `CONFLICTING` with no recoverable head. Both are
one root cause: branch deletion coupled to merge success in a step whose exit code is read
as the merge verdict.

The invariant this restores is the one the original decision assumed: **the step's exit
status answers "did the PR merge?" and nothing else.** Enforced by
`scripts/ci-gate/merge-branch-cleanup.test.sh`, which extracts the real block from the
workflow and runs it under `set -euo pipefail` against a stubbed `gh` with independently
driven merge and delete outcomes. Eight mutants die: re-coupling `--delete-branch`, dropping
the delete's failure tolerance, deleting unconditionally, accepting a merge at an unattested
head, inverting the cross-repository gate, removing it, defaulting an unknown relationship to
same-repo, and rewording the notice the harness terminates extraction on — that last one
because the extraction is now bounded by line count and `fi` arity, not only by "non-empty".
The fork hole above was found by review, not by that suite, and the suite gained the case
that would have found it.

**This does not reach the repository that reported it.** `tequityapp/tequity-api` pins `@v1`
(ADR 0022), an annotated tag whose commit is still `e3cf463` (2026-07-24) — a revision predating the split
this ADR records, so it merges from `ai-review-merge.yml`'s live step and is unaffected by
any fix to `ai-privileged-merge.yml`. `main`'s copy of that step has been `if: ${{ false }}`
since `87b4d54`, so it is left alone rather than fixed in place. Cross-org consumers get this
only when `v1` is advanced, which is a separate decision with a much wider blast radius than
one 404.
