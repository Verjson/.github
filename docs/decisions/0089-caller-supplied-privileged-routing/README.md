# 0089 — Pass privileged routing through the trusted caller

- **Date:** 2026-08-10
- **Issue:** [Verjson/.github#721](https://github.com/Verjson/.github/issues/721)
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
