# 0106 — Generated changelog publishes the live required context

- **Date:** 2026-08-16
- **Issue:** [#835](https://github.com/Verjson/.github/issues/835)
- **Supersedes:** [ADR 0075](../0075-generated-artifacts-is-the-changelog-check-prefix/README.md) and ADR 0092's changelog context-name choice
- **Category:** Required-check contract / organization policy — **sensitive class**
- **Status:** Accepted

## Context

The active organization ruleset `changelog-contract-required` (20513599)
requires `changelog / validate` on the default branch of repositories whose
`changelog-contract` property is `adopted`. The generated-artifacts caller used
the job key `generated-artifacts`, so GitHub published
`generated-artifacts / validate` instead. The generated adopter contract
accepted that shape even though it could never satisfy the active ruleset.

ADR 0075 selected the generated job name as a future canonical context, but the
live ruleset was not migrated. Changing protection first would require a
fleet-wide transition and would leave existing adopters without their required
check. The reusable workflow already exposes the correct inner `validate` job;
only the generated caller prefix needs to agree with live protection.

## Decision

Every changelog-enabled mode of `scripts/gen-changelog-caller.sh` emits a caller
job named `changelog` that invokes the pinned `generated-artifacts.yml` reusable
workflow with `changelog: true`. GitHub therefore publishes the exact active
required context, `changelog / validate`, while retaining the consolidated
generated-artifacts implementation.

The generated contract test binds the reusable workflow, `changelog: true`, and
the immutable `contract_ref` to that one `changelog` job. A second job with the
right name cannot mask a misnamed reusable caller. Job-level `name`, `strategy`,
matrix, and other check-shaping fields are forbidden. The declared
required-check contract and PyYAML-backed read-only audit validate the same
exact mapping and context as the active ruleset. No organization ruleset
mutation is part of this change.

## Consequences

- A generated-artifacts-only adopter can satisfy current organization
  protection without a temporary second caller or administrator bypass.
- Existing adopters already publishing `changelog / validate` keep satisfying
  the ruleset while they regenerate at the new immutable contract pin.
- Adopters publishing `generated-artifacts / validate` must regenerate; the
  generated contract and central audit reject that stale caller shape.
- `workflow` remains a compatibility command, but it emits the same canonical
  generated-artifacts implementation and required context as the explicit
  generated modes.
