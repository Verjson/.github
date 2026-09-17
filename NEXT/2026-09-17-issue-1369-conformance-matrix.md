---
date: 2026-09-17
issue: 1369
title: The contract is exercised against synthetic adopters before it is published
impact: minor
---

A reusable workflow is only ever exercised by real callers, after publication,
so a contract defect reaches every adopter before anyone is positioned to see
it. `Verjson/verjson-ci#184` is the worked example: `node-ci.yml` shipped in a
state where a deferred head reported the required `ci / build-test` context
SUCCESS having executed no test, lint, type check, or repository-local contract
guard. It was green the whole time.

`scripts/ci-gate/conformance/` closes that gap at the hub. Synthetic adopters
under `adopters/` are ordinary caller workflows — the shape a real repository
commits — and the harness statically models what the contract does when each
one calls it under a given scenario: which jobs run, which steps execute, and
what conclusion each job contributes to the caller's check rollup.

Every case asserts **positive evidence of execution**, never absence of red. A
suite that only asserts "the run was green" reproduces the exact defect it
exists to prevent. Concretely:

- A deferred head must publish a rollup entry whose conclusion is outside the
  set a merge gate accepts, not merely skip its work quietly.
- A lane that runs must execute a step from a registered work-step set, and a
  separate assertion requires every registered step to still exist in the
  contract — an evidence list that silently stops matching is worse than none.
- `regressions/node-ci-pre-adr-0178.yml` is the contract as it stood when #184
  shipped, checked in as a counter-example, and the matrix asserts the deferral
  property **fails** against it. A regression test that passes against the
  defective contract proves nothing.

Two properties of the harness matter as much as the cases. It fails closed:
a guard reading a context the scenario does not bind raises, and an expression
construct the evaluator does not implement raises, rather than evaluating to
false — a model that guesses reports every guarded step as skipped and asserts
nothing while looking thorough, which is the same shape of failure again. And
input bindings are derived from the fixture callers rather than hand-written,
so removing or renaming a `workflow_call` input fails here instead of in a
hundred adopter builds. That already earned itself: `node-ci-protected.yml`
requires three inputs `node-ci.yml` does not, which is why it has its own
fixture.

Step 3 of the contract-distribution sequence in ADR 0185. The matrix covers
`node-ci.yml` and `node-ci-protected.yml`; extending it to the generated
adopter set and the remaining reusable workflows is follow-up work.
