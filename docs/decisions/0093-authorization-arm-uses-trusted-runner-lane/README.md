# 0093 — Route the authorization arm through the trusted runner lane

- **Date:** 2026-08-11
- **Status:** Accepted
- **Issue:** [#742](https://github.com/Verjson/.github/issues/742)
- **Supersedes:** [ADR 0091](../0091-ruleset-requires-authorization-arm/README.md) only for authorization-arm runner placement
- **Affirms:** [ADR 0040](../0040-runner-lanes-and-admission-axes/README.md), [ADR 0041](../0041-shared-admission-hosted-and-self-hosted/README.md)

## Context

ADR 0091 made `gate-rearm.yml` a deliberate exception to the organization
runner-routing contract by hardcoding `ubuntu-24.04`. A live label event in
`Verjson/renovate-config#14` proved that this bypasses the configured Verjson
fleet: GitHub rejected the hosted job at admission for account billing while
the organization’s trusted and fallback lane variables both selected available
self-hosted general capacity.

The arm is trusted control-plane work. It loads only the base-branch workflow,
does not check out pull-request code, consumes the authorization App credential,
and writes the exact-head receipt. Its placement therefore belongs to the
trusted lane, not to an immutable provider label.

## Decision

Route the arm through the standard organization-variable chain:

```yaml
runs-on: ${{ fromJSON(vars.VERJSON_LANE_TRUSTED || vars.VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]') }}
```

`VERJSON_LANE_TRUSTED` names the work’s trust class. `VERJSON_LANE_FALLBACK`
keeps fleet placement centrally switchable when the specific lane is unset.
The terminal hosted selector remains only the reusable-workflow portability
tail for organizations that define neither variable; it is not the Verjson
route while the organization variables exist.

Remove the gate-specific exceptions from the runner policy test. The required
workflow rollout audit must verify the complete trusted-lane expression rather
than a provider label. `continue-on-error`, the five-minute timeout, receipt
checks, App identity, permissions, and the non-vetoing human path do not change.

## Consequences

- Verjson can move the authorization arm between admitted fleets through
  organization variables without changing or repinning workflow code.
- A hosted billing failure cannot override an available configured trusted or
  fallback lane.
- External reuse remains portable when no organization lane variables exist.
- A fully unavailable selected self-hosted fleet can still queue the arm; fleet
  health and admission monitoring remain the operational control for that case.

## Rollback

Repoint `VERJSON_LANE_TRUSTED` or `VERJSON_LANE_FALLBACK` to known-good capacity.
Do not restore a hardcoded hosted or self-hosted label. Reverting the workflow
requires a new decision explaining why central lane routing is no longer the
organization contract.
