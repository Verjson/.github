# 0075 — Generated artifacts is the changelog check prefix

- **Date:** 2026-08-07
- **Issue:** [#577](https://github.com/Verjson/.github/issues/577)
- **Supersedes:** ADR 0061's `changelog / validate` context-name decision
- **Extends:** ADR 0038 (canonical changelog contract)
- **Category:** Required-check contract / organization policy — **sensitive class**
- **Status:** Accepted

## Context

The canonical scaffold command is:

```text
scripts/gen-changelog-caller.sh generated-artifacts <contract-sha>
```

It emits a caller job named `generated-artifacts` that delegates to the
`generated-artifacts.yml` reusable workflow's `validate` job. GitHub therefore
reports the exact context `generated-artifacts / validate`.

The plan-only required-check contract still declared `changelog / validate` and
the read-only audit required the caller job to be named `changelog`. A freshly
scaffolded repository could be correct by the generator contract and
nonconformant by the required-check contract at the same time. Requiring the
stale name would create a permanently pending check.

## Decision

`generated-artifacts / validate` is the canonical changelog-validation context
for package repositories:

- Node, UI, and Helm stack contracts declare that context.
- The plan for `changelog-contract-required` declares that context.
- `caller_job_names.generated_artifacts` is `generated-artifacts`; the retired
  `caller_job_names.changelog` key is removed.
- The read-only audit accepts both canonical reusable workflow paths while
  requiring their caller to publish the one canonical job prefix.
- Generator tests pin the generated caller job key, and audit tests exercise
  the exact emitted context and reject a renamed caller.

This commit changes repository-owned declarations, tests, and read-only audit
logic only. It does not mutate a repository custom property, organization
ruleset, enforcement mode, or policy. Any live-property classification or
ruleset migration requires fresh repository-scoped audit evidence and a
separate human authorization gate.

## Consequences

- A repository generated from the current canonical scaffold and classified as
  a package stack can satisfy the central source contract.
- Existing repositories that still emit `changelog / validate` need a generated
  caller migration before any live rule changes.
- During migration, the read-only audit fails closed on either an absent
  `generated-artifacts / validate` context or a noncanonical caller name.
- The contract remains `plan-only` with `mutation_authorized: false`; this
  decision cannot be used as authority to enable enforcement.
