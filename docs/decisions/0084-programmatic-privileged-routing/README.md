# 0084 — Resolve privileged routing programmatically

- **Date:** 2026-08-09
- **Issue:** [Verjson/.github#676](https://github.com/Verjson/.github/issues/676)
- **Corrects:** ADR 0040's assumption that caller `vars` preserve organization authority
- **Extends:** ADR 0036's separation of privileged merge from review execution

## Context

Terminal merge promotion holds `ORG_ADMIN_TOKEN`. Stale generated callers can pass
`runner_labels`, while repository variables shadow organization variables in GitHub's
`vars` context. Reordering a `runs-on` expression therefore cannot make
`VERJSON_LANE_PRIVILEGED` organization-authoritative.

Public visibility is not the threat model. Reusable workflows execute in the caller's
context, external callers use their own capacity, fork heads cannot autonomously merge,
and these repositories are not open-contribution surfaces. The actionable boundary is
reuse of persistent runners after ordinary organization workloads.

GitHub-hosted private compute is currently unavailable. The live privileged variable
remains `["self-hosted","general"]` on DigitalOcean while the routing path is corrected.

## Decision

A checkout-free resolver bootstraps on the explicitly admitted DigitalOcean
`[self-hosted,general]` selector for Verjson; external callers bootstrap on
`ubuntu-24.04` in their own context. The resolver uses a fine-grained PAT
with organization Actions variables read permission only. It reads
`VERJSON_LANE_PRIVILEGED` from `/orgs/Verjson/actions/variables/...`, validates the JSON
selector, and exposes it to the downstream terminal job. The broad merge credential is
not present in the resolver.

Stage one accepts only the current `["self-hosted","general"]` value. This prevents an
accidental hosted or zero-capacity cutover before billing/capacity evidence is wired.
Direct trusted `workflow_dispatch` resolves the organization secret itself; reusable
callers supply the neutral secret mapping.

The reusable secret is named `ACTIONS_VARIABLES_TOKEN`; generated Verjson callers map
`VERJSON_ACTIONS_TOKEN` to it. During caller migration the secret is optional and an
absent token emits no selector, preserving the existing route. Once all privileged
callers are regenerated, a final canonical change will require the token and remove the
legacy expression.

The resolver accepts only the allowlisted `Verjson` owner in this stage. TequityApp is
blocked until `TEQUITY_ACTIONS_TOKEN` and its lane variables are visible and its caller
generator can map the same neutral reusable secret.

## Consequences

- Regenerated callers receive organization policy before caller, FASTLANE, OVERFLOW, or
  repository-variable selectors.
- Existing callers continue working during the bounded migration.
- The read-only token is exposed to the trusted DigitalOcean resolver, but it cannot
  merge, administer repositories, mutate Actions, read secrets, or manage runners.
- The terminal merge remains on persistent `general` until hosted capacity is authorized
  and proven. No automatic fallback to `general` will remain after the migration closes.
