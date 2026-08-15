# 0089 — Pass privileged routing through the trusted caller

- **Date:** 2026-08-10
- **Issues:** [Verjson/.github#721](https://github.com/Verjson/.github/issues/721),
  [Verjson/.github#676](https://github.com/Verjson/.github/issues/676)
- **Supersedes:** [ADR 0084](../0084-programmatic-privileged-routing/README.md)
- **Extends:** ADR 0036's separation of privileged merge from review execution

## Context

ADR 0084 made the reusable privileged workflow read the organization lane through a
fine-grained PAT. The live `micro-one` canary proved the authorization and exact-head
checks succeeded, then the route read failed with HTTP 403. Terminal repository
administration does not require organization Actions-variable read permission, and
coupling those capabilities made a declarative runner choice a new credential failure
surface.

The generated caller executes only from the target repository's trusted default branch.
It can evaluate the effective `VERJSON_LANE_PRIVILEGED` variable before invoking the
immutable reusable workflow. Repository variables can shadow organization variables, so
the reusable workflow must still treat the supplied value as untrusted routing data.

## Decision

Generated privileged callers pass `vars.VERJSON_LANE_PRIVILEGED` as the
`privileged_lane` workflow input. The canonical checkout-free resolver receives no
credential and accepts exactly `["self-hosted","general"]` for Verjson repositories
before the terminal merge job is scheduled. Missing, malformed, hosted, widened, or
shadowed values fail closed. The resolver's own bootstrap selector remains the same
fixed admitted DigitalOcean lane.

External organizations keep the explicit `runner_labels` escape hatch and do not use
Verjson's lane allowlist. The terminal job alone receives `ORG_ADMIN_TOKEN`; its
maintainer-permission, immutable-workflow, exact-head, arm-receipt, and authorization-App
checks are unchanged.

## Consequences

- Privileged promotion no longer depends on `ACTIONS_VARIABLES_TOKEN` or organization
  variable API permissions.
- A repository-level variable cannot redirect merge authority because only the exact
  admitted selector passes validation.
- A future lane change requires a reviewed canonical allowlist update before callers can
  schedule the terminal job on that lane.
- Existing callers must be regenerated at this contract revision to supply the input.

## 2026-08-14 amendment — repository-bound public hosted stage

The organization-wide lane cannot move yet: current private hosted capacity and budget
evidence does not prove that private privileged continuations remain placeable. The
consumer inventory found 55 active workflow locations: the canonical direct workflow in
`Verjson/.github` and 54 generated callers. Exactly two consuming repositories are
public: `Verjson/.github` and `Verjson/verjson-github-runner`; the other 53 generated
callers are private.

An independent adversarial review rejected a runner-executed resolver: even without a
credential or checkout, a compromised persistent worker could forge its job output and
place the following secret-bearing job back on that worker. Terminal placement therefore
uses GitHub control-plane context directly. The job-level admission expression recognizes
the two exact repository identities only with `public` visibility and the `runs-on`
expression selects exactly `ubuntu-24.04`; no job output participates. Every other
Verjson repository must be an unlisted `private` identity and receives the literal
`["self-hosted","general"]` selector. Unknown public identities, unknown visibility, and
visibility drift skip the terminal job before `ORG_ADMIN_TOKEN` is available. External
organizations retain the existing `runner_labels` portability path.

This is a narrow reversible stage, not the organization-wide cutover. No organization
variable changes, new capacity, or credential changes are authorized by it. The runner
repository must regenerate its caller at the eventual immutable merge revision before
its staged route becomes active, and representative terminal canaries remain required.

Fleet conformance now inventories the canonical direct consumer plus generated caller
files rather than assuming every active repository is a consumer. It verifies secret
scope for both shapes. For a generated caller it proves the pin exists on canonical main,
fetches the historical generator and reusable-workflow interface at that exact pin, and
compares the caller with credentialless historical generation. The audit checkout stays
event-SHA-bound, while an unrelated audit commit no longer makes every unchanged caller
non-canonical. The audit itself is fixed to `ubuntu-24.04`; its privileged read token is
never placed by a repository variable or persistent runner output.
