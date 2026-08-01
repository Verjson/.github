# 0043 — Privileged merge verifies which revision of itself is executing

- **Date:** 2026-08-01
- **Issue:** [Verjson/.github#278](https://github.com/Verjson/.github/issues/278)
- **Extends:** [ADR 0042](../0042-privileged-merge-reusable-split/README.md) (the `@main` pin),
  [ADR 0039](../0039-required-workflow-gate-provenance/README.md) (gate provenance)
- **Category:** merge authority / org admin token — **sensitive class**

## Context

ADR 0042 requires a consumer's thin caller to pin `@main` rather than a SHA, arguing that a
SHA-pinned caller would let a repository admin freeze an older privileged merge while the
trust anchor moved on. **Nothing enforced that**, and the ADR recorded the exposure as
closed — which is the more serious half of the defect.

The two mechanisms it named both run *here*:
`scripts/gen-privileged-merge-caller.sh` generates the caller and
`scripts/node-workflow-pins.test.sh` asserts the pin's form. The caller file lives in the
**consumer's** repository. Neither binds anything downstream, so a consumer admin could
re-pin to a pre-ADR-0039 revision and reinstate a weaker merge path.

The existing runtime anchor does not catch it either: `trusted_workflow_sha` pins the
**gate**'s revision inside `trusted_run_def`, not `ai-privileged-merge.yml`'s own. Every
other guard could pass while this workflow was itself executing from a fork.

## Decision

The privileged merge resolves the revision of **itself** that is executing and requires it
to be on `Verjson/.github@main`, before it does anything with the admin token.

The revision comes from `job.workflow_sha` / `job.workflow_repository` — the workflow
identity of the job's *defining* workflow, which is what a reusable call carries — falling
back to `github.workflow_sha` for `.github`'s own `pull_request_target` run, where the job
is not reusable-defined. Neither spelling is trusted to be present: an absent or
non-40-hex value is a hard failure naming that cause, not a `set -u` abort somewhere
downstream.

Acceptance is **reachability from `main`**, not equality:

| Comparison | Outcome |
|---|---|
| equal to `main`'s tip | accepted, no API call |
| `identical` / `ahead` with `behind_by == 0` | accepted, **with a warning** |
| `behind`, `diverged`, or any `behind_by > 0` | rejected |
| comparison unreadable, or missing `.status` | rejected |
| executing repository is not `Verjson/.github` | rejected |

Equality alone cannot be required: `main` may legitimately advance between the caller's
dispatch and this step, and a strict check would turn every such race into a red merge
check on a correctly merged pull request — the failure mode ADR 0042's concurrency section
already had to unwind once.

`behind_by` is checked alongside `status` because `ahead` on its own also describes a
diverged history that merely shares an ancestor.

## What this does NOT close

Stated plainly, because recording an exposure as closed when it is not is exactly the
defect this ADR exists to correct.

**A caller pinned to an older commit that is still on `main` passes.** It is reachable, so
it is accepted. Distinguishing a deliberate stale pin from the benign advance-mid-flight
race needs dispatch-time state this job does not have, so the two are indistinguishable
here and the run emits a `::warning::` naming both readings rather than choosing one.

What is now closed is the larger half: a workflow executing from a **fork**, a side branch,
a rewritten history, or any revision never on `main` cannot reach the admin token.

The residual is bounded by how far `main` can be behind itself, and is visible in the run
log every time it occurs. Narrowing it further — for example by binding the caller's
resolved ref at dispatch — belongs with #276's runtime self-derivation work, which touches
the same wait loop.

## Consequences

- Every consumer's privileged merge now makes one additional API call on the non-equal
  path only. The equality path, which is the normal case, costs nothing.
- A consumer that re-pins to a SHA off `main` breaks **loudly and immediately**, with a
  message naming ADR 0042, instead of silently running an older trust boundary.
- `scripts/ci-gate/privileged-merge-pin.test.sh` pins the behaviour; the existing
  privileged-merge suites now supply the workflow identity, so a future change that drops
  the check fails eleven assertions rather than one.

## Rollback

Revert the implementing PR. The check is self-contained and additive: nothing else reads
`executing_workflow_sha`, and removing it returns the workflow to trusting whatever ref a
caller pinned. No consumer migration is involved either way, because the caller side is
unchanged — this is entirely a runtime assertion on the callee.
