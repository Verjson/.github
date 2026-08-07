# 0073 — The required Node CI context always reports

- **Date:** 2026-08-07
- **Issue:** [#191](https://github.com/Verjson/.github/issues/191)
- **Supersedes in part:** [ADR 0058](../0058-github-waits-for-checks-not-the-gate/README.md)
- **Extends:** [ADR 0023](../0023-skip-ci-while-stability-days-pending/README.md)
- **Category:** CI policy
- **Status:** Accepted

## Context

ADR 0023 defers expensive Node CI while Renovate's release-age status is
pending. The reusable workflow implemented that optimization by putting the
eligibility decision on the `build-test` job itself. A defer therefore produced
`ci / eligibility = success` and `ci / build-test = skipped`.

Verjson/verjson-cli#97 demonstrated that this is not a safe required-check
contract. Its digest-only Renovate update emitted the skipped `ci / build-test`
check, but ruleset 18099719 still left the required context unsatisfied. The
merge gate also deferred the PR, so the update remained wedged until an
administrator merged it.

ADR 0058 later generalized that a conditional job's `skipped` conclusion
satisfies a required check. The observed Node workflow contradicts that
assumption. A required context must report success on an intentional no-op
rather than relying on GitHub's treatment of `skipped`.

## Decision

The `build-test` job always starts with `if: always()`, preserving the required
`ci / build-test` context on every reusable workflow run.

When eligibility explicitly returns `should-run=false`, the job runs one
trusted notice step and succeeds. Checkout, setup, installs, build, tests,
lint, database lifecycle, and cache upload all remain suppressed. No consumer
code or dependency executes on the deferred path.

Every executable step uses the fail-open predicate
`needs.eligibility.outputs.should-run != 'false'`. An eligibility failure
produces an empty output, so the complete suite still runs. Existing input
conditions are conjunctive with that predicate, and cleanup retains `always()`
while still refusing to run on the deferred path.

The merge-safety boundary from ADR 0023 is unchanged: the merge gate's defer
lane and Renovate's own release-age policy keep the held PR unmerged. The green
no-op context only prevents a required-check deadlock.

## Consequences

- `ci / build-test` is present and successful during an intentional defer.
- Deferred Renovate PRs consume one short runner assignment for the notice job,
  but do not check out or execute their branch.
- Normal, manually dispatched, and eligibility-error paths execute the same
  suite as before.
- Required-check policy no longer depends on whether GitHub counts `skipped`
  as satisfying a context.
- Other stacks must prove their own no-op required contexts; this decision does
  not claim that every skipped job in every workflow is unsafe.

## Rejected alternatives

- **Keep relying on `skipped`.** The concrete #97 ruleset outcome disproves that
  as a portable invariant.
- **Exclude digest-only changes from eligibility.** The defect is the missing
  success result, not the dependency-update subtype; other held Renovate PRs
  can encounter the same required context.
- **Teach the merge gate to bypass the ruleset.** That weakens the enforcement
  boundary and leaves human merges wedged.
- **Add a second job with the same displayed context.** Duplicate check names
  make provenance ambiguous. One always-reporting job keeps one authority.
