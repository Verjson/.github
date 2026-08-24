# 0128 — Separate generated-contract enforcement from the authorization arm

- **Date:** 2026-08-24
- **Issue:** [#731](https://github.com/Verjson/.github/issues/731)
- **Extends:** [ADR 0092](../0092-stage-generated-changelog-contract-requirement/README.md)
- **Aligns with:** [ADR 0094](../0094-arm-required-by-its-own-property-scoped-ruleset/README.md)
- **Category:** Organization ruleset / branch protection — **sensitive class**
- **Status:** Accepted, rollout blocked on consumer conformance

## Context

ADR 0092 staged the `changelog-contract` requirement behind a frozen-head
read-only audit. At the time, that audit treated `gate` as a universal status
context supplied by the organization workflows rule. ADR 0094 subsequently
moved authorization arming into the property-scoped
`ai-authorization-arm-required` ruleset, whose required workflow publishes the
`arm` job and whose App authorization is a separate authentication decision.

Keeping `gate` in the deterministic required-check declaration now makes the
#731 audit reject otherwise conformant repositories for an obsolete context.
It also incorrectly makes generated-artifact protection depend on the health
and naming of the authorization arm. The live `core-checks-node` ruleset does
not require `gate`, and #731 must add only `changelog-contract` to that ruleset.

The corrected live audit still finds genuine consumer drift. With the obsolete
authorization context excluded, 7 of 22 selected repositories conform and 15
remain nonconformant. Activating the ruleset while those 15 fail would strand
their pull requests on a required context they cannot publish.

## Decision

The required-check contract and its audit contain only deterministic stack and
generated-changelog contexts. Remove the obsolete universal `gate` declaration
and the nonexistent planned `core-checks-universal` status-check ruleset.

Authorization-arm conformance remains governed and audited exclusively by ADR
0094's `ai-authorization-arm-required` ruleset and its dedicated audit. Neither
`gate`, `arm`, nor the App's authorization conclusion can satisfy or block the
`changelog-contract` source and observed-context checks.

The #731 rollout remains staged and fail-closed. It may add
`changelog-contract` to live `core-checks-node` only after every frozen selected
head passes the corrected read-only audit, the canonical files are merged on
the default branch, and the explicit acknowledgement gate is supplied.

## Consequences

- A missing authorization-arm context no longer produces a false #731
  conformance failure.
- Missing, renamed, conditional, stale, or unobserved `changelog-contract`
  jobs continue to fail closed.
- Authorization review cannot be used as evidence for generated-artifact
  integrity, and generated-artifact success cannot authorize a merge.
- The live ruleset is unchanged by this decision. Fifteen selected consumers
  must be repaired before activation.

## Rollback

Revert this change before activation if ADR 0094 is itself superseded by a
reviewed design that once again publishes and requires a universal status
context. Do not reintroduce an authorization context merely to make the #731
audit green, and do not mutate the live ruleset while consumer conformance is
red.
